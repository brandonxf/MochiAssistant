//! Daemon: guarda el estado de las sesiones y lo difunde a la UI de Quickshell.
//! También aloja el chat con la API de Anthropic y la configuración de la isla.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::process::Command;
use tokio::sync::{Notify, broadcast, oneshot};

const MAX_ACTIVITY: usize = 12;
const MAX_TRANSCRIPT: usize = 200;
const MAX_GRAB: usize = 50_000;
/// Marca interna para distinguir una cancelación del usuario de un error real.
const CANCELLED: &str = "\u{0}cancelled";
const MAX_HISTORY: usize = 24;
const MAX_TEXT_FILE: usize = 100_000;
const MAX_IMAGE_BYTES: u64 = 5 * 1024 * 1024;
const DEFAULT_MODEL: &str = "claude-sonnet-5-5";
const FALLBACK_MODELS: [&str; 4] =
    ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001", "claude-fable-5-1"];
const SYSTEM_PROMPT: &str = "Eres Mochi, el ajolote de la isla de Quickshell: un compañero breve y amable. \
Responde en el idioma del usuario, de forma concisa.";

// ---------------------------------------------------------------- estado

struct Step {
    tool: String,
    summary: String,
    ts: u64,
}

struct Session {
    agent: String,
    cwd: String,
    status: &'static str,
    last_tool: String,
    updated: u64,
    activity: VecDeque<Step>,
    /// PID del hook y de sus ancestros: uno de ellos es el de la terminal (para saltar a su ventana).
    pids: Vec<u32>,
    /// Último fallo del turno (tipo, mensaje) si `status == "error"`.
    error: Option<(String, String)>,
}

struct Pending {
    session_id: String,
    agent: String,
    tool: String,
    summary: String,
    /// "permission" o "question" (la herramienta AskUserQuestion).
    kind: &'static str,
    questions: Value,
    /// Texto de la regla que se guardaría con "siempre permitir"; `None` si no hay sugerencia.
    always_label: Option<String>,
    tx: oneshot::Sender<Value>,
}

#[derive(Default)]
struct State {
    sessions: HashMap<String, Session>,
    pending: HashMap<String, Pending>,
    next_id: u64,
}

impl State {
    fn snapshot(&self) -> String {
        let mut sessions: Vec<_> = self
            .sessions
            .iter()
            .map(|(id, s)| {
                let activity: Vec<_> = s
                    .activity
                    .iter()
                    .map(|a| json!({ "tool": a.tool, "summary": a.summary, "ts": a.ts }))
                    .collect();
                json!({ "id": id, "agent": s.agent, "cwd": s.cwd, "status": s.status,
                        "last_tool": s.last_tool, "updated": s.updated, "activity": activity,
                        "error_type": s.error.as_ref().map(|e| e.0.clone()),
                        "error_message": s.error.as_ref().map(|e| e.1.clone()) })
            })
            .collect();
        sessions.sort_by_key(|s| s["id"].as_str().unwrap_or("").to_string());
        let pending: Vec<_> = self
            .pending
            .iter()
            .map(|(id, p)| {
                json!({ "id": id, "session_id": p.session_id, "agent": p.agent,
                        "tool": p.tool, "summary": p.summary, "kind": p.kind,
                        "questions": p.questions, "always_label": p.always_label })
            })
            .collect();
        json!({ "type": "state", "sessions": sessions, "pending": pending }).to_string()
    }
}

// ---------------------------------------------------------------- configuración

struct Config {
    api_key: String,
    model: String,
    /// "subscription" (por defecto): usa el CLI `claude` con la suscripción del usuario.
    /// "api": llama a la API de Anthropic con `api_key`.
    backend: String,
    sound: bool,
    volume: f64,
    /// Accesorios de Mochi, por ranura (ver HEADS / FACES / NECKS) y su color ("auto" o "#rrggbb").
    head: String,
    face: String,
    neck: String,
    acc_color: String,
    /// Dónde se ancla la isla: "right" (esquina) o "center".
    position: String,
    /// Minutos sin actividad antes de dormirse (0 = nunca).
    sleep_minutes: u32,
    /// Si Mochi baila cuando suena música.
    dance: bool,
    pomo_work: u32,
    pomo_break: u32,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            api_key: String::new(),
            model: DEFAULT_MODEL.into(),
            backend: "subscription".into(),
            sound: true,
            volume: 0.5,
            head: "none".into(),
            face: "none".into(),
            neck: "none".into(),
            acc_color: "auto".into(),
            position: "right".into(),
            sleep_minutes: 10,
            dance: true,
            pomo_work: 25,
            pomo_break: 5,
        }
    }
}

const HEADS: [&str; 11] =
    ["none", "beanie", "crown", "bow", "tophat", "catears", "halo", "horns", "cap", "wizard", "flower"];
const FACES: [&str; 5] = ["none", "glasses", "sunglasses", "monocle", "mustache"];
const NECKS: [&str; 4] = ["none", "scarf", "bowtie", "bell"];

/// "auto" (el color propio de cada accesorio) o un color "#rrggbb".
fn valid_color(c: &str) -> bool {
    c == "auto" || (c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|h| h.is_ascii_hexdigit()))
}

fn config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("axolotl-notch").join("config.json")
}

