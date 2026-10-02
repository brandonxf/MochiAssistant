import QtQuick

// Interruptor.
Rectangle {
    id: root

    property bool checked: false
    signal toggled(bool value)

    width: 46; height: 26; radius: 13
    color: checked ? Theme.primary : Theme.cardHigh
    Behavior on color { ColorAnimation { duration: 160 } }

    Rectangle {
        width: 20; height: 20; radius: 10; y: 3
        x: root.checked ? root.width - width - 3 : 3
        color: root.checked ? Theme.m3onPrimary : Theme.m3onSurfaceVariant
        Behavior on x { Spring { fast: true } }
        Behavior on color { ColorAnimation { duration: 160 } }
    }

    TapHandler { onTapped: root.toggled(!root.checked) }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
}
