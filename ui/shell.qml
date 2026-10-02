import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Caelestia.Config
import Caelestia.Blobs

// Isla del ajolote, integrada con el shell de Caelestia:
//  - la tarjeta emerge del marco superior de la pantalla y se funde con él (mismos blobs,
//    mismo grosor de marco, mismas curvas de animación y tipografías),
//  - los colores salen del esquema dinámico del wallpaper (Theme.qml),
//  - el ajolote está siempre visible en la esquina superior derecha (estado "asomado");
//    al hacer clic sobre él se abre con el resumen de los agentes y el chat, y se queda
//    abierta hasta que haces clic fuera de ella (o pulsas Esc); con el botón de fijar
//    no se cierra al hacer clic fuera, así se pueden arrastrar archivos desde otra ventana,
//  - solo una solicitud de permiso, una pregunta de Claude o una alarma la abren sola (hay que
//    atenderlas); al terminar una tarea Mochi celebra sin abrirse. Chat con tu suscripción o la API,
//    saltar a la terminal de cada sesión, recordatorios y pomodoro, y ajustes de Mochi.
ShellRoot {
    id: root

    // --- Geometría ---
    readonly property int bt: island.bt                      // grosor del marco de Caelestia
    readonly property int cardGap: 3                         // separación entre la tarjeta y el marco
    readonly property int openWidth: 560
    readonly property int peekW: 112
    readonly property int peekH: 64

    // --- Datos del daemon ---
    property var sessions: []
    property var pending: []
    readonly property bool hasPending: pending.length > 0
    readonly property int working: sessions.filter(s => s.status === "working").length
    property string focusId: ""
    readonly property var focusSession: pickFocus()

    // --- Configuración y chat ---
    property bool hasKey: false
    property string backend: "subscription"
    property string model: ""
    property var models: []
    property bool soundOn: true
    property real volume: 0.5
    property string head: "none"
    property string face: "none"
    property string neck: "none"
    property string accColor: "auto"
    property string position: "right"
    readonly property bool centered: position === "center"
    property int sleepMinutes: 10
    property bool dance: true
    property bool chatBusy: false
    property string chatError: ""
    property var attachments: []
    property var contexts: []                // fragmentos de texto para el chat: [{label, text}]
    ListModel { id: chatModel }

    // --- Relojes (los guarda y dispara el daemon) ---
    property var timers: ({ reminders: [], pomo: { running: false, phase: "work", ends_at: 0, cycle: 0, work_min: 25, break_min: 5 } })
    property var alarms: []                  // alarmas por atender: [{kind, label}]
    property string focusMsg: ""             // aviso de "saltar a la terminal"

    // --- Modo demostración (AXOLOTL_DEMO=1): para grabar videos sin exponer la música real del usuario ---
    readonly property bool demo: Quickshell.env("AXOLOTL_DEMO") === "1"
    property bool demoMusic: false
    readonly property var demoPlayer: ({ isPlaying: true, trackTitle: "Lo-fi para programar", trackArtist: "Mochi Beats",
                                         previous: function () {}, next: function () {}, togglePlaying: function () {} })

    // --- Música (MPRIS) ---
    readonly property var player: pickPlayer()
    readonly property bool hasPlayer: player !== null
    readonly property bool playing: player !== null && player.isPlaying
    readonly property bool dancing: dance && playing && working === 0

    // --- Sueño ---
    property double lastActivity: Date.now()
    property bool sleeping: false

    // --- Errores de agentes ---
    readonly property var errorSession: sessions.find(s => s.status === "error") || null
    readonly property string errorMood: errorSession ? (errorSession.error_type === "rate_limit" ? "tired" : "sad") : ""

    // --- Estado de la interfaz ---
    property string userMode: "peek"          // hidden | peek | open (hidden solo por IPC)
    property string tab: "overview"           // overview | chat | time | settings
    property bool hoverHit: false
    property bool hoverCard: false
    readonly property bool hovered: hoverHit || hoverCard
    // Arrastre de archivos: `dragActive` = hay un archivo flotando sobre la isla; `swallowing` = ya se
    // soltó y el ajolote se lo está tragando. La vista de "soltar" dura mientras ocurra cualquiera.
    property bool dragActive: false
    property bool swallowing: false
    readonly property bool dropping: dragActive || swallowing
    property var swallowUrls: []
    property real mouthOpen: 0
    property real foodX: 0
    property real foodY: 0
    property real foodScale: 1
    property real foodOpacity: 0
    property real foodRot: -8
    property bool pinnedOpen: false          // fijada: un clic fuera no la cierra (para arrastrar archivos)
    property string overrideMood: ""
    property real lookX: 0
    property real lookY: 0

    readonly property string effMode: (hasPending || dropping || alarms.length > 0) ? "open" : userMode
    // Tamaño que conserva la tarjeta mientras se esconde (solo se desliza hacia el marco).
    property string sizeMode: "peek"
    readonly property bool openShown: sizeMode === "open"
    readonly property string view: hasPending ? (pending[0].kind === "question" ? "question" : "approval")
                                  : alarms.length > 0 ? "alarm" : dropping ? "upload" : tab
    readonly property string baseMood: (hasPending || alarms.length > 0) ? "waiting" : dropping ? "hungry"
                                     : errorMood !== "" ? errorMood : working > 0 ? "working"
                                     : dancing ? "dance" : sleeping ? "sleeping" : "idle"
    readonly property bool previewing: view === "settings" && settingsView.page === "accessories"
    readonly property string mood: overrideMood !== "" ? overrideMood : previewing ? "idle" : baseMood

    // Al cambiar un accesorio mientras se previsualiza: Mochi reacciona (squish) y lanza chispitas,
    // para que personalizarlo se sienta como equipar algo en un juego.
    function gearPop() {
        character.slap();
        sounds.play("blip");
        sparkleBurst.seq++;
    }
    onHeadChanged: if (previewing) gearPop()
    onFaceChanged: if (previewing) gearPop()
    onNeckChanged: if (previewing) gearPop()
    onAccColorChanged: if (previewing) gearPop()
    readonly property int openHeight: view === "chat" ? 468
                                    : view === "approval" ? 272
                                    : view === "question" ? Math.min(470, 52 + questionView.contentHeight + 22)
                                    : (view === "upload" || view === "alarm") ? 172
                                    : view === "time" ? 366
                                    : view === "settings" ? 50 + settingsView.contentHeight + 24
                                    // Resumen: Mochi centrado arriba empuja el contenido más abajo que antes.
                                    : hasPlayer ? 458 : 414

    property string lastEffMode: "hidden"
    onEffModeChanged: {
        // Fija la duración del fundido de la cabecera ANTES de que cambie `sizeMode` (lo que dispara
        // su opacity): un `duration: root.effMode==="open"?...` leído dentro del propio Behavior
        // llegaba tarde (la animación ya arrancada seguía usando el valor de la transición anterior).
        header.fadeDelay = effMode === "open" ? 260 : 0;
        header.fadeDur = effMode === "open" ? 240 : 0;
        if (effMode !== "hidden") sizeMode = effMode;
        if (effMode === "open" && lastEffMode !== "open") sounds.play("open");
        else if (effMode !== "open" && lastEffMode === "open") sounds.play("close");
        lastEffMode = effMode;
    }
    onHoveredChanged: onHover(hovered)
    onViewChanged: if (view === "chat") focusChatLater.restart()

    // ------------------------------------------------------------ lógica
    function send(obj) {
        if (!sock.connected) return;
        sock.write(JSON.stringify(obj) + "\n");
        sock.flush();
    }

    function pickFocus() {
        if (hasPending) {
            const p = sessions.find(s => s.id === pending[0].session_id);
            if (p) return p;
        }
        if (errorSession) return errorSession;
        const chosen = sessions.find(s => s.id === focusId);
        if (chosen) return chosen;
        const w = sessions.find(s => s.status === "working");
        if (w) return w;
        return sessions.slice().sort((a, b) => b.updated - a.updated)[0] || null;
    }

    function baseName(path) {
        const parts = (path || "").split("/").filter(p => p.length > 0);
        return parts.length ? parts[parts.length - 1] : "";
    }
    function agentName(a) {
        return a === "claude" ? "Claude Code" : a === "gemini" ? "Gemini CLI" : a === "antigravity" ? "Antigravity" : a;
    }
    readonly property var toolIcons: ({
        Read: "visibility", Write: "save", Edit: "edit", MultiEdit: "edit", NotebookEdit: "edit",
        Bash: "terminal", BashOutput: "terminal", KillShell: "stop_circle",
        Glob: "folder", Grep: "search", WebFetch: "public", WebSearch: "travel_explore",
        Task: "smart_toy", TodoWrite: "checklist"
    })
    function toolIcon(t) {
        return root.toolIcons[t] || "bolt";
    }
    function statusColor(s) {
        return s === "working" ? Theme.success : s === "waiting" ? Theme.tertiary
             : s === "error" ? Theme.error : Theme.m3onSurfaceVariant;
    }
    function errorText(sess) {
        const t = sess ? sess.error_type : "";
        const known = { rate_limit: "Límite de uso alcanzado", overloaded: "Servicio saturado",
                        authentication_failed: "Falló la autenticación", oauth_org_not_allowed: "Organización no permitida",
                        account_on_hold: "Cuenta en pausa", billing_error: "Problema de facturación",
                        invalid_request: "Solicitud no válida", model_not_found: "Modelo no encontrado",
                        server_error: "Error del servidor", max_output_tokens: "Respuesta demasiado larga" };
        return known[t] || (sess && sess.error_message) || "Error";
    }
    function statusText(sess) {
        const s = sess ? sess.status : "idle";
        return s === "working" ? "Trabajando" : s === "waiting" ? "Esperando tu respuesta"
             : s === "error" ? errorText(sess) : "En reposo";
    }

    // Una reproducción en curso tiene prioridad; si no, el primer reproductor con pista.
    function pickPlayer() {
        if (demo) return demoMusic ? demoPlayer : null;
        const list = Mpris.players.values;
        let fallback = null;
        for (let i = 0; i < list.length; i++) {
            if (list[i].isPlaying) return list[i];
            if (!fallback && list[i].trackTitle) fallback = list[i];
        }
        return fallback;
    }

    // Cualquier interacción despierta a Mochi y reinicia la cuenta del sueño.
    function touchActivity() {
        lastActivity = Date.now();
        if (sleeping || yawnTimer.running) {
            sleeping = false;
            yawnTimer.stop();
            if (overrideMood === "yawn") overrideMood = "";
        }
    }

    // Enfoca la ventana de la terminal de la sesión (el daemon la localiza por su cadena de procesos).
    function jumpToTerminal(sessionId) {
        if (!sessionId) return;
        focusMsg = "";
        send({ type: "focus", session_id: sessionId });
    }

    function setMood(m, ms) {
        overrideMood = m;
        moodTimer.interval = ms;
        moodTimer.restart();
    }

    function openIsland() {
        touchActivity();
        userMode = "open";
    }
    // Cerrar = volver al ajolote asomado en la esquina (siempre visible).
    function closeIsland() {
        pinnedOpen = false;
        if (userMode !== "hidden") userMode = "peek";
    }

    // Un saludo breve al acercar el mouse (solo si está en reposo). Salir con el mouse no cierra.
    function onHover(h) {
        if (h) touchActivity();
        if (h && userMode === "peek" && overrideMood === "" && mood === "idle") setMood("wave", 1400);
    }

    function updateLook(pos) {
        const cx = character.x + character.width / 2, cy = character.y + character.height * 0.6;
        lookX = Math.tanh((pos.x - cx) / 200);
        lookY = Math.tanh((pos.y - cy) / 160);
    }

    function decide(id, decision, answers) {
        touchActivity();
        sounds.play(decision === "deny" ? "deny" : "approve");
        setMood(decision === "deny" ? "annoyed" : "happy", 900);
        send({ type: "decide", id: id, decision: decision, answers: answers });
    }
    // "Decidir en la terminal": se deja la solicitud al agente y se enfoca su ventana.
    function askInTerminal(req) {
        if (!req) return;
        jumpToTerminal(req.session_id);
        decide(req.id, "ask");
    }
    function dismissAlarm() { alarms = alarms.slice(1); }
    function snoozeAlarm() {
        if (alarms.length === 0) return;
        send({ type: "timer_add", secs: 300, label: alarms[0].label });
        dismissAlarm();
    }

    // Clic sobre el ajolote: abrir (si está asomado), claque, o mareo con tres clics seguidos.
    property var clickTimes: []
    function poke() {
        touchActivity();
        if (effMode === "peek") { openIsland(); return; }
        const now = Date.now();
        clickTimes = clickTimes.filter(t => now - t < 1700).concat([now]);
        if (clickTimes.length >= 3) {
            clickTimes = [];
            sounds.play("dizzy");
            setMood("dizzy", 3300);
        } else {
            sounds.play("slap");
            character.slap();
            // Una palmada y Mochi reacciona al azar: se enoja, se pone triste o se achicopala.
            const reactions = ["annoyed", "sad", "tired"];
            const m = reactions[Math.floor(Math.random() * reactions.length)];
            if (m === "annoyed") sounds.play("annoyed");
            setMood(m, m === "annoyed" ? 800 : 1500);
        }
    }

    function sendChat(text) {
        touchActivity();
        const names = attachments.map(p => baseName(p)).concat(contexts.map(c => c.label)).join(", ");
        const display = (names ? "[" + names + "]\n" : "") + text;
        chatModel.append({ role: "user", text: display });
        chatModel.append({ role: "assistant", text: "" });
        chatError = "";
        chatBusy = true;
        send({ type: "chat", text: text, display: display, files: attachments, contexts: contexts });
        attachments = [];
        contexts = [];
        sounds.play("send");
    }
    function copyToClipboard(text) { Quickshell.execDetached(["wl-copy", text]); }
    // Pide el portapapeles o la selección al daemon; llega como "grabbed" y queda como chip de contexto.
    function grabContext(what) { chatError = ""; send({ type: "grab", what: what }); }

    // Mientras se arrastra: los ojos y la boca siguen al archivo (pos en coordenadas de la tarjeta);
    // la boca se abre más cuanto más cerca está.
    function dragMove(pos) {
        touchActivity();
        if (swallowing) return;
        updateLook(pos);
        foodX = pos.x; foodY = pos.y; foodScale = 1; foodOpacity = 1; foodRot = -8;
        const d = Math.hypot(pos.x - (character.x + character.mouthX), pos.y - (character.y + character.mouthY));
        mouthOpen = Math.max(0.2, Math.min(1, 1.15 - d / 240));
    }

    // Soltar: el archivo vuela hasta la boca (swallowAnim) y, al llegar, se lo traga (finishSwallow).
    function beginSwallow(urls) {
        swallowUrls = urls;
        dragLeave.stop();
        swallowing = true;
        dragActive = false;
        swallowAnim.restart();
    }
    function finishSwallow() {
        foodOpacity = 0;
        mouthOpen = 0;
        sounds.play("gulp");
        character.gulp();
        character.chew = 1;
        chewDown.restart();
        setMood("happy", 1500);
        swallowDone.restart();
    }
    // Tras tragar y masticar: el archivo queda adjunto y se abre el chat.
    function acceptFiles(urls) {
        const paths = urls.map(u => decodeURIComponent(u.toString().replace(/^file:\/\//, ""))).filter(p => p.length > 0);
        attachments = attachments.concat(paths.filter(p => attachments.indexOf(p) < 0));
        swallowing = false;
        tab = "chat";
        openIsland();
    }

    function handle(msg) {
        if (msg.type === "state") {
            if (msg.pending.length > pending.length) { sounds.play("approval"); touchActivity(); }
            sessions = msg.sessions;
            pending = msg.pending;
            if (msg.sessions.some(s => s.status === "working")) touchActivity();
        } else if (msg.type === "config") {
            const first = model === "";
            hasKey = msg.has_key;
            backend = msg.backend;
            model = msg.model;
            soundOn = msg.sound;
            volume = msg.volume;
            head = msg.head || "none";
            face = msg.face || "none";
            neck = msg.neck || "none";
            accColor = msg.acc_color || "auto";
            position = msg.position || "right";
            sleepMinutes = msg.sleep_minutes;
            dance = msg.dance;
            if (first || models.length === 0) send({ type: "list_models" });
        } else if (msg.type === "timers") {
            timers = msg;
        } else if (msg.type === "alarm") {
            alarms = alarms.concat([{ kind: msg.kind, label: msg.label }]);
            sounds.play("approval");
            touchActivity();
        } else if (msg.type === "agent_error") {
            sounds.play("error");
            touchActivity();
        } else if (msg.type === "focus_result") {
            if (!msg.ok) {
                focusMsg = "No encuentro la ventana de la terminal";
                focusMsgTimer.restart();
            }
        } else if (msg.type === "chat_history") {
            // Solo al conectar: si ya hay conversación en pantalla no se duplica.
            if (chatModel.count === 0) msg.messages.forEach(m => chatModel.append({ role: m.role, text: m.text }));
        } else if (msg.type === "chat_cancelled") {
            chatBusy = false;
            const last = chatModel.count - 1;
            if (last >= 0 && chatModel.get(last).role === "assistant") {
                if (chatModel.get(last).text === "") chatModel.remove(last);
                else chatModel.setProperty(last, "text", chatModel.get(last).text + "\n\n_(detenido)_");
            }
        } else if (msg.type === "grabbed") {
            const label = msg.what === "primary" ? "Selección" : "Portapapeles";
            if (msg.text.trim() === "") chatError = msg.what === "primary" ? "No hay texto seleccionado." : "El portapapeles está vacío.";
            else contexts = contexts.concat([{ label: label, text: msg.text }]);
        } else if (msg.type === "models") {
            models = msg.models;
        } else if (msg.type === "finished") {
            sounds.play("finish");
            setMood("finished", 5200);   // celebra en su sitio; no se abre sola
        } else if (msg.type === "chat_delta") {
            const last = chatModel.count - 1;
            if (last >= 0) chatModel.setProperty(last, "text", chatModel.get(last).text + msg.text);
        } else if (msg.type === "chat_done") {
            chatBusy = false;
            sounds.play("receive");
        } else if (msg.type === "chat_error") {
            chatBusy = false;
            chatError = msg.message;
            const last = chatModel.count - 1;
            if (last >= 0 && chatModel.get(last).role === "assistant" && chatModel.get(last).text === "")
                chatModel.remove(last);
            sounds.play("error");
        }
    }

    // ------------------------------------------------------------ conexión
    Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/axolotl.sock"
        connected: true
        onConnectedChanged: if (connected) { write('{"type":"subscribe"}\n'); flush(); }
        parser: SplitParser {
            onRead: data => {
                try { root.handle(JSON.parse(data)); } catch (e) { console.log("axolotl:", e); }
            }
        }
    }
    Timer {   // reintento si el daemon no está arriba
        interval: 2000
        running: !sock.connected
        repeat: true
        onTriggered: { sock.connected = false; sock.connected = true; }
    }

    // ------------------------------------------------------------ temporizadores
    Timer { id: moodTimer; onTriggered: root.overrideMood = "" }
    // Margen antes de dar el arrastre por terminado: un `exited` suelto (p. ej. al cambiar de tamaño
    // la zona de entrada) no debe apagar la vista de soltar y hacerla parpadear.
    Timer { id: dragLeave; interval: 300; onTriggered: root.dragActive = false }
    Timer { id: swallowDone; interval: 1000; onTriggered: root.acceptFiles(root.swallowUrls) }
    SequentialAnimation {
        id: swallowAnim
        ParallelAnimation {
            NumberAnimation { target: root; property: "foodX"; to: character.x + character.mouthX; duration: 340; easing.type: Easing.InCubic }
            NumberAnimation { target: root; property: "foodY"; to: character.y + character.mouthY; duration: 340; easing.type: Easing.InCubic }
            NumberAnimation { target: root; property: "foodScale"; to: 0.2; duration: 340; easing.type: Easing.InQuad }
            NumberAnimation { target: root; property: "foodRot"; to: 0; duration: 340 }
            NumberAnimation { target: root; property: "mouthOpen"; to: 1; duration: 200 }
        }
        ScriptAction { script: root.finishSwallow() }
    }
    Timer { id: loveTimer; interval: 1900; onTriggered: if (root.effMode === "open") { root.setMood("love", 2400); sounds.play("love"); } }
    Timer { id: focusMsgTimer; interval: 3500; onTriggered: root.focusMsg = "" }
    // Las alarmas del pomodoro se descartan solas; las de recordatorio esperan a que las atiendas.
    Timer { id: alarmAuto; interval: 12000; onTriggered: if (root.alarms.length > 0 && root.alarms[0].kind === "pomo") root.dismissAlarm() }
    onAlarmsChanged: if (alarms.length > 0 && alarms[0].kind === "pomo") alarmAuto.restart()
    // Sueño: tras `sleepMinutes` sin actividad (y sin nada que atender) Mochi bosteza y se duerme.
    Timer {
        id: sleepCheck
        interval: 10000; running: true; repeat: true
        onTriggered: {
            if (root.sleepMinutes > 0 && !root.sleeping && !yawnTimer.running && root.effMode === "peek"
                && root.mood === "idle" && !root.hovered
                && Date.now() - root.lastActivity > root.sleepMinutes * 60000) {
                root.setMood("yawn", 2300);
                yawnTimer.restart();
            }
        }
    }
    Timer { id: yawnTimer; interval: 2300; onTriggered: root.sleeping = true }
    Timer { id: focusChatLater; interval: 380; onTriggered: if (root.view === "chat") chatView.focusInput() }

    Sounds { id: sounds; enabled: root.soundOn; volume: root.volume }

    // Control externo: `qs ipc -p ~/axolotl-notch/ui call island open [overview|chat]` (útil para un atajo).
    IpcHandler {
        target: "island"
        function open(tab: string): void {
            if (tab === "chat" || tab === "overview" || tab === "time" || tab === "settings") root.tab = tab;
            root.openIsland();
        }
        // Elige la sección de Ajustes: "general" o "accessories".
        function settingsPage(page: string): void { if (page === "general" || page === "accessories") settingsView.page = page; }
        // Para atajos: abre el chat con el portapapeles o la selección ya adjuntos.
        function askClipboard(): void { root.tab = "chat"; root.openIsland(); root.grabContext("clipboard"); }
        function askSelection(): void { root.tab = "chat"; root.openIsland(); root.grabContext("primary"); }
        // Pruebas: simulan un recordatorio vencido y el estado de error.
        function testAlarm(label: string): void { root.handle({ type: "alarm", kind: "reminder", label: label }); }
        function peek(): void { root.userMode = "peek"; }
        function hide(): void { root.closeIsland(); root.userMode = "hidden"; }
        function toggle(): void { if (root.userMode === "open") root.closeIsland(); else root.openIsland(); }
        function close(): void { root.closeIsland(); }
        function dismissAlarm(): void { root.dismissAlarm(); }
        // Demostración: añade un chip de contexto de ejemplo (sin leer el portapapeles real).
        function demoContext(label: string, text: string): void { root.contexts = root.contexts.concat([{ label: label, text: text }]); }
        // Demostración: fuerza un estado de ánimo un rato y activa/desactiva la música ficticia.
        function mood(name: string, ms: int): void { root.setMood(name, ms); }
        function demoMusic(on: bool): void { root.demoMusic = on; }
        // Mochi se duerme ahora (bosteza y se acuesta); cualquier interacción lo despierta.
        function sleep(): void { root.setMood("yawn", 2300); yawnTimer.restart(); }
        function wake(): void { root.touchActivity(); }
        // Simulan un arrastre de archivo con la misma ruta de código que los eventos reales del DropArea
        // (para pruebas): dragAt mueve el archivo (coordenadas de la tarjeta), dropFile lo suelta.
        function dragAt(x: real, y: real): void { dragLeave.stop(); root.dragActive = true; root.dragMove(Qt.point(x, y)); }
        function dragStop(): void { dragLeave.restart(); }
        function dropFile(path: string): void { root.beginSwallow(["file://" + path]); }
    }

    // ------------------------------------------------------------ ventana
    PanelWindow {
        id: island

        // Ventana de tamaño fijo: lo que se anima es la tarjeta, no la superficie del
        // compositor (redimensionar un layer-shell a cada frame causaba el parpadeo).
        // Flota cerca de la esquina superior derecha, separada del marco de Caelestia.
        readonly property int hotWidth: 220
        readonly property int bt: contentItem.Config.border.thickness

        // Caelestia necesita saber en qué pantalla está para leer su configuración
        contentItem.Config.screen: screen.name
        contentItem.Tokens.screen: screen.name

        anchors.top: true
        anchors.right: !root.centered          // sin anclar a la derecha el compositor la centra
        implicitWidth: root.openWidth + root.bt + root.cardGap + 64
        implicitHeight: 760 + root.bt + root.cardGap + 56
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "axolotl-notch"
        // Mismo modo mientras está abierta (no solo en el chat): cambiarlo al cambiar de pestaña hacía
        // que el compositor soltara el foco, saltaba el "clic fuera" y la isla se cerraba sola.
        WlrLayershell.keyboardFocus: root.effMode === "open" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // Solo esta zona recibe el mouse: una franja del grosor del marco en el borde superior
        // mientras está oculta, o la tarjeta completa cuando está visible. El resto es transparente.
        Item {
            id: hit
            anchors.right: root.centered ? undefined : parent.right
            anchors.horizontalCenter: root.centered ? parent.horizontalCenter : undefined
            // Solo cubre la tarjeta (y un margen), para no bloquear lo que hay debajo mientras
            // el ajolote está asomado. Oculta (solo por IPC) queda una franja en el borde.
            // Tamaños de destino, no los de la animación: así la región de entrada cambia de golpe y no
            // en cada fotograma (recalcularla durante un arrastre hacía parpadear la ventana).
            width: root.effMode === "open" ? root.openWidth + root.bt + 40
                 : root.effMode === "peek" ? root.peekW + root.bt + 6 : island.hotWidth
            height: root.effMode === "hidden" ? root.bt
                  : (root.effMode === "open" ? root.openHeight : root.peekH) + root.bt + 8

            HoverHandler { onHoveredChanged: root.hoverHit = hovered }
            DropArea {
                anchors.fill: parent
                onEntered: drag => { if (drag.hasUrls) { dragLeave.stop(); root.dragActive = true; } }
                onExited: dragLeave.restart()
                onPositionChanged: drag => { if (drag.hasUrls) root.dragMove(hit.mapToItem(card, drag.x, drag.y)); }
                onDropped: drop => {
                    if (drop.hasUrls) { drop.accept(); root.beginSwallow(drop.urls); }
                    else dragLeave.restart();
                }
            }
        }
        mask: Region { item: hit }

        // Mientras esté abierta por el usuario, un clic fuera de la isla la cierra. El compositor
        // avisa con `cleared`. Las aperturas forzadas (permiso, soltar archivo) no capturan el foco.
        HyprlandFocusGrab {
            id: outsideClick
            windows: [island]
            active: root.userMode === "open" && !root.pinnedOpen
            onCleared: root.closeIsland()
        }

        // -------------------------------------------------- sombra de la tarjeta
        // Igual que la de Caelestia (MultiEffect, blurMax 15, 0.7), pero solo de la tarjeta: la de
        // las franjas del marco ya la dibuja Caelestia y duplicarla dejaba una línea. No se recorta
        // por el marco, igual que la sombra del dashboard de Caelestia cae sobre la franja que toca.
        // Se recorta fuera de las franjas del marco: en Caelestia la sombra es de la forma unida
        // (marco + panel), así que en la unión no hay sombra; la de la tarjeta sola caía sobre la
        // franja y dejaba una línea oscura justo en la junta (muy visible en modo claro).
        Item {
            x: 0; y: root.bt
            width: root.centered ? island.width : island.width - root.bt
            height: island.height - root.bt
            clip: true
            visible: card.offsetScale < 1
            Item {
                x: 0; y: -root.bt
                width: island.width; height: island.height
                opacity: Theme.frame.a
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskInverted: true
                    maskSource: cardShape
                }
                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        blurMax: 15
                        shadowColor: Qt.alpha(Theme.shadow, 0.7)
                    }
                    Rectangle {
                        x: card.x; y: card.y; width: card.width; height: card.height
                        radius: Tokens.rounding.extraLarge
                        color: "black"
                    }
                }
            }
        }

        // -------------------------------------------------- fondo: blobs de Caelestia
        // El marco superior y derecho ya los dibuja Caelestia; aquí solo se pinta lo que queda
        // por debajo/izquierda de él (la tarjeta y sus curvas de unión), recortando el resto
        // para no duplicar la transparencia del marco.
        Item {
            x: 0; y: root.bt
            width: root.centered ? parent.width : parent.width - root.bt
            height: parent.height - root.bt
            clip: true
            visible: card.offsetScale < 1

            // Recorta el resultado FINAL (tarjeta + sombra) con el redondeo del marco de Caelestia:
            // la esquina entre su arco y el ángulo recto ya la pinta Caelestia, y nuestra sombra
            // caía encima oscureciéndola (el "triangulito").
            Item {
                x: 0; y: -root.bt
                width: island.width; height: island.height
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: cornerMask
                }

                Item {
                    x: 0; y: 0
                    width: island.width; height: island.height
                    opacity: Theme.frame.a
                    // En una sola capa: sin ella la opacidad se aplica a cada blob por separado y
                    // donde la tarjeta toca las franjas del marco se pintaba dos veces (franja en L).
                    layer.enabled: true

                    // Grupo propio de la tarjeta: ya no comparte marco con BlobInvertedRect, así que
                    // no se fusiona con él (tarjeta despegada del marco, con hueco de por medio).
                    BlobGroup {
                        id: blobGroup
                        color: Qt.alpha(Theme.frame, 1)     // la transparencia la pone la capa (opacity), como en Caelestia
                        smoothing: Config.border.smoothing
                    }
                    BlobRect {
                        id: cardBg
                        group: blobGroup
                        x: card.x
                        y: card.y
                        implicitWidth: card.width
                        implicitHeight: card.height
                        radius: Tokens.rounding.extraLarge
                        deformScale: (0.1 * Config.appearance.deformScale) / 10000
                    }
            }
            }
        }

        // Forma de la tarjeta (para que su sombra no se pinte bajo ella)
        Item {
            id: cardShape
            visible: false
            layer.enabled: true
            width: island.width; height: island.height
            Rectangle {
                x: card.x; y: card.y; width: card.width; height: card.height
                radius: Tokens.rounding.extraLarge
            }
        }

        // Máscara del recorte: interior de la pantalla, con el redondeo de las esquinas del marco.
        // Los bordes izquierdo e inferior quedan fuera de la ventana; solo importa la esquina
        // superior derecha, que coincide con la esquina interior del marco de Caelestia.
        Item {
            id: cornerMask
            visible: false
            layer.enabled: true
            width: island.width; height: island.height
            Rectangle {
                x: -80; y: root.bt
                width: root.centered ? island.width + 160 : island.width - root.bt + 80
                height: island.height + 80
                radius: Config.border.rounding
            }
        }

        // -------------------------------------------------- la tarjeta
        Item {
            id: card

            // 1 = escondida tras el marco, 0 = visible
            property real offsetScale: root.effMode === "hidden" ? 1 : 0

            width: root.openShown ? root.openWidth : root.peekW
            height: root.openShown ? root.openHeight : root.peekH
            x: root.centered ? (island.width - width) / 2 : island.width - root.bt - root.cardGap - width
            y: root.bt + root.cardGap + (-height - 5) * offsetScale
            opacity: 1 - offsetScale
            visible: offsetScale < 1
            clip: true
            focus: true
            transform: Matrix4x4 { matrix: cardBg.deformMatrix }

            Keys.onEscapePressed: root.closeIsland()

            // Asomado: un clic en cualquier parte de la pestaña la abre.
            TapHandler {
                enabled: root.effMode === "peek"
                onTapped: root.openIsland()
            }

            Behavior on offsetScale { Spring {} }
            Behavior on width { Spring {} }
            Behavior on height { Spring {} }

            HoverHandler {
                onHoveredChanged: root.hoverCard = hovered
                onPointChanged: root.updateLook(point.position)
            }

            // Pulso en el borde cuando el agente espera una respuesta.
            Rectangle {
                id: pulse
                anchors.fill: parent
                radius: Tokens.rounding.extraLarge
                color: "transparent"
                border.width: 2
                border.color: Theme.tertiary
                opacity: 0
                SequentialAnimation {
                    running: root.hasPending
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) pulse.opacity = 0
                    NumberAnimation { target: pulse; property: "opacity"; to: 0.9; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { target: pulse; property: "opacity"; to: 0; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            // -------------------------------------------------- cabecera (aparece con retraso)
            Item {
                id: header
                x: 0; y: 0
                width: root.openWidth; height: 44
                // Fijadas desde root.onEffModeChanged ANTES de que `sizeMode` cambie (y con él esta
                // opacity): leerlas aquí mismo con un ternario sobre root.effMode llegaba tarde, la
                // animación arrancaba todavía con la duración de la transición anterior.
                property int fadeDelay: 0
                property int fadeDur: 0
                opacity: root.openShown && root.effMode === "open" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: header.fadeDelay }
                        // Al cerrar, desaparece de golpe (no en 120ms): en Chat/Tiempo/Ajustes-General
                        // Mochi está sentado sobre la cabecera y vuelve volando al pico, cruzando toda
                        // esta fila; si la cabecera tardaba en desvanecerse, su nombre e icono quedaban
                        // un instante detrás de Mochi en pleno vuelo.
                        NumberAnimation { duration: header.fadeDur }
                    }
                }

                Row {
                    visible: root.view === "overview" || root.view === "chat" || root.view === "time" || root.view === "settings"
                    anchors.left: parent.left; anchors.leftMargin: 26
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 16
                    Repeater {
                        model: [{ id: "overview", label: "Resumen", icon: "summarize" }, { id: "chat", label: "Chat", icon: "forum" },
                                { id: "time", label: "Tiempo", icon: "schedule" }, { id: "settings", label: "Ajustes", icon: "tune" }]
                        delegate: Item {
                            id: tabItem
                            required property var modelData
                            readonly property bool active: root.tab === tabItem.modelData.id
                            width: tabRow.implicitWidth; height: 30
                            Row {
                                id: tabRow
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: tabItem.active ? 6 : 0
                                Behavior on spacing { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                Icon {
                                    id: tabIcon
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: tabItem.modelData.icon; size: tabItem.active ? 18 : 20
                                    color: tabItem.active ? Theme.primary : Theme.m3onSurfaceVariant
                                    Behavior on color { ColorAnimation { duration: 160 } }
                                    Behavior on size { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                    SequentialAnimation {
                                        id: tapBounce
                                        NumberAnimation { target: tabIcon; property: "scale"; to: 1.35; duration: 90; easing.type: Easing.OutQuad }
                                        NumberAnimation { target: tabIcon; property: "scale"; to: 1; duration: 200; easing.type: Easing.OutBack }
                                    }
                                }
                                Item {
                                    id: labelClip
                                    clip: true
                                    height: 20
                                    width: tabItem.active ? labelText.implicitWidth : 0
                                    Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                    Text {
                                        id: labelText
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: tabItem.modelData.label
                                        font: Theme.label
                                        color: Theme.m3onSurface
                                        opacity: tabItem.active ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: tabItem.active ? 260 : 100 } }
                                    }
                                }
                            }
                            Rectangle {
                                anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                                height: 3; radius: 1.5; color: Theme.primary
                                width: tabItem.active ? parent.width : 0
                                Behavior on width { Spring { fast: true } }
                            }
                            TapHandler {
                                onTapped: { root.tab = tabItem.modelData.id; tapBounce.restart(); sounds.play("blip"); root.touchActivity(); }
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                        }
                    }
                }
                Text {
                    visible: root.view === "approval" || root.view === "question" || root.view === "alarm" || root.view === "upload"
                    anchors.left: parent.left; anchors.leftMargin: 26
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.m3onSurfaceVariant; font: Theme.label
                    text: root.view === "approval" ? "Permiso pendiente"
                        : root.view === "question" ? "Pregunta de Claude"
                        : root.view === "alarm" ? (root.alarms.length > 0 && root.alarms[0].kind === "pomo" ? "Pomodoro" : "Recordatorio")
                        : "Soltar archivos"
                }

                Row {
                    visible: root.working > 0 && root.view === "overview"
                    anchors.right: pinBtn.left; anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 3.5; color: Theme.success }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.success; font: Theme.caption
                        text: root.working
                    }
                }
                Item {
                    id: pinBtn
                    anchors.right: soundBtn.left; anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 36; height: 36
                    Rectangle {
                        anchors.fill: parent; radius: 18
                        color: root.pinnedOpen ? Theme.primaryContainer : (pinHover.hovered ? Theme.cardHigh : "transparent")
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }
                    Icon {
                        anchors.centerIn: parent
                        name: "push_pin"
                        size: 20
                        rotation: root.pinnedOpen ? 0 : 35
                        color: root.pinnedOpen ? Theme.m3onPrimaryContainer : Theme.m3onSurfaceVariant
                        Behavior on rotation { Spring { fast: true } }
                    }
                    HoverHandler { id: pinHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.pinnedOpen = !root.pinnedOpen; sounds.play("blip"); } }
                }
                Item {
                    id: soundBtn
                    anchors.right: parent.right; anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    width: 36; height: 36
                    Rectangle {
                        anchors.fill: parent; radius: 18
                        color: soundHover.hovered ? Theme.cardHigh : "transparent"
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }
                    Icon {
                        anchors.centerIn: parent
                        name: root.soundOn ? "volume_up" : "volume_off"
                        size: 22
                        color: root.soundOn ? Theme.primary : Theme.m3onSurfaceVariant
                    }
                    HoverHandler { id: soundHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.send({ type: "set_config", sound: !root.soundOn }) }
                }
            }

            // -------------------------------------------------- vista: resumen
            Item {
                id: overviewView
                anchors.fill: parent
                opacity: root.openShown && root.effMode === "open" && root.view === "overview" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: overviewView.opacity < 0.5 && root.view === "overview" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                readonly property var steps: root.focusSession ? root.focusSession.activity : []

                Column {
                    visible: !root.focusSession
                    x: 24; y: 204; width: root.openWidth - 48
                    spacing: 8
                    Text {
                        width: parent.width; wrapMode: Text.WordWrap
                        color: Theme.m3onSurface; font: Theme.title
                        text: "Nada en marcha por ahora."
                    }
                    Text {
                        width: parent.width; wrapMode: Text.WordWrap
                        color: Theme.m3onSurfaceVariant; font: Theme.caption
                        text: "Cuando un agente trabaje, verás aquí cada paso. Chatea con la pestaña de arriba."
                    }
                }

                Item {
                    visible: root.focusSession !== null
                    x: 24; y: 204; width: root.openWidth - 48; height: parent.height - 204

                    Row {
                        spacing: 9
                        height: 26
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10; height: 10; radius: 5
                            color: root.focusSession ? root.statusColor(root.focusSession.status) : Theme.m3onSurfaceVariant
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.m3onSurface; font: Theme.title
                            text: root.focusSession
                                ? root.agentName(root.focusSession.agent) + "  ·  " + root.baseName(root.focusSession.cwd) : ""
                        }
                    }
                    Text {
                        y: 28
                        width: parent.width - 40; elide: Text.ElideRight
                        color: root.focusMsg !== "" ? Theme.error
                             : (root.focusSession ? root.statusColor(root.focusSession.status) : Theme.m3onSurfaceVariant)
                        font: Theme.caption
                        text: root.focusMsg !== "" ? root.focusMsg : root.statusText(root.focusSession)
                    }
                    // Saltar a la ventana de la terminal de esta sesión
                    Item {
                        id: jumpBtn
                        anchors.right: parent.right; y: -4
                        width: 32; height: 32
                        Rectangle {
                            anchors.fill: parent; radius: 16
                            color: jumpHover.hovered ? Theme.cardHigh : "transparent"
                            Behavior on color { ColorAnimation { duration: 140 } }
                        }
                        Icon { anchors.centerIn: parent; name: "terminal"; size: 20; color: Theme.primary }
                        HoverHandler { id: jumpHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.jumpToTerminal(root.focusSession ? root.focusSession.id : "") }
                    }

                    // Defilé de pasos del agente (el más reciente abajo, resaltado)
                    Item {
                        id: stepsClip
                        y: 56; width: parent.width; height: 112
                        clip: true

                        Text {
                            visible: overviewView.steps.length === 0
                            anchors.bottom: parent.bottom; anchors.bottomMargin: 6
                            color: Theme.m3onSurfaceVariant; font: Theme.caption
                            text: "Sin actividad todavía"
                        }
                        Column {
                            id: stepsCol
                            width: parent.width
                            y: stepsClip.height - implicitHeight
                            Behavior on y { Spring { fast: true } }
                            Repeater {
                                model: overviewView.steps
                                delegate: Row {
                                    id: stepRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool current: index === overviewView.steps.length - 1
                                    width: stepsCol.width; height: 28; spacing: 10
                                    opacity: Math.max(0.2, 1 - (overviewView.steps.length - 1 - index) * 0.26)
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 24; height: 24; radius: 12
                                        color: stepRow.current ? Theme.primaryContainer : Theme.cardHigh
                                        Icon {
                                            anchors.centerIn: parent
                                            name: root.toolIcon(stepRow.modelData.tool)
                                            size: 14
                                            color: stepRow.current ? Theme.m3onPrimaryContainer : Theme.m3onSurfaceVariant
                                        }
                                    }
                                    Text {
                                        id: stepText
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 34; elide: Text.ElideMiddle
                                        font: Theme.caption
                                        color: stepRow.current ? Theme.m3onSurface : Theme.m3onSurfaceVariant
                                        maximumLineCount: 1
                                        textFormat: Text.PlainText
                                        text: stepRow.modelData.summary.replace(/\s+/g, " ")
                                        SequentialAnimation on opacity {
                                            running: stepRow.current && root.focusSession && root.focusSession.status === "working"
                                            loops: Animation.Infinite
                                            onRunningChanged: if (!running) stepText.opacity = 1
                                            NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Otras sesiones
                    Flow {
                        visible: root.sessions.length > 1
                        y: 176; width: parent.width; height: 28
                        spacing: 8; clip: true
                        Repeater {
                            model: root.sessions
                            delegate: Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool selected: root.focusSession && root.focusSession.id === modelData.id
                                height: 28; radius: 14
                                width: Math.min(150, chipLabel.implicitWidth + 38)
                                color: selected ? Theme.secondaryContainer : Theme.cardHigh
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Rectangle {
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 8; height: 8; radius: 4
                                    color: root.statusColor(chip.modelData.status)
                                }
                                Text {
                                    id: chipLabel
                                    anchors.left: parent.left; anchors.leftMargin: 28
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 36; elide: Text.ElideRight
                                    color: chip.selected ? Theme.m3onSecondaryContainer : Theme.m3onSurface
                                    font: Theme.caption
                                    text: root.baseName(chip.modelData.cwd) || root.agentName(chip.modelData.agent)
                                }
                                TapHandler {
                                    onTapped: { root.focusId = chip.modelData.id; sounds.play("blip"); }
                                }
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                            }
                        }
                    }
                }
            }

            // -------------------------------------------------- vista: permiso
            Item {
                id: approvalView
                anchors.fill: parent
                opacity: root.openShown && root.effMode === "open" && root.view === "approval" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: approvalView.opacity < 0.5 && root.view === "approval" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                readonly property var req: root.hasPending ? root.pending[0] : null

                Column {
                    x: 120; y: 50; width: root.openWidth - 120 - 28
                    spacing: 10
                    Text {
                        width: parent.width; elide: Text.ElideRight
                        color: Theme.m3onSurface; font: Theme.title
                        text: approvalView.req
                            ? root.agentName(approvalView.req.agent) + " quiere usar " + approvalView.req.tool
                              + (root.pending.length > 1 ? "  (+" + (root.pending.length - 1) + ")" : "")
                            : ""
                    }
                    Rectangle {
                        width: parent.width; height: 74; radius: 18
                        color: Theme.card
                        Text {
                            anchors.fill: parent; anchors.margins: 12
                            wrapMode: Text.WrapAnywhere; elide: Text.ElideRight; maximumLineCount: 3
                            color: Theme.m3onSurface
                            font.family: Theme.mono.family; font.pixelSize: 14
                            text: approvalView.req ? approvalView.req.summary : ""
                        }
                    }
                    Row {
                        spacing: 12
                        Repeater {
                            model: [
                                { label: "Rechazar", value: "deny" },
                                { label: "Permitir", value: "allow" }
                            ]
                            delegate: Rectangle {
                                id: btn
                                required property var modelData
                                readonly property bool primary: modelData.value === "allow"
                                width: 124; height: 40; radius: 20
                                color: primary ? Theme.primary : Theme.cardHigh
                                scale: btnTap.pressed ? 0.94 : 1
                                Behavior on scale { Spring { fast: true } }
                                Text {
                                    anchors.centerIn: parent
                                    text: btn.modelData.label
                                    color: btn.primary ? Theme.m3onPrimary : Theme.m3onSurface
                                    font: Theme.label
                                }
                                TapHandler {
                                    id: btnTap
                                    onTapped: if (approvalView.req) root.decide(approvalView.req.id, btn.modelData.value)
                                }
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                            }
                        }
                    }
                    // "Siempre permitir": guarda la regla que sugiere Claude Code (solo si ofreció una)
                    Text {
                        visible: approvalView.req !== null && approvalView.req.always_label !== null
                        width: parent.width; elide: Text.ElideRight
                        color: Theme.primary; font: Theme.caption
                        text: approvalView.req && approvalView.req.always_label ? "Siempre permitir  " + approvalView.req.always_label : ""
                        TapHandler { onTapped: if (approvalView.req) root.decide(approvalView.req.id, "allow_always") }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                    Text {
                        color: Theme.primary; font: Theme.caption
                        text: "Decidir en la terminal"
                        TapHandler { onTapped: root.askInTerminal(approvalView.req) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }

            // -------------------------------------------------- vista: pregunta de Claude
            Item {
                id: questionHolder
                anchors.fill: parent
                opacity: root.openShown && root.effMode === "open" && root.view === "question" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: questionHolder.opacity < 0.5 && root.view === "question" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                QuestionView {
                    id: questionView
                    x: 120; y: 50; width: root.openWidth - 120 - 28
                    req: root.hasPending && root.pending[0].kind === "question" ? root.pending[0] : null
                    onSubmit: answers => { if (req) root.decide(req.id, "allow", answers); }
                    onTerminal: root.askInTerminal(req)
                }
            }

            // -------------------------------------------------- vista: alarma
            Item {
                id: alarmView
                anchors.fill: parent
                opacity: root.openShown && root.effMode === "open" && root.view === "alarm" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: alarmView.opacity < 0.5 && root.view === "alarm" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                readonly property var alarm: root.alarms.length > 0 ? root.alarms[0] : null

                Column {
                    x: 140; y: 54; width: root.openWidth - 140 - 28
                    spacing: 10
                    Text {
                        width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                        color: Theme.m3onSurface; font: Theme.title
                        text: alarmView.alarm ? alarmView.alarm.label : ""
                    }
                    Row {
                        spacing: 10
                        Chip { label: "OK"; accent: true; onClicked: root.dismissAlarm() }
                        Chip {
                            visible: alarmView.alarm !== null && alarmView.alarm.kind === "reminder"
                            label: "+5 min"; iconName: "snooze"
                            onClicked: root.snoozeAlarm()
                        }
                    }
                }
            }

            // -------------------------------------------------- vista: soltar archivos
            Item {
                id: uploadView
                anchors.fill: parent
                opacity: root.openShown && root.effMode === "open" && root.view === "upload" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 200 } }

                Rectangle {
                    x: 140; y: 52; width: root.openWidth - 140 - 28; height: 96
                    radius: 22; color: Qt.alpha(Theme.successContainer, 0.6)
                    border.width: 2; border.color: Theme.success
                    Column {
                        anchors.centerIn: parent
                        spacing: 4
                        Text { anchors.horizontalCenter: parent.horizontalCenter; color: Theme.m3onSurface; font: Theme.title; text: "Suelta tus archivos aquí" }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; color: Theme.m3onSurfaceVariant; font: Theme.caption; text: "Se adjuntan al chat" }
                    }
                }
            }

            // -------------------------------------------------- vista: chat
            ChatView {
                id: chatView
                x: 16; y: 50; width: root.openWidth - 32; height: parent.height - 50 - 16
                opacity: root.openShown && root.effMode === "open" && root.view === "chat" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: chatView.opacity < 0.5 && root.view === "chat" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                messages: chatModel
                busy: root.chatBusy
                hasKey: root.hasKey
                backend: root.backend
                model: root.model
                models: root.models
                errorText: root.chatError
                attachments: root.attachments
                contexts: root.contexts

                onSendMessage: text => root.sendChat(text)
                onSaveKey: key => root.send({ type: "set_config", api_key: key })
                onToggleBackend: root.send({ type: "set_config", backend: root.backend === "api" ? "subscription" : "api" })
                onPickModel: m => root.send({ type: "set_config", model: m })
                onClearChat: { chatModel.clear(); root.contexts = []; root.chatError = ""; root.send({ type: "chat_reset" }); }
                onRemoveAttachment: index => root.attachments = root.attachments.filter((p, i) => i !== index)
                onRemoveContext: index => root.contexts = root.contexts.filter((c, i) => i !== index)
                onCancel: root.send({ type: "chat_cancel" })
                onCopyText: text => root.copyToClipboard(text)
                onGrab: what => root.grabContext(what)
            }

            // -------------------------------------------------- vista: tiempo (pomodoro y recordatorios)
            TimeView {
                id: timeView
                x: 16; y: 52; width: root.openWidth - 32; height: contentHeight
                opacity: root.openShown && root.effMode === "open" && root.view === "time" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: timeView.opacity < 0.5 && root.view === "time" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                timers: root.timers
                onPomoAction: action => { root.touchActivity(); root.send({ type: "pomo", action: action }); }
                onAddReminder: (secs, label) => { root.touchActivity(); root.send({ type: "timer_add", secs: secs, label: label }); sounds.play("blip"); }
                onCancelReminder: id => root.send({ type: "timer_cancel", id: id })
                onInteracted: root.touchActivity()
            }

            // -------------------------------------------------- vista: ajustes de Mochi
            SettingsView {
                id: settingsView
                x: 16; y: 54; width: root.openWidth - 32
                opacity: root.openShown && root.effMode === "open" && root.view === "settings" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { SequentialAnimation {
                    PauseAnimation { duration: settingsView.opacity < 0.5 && root.view === "settings" ? 220 : 0 }
                    NumberAnimation { duration: 220 } } }

                soundOn: root.soundOn
                volume: root.volume
                head: root.head
                face: root.face
                neck: root.neck
                accColor: root.accColor
                position: root.position
                sleepMinutes: root.sleepMinutes
                dance: root.dance
                pomoWork: root.timers.pomo.work_min
                pomoBreak: root.timers.pomo.break_min
                onPatch: values => {
                    root.touchActivity();
                    // Se aplica ya (vista previa en vivo) y el daemon lo guarda y lo confirma después.
                    if (values.head !== undefined) root.head = values.head;
                    if (values.face !== undefined) root.face = values.face;
                    if (values.neck !== undefined) root.neck = values.neck;
                    if (values.acc_color !== undefined) root.accColor = values.acc_color;
                    root.send(Object.assign({ type: "set_config" }, values));
                }
            }

            // -------------------------------------------------- música (MPRIS): reproductor y controles
            Rectangle {
                id: mediaRow
                x: 16; width: root.openWidth - 32; height: 38; radius: 19
                y: card.height - height - 12
                color: Theme.card
                opacity: overviewView.opacity
                visible: root.hasPlayer && overviewView.opacity > 0.01

                Icon {
                    id: noteIcon
                    anchors.left: parent.left; anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    name: "music_note"; size: 20; color: root.playing ? Theme.primary : Theme.m3onSurfaceVariant
                }
                Text {
                    anchors.left: noteIcon.right; anchors.leftMargin: 8
                    anchors.right: controls.left; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    color: Theme.m3onSurface; font: Theme.caption
                    text: root.player ? (root.player.trackTitle || "Sin título")
                          + (root.player.trackArtist ? "  ·  " + root.player.trackArtist : "") : ""
                }
                Row {
                    id: controls
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Repeater {
                        model: [{ i: "skip_previous", a: "previous" }, { i: "toggle", a: "toggle" }, { i: "skip_next", a: "next" }]
                        delegate: Item {
                            id: mb
                            required property var modelData
                            width: 32; height: 32
                            Rectangle {
                                anchors.fill: parent; radius: 16
                                color: mbHover.hovered ? Theme.cardHigh : "transparent"
                                Behavior on color { ColorAnimation { duration: 140 } }
                            }
                            Icon {
                                anchors.centerIn: parent; size: 22; color: Theme.m3onSurface
                                name: mb.modelData.i === "toggle" ? (root.playing ? "pause" : "play_arrow") : mb.modelData.i
                            }
                            HoverHandler { id: mbHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    if (!root.player) return;
                                    root.touchActivity();
                                    if (mb.modelData.a === "previous") root.player.previous();
                                    else if (mb.modelData.a === "next") root.player.next();
                                    else root.player.togglePlaying();
                                }
                            }
                        }
                    }
                }
            }

            // -------------------------------------------------- el archivo arrastrado (sigue al cursor)
            Icon {
                id: food
                z: 100
                name: "description"
                size: 46
                color: Theme.primary
                visible: root.dropping && root.foodOpacity > 0.01
                opacity: root.foodOpacity
                scale: root.foodScale
                rotation: root.foodRot
                x: root.foodX - width / 2
                y: root.foodY - height / 2
            }

            // -------------------------------------------------- aura rosa detrás de Mochi (como en coucou)
            // Aparte del Canvas del ajolote a propósito: un halo dibujado DENTRO del Canvas (como el
            // que ya trae Axolotl.qml para el color de ánimo) solo puede llegar hasta el borde de su
            // propio lienzo, que es justo del tamaño del cuerpo — por eso se sentía "una pared
            // invisible" cortándolo en vez de desvanecerse. Este vive fuera, más grande que el cuerpo,
            // y sigue a `character` en tiempo real (sus x/y/width ya animan con Spring).
            // Un círculo plano + MultiEffect de blur se veía "muy falso" (un blob con un aro parejo,
            // no un resplandor): coucou usa un degradado radial de verdad (opacidad plena en el centro,
            // 0 en el borde) — por eso aquí es un Canvas con createRadialGradient, igual que el halo de
            // ánimo que YA dibuja Axolotl.qml, en vez de pelear con un efecto para simular el degradado.
            Item {
                id: auraHolder
                // Asomada (pico) es chica y pegada al marco de Caelestia: un aura al 2.3x se salía
                // de él. Grande solo cuando la tarjeta está abierta (hay tarjeta detrás que la contiene).
                readonly property real d: character.width * (root.openShown ? 2.3 : 1.3)
                x: character.x + character.width / 2 - d / 2
                // Centrado en el CUERPO visible, no en la caja del Canvas: Axolotl.qml dibuja el
                // cuerpo apoyado cerca de la base (`ground - ry` = 0.9s - 0.28s = 0.62 de su alto),
                // no a la mitad — centrarla en 0.5 dejaba el aura notoriamente más arriba que Mochi.
                y: character.y + character.height * 0.62 - d / 2
                width: d; height: d
                visible: character.width > 4

                Canvas {
                    id: auraCanvas
                    anchors.fill: parent
                    property real breathe: 0.78
                    readonly property color c: character.gill
                    onBreatheChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        const cx = width / 2, cy = height / 2, r = width / 2;
                        const a = 0.34 * breathe;
                        const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
                        g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, a));
                        g.addColorStop(0.45, Qt.rgba(c.r, c.g, c.b, a * 0.5));
                        g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0));
                        ctx.fillStyle = g;
                        ctx.beginPath();
                        ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                        ctx.fill();
                    }
                    SequentialAnimation on breathe {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.55; duration: 2400; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0.78; duration: 2400; easing.type: Easing.InOutSine }
                    }
                }
            }

            // -------------------------------------------------- el ajolote (elemento compartido)
            Axolotl {
                id: character
                readonly property var geom: {
                    // Centrado en la masa visible de la pestaña (la tarjeta + el marco que tiene encima):
                    // el cuerpo del ajolote ocupa del 32 % al 90 % de su lienzo, de ahí el desplazamiento.
                    if (!root.openShown) return { x: 24, y: -12, s: 72 };
                    switch (root.view) {
                    case "approval": return { x: 12, y: 50, s: 98 };
                    case "question": return { x: 12, y: 50, s: 98 };
                    case "upload": return { x: 12, y: 46, s: 112 };
                    case "alarm": return { x: 12, y: 46, s: 112 };
                    case "chat": return { x: root.openWidth - 132, y: 2, s: 40 };
                    case "time": return { x: root.openWidth - 132, y: 2, s: 40 };
                    // Accesorios: Mochi en grande y centrado; General: pequeño en la cabecera.
                    case "settings": return settingsView.page === "accessories"
                        ? { x: (root.openWidth - settingsView.previewSize) / 2, y: settingsView.y + settingsView.previewY, s: settingsView.previewSize }
                        : { x: root.openWidth - 132, y: 2, s: 40 };
                    // Resumen: Mochi centrado arriba, el contenido va debajo (no al lado). Mismo
                    // tamaño que en Accesorios (`previewSize`): a 112 se sentía chico como protagonista.
                    default: return { x: (root.openWidth - settingsView.previewSize) / 2, y: 38, s: settingsView.previewSize };
                    }
                }
                x: geom.x; y: geom.y; width: geom.s; height: geom.s
                Behavior on x { Spring {} }
                Behavior on y { Spring {} }
                Behavior on width { Spring {} }
                Behavior on height { Spring {} }

                mood: root.mood
                head: root.head
                face: root.face
                neck: root.neck
                accColor: root.accColor
                minInterval: root.effMode !== "peek" ? 0 : (root.mood === "idle" && !hovered ? 33 : 16)
                lookX: root.lookX
                lookY: root.lookY
                mouthOpen: root.mouthOpen
                Behavior on lookX { NumberAnimation { duration: 140 } }
                Behavior on lookY { NumberAnimation { duration: 140 } }

                // Tragar: se estira hacia arriba, se encoge y vuelve (squish negativo = estirado).
                function gulp() { gulpAnim.restart(); }
                SequentialAnimation {
                    id: gulpAnim
                    NumberAnimation { target: character; property: "squish"; to: -0.4; duration: 90; easing.type: Easing.OutQuad }
                    NumberAnimation { target: character; property: "squish"; to: 0.55; duration: 110; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: character; property: "squish"; to: 0; duration: 230; easing.type: Easing.OutBack }
                }
                // La masticación se va apagando.
                NumberAnimation { id: chewDown; target: character; property: "chew"; from: 1; to: 0; duration: 1200; easing.type: Easing.InQuad }

                // Aplastamiento: 70 / 130 / 170 ms
                function slap() { slapAnim.restart(); }
                SequentialAnimation {
                    id: slapAnim
                    NumberAnimation { target: character; property: "squish"; to: 1; duration: 70; easing.type: Easing.OutQuad }
                    NumberAnimation { target: character; property: "squish"; to: -0.25; duration: 130; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: character; property: "squish"; to: 0; duration: 170; easing.type: Easing.OutBack }
                }

                // Pasivos: un MouseArea con hoverEnabled "robaría" el hover a la zona que
                // mantiene abierta la tarjeta y la cerraría al pasar el mouse por el ajolote.
                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: {
                        character.hovered = hovered;
                        if (hovered) {
                            if (root.effMode === "open") sounds.play("hover");
                            loveTimer.restart();
                        } else {
                            loveTimer.stop();
                        }
                    }
                    onPointChanged: if (hovered) loveTimer.restart()
                }
                TapHandler { onTapped: root.poke() }
            }

            // -------------------------------------------------- chispitas al cambiar un accesorio (Ajustes → Accesorios)
            Item {
                id: sparkleBurst
                property int seq: 0
                x: character.x + character.width / 2
                y: character.y + character.height / 2
                z: 60
                visible: root.previewing
                Behavior on x { Spring {} }
                Behavior on y { Spring {} }
                Repeater {
                    model: 8
                    delegate: Item {
                        id: starItem
                        required property int index
                        readonly property real angle: index * (Math.PI * 2 / 8)
                        property real dist: 0
                        x: -6; y: -6; width: 12; height: 12
                        opacity: 0
                        transform: Translate { x: Math.cos(starItem.angle) * starItem.dist; y: Math.sin(starItem.angle) * starItem.dist }
                        Icon { anchors.fill: parent; name: "star"; size: 12; color: Theme.primary }
                        Connections {
                            target: sparkleBurst
                            function onSeqChanged() { burstAnim.restart(); }
                        }
                        SequentialAnimation {
                            id: burstAnim
                            PropertyAction { target: starItem; property: "opacity"; value: 1 }
                            PropertyAction { target: starItem; property: "dist"; value: 0 }
                            ParallelAnimation {
                                NumberAnimation { target: starItem; property: "dist"; to: 46; duration: 420; easing.type: Easing.OutCubic }
                                NumberAnimation { target: starItem; property: "opacity"; to: 0; duration: 420; easing.type: Easing.InQuad }
                            }
                        }
                    }
                }
            }
        }
    }
}