impl Config {
    fn load() -> Config {
        let mut c = Config::default();
        let Ok(text) = std::fs::read_to_string(config_path()) else { return c };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { return c };
        if let Some(k) = v["api_key"].as_str() {
            c.api_key = k.to_string();
        }
        if let Some(m) = v["model"].as_str().filter(|m| !m.is_empty()) {
            c.model = m.to_string();
        }
        if let Some(b) = v["backend"].as_str().filter(|b| matches!(*b, "subscription" | "api")) {
            c.backend = b.to_string();
        }
        if let Some(b) = v["sound"].as_bool() {
            c.sound = b;
        }
        if let Some(x) = v["volume"].as_f64() {
            c.volume = x.clamp(0.0, 1.0);
        }
        // Migración del ajuste antiguo de un solo accesorio.
        match v["accessory"].as_str() {
            Some(a @ ("beanie" | "crown" | "bow")) => c.head = a.to_string(),
            Some("glasses") => c.face = "glasses".into(),
            _ => {}
        }
        if let Some(a) = v["head"].as_str().filter(|a| HEADS.contains(a)) {
            c.head = a.to_string();
        }
        if let Some(a) = v["face"].as_str().filter(|a| FACES.contains(a)) {
            c.face = a.to_string();
        }
        if let Some(a) = v["neck"].as_str().filter(|a| NECKS.contains(a)) {
            c.neck = a.to_string();
        }
        if let Some(a) = v["acc_color"].as_str().filter(|a| valid_color(a)) {
            c.acc_color = a.to_string();
        }
        if let Some(p) = v["position"].as_str().filter(|p| matches!(*p, "right" | "center")) {
            c.position = p.to_string();
        }
        if let Some(m) = v["sleep_minutes"].as_u64() {
            c.sleep_minutes = m.min(240) as u32;
        }
        if let Some(b) = v["dance"].as_bool() {
            c.dance = b;
        }
        if let Some(m) = v["pomo_work"].as_u64().filter(|m| (1..=180).contains(m)) {
            c.pomo_work = m as u32;
        }
        if let Some(m) = v["pomo_break"].as_u64().filter(|m| (1..=180).contains(m)) {
            c.pomo_break = m as u32;
        }
        c
    }

    fn save(&self) {
        let path = config_path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let body = json!({ "api_key": self.api_key, "model": self.model, "backend": self.backend,
                           "sound": self.sound, "volume": self.volume, "head": self.head,
                           "face": self.face, "neck": self.neck, "acc_color": self.acc_color,
                           "position": self.position, "sleep_minutes": self.sleep_minutes,
                           "dance": self.dance, "pomo_work": self.pomo_work, "pomo_break": self.pomo_break });
        // La clave de API vive aquí: solo legible por el usuario.
        let _ = write_private(&path, body.to_string().as_bytes());
    }

    fn message(&self) -> String {
        json!({ "type": "config", "has_key": !self.api_key.is_empty(), "model": self.model,
                "backend": self.backend, "sound": self.sound, "volume": self.volume,
                "head": self.head, "face": self.face, "neck": self.neck, "acc_color": self.acc_color,
                "position": self.position,
                "sleep_minutes": self.sleep_minutes, "dance": self.dance,
                "pomo_work": self.pomo_work, "pomo_break": self.pomo_break })
        .to_string()
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(bytes)
}

#[derive(Default)]
struct Chat {
    /// Historial del backend "api" (el CLI guarda el suyo en su sesión).
    history: Vec<Value>,
    /// Sesión de `claude` en curso (backend "subscription"); `None` hasta el primer turno.
    session: Option<String>,
    busy: bool,
    /// Conversación tal como se ve en la isla (rol, texto); se guarda en disco entre reinicios.
    transcript: Vec<(String, String)>,
    /// Texto de la respuesta en curso (para conservarlo si se cancela).
    partial: String,
}

fn data_dir() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("axolotl-notch")
}

impl Chat {
    fn load() -> Chat {
        let mut chat = Chat::default();
        let Ok(text) = std::fs::read_to_string(data_dir().join("history.json")) else { return chat };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { return chat };
        chat.session = v["session"].as_str().map(String::from);
        for m in v["messages"].as_array().into_iter().flatten() {
            let (role, text) = (str_of(&m["role"]), str_of(&m["text"]));
            if !role.is_empty() {
                chat.transcript.push((role, text));
            }
        }
        // El backend "api" retoma la conversación desde el texto guardado.
        for (role, text) in &chat.transcript {
            chat.history.push(json!({ "role": role, "content": text }));
        }
        chat
    }

    fn save(&self) {
        let dir = data_dir();
        let _ = std::fs::create_dir_all(&dir);
        let body = json!({ "session": self.session, "messages": self.messages_json() });
        let _ = std::fs::write(dir.join("history.json"), body.to_string());
    }

    fn messages_json(&self) -> Vec<Value> {
        self.transcript.iter().map(|(r, t)| json!({ "role": r, "text": t })).collect()
    }

    fn trim(&mut self) {
        let excess = self.transcript.len().saturating_sub(MAX_TRANSCRIPT);
        self.transcript.drain(..excess);
    }
}

// ---------------------------------------------------------------- recordatorios y pomodoro

struct Reminder {
    id: u64,
    label: String,
    at: u64,
}

#[derive(Default)]
struct Pomo {
    running: bool,
    /// "work" o "break"
    phase: String,
    ends_at: u64,
    cycle: u32,
}

#[derive(Default)]
struct Timers {
    reminders: Vec<Reminder>,
    pomo: Pomo,
    next_id: u64,
}

