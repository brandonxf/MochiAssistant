import QtQuick
import Caelestia.Config

// Animación espacial de Caelestia (500 ms con ligero rebote), leída de sus tokens.
// `fast: true` usa la variante rápida para movimientos pequeños.
NumberAnimation {
    property bool fast: false

    duration: fast ? Tokens.anim.durations.expressiveFastSpatial : Tokens.anim.durations.expressiveDefaultSpatial
    easing: fast ? Tokens.anim.expressiveFastSpatial : Tokens.anim.expressiveDefaultSpatial
}
