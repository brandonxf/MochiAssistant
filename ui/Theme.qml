pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.Images

// Colores dinámicos de Caelestia: lee el mismo scheme.json que vigila el shell
// (~/.local/state/caelestia/scheme.json), así la isla cambia con el wallpaper.
Singleton {
    id: root

    property bool light: false
    property var prev: ({})
    property var next: ({})
    property real mixT: 1            // 0 = esquema anterior, 1 = esquema nuevo

    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/caelestia"
    readonly property string statePath: stateDir + "/scheme.json"

    // Luminancia del wallpaper, con el mismo analizador que usa Colours.qml de Caelestia
    // (Caelestia.Images.ImageAnalyser sobre el wallpaper actual, leído de su fichero de estado).
    property string wallPath: ""
    readonly property real wallLuminance: analyser.luminance
    ImageAnalyser { id: analyser; source: root.wallPath }
    FileView {
        path: root.stateDir + "/wallpaper/path.txt"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.wallPath = text().trim()
    }

    // --- Transparencia (misma fórmula que Colours.qml de Caelestia)
    readonly property bool transparent: Tokens.transparency.enabled
    readonly property real tBase: Math.max(0, Math.min(1, Tokens.transparency.base - (light ? 0.1 : 0)))
    readonly property real tLayers: Math.max(0, Math.min(1, Tokens.transparency.layers))

    function hex(map, name, fallback) {
        const v = map[name];
        return v ? "#" + v : fallback;
    }
    function blend(name, fallback) {
        const a = Qt.color(hex(prev, name, fallback)), b = Qt.color(hex(next, name, fallback));
        return Qt.rgba(a.r + (b.r - a.r) * mixT, a.g + (b.g - a.g) * mixT, a.b + (b.b - a.b) * mixT, 1);
    }

    function luminance(c) {
        return Math.sqrt(0.299 * c.r * c.r + 0.587 * c.g * c.g + 0.114 * c.b * c.b);
    }
    // Capa translúcida: 0 = superficie del marco; 1.. = contenedores encima.
    // Copia de Colours.layer/alterColour de Caelestia, incluido el término de luminancia del wallpaper.
    function layer(c, n) {
        if (!transparent) return c;
        if (n === 0) return Qt.alpha(c, tBase);
        const lum = luminance(c);
        if (lum === 0) return Qt.alpha(c, tLayers);
        const offset = (!light || n === 1 ? 1 : -n / 2) * (light ? 0.2 : 0.3) * (1 - tBase)
                     * (1 + wallLuminance * (light ? (n === 1 ? 3 : 1) : 2.5));
        const k = (lum + offset) / lum;
        return Qt.rgba(Math.max(0, Math.min(1, c.r * k)), Math.max(0, Math.min(1, c.g * k)),
                       Math.max(0, Math.min(1, c.b * k)), tLayers);
    }

    // --- Paleta (con los valores por defecto de Caelestia si aún no hay scheme.json)
    readonly property color surface: blend("surface", "#191114")
    readonly property color m3onSurface: blend("onSurface", "#efdfe2")
    readonly property color m3onSurfaceVariant: blend("onSurfaceVariant", "#d5c2c6")
    readonly property color surfaceContainer: blend("surfaceContainer", "#261d20")
    readonly property color surfaceContainerHigh: blend("surfaceContainerHigh", "#31282a")
    readonly property color surfaceContainerHighest: blend("surfaceContainerHighest", "#3c3235")
    readonly property color primary: blend("primary", "#ffb0ca")
    readonly property color m3onPrimary: blend("onPrimary", "#541d34")
    readonly property color primaryContainer: blend("primaryContainer", "#6f334a")
    readonly property color m3onPrimaryContainer: blend("onPrimaryContainer", "#ffd9e3")
    readonly property color secondary: blend("secondary", "#e2bdc7")
    readonly property color secondaryContainer: blend("secondaryContainer", "#5a3f48")
    readonly property color m3onSecondaryContainer: blend("onSecondaryContainer", "#ffd9e3")
    readonly property color tertiary: blend("tertiary", "#efbc95")
    readonly property color m3onTertiary: blend("onTertiary", "#48290c")
    readonly property color tertiaryContainer: blend("tertiaryContainer", "#5d4033")
    readonly property color m3onTertiaryContainer: blend("onTertiaryContainer", "#ffdcc7")
    readonly property color error: blend("error", "#ffb4ab")
    readonly property color m3onError: blend("onError", "#690005")
    readonly property color errorContainer: blend("errorContainer", "#93000a")
    readonly property color m3onErrorContainer: blend("onErrorContainer", "#ffdad6")
    readonly property color success: blend("success", "#b5ccba")
    readonly property color m3onSuccess: blend("onSuccess", "#213528")
    readonly property color successContainer: blend("successContainer", "#374b3e")
    readonly property color outlineVariant: blend("outlineVariant", "#514347")
    readonly property color shadow: blend("shadow", "#000000")

    // Color del marco y de las tarjetas (con transparencia, como el resto del shell)
    readonly property color frame: layer(surface, 0)
    // Capa 1, como Colours.tPalette.m3surfaceContainer* (lo que usan las tarjetas del dashboard)
    readonly property color card: layer(surfaceContainer, 1)
    readonly property color cardHigh: layer(surfaceContainerHigh, 1)

    // --- Tipografías de Caelestia
    readonly property font title: Tokens.font.title.small
    readonly property font body: Tokens.font.body.small
    readonly property font label: Tokens.font.label.medium
    readonly property font caption: Tokens.font.label.small
    readonly property font mono: Tokens.font.mono.small
    readonly property string iconFamily: Tokens.font.icon.small.family

    // Misma regla de capa que Caelestia aplica a sus paneles (Colours.reloadHyprRules): el umbral
    // de ignore_alpha depende de la transparencia base, que cambia entre modo claro y oscuro.
    function reloadHyprRule() {
        if (!Tokens.transparency.base) return;
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.layer_rule({ match = { namespace = "axolotl-notch" }, blur = ${transparent}, ignore_alpha = ${Math.max(0, tBase - 0.03).toFixed(3)} })`]);
    }
    Timer { id: ruleTimer; interval: 300; onTriggered: root.reloadHyprRule() }
    onTBaseChanged: ruleTimer.restart()
    onTransparentChanged: ruleTimer.restart()
    Component.onCompleted: ruleTimer.restart()

    function load(text) {
        let data;
        try { data = JSON.parse(text); } catch (e) { return; }
        if (!data || !data.colours) return;
        prev = next;
        next = data.colours;
        light = data.mode === "light";
        mixT = 0;
        fade.restart();
    }

    // Mismo fundido que CAnim de Caelestia (el que usa para surfaceColour al cambiar de esquema)
    NumberAnimation { id: fade; target: root; property: "mixT"; to: 1
                      duration: Tokens.anim.durations.expressiveSlowEffects; easing: Tokens.anim.expressiveSlowEffects }

    FileView {
        path: root.statePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.load(text())
    }
}