impl Timers {
    fn load() -> Timers {
        let mut t = Timers::default();
        let Ok(text) = std::fs::read_to_string(data_dir().join("timers.json")) else { return t };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { return t };
        for r in v["reminders"].as_array().into_iter().flatten() {
            if let (Some(id), Some(at)) = (r["id"].as_u64(), r["at"].as_u64()) {
                t.next_id = t.next_id.max(id);
                t.reminders.push(Reminder { id, label: str_of(&r["label"]), at });
            }
        }
        let p = &v["pomo"];
        t.pomo = Pomo {
            running: p["running"].as_bool().unwrap_or(false),
            phase: p["phase"].as_str().unwrap_or("work").to_string(),
            ends_at: p["ends_at"].as_u64().unwrap_or(0),
            cycle: p["cycle"].as_u64().unwrap_or(0) as u32,
        };
        t
    }

    fn save(&self) {
        let dir = data_dir();
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("timers.json"), self.state_json().to_string());
    }

    fn state_json(&self) -> Value {
        let reminders: Vec<_> =
            self.reminders.iter().map(|r| json!({ "id": r.id, "label": r.label, "at": r.at })).collect();
        json!({ "reminders": reminders,
                "pomo": { "running": self.pomo.running, "phase": self.pomo.phase,
                          "ends_at": self.pomo.ends_at, "cycle": self.pomo.cycle } })
    }
}

struct Shared {
    state: Mutex<State>,
    config: Mutex<Config>,
    chat: Mutex<Chat>,
    timers: Mutex<Timers>,
    cancel: Notify,
    tx: broadcast::Sender<String>,
}

impl Shared {
    fn publish(&self) {
        let snap = self.state.lock().unwrap().snapshot();
        let _ = self.tx.send(snap);
    }

    fn send(&self, msg: Value) {
        let _ = self.tx.send(msg.to_string());
    }

    fn publish_config(&self) {
        let msg = self.config.lock().unwrap().message();
        let _ = self.tx.send(msg);
    }

    fn timers_message(&self) -> String {
        let (state, work, brk) = {
            let c = self.config.lock().unwrap();
            (self.timers.lock().unwrap().state_json(), c.pomo_work, c.pomo_break)
        };
        let mut msg = state;
        msg["type"] = json!("timers");
        msg["now"] = json!(now());
        msg["pomo"]["work_min"] = json!(work);
        msg["pomo"]["break_min"] = json!(brk);
        msg.to_string()
    }

    fn publish_timers(&self) {
        let _ = self.tx.send(self.timers_message());
    }

    fn history_message(&self) -> String {
        let chat = self.chat.lock().unwrap();
        json!({ "type": "chat_history", "messages": chat.messages_json() }).to_string()
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn str_of(v: &Value) -> String {
    v.as_str().unwrap_or("").to_string()
}

/// Resumen corto de lo que la herramienta quiere hacer.
fn summarize(tool: &str, input: &Value) -> String {
    let key = match tool {
        "Bash" | "run_shell_command" => "command",
        "Edit" | "Write" | "Read" | "MultiEdit" | "read_file" | "write_file" | "replace" => {
            "file_path"
        }
        "Grep" | "Glob" => "pattern",
        _ => "",
    };
    let s = input[key].as_str().map(str::to_string).unwrap_or_else(|| {
        if input.is_null() { String::new() } else { input.to_string() }
    });
    s.chars().take(200).collect()
}

/// Actualiza la sesión; devuelve `true` si el agente acaba de terminar un turno de trabajo.
fn touch_session(shared: &Shared, msg: &Value) -> bool {
    let event = str_of(&msg["event"]);
    let id = str_of(&msg["session_id"]);
    if id.is_empty() {
        return false;
    }
    let mut st = shared.state.lock().unwrap();
    if event == "SessionEnd" {
        st.sessions.remove(&id);
        return false;
    }
    let Some(status) = axolotl_notch::status_for_event(&event) else {
        return false;
    };
    let s = st.sessions.entry(id).or_insert_with(|| Session {
        agent: str_of(&msg["agent"]),
        cwd: String::new(),
        status: "idle",
        last_tool: String::new(),
        updated: 0,
        activity: VecDeque::new(),
        pids: Vec::new(),
        error: None,
    });
    let finished = axolotl_notch::is_turn_end(&event) && s.status == "working";
    s.status = status;
    s.updated = now();
    if let Some(pids) = msg["pids"].as_array() {
        s.pids = pids.iter().filter_map(|p| p.as_u64().map(|p| p as u32)).collect();
    }
    // Un fallo del turno queda hasta que el agente vuelva a hacer algo.
    s.error = if event == "StopFailure" {
        Some((str_of(&msg["error_type"]), str_of(&msg["error_message"])))
    } else {
        None
    };
    if let Some(cwd) = msg["cwd"].as_str() {
        s.cwd = cwd.to_string();
    }
    if let Some(tool) = msg["tool"].as_str() {
        s.last_tool = tool.to_string();
        if axolotl_notch::is_tool_start(&event) {
            s.activity.push_back(Step {
                tool: tool.to_string(),
                summary: summarize(tool, &msg["input"]),
                ts: now(),
            });
            while s.activity.len() > MAX_ACTIVITY {
                s.activity.pop_front();
            }
        }
    }
    finished
}

// ---------------------------------------------------------------- chat

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18 & 63) as usize] as char);
        out.push(T[(n >> 12 & 63) as usize] as char);
        out.push(if c.len() > 1 { T[(n >> 6 & 63) as usize] as char } else { '=' });
        out.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn image_media_type(path: &Path) -> Option<&'static str> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

