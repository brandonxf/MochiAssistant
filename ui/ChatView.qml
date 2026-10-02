import QtQuick

// Chat con la API de Anthropic. No habla con el daemon directamente: expone señales y
// propiedades para que shell.qml lo conecte al socket.
Item {
    id: root

    required property ListModel messages
    property bool busy: false
    property bool hasKey: false
    property string backend: "subscription"      // subscription | api
    readonly property bool needsKey: backend === "api" && !hasKey
    property string model: ""
    property var models: []
    property string errorText: ""
    property var attachments: []          // rutas locales de archivos adjuntos
    property var contexts: []             // fragmentos de texto adjuntos: [{label, text}]
    readonly property int extras: attachments.length + contexts.length
    readonly property bool inputFocused: input.activeFocus || keyInput.activeFocus

    signal sendMessage(string text)
    signal saveKey(string key)
    signal toggleBackend()
    signal pickModel(string model)
    signal clearChat()
    signal removeAttachment(int index)
    signal removeContext(int index)
    signal cancel()
    signal copyText(string text)
    signal grab(string what)
    signal interacted()

    function baseName(p) {
        const parts = (p || "").split("/").filter(x => x.length > 0);
        return parts.length ? parts[parts.length - 1] : "";
    }
    function shortModel(m) {
        return (m || "").replace(/^claude-/, "").replace(/-\d{8}$/, "");
    }
    function focusInput() { if (needsKey) keyInput.forceActiveFocus(); else input.forceActiveFocus(); }
    function submit() {
        const text = input.text.trim();
        if (text.length === 0 || busy) return;
        sendMessage(text);
        input.text = "";
    }

    // Pastilla de Caelestia: fondo de capa translúcida, sin borde.
    component Pill: Rectangle {
        radius: height / 2
        color: Theme.cardHigh
    }

    // ------------------------------------------------------------ sin clave de API
    Column {
        visible: root.needsKey
        anchors.centerIn: parent
        width: parent.width - 48
        spacing: 12

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: Theme.m3onSurface
            font: Theme.body
            text: "Pega tu clave de API de Anthropic para chatear desde la isla."
        }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: Theme.m3onSurfaceVariant
            font: Theme.caption
            text: "Se guarda en ~/.config/axolotl-notch/config.json (solo tu usuario puede leerla)."
        }
        Pill {
            width: parent.width; height: 40
            border.width: keyInput.activeFocus ? 2 : 0
            border.color: Theme.primary
            TextInput {
                id: keyInput
                anchors.fill: parent
                anchors.leftMargin: 18; anchors.rightMargin: 18
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.m3onSurface
                font: Theme.body
                echoMode: TextInput.Password
                clip: true
                selectByMouse: true
                onTextEdited: root.interacted()
                onAccepted: if (text.trim().length > 0) { root.saveKey(text.trim()); text = ""; }
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !keyInput.text && !keyInput.activeFocus
                    color: Theme.m3onSurfaceVariant; font: Theme.body
                    text: "sk-ant-…"
                }
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 120; height: 36; radius: 18
            readonly property bool ready: keyInput.text.trim().length > 0
            color: ready ? Theme.primary : Theme.cardHigh
            Behavior on color { ColorAnimation { duration: 160 } }
            Text {
                anchors.centerIn: parent
                text: "Guardar"
                font: Theme.label
                color: parent.ready ? Theme.m3onPrimary : Theme.m3onSurfaceVariant
            }
            TapHandler {
                onTapped: if (parent.ready) { root.saveKey(keyInput.text.trim()); keyInput.text = ""; }
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: Theme.primary; font: Theme.caption
            text: "Usar mi suscripción de Claude"
            TapHandler { onTapped: root.toggleBackend() }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
    }

    // ------------------------------------------------------------ chat
    Item {
        visible: !root.needsKey
        anchors.fill: parent

        // Barra superior: modelo y nueva conversación
        Item {
            id: topBar
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: 30

            Pill {
                id: backendChip
                height: 28
                width: backendText.implicitWidth + 24
                color: Theme.secondaryContainer
                Text {
                    id: backendText
                    anchors.centerIn: parent
                    color: Theme.m3onSecondaryContainer
                    font: Theme.caption
                    text: root.backend === "api" ? "API" : "Suscripción"
                }
                TapHandler { onTapped: { root.toggleBackend(); root.interacted(); } }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
            Pill {
                id: modelChip
                anchors.left: backendChip.right; anchors.leftMargin: 8
                height: 28
                width: modelRow.implicitWidth + 24
                color: picker.visible ? Theme.primaryContainer : Theme.cardHigh
                Behavior on color { ColorAnimation { duration: 160 } }
                Row {
                    id: modelRow
                    anchors.centerIn: parent
                    spacing: 4
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        color: picker.visible ? Theme.m3onPrimaryContainer : Theme.m3onSurface
                        font: Theme.caption
                        text: root.shortModel(root.model)
                    }
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "keyboard_arrow_down"; size: 18
                        color: picker.visible ? Theme.m3onPrimaryContainer : Theme.m3onSurfaceVariant
                    }
                }
                TapHandler { onTapped: { picker.visible = !picker.visible; root.interacted(); } }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.messages.count > 0 && !root.busy
                spacing: 4
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "add"; size: 18; color: Theme.m3onSurfaceVariant }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.m3onSurfaceVariant
                    font: Theme.caption
                    text: "Nueva conversación"
                }
                TapHandler { onTapped: { root.clearChat(); root.interacted(); } }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }

        // Mensajes
        ListView {
            id: list
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: topBar.bottom; anchors.topMargin: 8
            anchors.bottom: quick.top; anchors.bottomMargin: 6
            clip: true
            spacing: 8
            model: root.messages
            boundsBehavior: Flickable.StopAtBounds

            onCountChanged: Qt.callLater(() => list.positionViewAtEnd())
            Connections {
                target: root.messages
                function onDataChanged() { if (list.atYEnd || root.busy) Qt.callLater(() => list.positionViewAtEnd()); }
            }

            delegate: Item {
                id: row
                required property string role
                required property string text
                width: list.width
                height: bubble.height

                Rectangle {
                    id: bubble
                    readonly property bool mine: row.role === "user"
                    readonly property bool copyable: !mine && row.text.length > 0
                    anchors.right: mine ? parent.right : undefined
                    anchors.left: mine ? undefined : parent.left
                    // Las respuestas llevan Markdown (listas, código...), que necesita un ancho fijo.
                    width: mine ? Math.min(row.width * 0.88, content.implicitWidth + 28) : row.width * 0.94
                    height: content.implicitHeight + (copyable ? 38 : 20)
                    radius: 18
                    color: mine ? Theme.primaryContainer : Theme.cardHigh
                    TextEdit {
                        id: content
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: 10
                        anchors.leftMargin: 14; anchors.rightMargin: 14
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: bubble.mine ? Theme.m3onPrimaryContainer : Theme.m3onSurface
                        selectionColor: Theme.primary
                        selectedTextColor: Theme.m3onPrimary
                        font: Theme.body
                        textFormat: bubble.mine ? TextEdit.PlainText : TextEdit.MarkdownText
                        text: row.text.length > 0 ? row.text : "…"
                        onSelectedTextChanged: root.interacted()
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                    // Copiar la respuesta completa
                    Item {
                        id: copyBtn
                        visible: bubble.copyable
                        anchors.right: parent.right; anchors.bottom: parent.bottom
                        anchors.rightMargin: 8; anchors.bottomMargin: 6
                        width: 28; height: 24
                        property bool done: false
                        Timer { id: doneTimer; interval: 1300; onTriggered: copyBtn.done = false }
                        Icon {
                            anchors.centerIn: parent
                            name: copyBtn.done ? "check" : "content_copy"
                            size: 16
                            color: copyBtn.done ? Theme.success : Theme.m3onSurfaceVariant
                        }
                        TapHandler { onTapped: { root.copyText(row.text); copyBtn.done = true; doneTimer.restart(); } }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.messages.count === 0
                color: Theme.m3onSurfaceVariant; font: Theme.caption
                text: "Pregúntale algo a Mochi."
                      + (root.backend === "api" ? "" : "\nUsa tu suscripción de Claude Code.")
                      + "\nPuedes soltar archivos sobre la isla."
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // Acciones rápidas: adjuntar el portapapeles o el texto seleccionado como contexto
        Row {
            id: quick
            anchors.left: parent.left
            anchors.bottom: chips.top; anchors.bottomMargin: root.extras > 0 ? 6 : 0
            spacing: 6
            height: 28
            Chip { height: 28; label: "Portapapeles"; iconName: "content_paste"; onClicked: { root.grab("clipboard"); root.interacted(); } }
            Chip { height: 28; label: "Selección"; iconName: "select_all"; onClicked: { root.grab("primary"); root.interacted(); } }
        }

        // Archivos y fragmentos adjuntos
        Flow {
            id: chips
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: errorLabel.visible ? errorLabel.top : inputRow.top
            anchors.bottomMargin: root.extras > 0 ? 8 : 6
            height: root.extras > 0 ? implicitHeight : 0
            spacing: 6
            Repeater {
                model: root.attachments
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    height: 28; radius: 14
                    width: Math.min(190, chipText.implicitWidth + 50)
                    color: Theme.secondaryContainer
                    Text {
                        id: chipText
                        anchors.left: parent.left; anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 40
                        elide: Text.ElideMiddle
                        color: Theme.m3onSecondaryContainer; font: Theme.caption
                        text: root.baseName(modelData)
                    }
                    Icon {
                        anchors.right: parent.right; anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        name: "close"; size: 18; color: Theme.m3onSecondaryContainer
                        TapHandler { onTapped: root.removeAttachment(index) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }
            Repeater {
                model: root.contexts
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    height: 28; radius: 14
                    width: Math.min(220, ctxText.implicitWidth + 50)
                    color: Theme.tertiaryContainer
                    Text {
                        id: ctxText
                        anchors.left: parent.left; anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 40
                        elide: Text.ElideRight
                        color: Theme.m3onTertiaryContainer; font: Theme.caption
                        text: modelData.label + " · " + modelData.text.length + " car."
                    }
                    Icon {
                        anchors.right: parent.right; anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        name: "close"; size: 18; color: Theme.m3onTertiaryContainer
                        TapHandler { onTapped: root.removeContext(index) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }
        }

        // Error
        Text {
            id: errorLabel
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: inputRow.top; anchors.bottomMargin: 6
            visible: root.errorText.length > 0
            elide: Text.ElideRight
            color: Theme.error; font: Theme.caption
            text: root.errorText
        }

        // Entrada de texto
        Item {
            id: inputRow
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: 44

            Pill {
                anchors.left: parent.left; anchors.right: sendBtn.left; anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                height: 42
                border.width: input.activeFocus ? 2 : 0
                border.color: Theme.primary

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: 18; anchors.rightMargin: 18
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.m3onSurface
                    font: Theme.body
                    clip: true
                    selectByMouse: true
                    enabled: !root.busy
                    onTextEdited: root.interacted()
                    onAccepted: root.submit()
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: !input.text
                        color: Theme.m3onSurfaceVariant; font: Theme.body
                        text: root.busy ? "Escribiendo…" : "Escribe un mensaje"
                    }
                }
            }

            Rectangle {
                id: sendBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 42; height: 42; radius: 21
                readonly property bool ready: input.text.trim().length > 0 && !root.busy
                color: (ready || root.busy) ? Theme.primary : Theme.cardHigh
                Behavior on color { ColorAnimation { duration: 160 } }
                scale: sendTap.pressed ? 0.92 : 1
                Behavior on scale { NumberAnimation { duration: 90 } }
                Icon {
                    anchors.centerIn: parent
                    visible: !root.busy
                    name: "arrow_upward"; size: 22
                    color: sendBtn.ready ? Theme.m3onPrimary : Theme.m3onSurfaceVariant
                }
                Icon {   // mientras Mochi escribe, el botón se vuelve "parar"
                    anchors.centerIn: parent
                    visible: root.busy
                    name: "stop"; size: 22
                    color: Theme.m3onPrimary
                }
                TapHandler { id: sendTap; onTapped: { if (root.busy) root.cancel(); else root.submit(); } }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }

        // Selector de modelo
        Rectangle {
            id: picker
            visible: false
            anchors.left: parent.left; anchors.leftMargin: backendChip.width + 8
            anchors.top: topBar.bottom; anchors.topMargin: 2
            width: 280
            height: Math.min(pickerList.contentHeight, 200) + 16
            radius: 20
            color: Theme.surfaceContainerHigh
            z: 10
            ListView {
                id: pickerList
                anchors.fill: parent; anchors.margins: 8
                clip: true
                model: root.models
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                    id: opt
                    required property string modelData
                    width: pickerList.width; height: 34; radius: 12
                    color: optHover.hovered ? Theme.primaryContainer : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left; anchors.leftMargin: 12
                        width: parent.width - 24
                        elide: Text.ElideRight
                        font: Theme.caption
                        color: opt.modelData === root.model ? Theme.primary : Theme.m3onSurface
                        text: opt.modelData
                    }
                    HoverHandler { id: optHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.pickModel(opt.modelData); picker.visible = false; } }
                }
            }
        }
    }
}
