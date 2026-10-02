import QtQuick
import QtQml
import QtMultimedia

// Efectos de sonido precargados (ui/sounds/*.wav, generados por scripts/gen_sounds.py).
// Uso: sounds.play("greet"). Se apaga con `enabled: false`.
Item {
    id: root

    property bool enabled: true
    property real volume: 0.5

    readonly property var names: [
        "peek", "greet", "open", "close", "hover", "blip", "pop", "slap", "annoyed", "dizzy",
        "love", "approval", "question", "error", "finish", "approve", "deny", "gulp", "send", "receive"
    ]
    property var effects: ({})

    function play(name) {
        if (!enabled) return;
        const fx = effects[name];
        if (fx) fx.play();
    }

    Instantiator {
        model: root.names
        delegate: SoundEffect {
            required property string modelData
            source: Qt.resolvedUrl("sounds/" + modelData + ".wav")
            volume: root.volume * 0.6
        }
        onObjectAdded: (index, object) => root.effects[object.modelData] = object
    }
}