/// Convierte los archivos adjuntos en bloques de contenido de la API.
fn file_blocks(files: &[String]) -> Vec<Value> {
    let mut blocks = Vec::new();
    for f in files {
        let path = Path::new(f);
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("archivo");
        if let Some(media) = image_media_type(path) {
            match std::fs::metadata(path) {
                Ok(m) if m.len() <= MAX_IMAGE_BYTES => {
                    if let Ok(bytes) = std::fs::read(path) {
                        blocks.push(json!({ "type": "image", "source": {
                            "type": "base64", "media_type": media, "data": base64(&bytes) } }));
                    }
                }
                _ => blocks.push(json!({ "type": "text",
                    "text": format!("[La imagen {name} supera 5 MB y no se adjuntó]") })),
            }
            continue;
        }
        match std::fs::read(path) {
            Ok(bytes) if !bytes.contains(&0) => {
                let text = String::from_utf8_lossy(&bytes);
                let clipped: String = text.chars().take(MAX_TEXT_FILE).collect();
                blocks.push(json!({ "type": "text",
                    "text": format!("Archivo `{name}`:\n```\n{clipped}\n```") }));
            }
            Ok(_) => blocks.push(json!({ "type": "text",
                "text": format!("[El archivo {name} es binario y no se adjuntó]") })),
            Err(_) => {}
        }
    }
    blocks
}

/// Base de la API; se puede cambiar con AXOLOTL_API_BASE (pruebas con un servidor falso).
fn api_base() -> String {
    std::env::var("AXOLOTL_API_BASE").unwrap_or_else(|_| "https://api.anthropic.com".into())
}

fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// Config de curl en un archivo 0600: así la clave no aparece en `ps`.
fn curl_config(key: &str, extra: &str) -> String {
    let key = key.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "header = \"x-api-key: {key}\"\nheader = \"anthropic-version: 2023-06-01\"\n\
         header = \"content-type: application/json\"\n{extra}"
    )
}

fn api_error(v: &Value) -> String {
    let msg = v["error"]["message"].as_str().unwrap_or("error de la API");
    if v["error"]["type"] == "not_found_error" {
        format!("Modelo no encontrado. Elige otro. ({msg})")
    } else {
        msg.to_string()
    }
}

async fn list_models(shared: Arc<Shared>) {
    let key = shared.config.lock().unwrap().api_key.clone();
    let mut models: Vec<String> = Vec::new();
    if !key.is_empty() {
        let cfg_path = runtime_dir().join("axolotl-models.curl");
        let cfg = curl_config(&key, &format!("url = \"{}/v1/models?limit=100\"\n", api_base()));
        if write_private(&cfg_path, cfg.as_bytes()).is_ok() {
            let out = Command::new("curl")
                .args(["-sS", "--max-time", "15", "--config"])
                .arg(&cfg_path)
                .stderr(Stdio::null())
                .output()
                .await;
            let _ = std::fs::remove_file(&cfg_path);
            if let Ok(out) = out {
                if let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) {
                    models = v["data"]
                        .as_array()
                        .map(|a| a.iter().filter_map(|m| m["id"].as_str().map(String::from)).collect())
                        .unwrap_or_default();
                }
            }
        }
    }
    if models.is_empty() {
        models = FALLBACK_MODELS.iter().map(|m| m.to_string()).collect();
    }
    shared.send(json!({ "type": "models", "models": models }));
}

/// Datos de un mensaje del chat: `display` es lo que se ve en la isla (con los nombres de adjuntos),
/// `contexts` son fragmentos de texto (portapapeles, selección) que se añaden al mensaje.
struct ChatInput {
    text: String,
    display: String,
    files: Vec<String>,
    contexts: Vec<(String, String)>,
}

/// Fragmentos de contexto como bloques de texto para el modelo.
fn context_blocks(contexts: &[(String, String)]) -> Vec<Value> {
    contexts
        .iter()
        .map(|(label, text)| {
            let clipped: String = text.chars().take(MAX_TEXT_FILE).collect();
            json!({ "type": "text", "text": format!("{label}:\n```\n{clipped}\n```") })
        })
        .collect()
}

async fn chat_turn(shared: Arc<Shared>, input: ChatInput) {
    let (key, model, backend) = {
        let c = shared.config.lock().unwrap();
        (c.api_key.clone(), c.model.clone(), c.backend.clone())
    };
    if backend == "api" && key.is_empty() {
        shared.send(json!({ "type": "chat_error", "message": "Falta la clave de API de Anthropic." }));
        return;
    }
    {
        let mut chat = shared.chat.lock().unwrap();
        if chat.busy {
            return;
        }
        chat.busy = true;
        chat.partial.clear();
        let display = if input.display.is_empty() { input.text.clone() } else { input.display.clone() };
        chat.transcript.push(("user".into(), display));
    }

    // El botón de parar avisa por `cancel`; al descartar el futuro se mata el proceso (kill_on_drop).
    let work = async {
        if backend == "api" {
            api_turn(&shared, &key, &model, &input).await
        } else {
            cli_turn(&shared, &model, &input).await
        }
    };
    let reply = tokio::select! {
        r = work => r,
        _ = shared.cancel.notified() => Err(CANCELLED.to_string()),
    };

    let mut chat = shared.chat.lock().unwrap();
    chat.busy = false;
    let event = match reply {
        Ok(answer) if !answer.is_empty() => {
            chat.transcript.push(("assistant".into(), answer));
            json!({ "type": "chat_done" })
        }
        Ok(_) => {
            chat.transcript.pop();
            json!({ "type": "chat_error", "message": "Respuesta vacía." })
        }
        Err(e) if e == CANCELLED => {
            if backend == "api" {
                chat.history.pop(); // el mensaje del usuario que api_turn dejó puesto
            }
            let partial = std::mem::take(&mut chat.partial);
            if partial.is_empty() {
                chat.transcript.pop();
            } else {
                chat.transcript.push(("assistant".into(), format!("{partial}\n\n_(detenido)_")));
            }
            json!({ "type": "chat_cancelled" })
        }
        Err(message) => {
            chat.transcript.pop();
            json!({ "type": "chat_error", "message": message })
        }
    };
    chat.trim();
    chat.save();
    drop(chat);
    shared.send(event);
}

