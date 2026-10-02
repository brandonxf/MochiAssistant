import QtQuick

// Deslizador 0..1. Mientras se arrastra muestra su propio valor; al soltar emite `released`.
Item {
    id: root

    property real value: 0.5
    property bool dragging: false
    property real local: 0.5
    readonly property real shown: dragging ? local : value
    signal released(real value)

    width: 160; height: 26

    function setFrom(x) {
        local = Math.max(0, Math.min(1, (x - 9) / (width - 18)));
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width; height: 6; radius: 3
        color: Theme.cardHigh
        Rectangle { width: parent.width * root.shown; height: parent.height; radius: 3; color: Theme.primary }
    }
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 18; height: 18; radius: 9
        x: root.shown * (root.width - width)
        color: Theme.primary
        scale: root.dragging ? 1.2 : 1
        Behavior on scale { Spring { fast: true } }
    }
    // Sin hoverEnabled: no le quita el hover a la tarjeta.
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: m => { root.dragging = true; root.setFrom(m.x); }
        onPositionChanged: m => root.setFrom(m.x)
        onReleased: { root.dragging = false; root.released(root.local); }
    }
}
