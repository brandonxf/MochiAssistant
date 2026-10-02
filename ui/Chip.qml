import QtQuick

// Píldora seleccionable (opciones, filtros, acciones pequeñas).
Rectangle {
    id: root

    property string label: ""
    property string iconName: ""
    property bool selected: false
    property bool accent: false          // resaltada como acción principal
    signal clicked()

    height: 30
    radius: 15
    property int pad: 28
    width: content.implicitWidth + pad
    color: accent ? Theme.primary : (selected ? Theme.secondaryContainer : Theme.cardHigh)
    scale: tap.pressed ? 0.95 : 1
    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on scale { Spring { fast: true } }

    readonly property color ink: accent ? Theme.m3onPrimary : (selected ? Theme.m3onSecondaryContainer : Theme.m3onSurface)

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 5
        Icon { visible: root.iconName !== ""; name: root.iconName; size: 16; color: root.ink; anchors.verticalCenter: parent.verticalCenter }
        Text { text: root.label; font: Theme.caption; color: root.ink; anchors.verticalCenter: parent.verticalCenter }
    }

    TapHandler { id: tap; onTapped: root.clicked() }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
}