/// Turno por la API de Anthropic con el historial guardado aquí.
async fn api_turn(shared: &Arc<Shared>, key: &str, model: &str, input: &ChatInput) -> Result<String, String> {
    {
        let mut chat = shared.chat.lock().unwrap();
        let mut content = context_blocks(&input.contexts);
        content.extend(file_blocks(&input.files));
        content.push(json!({ "type": "text", "text": input.text }));
        chat.history.push(json!({ "role": "user", "content": content }));
        let excess = chat.history.len().saturating_sub(MAX_HISTORY);
        chat.history.drain(..excess);
        // La conversación debe empezar con un mensaje de usuario.
        while chat.history.first().is_some_and(|m| m["role"] != "user") {
            chat.history.remove(0);
        }
    }
    let reply = run_chat_request(shared, key, model).await;
    let mut chat = shared.chat.lock().unwrap();
    match &reply {
        Ok(answer) if !answer.is_empty() => {
            chat.history.push(json!({ "role": "assistant", "content": answer }));
        }
        _ => {
            chat.history.pop();
        }
    }
    reply
}

fn new_uuid() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/uuid")
        .map(|u| u.trim().to_string())
        .unwrap_or_else(|_| format!("{:032x}", now() as u128 * 2654435761))
}

fn chat_dir() -> PathBuf {
    data_dir().join("chat")
}

/// Turno usando el CLI `claude` con la suscripción del usuario. Se lanza en modo no interactivo,
/// sin herramientas (solo conversación) y con su propia carpeta de sesiones.
async fn cli_turn(shared: &Arc<Shared>, model: &str, input: &ChatInput) -> Result<String, String> {
    // Sin herramientas el modelo no puede leer archivos: se incluyen en el propio mensaje.
    let mut prompt = String::new();
    let mut blocks = context_blocks(&input.contexts);
    blocks.extend(file_blocks(&input.files));
    for block in blocks {
        if let Some(t) = block["text"].as_str() {
            prompt.push_str(t);
            prompt.push_str("\n\n");
        } else if block["type"] == "image" {
            prompt.push_str("[Hay una imagen adjunta; el modo suscripción aún no envía imágenes]\n\n");
        }
    }
    prompt.push_str(&input.text);

    let (session, resume) = {
        let chat = shared.chat.lock().unwrap();
        match &chat.session {
            Some(s) => (s.clone(), true),
            None => (new_uuid(), false),
        }
    };
    let dir = chat_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    let mut cmd = Command::new("claude");
    cmd.args(["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
        .args(["--tools", "", "--setting-sources", "", "--system-prompt", SYSTEM_PROMPT])
        .args(["--model", model])
        .args([if resume { "--resume" } else { "--session-id" }, &session])
        .current_dir(&dir)
        // Que el hook de la isla ignore esta sesión (si no, el chat aparecería como un agente más).
        .env("AXOLOTL_IGNORE", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd.spawn().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "No encuentro el comando `claude`. Instala Claude Code o cambia a la API.".to_string()
        } else {
            format!("No se pudo ejecutar claude: {e}")
        }
    })?;
    // El mensaje va por stdin (puede incluir archivos largos, que no caben como argumento).
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes()).await;
    }
    let stdout = child.stdout.take().ok_or("sin salida de claude")?;
    let mut stderr = child.stderr.take();
    let mut lines = BufReader::new(stdout).lines();
    let mut answer = String::new();
    let mut error: Option<String> = None;

    let read = async {
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            match v["type"].as_str() {
                Some("stream_event")
                    if v["event"]["type"] == "content_block_delta" && v["event"]["delta"]["type"] == "text_delta" =>
                {
                    if let Some(t) = v["event"]["delta"]["text"].as_str() {
                        answer.push_str(t);
                        shared.chat.lock().unwrap().partial.push_str(t);
                        shared.send(json!({ "type": "chat_delta", "text": t }));
                    }
                }
                Some("result") if v["is_error"] == true => {
                    error = Some(v["result"].as_str().unwrap_or("error de Claude").to_string());
                }
                _ => {}
            }
        }
    };
    if tokio::time::timeout(std::time::Duration::from_secs(300), read).await.is_err() {
        return Err("Claude tardó demasiado en responder.".into());
    }
    let status = child.wait().await.map_err(|e| e.to_string())?;
    if let Some(e) = error {
        if !resume {
            // La sesión no llegó a crearse: el próximo turno vuelve a empezar de cero.
            shared.chat.lock().unwrap().session = None;
        }
        return Err(e);
    }
    if answer.is_empty() && !status.success() {
        use tokio::io::AsyncReadExt;
        let mut err = String::new();
        if let Some(se) = stderr.as_mut() {
            let _ = se.read_to_string(&mut err).await;
        }
        let err = err.trim();
        return Err(if err.is_empty() { "Claude terminó con error.".into() } else { err.chars().take(300).collect() });
    }
    shared.chat.lock().unwrap().session = Some(session);
    Ok(answer)
}

