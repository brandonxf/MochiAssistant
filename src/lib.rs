//! Protocolo compartido entre el hook, el daemon y la UI (líneas JSON sobre un socket Unix).

use std::path::PathBuf;

pub fn socket_path() -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("axolotl.sock")
}

/// Estado visible de una sesión de agente.
pub fn status_for_event(event: &str) -> Option<&'static str> {
    match event {
        "SessionStart" | "Stop" | "AfterAgent" => Some("idle"),
        "StopFailure" => Some("error"),
        "UserPromptSubmit" | "BeforeAgent" | "PreToolUse" | "BeforeTool" | "PostToolUse"
        | "AfterTool" | "PreInvocation" | "PostInvocation" => Some("working"),
        "Notification" | "PermissionRequest" => Some("waiting"),
        _ => None,
    }
}

/// Eventos que cuentan como "el agente empezó a usar una herramienta".
pub fn is_tool_start(event: &str) -> bool {
    matches!(event, "PreToolUse" | "BeforeTool")
}

/// Eventos que cuentan como "el agente terminó su turno".
pub fn is_turn_end(event: &str) -> bool {
    matches!(event, "Stop" | "AfterAgent")
}
