import QtQuick

// Ajustes de Mochi, en dos secciones: General y Accesorios (con Mochi en grande y en vivo).
// No guarda nada: emite `patch({...})` y el daemon persiste la configuración.
Item {
    id: root

    property bool soundOn: true
    property real volume: 0.5
    property string head: "none"
    property string face: "none"
    property string neck: "none"
    property string accColor: "auto"
    property string position: "right"
    property int sleepMinutes: 10
    property bool dance: true
    property int pomoWork: 25
    property int pomoBreak: 5
    property string page: "general"       // general | accessories
    signal patch(var values)

    // Mochi se dibuja en shell.qml (elemento compartido): aquí solo se reserva el hueco de la vista previa.
    readonly property int previewSize: 144
    readonly property int previewY: pageRow.height + 8
    readonly property real contentHeight: pageRow.height + 12
        + (page === "general" ? generalCol.implicitHeight : accCol.implicitHeight)

    readonly property var swatches: ["#e5484d", "#fb923c", "#fbbf24", "#34d399", "#60a5fa", "#a78bfa", "#ff5d9e", "#f5f5f7", "#1f2937"]

    component Row2: Item {
        id: r
        property string title: ""
        property string iconName: ""
        property int labelWidth: 64
        default property alias content: slot.data
        width: parent.width
        height: Math.max(30, slot.childrenRect.height)
        Row {
            width: r.labelWidth; height: 30
            spacing: 5
            Icon { visible: r.iconName !== ""; anchors.verticalCenter: parent.verticalCenter; name: r.iconName; size: 15; color: Theme.primary }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.m3onSurfaceVariant; font: Theme.caption
                text: r.title
            }
        }
        Item {
            id: slot
            x: r.labelWidth; width: parent.width - r.labelWidth
            height: childrenRect.height
        }
    }

    // Tarjeta compacta con icono + título arriba y el control debajo; usada en la pestaña General.
    component SettingCard: Rectangle {
        id: card
        property string title: ""
        property string iconName: ""
        default property alias content: slot.data
        radius: 16
        color: Theme.cardHigh
        height: inner.implicitHeight + 24
        Column {
            id: inner
            x: 14; y: 12; width: parent.width - 28
            spacing: 8
            Row {
                spacing: 6
                Icon { anchors.verticalCenter: parent.verticalCenter; name: card.iconName; size: 16; color: Theme.primary }
                Text { anchors.verticalCenter: parent.verticalCenter; text: card.title; font: Theme.caption; color: Theme.m3onSurfaceVariant }
            }
            Item { id: slot; width: parent.width; height: childrenRect.height }
        }
    }

    // Selector tipo "carrusel de juego": flechas a los lados, el nombre entra deslizándose
    // y rebotando, puntitos abajo marcan cuántas opciones hay. Usado en Accesorios.
    component PickerCard: Rectangle {
        id: card
        property string title: ""
        property string iconName: ""
        property var items: []            // [{ l, v }]
        property var current
        property int slideDir: 1
        signal picked(var value)
        radius: 16
        color: Theme.cardHigh
        height: 106

        readonly property int idx: Math.max(0, card.items.findIndex(it => it.v === card.current))

        function move(dir) {
            if (card.items.length < 2) return;
            card.slideDir = dir;
            const next = (card.idx + dir + card.items.length) % card.items.length;
            card.picked(card.items[next].v);
            slideAnim.restart();
            popAnim.restart();
        }

        Row {
            x: 14; y: 12; spacing: 6
            Icon { anchors.verticalCenter: parent.verticalCenter; name: card.iconName; size: 15; color: Theme.primary }
            Text { anchors.verticalCenter: parent.verticalCenter; text: card.title; font: Theme.caption; color: Theme.m3onSurfaceVariant }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 38
            spacing: 8
            Rectangle {
                id: prevBtn
                width: 34; height: 34; radius: 17
                anchors.verticalCenter: parent.verticalCenter
                color: prevHover.hovered ? Theme.card : "transparent"
                Icon { anchors.centerIn: parent; name: "chevron_left"; size: 19; color: Theme.primary }
                scale: prevTap.pressed ? 0.82 : 1
                Behavior on scale { Spring { fast: true } }
                TapHandler { id: prevTap; onTapped: card.move(-1) }
                HoverHandler { id: prevHover; cursorShape: Qt.PointingHandCursor }
            }
            Item {
                id: labelClip
                width: 150; height: 34
                clip: true
                Text {
                    id: labelTxt
                    property real offsetX: 0
                    anchors.verticalCenter: parent.verticalCenter
                    x: (labelClip.width - width) / 2 + offsetX
                    width: labelClip.width
                    horizontalAlignment: Text.AlignHCenter
                    font: Theme.body
                    color: Theme.m3onSurface
                    text: card.items[card.idx] ? card.items[card.idx].l : ""
                }
            }
            Rectangle {
                id: nextBtn
                width: 34; height: 34; radius: 17
                anchors.verticalCenter: parent.verticalCenter
                color: nextHover.hovered ? Theme.card : "transparent"
                Icon { anchors.centerIn: parent; name: "chevron_right"; size: 19; color: Theme.primary }
                scale: nextTap.pressed ? 0.82 : 1
                Behavior on scale { Spring { fast: true } }
                TapHandler { id: nextTap; onTapped: card.move(1) }
                HoverHandler { id: nextHover; cursorShape: Qt.PointingHandCursor }
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 80
            spacing: 5
            Repeater {
                model: card.items.length
                delegate: Rectangle {
                    required property int index
                    width: index === card.idx ? 14 : 6; height: 6; radius: 3
                    color: index === card.idx ? Theme.primary : Theme.outlineVariant
                    Behavior on width { Spring { fast: true } }
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
            }
        }

        SequentialAnimation {
            id: slideAnim
            PropertyAction { target: labelTxt; property: "offsetX"; value: card.slideDir > 0 ? 20 : -20 }
            PropertyAction { target: labelTxt; property: "opacity"; value: 0 }
            ParallelAnimation {
                NumberAnimation { target: labelTxt; property: "offsetX"; to: 0; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { target: labelTxt; property: "opacity"; to: 1; duration: 190 }
            }
        }
        SequentialAnimation {
            id: popAnim
            NumberAnimation { target: labelTxt; property: "scale"; to: 1.18; duration: 90; easing.type: Easing.OutQuad }
            NumberAnimation { target: labelTxt; property: "scale"; to: 1; duration: 220; easing.type: Easing.OutBack }
        }
    }

    component Options: Flow {
        id: f
        property var items: []            // [{ l, v }]
        property var current
        property int pad: 28
        signal picked(var value)
        width: parent.width; spacing: 6
        Repeater {
            model: f.items
            delegate: Chip {
                required property var modelData
                pad: f.pad
                label: modelData.l
                selected: f.current === modelData.v
                onClicked: f.picked(modelData.v)
            }
        }
    }

    // ------------------------------------------------------------ selector de sección
    Row {
        id: pageRow
        spacing: 8
        height: 30
        Chip { label: "General"; iconName: "tune"; selected: root.page === "general"; onClicked: root.page = "general" }
        Chip { label: "Accesorios"; iconName: "checkroom"; selected: root.page === "accessories"; onClicked: root.page = "accessories" }
    }
    Chip {
        visible: root.page === "accessories"
        anchors.right: parent.right; anchors.top: pageRow.top
        label: "Quitar todo"; iconName: "restart_alt"
        onClicked: root.patch({ head: "none", face: "none", neck: "none", acc_color: "auto" })
    }

    // ------------------------------------------------------------ General
    Column {
        id: generalCol
        visible: root.page === "general"
        anchors.top: pageRow.bottom; anchors.topMargin: 14
        width: parent.width
        spacing: 12

        readonly property int colW: (width - 12) / 2

        Grid {
            columns: 2; columnSpacing: 12; rowSpacing: 12

            SettingCard {
                width: generalCol.colW
                title: "Sonido"; iconName: "volume_up"
                Row {
                    spacing: 10
                    Toggle { anchors.verticalCenter: parent.verticalCenter; checked: root.soundOn; onToggled: v => root.patch({ sound: v }) }
                    VolumeSlider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 110
                        value: root.volume
                        opacity: root.soundOn ? 1 : 0.4
                        onReleased: v => root.patch({ volume: v })
                    }
                }
            }
            SettingCard {
                width: generalCol.colW
                title: "Posición"; iconName: "my_location"
                Options {
                    pad: 18
                    items: [{ l: "Derecha", v: "right" }, { l: "Centro", v: "center" }]
                    current: root.position
                    onPicked: v => root.patch({ position: v })
                }
            }
            SettingCard {
                width: generalCol.colW
                title: "Dormir tras"; iconName: "bedtime"
                Options {
                    pad: 16
                    items: [{ l: "Nunca", v: 0 }, { l: "5 min", v: 5 }, { l: "10 min", v: 10 }, { l: "30 min", v: 30 }]
                    current: root.sleepMinutes
                    onPicked: v => root.patch({ sleep_minutes: v })
                }
            }
            SettingCard {
                width: generalCol.colW
                title: "Baila con música"; iconName: "music_note"
                Toggle { checked: root.dance; onToggled: v => root.patch({ dance: v }) }
            }
        }

        SettingCard {
            width: parent.width
            title: "Pomodoro"; iconName: "timer"
            Flow {
                width: parent.width; spacing: 6
                Repeater {
                    model: [{ l: "25 / 5", w: 25, b: 5 }, { l: "50 / 10", w: 50, b: 10 }, { l: "15 / 3", w: 15, b: 3 }]
                    delegate: Chip {
                        required property var modelData
                        label: modelData.l + " min"
                        selected: root.pomoWork === modelData.w && root.pomoBreak === modelData.b
                        onClicked: root.patch({ pomo_work: modelData.w, pomo_break: modelData.b })
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ Accesorios
    Column {
        id: accCol
        visible: root.page === "accessories"
        anchors.top: pageRow.bottom; anchors.topMargin: 6
        width: parent.width
        spacing: 10

        // hueco de Mochi (lo dibuja shell.qml encima, centrado)
        Item { width: parent.width; height: root.previewSize }

        PickerCard {
            width: parent.width
            title: "Cabeza"; iconName: "auto_awesome"
            items: [{ l: "Ninguno", v: "none" }, { l: "Gorrito", v: "beanie" }, { l: "Corona", v: "crown" },
                    { l: "Moño", v: "bow" }, { l: "Chistera", v: "tophat" }, { l: "Orejas", v: "catears" },
                    { l: "Aureola", v: "halo" }, { l: "Cuernos", v: "horns" }, { l: "Gorra", v: "cap" },
                    { l: "Mago", v: "wizard" }, { l: "Flor", v: "flower" }]
            current: root.head
            onPicked: v => root.patch({ head: v })
        }
        PickerCard {
            width: parent.width
            title: "Cara"; iconName: "visibility"
            items: [{ l: "Ninguno", v: "none" }, { l: "Gafas", v: "glasses" }, { l: "De sol", v: "sunglasses" },
                    { l: "Monóculo", v: "monocle" }, { l: "Bigote", v: "mustache" }]
            current: root.face
            onPicked: v => root.patch({ face: v })
        }
        PickerCard {
            width: parent.width
            title: "Cuello"; iconName: "style"
            items: [{ l: "Ninguno", v: "none" }, { l: "Bufanda", v: "scarf" }, { l: "Pajarita", v: "bowtie" }, { l: "Cascabel", v: "bell" }]
            current: root.neck
            onPicked: v => root.patch({ neck: v })
        }
        SettingCard {
            width: parent.width
            title: "Color"; iconName: "palette"
            Flow {
                width: parent.width; spacing: 8
                Chip { label: "Auto"; pad: 20; selected: root.accColor === "auto"; onClicked: root.patch({ acc_color: "auto" }) }
                Repeater {
                    model: root.swatches
                    delegate: Rectangle {
                        id: sw
                        required property string modelData
                        width: 30; height: 30; radius: 15
                        color: modelData
                        border.width: root.accColor === modelData ? 3 : 1
                        border.color: root.accColor === modelData ? Theme.primary : Theme.outlineVariant
                        scale: swTap.pressed ? 0.85 : (root.accColor === modelData ? 1.12 : 1)
                        Behavior on scale { Spring { fast: true } }
                        TapHandler { id: swTap; onTapped: root.patch({ acc_color: sw.modelData }) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }
        }
    }
}