async fn run_chat_request(shared: &Arc<Shared>, key: &str, model: &str) -> Result<String, String> {
    let messages = shared.chat.lock().unwrap().history.clone();
    let body = json!({ "model": model, "max_tokens": 2048, "stream": true,
                       "system": SYSTEM_PROMPT, "messages": messages });
    let dir = runtime_dir();
    let body_path = dir.join("axolotl-chat-body.json");
    let cfg_path = dir.join("axolotl-chat.curl");
    write_private(&body_path, body.to_string().as_bytes()).map_err(|e| e.to_string())?;
    let cfg = curl_config(
        key,
        &format!(
            "url = \"{}/v1/messages\"\ndata-binary = \"@{}\"\n",
            api_base(),
            body_path.display()
        ),
    );
    write_private(&cfg_path, cfg.as_bytes()).map_err(|e| e.to_string())?;

    let result = stream_curl(shared, &cfg_path).await;
    let _ = std::fs::remove_file(&body_path);
    let _ = std::fs::remove_file(&cfg_path);
    result
}

async fn stream_curl(shared: &Arc<Shared>, cfg_path: &Path) -> Result<String, String> {
    let mut child = Command::new("curl")
        .args(["-sS", "-N", "--max-time", "180", "--config"])
        .arg(cfg_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("No se pudo ejecutar curl: {e}"))?;
    let stdout = child.stdout.take().ok_or("sin salida de curl")?;
    let mut lines = BufReader::new(stdout).lines();
    let mut answer = String::new();
    let mut error: Option<String> = None;

    while let Ok(Some(line)) = lines.next_line().await {
        // Errores fuera del flujo SSE llegan como un JSON suelto.
        let payload = line.strip_prefix("data: ").unwrap_or(&line);
        let Ok(v) = serde_json::from_str::<Value>(payload) else { continue };
        match v["type"].as_str() {
            Some("error") => error = Some(api_error(&v)),
            Some("content_block_delta") if v["delta"]["type"] == "text_delta" => {
                if let Some(t) = v["delta"]["text"].as_str() {
                    answer.push_str(t);
                    shared.chat.lock().unwrap().partial.push_str(t);
                    shared.send(json!({ "type": "chat_delta", "text": t }));
                }
            }
            _ => {}
        }
    }
    let status = child.wait().await.map_err(|e| e.to_string())?;
    if let Some(e) = error {
        return Err(e);
    }
    if answer.is_empty() && !status.success() {
        return Err("No se pudo conectar con la API de Anthropic.".into());
    }
    Ok(answer)
}

// ---------------------------------------------------------------- portapapeles, terminal y relojes

/// Lee el portapapeles o la selección primaria con `wl-paste` y lo manda a la isla.
async fn grab(shared: Arc<Shared>, what: String) {
    let mut cmd = Command::new("wl-paste");
    cmd.arg("-n");
    if what == "primary" {
        cmd.arg("-p");
    }
    cmd.stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(std::time::Duration::from_secs(3), cmd.output()).await;
    let text = match out {
        Ok(Ok(o)) if o.status.success() => String::from_utf8_lossy(&o.stdout).chars().take(MAX_GRAB).collect(),
        _ => String::new(),
    };
    shared.send(json!({ "type": "grabbed", "what": what, "text": text }));
}

/// Enfoca la ventana de la terminal de una sesión: alguno de los ancestros del hook es el proceso
/// de la ventana que Hyprland lista en `clients`.
async fn focus_session(shared: Arc<Shared>, id: String) {
    let pids: Vec<u32> = shared.state.lock().unwrap().sessions.get(&id).map(|s| s.pids.clone()).unwrap_or_default();
    let mut ok = false;
    if !pids.is_empty() {
        if let Ok(out) = Command::new("hyprctl").args(["clients", "-j"]).stderr(Stdio::null()).output().await {
            if let Ok(clients) = serde_json::from_slice::<Value>(&out.stdout) {
                let addr = clients.as_array().into_iter().flatten().find_map(|c| {
                    let pid = c["pid"].as_u64()? as u32;
                    if pids.contains(&pid) { c["address"].as_str().map(String::from) } else { None }
                });
                if let Some(addr) = addr {
                    let expr = format!("hl.dsp.focus({{ window = \"address:{addr}\" }})");
                    ok = Command::new("hyprctl")
                        .args(["dispatch", &expr])
                        .stderr(Stdio::null())
                        .output()
                        .await
                        .map(|o| o.status.success())
                        .unwrap_or(false);
                }
            }
        }
    }
    shared.send(json!({ "type": "focus_result", "session_id": id, "ok": ok }));
}

