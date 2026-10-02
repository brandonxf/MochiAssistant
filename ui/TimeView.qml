import QtQuick

// Pomodoro y recordatorios. El daemon guarda y dispara los relojes; aquí solo se muestran y se piden.
Item {
    id: root

    property var timers: ({ reminders: [], pomo: { running: false, phase: "work", ends_at: 0, cycle: 0, work_min: 25, break_min: 5 } })
    property real nowSec: Date.now() / 1000
    property string error: ""
    signal pomoAction(string action)
    signal addReminder(int secs, string label)
    signal cancelReminder(int id)
    signal interacted()

    readonly property var pomo: timers.pomo
    readonly property bool working: pomo.phase === "work"
    readonly property int totalSecs: (working ? pomo.work_min : pomo.break_min) * 60
    readonly property int remaining: pomo.running ? Math.max(0, Math.round(pomo.ends_at - nowSec)) : pomo.work_min * 60
    readonly property real contentHeight: 302
    readonly property bool inputFocused: input.activeFocus

    Timer { interval: 1000; running: root.visible; repeat: true; triggeredOnStart: true; onTriggered: root.nowSec = Date.now() / 1000 }

    function two(n) { return (n < 10 ? "0" : "") + n; }
    function clock(secs) { return two(Math.floor(secs / 60)) + ":" + two(secs % 60); }
    function human(secs) {
        if (secs < 60) return "en " + Math.max(0, Math.round(secs)) + " s";
        if (secs < 3600) return "en " + Math.ceil(secs / 60) + " min";
        const h = Math.floor(secs / 3600), m = Math.round((secs % 3600) / 60);
        return "en " + h + " h" + (m ? " " + two(m) + " min" : "");
    }

    // "10m té", "1h30 reunión", "en 5 min llamar", "15:30 salir", "20 estirar" (número suelto = minutos)
    function parse(text) {
        const t = text.trim();
        if (!t) return null;
        let m = t.match(/^(?:a\s+las\s+)?(\d{1,2}):(\d{2})\s*(.*)$/i);
        if (m) {
            const h = +m[1], mi = +m[2];
            if (h > 23 || mi > 59) return null;
            const now = new Date(), d = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, mi, 0);
            if (d <= now) d.setDate(d.getDate() + 1);
            return { secs: Math.round((d - now) / 1000), label: m[3] || "Recordatorio" };
        }
        m = t.match(/^(?:en\s+)?(\d+)\s*h\s*(\d{1,2})(?!\d)\s*(?:m(?:in(?:utos?)?)?\b)?\s*(.*)$/i);
        if (m) return { secs: +m[1] * 3600 + +m[2] * 60, label: m[3] || "Recordatorio" };
        m = t.match(/^(?:en\s+)?((?:\d+(?:[.,]\d+)?\s*(?:horas?|h|minutos?|min|m|segundos?|seg|s)\b\s*)+)(.*)$/i);
        if (m) {
            let secs = 0;
            const re = /(\d+(?:[.,]\d+)?)\s*(horas?|h|minutos?|min|m|segundos?|seg|s)\b/gi;
            let u;
            while ((u = re.exec(m[1])) !== null) {
                const v = parseFloat(u[1].replace(",", "."));
                const k = u[2][0].toLowerCase();
                secs += v * (k === "h" ? 3600 : k === "m" ? 60 : 1);
            }
            return secs > 0 ? { secs: Math.round(secs), label: m[2] || "Recordatorio" } : null;
        }
        m = t.match(/^(\d+)\s+(.*)$/);
        if (m) return { secs: +m[1] * 60, label: m[2] };
        m = t.match(/^(\d+)$/);
        if (m) return { secs: +m[1] * 60, label: "Recordatorio" };
        return null;
    }

    function submit() {
        const r = parse(input.text);
        if (!r || r.secs < 1) { error = "Prueba: 10m té  ·  1h30 reunión  ·  15:30 salir"; return; }
        error = "";
        addReminder(r.secs, r.label);
        input.text = "";
    }

    // ------------------------------------------------------------ pomodoro
    Rectangle {
        id: pomoCard
        width: parent.width; height: 96; radius: 22
        color: Theme.card

        Column {
            anchors.left: parent.left; anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            Text {
                color: !root.pomo.running ? Theme.m3onSurfaceVariant : (root.working ? Theme.primary : Theme.success)
                font: Theme.caption
                text: !root.pomo.running ? "Pomodoro detenido"
                    : (root.working ? "Enfoque" : "Descanso") + "  ·  ciclo " + root.pomo.cycle
            }
            Text {
                color: Theme.m3onSurface
                font.family: Theme.title.family
                font.pixelSize: 44; font.weight: Font.Medium
                text: root.clock(root.remaining)
            }
        }

        Row {
            anchors.right: parent.right; anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Chip { visible: !root.pomo.running; label: "Iniciar"; iconName: "play_arrow"; accent: true; onClicked: { root.pomoAction("start"); root.interacted(); } }
            Chip { visible: root.pomo.running; label: "Saltar"; iconName: "skip_next"; onClicked: { root.pomoAction("skip"); root.interacted(); } }
            Chip { visible: root.pomo.running; label: "Detener"; iconName: "stop"; onClicked: { root.pomoAction("stop"); root.interacted(); } }
        }

        Rectangle {   // progreso de la fase
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.leftMargin: 20; anchors.rightMargin: 20; anchors.bottomMargin: 10
            height: 4; radius: 2; color: Theme.cardHigh
            visible: root.pomo.running
            Rectangle {
                height: parent.height; radius: 2
                width: parent.width * Math.min(1, 1 - root.remaining / Math.max(1, root.totalSecs))
                color: root.working ? Theme.primary : Theme.success
                Behavior on width { NumberAnimation { duration: 900 } }
            }
        }
    }

    // ------------------------------------------------------------ recordatorios
    Row {
        id: remTitle
        anchors.top: pomoCard.bottom; anchors.topMargin: 14
        spacing: 6
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "alarm"; size: 15; color: Theme.m3onSurfaceVariant }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.m3onSurfaceVariant; font: Theme.caption
            text: "Recordatorios"
        }
    }
    Rectangle {
        id: inputBox
        anchors.top: remTitle.bottom; anchors.topMargin: 6
        anchors.left: parent.left; anchors.right: addBtn.left; anchors.rightMargin: 8
        height: 40; radius: 20
        color: Theme.cardHigh
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
            onTextEdited: { root.error = ""; root.interacted(); }
            onAccepted: root.submit()
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: !input.text
                color: Theme.m3onSurfaceVariant; font: Theme.body
                text: "10m llamar a mamá"
            }
        }
    }
    Rectangle {
        id: addBtn
        anchors.right: parent.right
        anchors.verticalCenter: inputBox.verticalCenter
        width: 40; height: 40; radius: 20
        readonly property bool ready: input.text.trim().length > 0
        color: ready ? Theme.primary : Theme.cardHigh
        Behavior on color { ColorAnimation { duration: 160 } }
        Icon { anchors.centerIn: parent; name: "add"; size: 22; color: parent.ready ? Theme.m3onPrimary : Theme.m3onSurfaceVariant }
        TapHandler { onTapped: root.submit() }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
    Text {
        id: hint
        anchors.top: inputBox.bottom; anchors.topMargin: 5
        width: parent.width; elide: Text.ElideRight
        color: root.error !== "" ? Theme.error : Theme.m3onSurfaceVariant; font: Theme.caption
        text: root.error !== "" ? root.error : "Ej.: 10m té  ·  1h30 reunión  ·  15:30 salir"
    }

    Column {
        anchors.top: hint.bottom; anchors.topMargin: 6
        width: parent.width
        spacing: 4
        Repeater {
            model: (root.timers.reminders || []).slice(0, 3)
            delegate: Rectangle {
                id: rem
                required property var modelData
                width: parent.width; height: 30; radius: 15
                color: Theme.cardHigh
                Icon {
                    id: remIcon
                    anchors.left: parent.left; anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: "notifications"; size: 15; color: Theme.m3onSurfaceVariant
                }
                Text {
                    anchors.left: remIcon.right; anchors.leftMargin: 8
                    anchors.right: when.left; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    color: Theme.m3onSurface; font: Theme.caption
                    text: rem.modelData.label
                }
                Text {
                    id: when
                    anchors.right: close.left; anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.primary; font: Theme.caption
                    text: root.human(rem.modelData.at - root.nowSec)
                }
                Icon {
                    id: close
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    name: "close"; size: 18; color: Theme.m3onSurfaceVariant
                    TapHandler { onTapped: root.cancelReminder(rem.modelData.id) }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
            }
        }
        Text {
            visible: (root.timers.reminders || []).length === 0
            color: Theme.m3onSurfaceVariant; font: Theme.caption
            text: "Sin recordatorios pendientes."
        }
    }
}
