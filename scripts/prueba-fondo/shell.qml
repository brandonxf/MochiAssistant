import QtQuick
import Quickshell
import Quickshell.Wayland

// Fondo limpio para `prueba --limpio`: sustituye al wallpaper en un espacio de trabajo vacío.
// Capa Bottom: queda bajo las ventanas y bajo el marco de Caelestia.
ShellRoot {
    PanelWindow {
        anchors.top: true; anchors.bottom: true; anchors.left: true; anchors.right: true
        exclusionMode: ExclusionMode.Ignore
        color: "#14101f"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "prueba-fondo"
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#17122b" }
                GradientStop { position: 0.55; color: "#2b1d52" }
                GradientStop { position: 1.0; color: "#4a2a6e" }
            }
        }
        Canvas {
            anchors.fill: parent
            onPaint: {
                const c = getContext("2d");
                const g = c.createRadialGradient(width * 0.8, height * 0.12, 0, width * 0.8, height * 0.12, 760);
                g.addColorStop(0, "rgba(244,130,156,0.30)"); g.addColorStop(1, "rgba(244,130,156,0)");
                c.fillStyle = g; c.fillRect(0, 0, width, height);
            }
        }
    }
}