/// Texto de la regla que guardaría "siempre permitir", a partir de la primera sugerencia de permiso
/// que Claude Code ofrece (su formato exacto puede variar, así que se tolera más de una forma).
fn suggestion_label(suggestions: &Value) -> Option<String> {
    let first = suggestions.as_array()?.iter().find(|s| s["behavior"] != "deny")?;
    let rules: Vec<String> = first["rules"]
        .as_array()
        .map(|rs| {
            rs.iter()
                .filter_map(|r| match r {
                    Value::String(t) => Some(t.clone()),
                    Value::Object(_) => {
                        let tool = r["toolName"].as_str()?;
                        Some(match r["ruleContent"].as_str() {
                            Some(c) => format!("{tool}({c})"),
                            None => tool.to_string(),
                        })
                    }
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();
    let label = if rules.is_empty() { "esta acción".to_string() } else { rules.join(", ") };
    Some(label.chars().take(80).collect())
}

/// Reloj de un segundo: dispara recordatorios vencidos y avanza el pomodoro.
async fn ticker(shared: Arc<Shared>) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        tick.tick().await;
        let t = now();
        let (work, brk) = {
            let c = shared.config.lock().unwrap();
            (c.pomo_work as u64, c.pomo_break as u64)
        };
        let mut alarms: Vec<Value> = Vec::new();
        let changed = {
            let mut timers = shared.timers.lock().unwrap();
            let mut changed = false;
            let (due, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut timers.reminders).into_iter().partition(|r| r.at <= t);
            timers.reminders = rest;
            for r in due {
                alarms.push(json!({ "type": "alarm", "kind": "reminder", "id": r.id, "label": r.label }));
                changed = true;
            }
            if timers.pomo.running && timers.pomo.ends_at <= t {
                if timers.pomo.phase == "work" {
                    let n = timers.pomo.cycle.max(1);
                    timers.pomo.phase = "break".into();
                    timers.pomo.ends_at = t + brk * 60;
                    alarms.push(json!({ "type": "alarm", "kind": "pomo",
                        "label": format!("Pomodoro {n} terminado: descansa {brk} min") }));
                } else {
                    timers.pomo.phase = "work".into();
                    timers.pomo.cycle += 1;
                    timers.pomo.ends_at = t + work * 60;
                    alarms.push(json!({ "type": "alarm", "kind": "pomo",
                        "label": format!("¡A trabajar! {work} min de enfoque") }));
                }
                changed = true;
            }
            if changed {
                timers.save();
            }
            changed
        };
        for a in alarms {
            shared.send(a);
        }
        if changed {
            shared.publish_timers();
        }
    }
}

// ---------------------------------------------------------------- conexiones

async fn handle(stream: UnixStream, shared: Arc<Shared>) {
    let (rd, mut wr) = stream.into_split();
    let mut lines = BufReader::new(rd).lines();
    let Ok(Some(first)) = lines.next_line().await else { return };
    let Ok(msg) = serde_json::from_str::<Value>(&first) else { return };

    match msg["type"].as_str() {
        Some("event") => {
            let finished = touch_session(&shared, &msg);
            shared.publish();
            if finished {
                let summary: String = str_of(&msg["last_message"]).chars().take(240).collect();
                shared.send(json!({ "type": "finished", "session_id": msg["session_id"],
                                    "agent": msg["agent"], "cwd": msg["cwd"], "summary": summary }));
            }
            if msg["event"] == "StopFailure" {
                shared.send(json!({ "type": "agent_error", "session_id": msg["session_id"],
                                    "agent": msg["agent"], "error_type": msg["error_type"],
                                    "error_message": msg["error_message"] }));
            }
        }
        Some("permission") => {
            // Sin UI conectada, el agente debe preguntar en su terminal.
            if shared.tx.receiver_count() == 0 {
                let _ = wr.write_all(b"{\"decision\":\"ask\"}\n").await;
                return;
            }
            touch_session(&shared, &msg);
            let (tx, rx) = oneshot::channel();
            let tool = str_of(&msg["tool"]);
            // AskUserQuestion no pide permiso: pregunta. Sus opciones se responden con botones.
            let (kind, questions) = if tool == "AskUserQuestion" {
                ("question", msg["input"]["questions"].clone())
            } else {
                ("permission", Value::Null)
            };
            let id = {
                let mut st = shared.state.lock().unwrap();
                st.next_id += 1;
                let id = format!("p{}", st.next_id);
                st.pending.insert(
                    id.clone(),
                    Pending {
                        session_id: str_of(&msg["session_id"]),
                        agent: str_of(&msg["agent"]),
                        summary: summarize(&tool, &msg["input"]),
                        tool,
                        kind,
                        questions,
                        always_label: if kind == "permission" { suggestion_label(&msg["suggestions"]) } else { None },
                        tx,
                    },
                );
                id
            };
            shared.publish();

            // Si el hook muere (p. ej. el usuario responde en la terminal), cancelar.
            let reply = tokio::select! {
                d = rx => d.unwrap_or_else(|_| json!({ "decision": "ask" })),
                _ = lines.next_line() => json!({ "decision": "ask" }),
            };
            shared.state.lock().unwrap().pending.remove(&id);
            shared.publish();
            let _ = wr.write_all(format!("{reply}\n").as_bytes()).await;
        }
        Some("subscribe") => {
            let mut rx = shared.tx.subscribe();
            let snap = shared.state.lock().unwrap().snapshot();
            let cfg = shared.config.lock().unwrap().message();
            let (hist, timers) = (shared.history_message(), shared.timers_message());
            if wr.write_all(format!("{snap}\n{cfg}\n{hist}\n{timers}\n").as_bytes()).await.is_err() {
                return;
            }
            loop {
                tokio::select! {
                    update = rx.recv() => match update {
                        Ok(s) => if wr.write_all(format!("{s}\n").as_bytes()).await.is_err() { break },
                        Err(broadcast::error::RecvError::Lagged(_)) => {
                            let snap = shared.state.lock().unwrap().snapshot();
                            if wr.write_all(format!("{snap}\n").as_bytes()).await.is_err() { break }
                        }
                        Err(_) => break,
                    },
                    line = lines.next_line() => match line {
                        Ok(Some(l)) => on_ui_message(&shared, &l),
                        _ => break,
                    },
                }
            }
        }
        _ => {}
    }
}

fn str_list(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|f| f.as_str().map(String::from)).collect()).unwrap_or_default()
}

