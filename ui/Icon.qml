import QtQuick

// Icono de Material Symbols Rounded (la fuente que usa Caelestia). `name` es el nombre del símbolo.
Text {
    property string name
    property int size: 20

    text: name
    font.family: Theme.iconFamily
    font.pixelSize: size
    color: Theme.m3onSurface
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering
}
