//! Hook para agentes: lee el JSON del hook por stdin y lo reenvía al daemon.
//!
//! Uso: `axolotl-hook --agent claude|gemini|antigravity`
//! Si el daemon no está corriendo, sale en silencio (el agente sigue su flujo normal).
//!
//! Instalación de hooks (con copia de seguridad previa): `axolotl-hook install claude|gemini`
//! y `axolotl-hook uninstall claude|gemini`.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use serde_json::{Map, Value, json};

/// Marca que identifica nuestras entradas dentro del settings.json de cada agente.
const MARKER: &str = "axolotl-hook";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(cmd @ ("install" | "uninstall")) = args.first().map(String::as_str) {
        let agent = args.get(1).map(String::as_str).unwrap_or("");
        match install::run(cmd == "install", agent) {
            Ok(msg) => println!("{msg}"),
            Err(e) => {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    relay(&args);
}

/// Traduce el payload de cada agente a los campos canónicos del protocolo.
fn normalize(agent: &str, payload: &Value) -> (String, Value, Value, Value, Value) {
    let event = payload["hook_event_name"].as_str().unwrap_or("").to_string();
    if agent == "antigravity" {
        // Antigravity: `conversationId` y `toolCall.{name,args}`.
        let session = if payload["conversationId"].is_null() {
            payload["session_id"].clone()
        } else {
            payload["conversationId"].clone()
        };
        let event = match event.as_str() {
            "PreInvocation" => "UserPromptSubmit".to_string(),
            "PostInvocation" => "PostToolUse".to_string(),
            _ => event,
        };
        return (
            event,
            session,
            payload["toolCall"]["name"].clone(),
            payload["toolCall"]["args"].clone(),
            payload["cwd"].clone(),
        );
    }
    (
        event,
        payload["session_id"].clone(),
        payload["tool_name"].clone(),
        payload["tool_input"].clone(),
        payload["cwd"].clone(),
    )
}

/// PIDs de los ancestros de este proceso (padre, abuelo...). Uno de ellos es la terminal del agente,
/// que la isla usa para saltar a su ventana.
fn ancestors() -> Vec<u32> {
    let mut out = Vec::new();
    let mut pid = std::process::id();
    for _ in 0..12 {
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else { break };
        // "pid (comm) estado ppid ...": el nombre puede tener espacios, se lee tras el último ')'.
        let Some((_, rest)) = stat.rsplit_once(')') else { break };
        let Some(ppid) = rest.split_whitespace().nth(1).and_then(|p| p.parse::<u32>().ok()) else { break };
        if ppid <= 1 {
            break;
        }
        out.push(ppid);
        pid = ppid;
    }
    out
}

fn relay(args: &[String]) {
    // Las sesiones que lanza el propio daemon (chat por suscripción) no deben aparecer en la isla.
    if std::env::var_os("AXOLOTL_IGNORE").is_some() {
        return;
    }
    let agent = args
        .iter()
        .skip_while(|a| *a != "--agent")
        .nth(1)
        .cloned()
        .unwrap_or_else(|| "claude".into());

    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return;
    }
    let payload: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
    let (event, session, tool, tool_input, cwd) = normalize(&agent, &payload);

    let Ok(mut stream) = UnixStream::connect(axolotl_notch::socket_path()) else {
        return;
    };

    let is_permission = event == "PermissionRequest";
    let msg = json!({
        "type": if is_permission { "permission" } else { "event" },
        "agent": agent,
        "event": event,
        "session_id": session,
        "cwd": cwd,
        "tool": tool,
        "input": tool_input,
        "pids": ancestors(),
        // Solo se rellenan en los eventos que los traen (StopFailure, Stop, PermissionRequest).
        "error_type": payload["error_type"],
        "error_message": payload["error_message"],
        "last_message": payload["last_assistant_message"],
        "suggestions": payload["permission_suggestions"],
    });
    if writeln!(stream, "{msg}").is_err() || !is_permission {
        return;
    }

    // Esperar la decisión del usuario desde la UI.
    let mut line = String::new();
    if BufReader::new(stream).read_line(&mut line).is_err() {
        return;
    }
    let reply: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
    let decision = match reply["decision"].as_str() {
        Some(d @ ("allow" | "allow_always")) => {
            let mut decision = json!({ "behavior": "allow" });
            // Preguntas de Claude (AskUserQuestion): se responden devolviendo la entrada con `answers`.
            if reply["answers"].is_object() {
                let mut input = payload["tool_input"].clone();
                input["answers"] = reply["answers"].clone();
                decision["updatedInput"] = input;
            }
            // "Siempre permitir": se reutiliza tal cual la primera sugerencia de regla que ofreció
            // Claude Code, así el formato es siempre el que él mismo espera.
            if d == "allow_always" {
                let suggestion = payload["permission_suggestions"]
                    .as_array()
                    .and_then(|a| a.iter().find(|s| s["behavior"] != "deny"));
                if let Some(sug) = suggestion {
                    decision["updatedPermissions"] = json!([sug]);
                }
            }
            decision
        }
        Some("deny") => json!({ "behavior": "deny", "message": "Rechazado desde Mochi" }),
        _ => return, // "ask": dejar que el agente pregunte en la terminal
    };
    println!(
        "{}",
        json!({ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": decision } })
    );
}

mod install {
    use super::*;

    struct Target {
        path: PathBuf,
        agent: &'static str,
        /// (evento, matcher, timeout)
        events: &'static [(&'static str, Option<&'static str>, u64)],
        /// Gemini mide el timeout en milisegundos; Claude Code en segundos.
        timeout_scale: u64,
        named: bool,
    }

    fn home() -> PathBuf {
        std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
    }

    fn target(agent: &str) -> Result<Target, String> {
        match agent {
            "claude" => Ok(Target {
                path: home().join(".claude/settings.json"),
                agent: "claude",
                events: &[
                    ("SessionStart", None, 5),
                    ("SessionEnd", None, 5),
                    ("UserPromptSubmit", None, 5),
                    ("PreToolUse", Some("*"), 5),
                    ("PostToolUse", None, 5),
                    ("Notification", None, 5),
                    ("Stop", None, 5),
                    ("StopFailure", None, 5),
                    ("PermissionRequest", Some("*"), 120),
                ],
                timeout_scale: 1,
                named: false,
            }),
            "gemini" => Ok(Target {
                path: home().join(".gemini/settings.json"),
                agent: "gemini",
                events: &[
                    ("SessionStart", None, 5),
                    ("SessionEnd", None, 5),
                    ("BeforeAgent", None, 5),
                    ("AfterAgent", None, 5),
                    ("BeforeTool", Some("*"), 5),
                    ("AfterTool", Some("*"), 5),
                ],
                timeout_scale: 1000,
                named: true,
            }),
            other => Err(format!("agente desconocido: '{other}' (usa claude o gemini)")),
        }
    }

    fn is_ours(entry: &Value) -> bool {
        entry["hooks"]
            .as_array()
            .is_some_and(|hs| hs.iter().any(|h| h["command"].as_str().is_some_and(|c| c.contains(MARKER))))
    }

    pub fn run(install: bool, agent: &str) -> Result<String, String> {
        let t = target(agent)?;
        let mut root: Value = match std::fs::read_to_string(&t.path) {
            Ok(text) if text.trim().is_empty() => json!({}),
            Ok(text) => serde_json::from_str(&text).map_err(|e| {
                format!("{} no es JSON válido ({e}); no lo toco.", t.path.display())
            })?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => json!({}),
            Err(e) => return Err(format!("no puedo leer {}: {e}", t.path.display())),
        };
        let Some(obj) = root.as_object_mut() else {
            return Err(format!("{} no es un objeto JSON; no lo toco.", t.path.display()));
        };

        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let command = format!("{} --agent {}", exe.display(), t.agent);

        let hooks = obj.entry("hooks").or_insert_with(|| Value::Object(Map::new()));
        let hooks = hooks.as_object_mut().ok_or("'hooks' no es un objeto")?;
        for (event, matcher, timeout) in t.events {
            let list = hooks.entry(*event).or_insert_with(|| json!([]));
            let list = list.as_array_mut().ok_or_else(|| format!("'hooks.{event}' no es una lista"))?;
            list.retain(|e| !is_ours(e));
            if install {
                let mut hook = json!({ "type": "command", "command": command,
                                       "timeout": timeout * t.timeout_scale });
                if t.named {
                    hook["name"] = json!("axolotl-notch");
                }
                let mut entry = json!({ "hooks": [hook] });
                if let Some(m) = matcher {
                    entry["matcher"] = json!(m);
                }
                list.push(entry);
            }
        }
        // Limpiar eventos que quedaron vacíos tras desinstalar.
        hooks.retain(|_, v| v.as_array().is_none_or(|a| !a.is_empty()));
        if hooks.is_empty() {
            obj.remove("hooks");
        }

        if let Some(dir) = t.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        if t.path.exists() {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let backup = t.path.with_extension(format!("json.bak-{stamp}"));
            std::fs::copy(&t.path, &backup).map_err(|e| format!("copia de seguridad: {e}"))?;
        }
        let text = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
        std::fs::write(&t.path, text + "\n").map_err(|e| e.to_string())?;
        Ok(format!(
            "Hooks de {} {} en {}",
            t.agent,
            if install { "instalados" } else { "eliminados" },
            t.path.display()
        ))
    }
}