fn on_ui_message(shared: &Arc<Shared>, line: &str) {
    let Ok(msg) = serde_json::from_str::<Value>(line) else { return };
    match msg["type"].as_str() {
        Some("decide") => {
            let decision = match msg["decision"].as_str() {
                Some(d @ ("allow" | "allow_always" | "deny" | "ask")) => d.to_string(),
                _ => return,
            };
            let pending = shared.state.lock().unwrap().pending.remove(&str_of(&msg["id"]));
            if let Some(p) = pending {
                let _ = p.tx.send(json!({ "decision": decision, "answers": msg["answers"] }));
            }
        }
        Some("focus") => {
            tokio::spawn(focus_session(shared.clone(), str_of(&msg["session_id"])));
        }
        Some("set_config") => {
            {
                let mut c = shared.config.lock().unwrap();
                if let Some(k) = msg["api_key"].as_str().map(str::trim).filter(|k| !k.is_empty()) {
                    c.api_key = k.to_string();
                }
                if let Some(m) = msg["model"].as_str().filter(|m| !m.is_empty()) {
                    c.model = m.to_string();
                }
                if let Some(b) = msg["backend"].as_str().filter(|b| matches!(*b, "subscription" | "api")) {
                    c.backend = b.to_string();
                }
                if let Some(b) = msg["sound"].as_bool() {
                    c.sound = b;
                }
                if let Some(v) = msg["volume"].as_f64() {
                    c.volume = v.clamp(0.0, 1.0);
                }
                if let Some(a) = msg["head"].as_str().filter(|a| HEADS.contains(a)) {
                    c.head = a.to_string();
                }
                if let Some(a) = msg["face"].as_str().filter(|a| FACES.contains(a)) {
                    c.face = a.to_string();
                }
                if let Some(a) = msg["neck"].as_str().filter(|a| NECKS.contains(a)) {
                    c.neck = a.to_string();
                }
                if let Some(a) = msg["acc_color"].as_str().filter(|a| valid_color(a)) {
                    c.acc_color = a.to_string();
                }
                if let Some(p) = msg["position"].as_str().filter(|p| matches!(*p, "right" | "center")) {
                    c.position = p.to_string();
                }
                if let Some(m) = msg["sleep_minutes"].as_u64() {
                    c.sleep_minutes = m.min(240) as u32;
                }
                if let Some(b) = msg["dance"].as_bool() {
                    c.dance = b;
                }
                if let Some(m) = msg["pomo_work"].as_u64().filter(|m| (1..=180).contains(m)) {
                    c.pomo_work = m as u32;
                }
                if let Some(m) = msg["pomo_break"].as_u64().filter(|m| (1..=180).contains(m)) {
                    c.pomo_break = m as u32;
                }
                c.save();
            }
            shared.publish_config();
            shared.publish_timers(); // los minutos del pomodoro viajan con los relojes
        }
        Some("list_models") => {
            tokio::spawn(list_models(shared.clone()));
        }
        Some("chat") => {
            let text = str_of(&msg["text"]);
            let contexts: Vec<(String, String)> = msg["contexts"]
                .as_array()
                .map(|a| a.iter().map(|c| (str_of(&c["label"]), str_of(&c["text"]))).collect())
                .unwrap_or_default();
            if !text.trim().is_empty() {
                let input = ChatInput {
                    display: str_of(&msg["display"]),
                    files: str_list(&msg["files"]),
                    contexts,
                    text,
                };
                tokio::spawn(chat_turn(shared.clone(), input));
            }
        }
        Some("chat_cancel") => shared.cancel.notify_waiters(),
        Some("chat_reset") => {
            let mut chat = shared.chat.lock().unwrap();
            if !chat.busy {
                chat.history.clear();
                chat.session = None;
                chat.transcript.clear();
                chat.save();
            }
        }
        Some("grab") => {
            tokio::spawn(grab(shared.clone(), str_of(&msg["what"])));
        }
        Some("timer_add") => {
            let secs = msg["secs"].as_u64().unwrap_or(0).clamp(1, 7 * 24 * 3600);
            let label: String = str_of(&msg["label"]).chars().take(120).collect();
            {
                let mut t = shared.timers.lock().unwrap();
                t.next_id += 1;
                let id = t.next_id;
                t.reminders.push(Reminder { id, label, at: now() + secs });
                t.reminders.sort_by_key(|r| r.at);
                t.save();
            }
            shared.publish_timers();
        }
        Some("timer_cancel") => {
            let id = msg["id"].as_u64().unwrap_or(0);
            {
                let mut t = shared.timers.lock().unwrap();
                t.reminders.retain(|r| r.id != id);
                t.save();
            }
            shared.publish_timers();
        }
        Some("pomo") => {
            let work = shared.config.lock().unwrap().pomo_work as u64;
            {
                let mut t = shared.timers.lock().unwrap();
                match msg["action"].as_str() {
                    Some("start") => {
                        t.pomo = Pomo { running: true, phase: "work".into(), ends_at: now() + work * 60, cycle: 1 };
                    }
                    Some("stop") => t.pomo.running = false,
                    Some("skip") if t.pomo.running => t.pomo.ends_at = now(), // el reloj avanza de fase
                    _ => {}
                }
                t.save();
            }
            shared.publish_timers();
        }
        _ => {}
    }
}

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let path = axolotl_notch::socket_path();
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    // Solo el usuario puede hablar con el daemon (aprueba permisos de herramientas).
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;

    let (tx, _) = broadcast::channel(256);
    let shared = Arc::new(Shared {
        state: Mutex::default(),
        config: Mutex::new(Config::load()),
        chat: Mutex::new(Chat::load()),
        timers: Mutex::new(Timers::load()),
        cancel: Notify::new(),
        tx,
    });
    eprintln!("axolotl-daemon escuchando en {}", path.display());
    tokio::spawn(ticker(shared.clone()));

    loop {
        tokio::select! {
            conn = listener.accept() => {
                let (stream, _) = conn?;
                tokio::spawn(handle(stream, shared.clone()));
            }
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    let _ = std::fs::remove_file(&path);
    Ok(())
}
