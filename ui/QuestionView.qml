import QtQuick

// Pregunta de Claude (herramienta AskUserQuestion): muestra las opciones como botones y devuelve
// las respuestas como { "texto de la pregunta": "opción elegida" }. Varias preguntas van una a una.
Item {
    id: root

    property var req: null
    signal submit(var answers)
    signal terminal()

    property var qs: req && Array.isArray(req.questions) ? req.questions : []
    property int qi: 0
    property var answers: ({})
    property var picked: []
    readonly property var q: qs.length > qi ? qs[qi] : null
    readonly property var options: q && Array.isArray(q.options) ? q.options : []
    readonly property real contentHeight: info.implicitHeight + 8 + optionsCol.implicitHeight + 10 + footer.implicitHeight

    property string lastReqId: ""
    // El daemon reenvía el estado a menudo: solo se reinicia cuando llega una pregunta distinta.
    onReqChanged: {
        const id = req ? req.id : "";
        if (id === lastReqId) return;
        lastReqId = id;
        qi = 0; answers = ({}); picked = [];
    }

    function labelOf(o) { return typeof o === "string" ? o : (o && o.label ? o.label : ""); }
    function descOf(o) { return (o && typeof o === "object" && o.description) ? o.description : ""; }

    function advance(value) {
        const a = Object.assign({}, answers);
        a[q.question] = value;
        answers = a;
        picked = [];
        if (qi + 1 < qs.length) qi++;
        else submit(a);
    }
    function choose(o) {
        const label = labelOf(o);
        if (q.multiSelect) {
            picked = picked.indexOf(label) >= 0 ? picked.filter(p => p !== label) : picked.concat([label]);
        } else {
            advance(label);
        }
    }

    Column {
        id: info
        width: parent.width
        spacing: 4
        Text {
            width: parent.width; elide: Text.ElideRight
            color: Theme.primary; font: Theme.caption
            text: root.q ? ((root.q.header || "Pregunta") + (root.qs.length > 1 ? "  ·  " + (root.qi + 1) + "/" + root.qs.length : "")) : ""
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
            color: Theme.m3onSurface; font: Theme.title
            text: root.q ? root.q.question : ""
        }
    }

    Column {
        id: optionsCol
        anchors.top: info.bottom; anchors.topMargin: 8
        width: parent.width
        spacing: 6
        Repeater {
            model: root.options
            delegate: Rectangle {
                id: opt
                required property var modelData
                readonly property bool on: root.picked.indexOf(root.labelOf(modelData)) >= 0
                width: optionsCol.width
                height: root.descOf(modelData) !== "" ? 46 : 36
                radius: 18
                color: on ? Theme.primaryContainer : Theme.cardHigh
                scale: optTap.pressed ? 0.98 : 1
                Behavior on color { ColorAnimation { duration: 140 } }
                Behavior on scale { Spring { fast: true } }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: 16
                    anchors.right: parent.right; anchors.rightMargin: 16
                    Text {
                        width: parent.width; elide: Text.ElideRight
                        color: opt.on ? Theme.m3onPrimaryContainer : Theme.m3onSurface; font: Theme.label
                        text: root.labelOf(opt.modelData)
                    }
                    Text {
                        visible: text !== ""
                        width: parent.width; elide: Text.ElideRight
                        color: opt.on ? Theme.m3onPrimaryContainer : Theme.m3onSurfaceVariant; font: Theme.caption
                        text: root.descOf(opt.modelData)
                    }
                }
                TapHandler { id: optTap; onTapped: root.choose(opt.modelData) }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }
    }

    Row {
        id: footer
        anchors.top: optionsCol.bottom; anchors.topMargin: 10
        spacing: 14
        Chip {
            visible: root.q !== null && root.q.multiSelect === true
            label: "Enviar"; accent: true
            onClicked: if (root.picked.length > 0) root.advance(root.picked.join(", "))
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.primary; font: Theme.caption
            text: "Responder en la terminal"
            TapHandler { onTapped: root.terminal() }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
    }
}
