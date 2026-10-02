import QtQuick

// Ajolote dibujado con Canvas, animado a 60 fps solo mientras está visible.
// Estados (`mood`): idle, working, waiting, finished, happy, annoyed, dizzy, wave, love, surprised, hungry,
// sad (error), tired (límite de uso), yawn, sleeping, dance.
// Accesorios por ranura: `head`, `face`, `neck` (ver drawHead/drawFace/drawNeck) y `accColor` ("auto" o "#rrggbb").
// `lookX/lookY` (-1..1) orientan los ojos y desplazan la boca; `squish` (-1..1) aplasta (+) o estira (-) el cuerpo.
// Al arrastrar un archivo (`hungry`) abre la boca hacia él: `mouthOpen` (0..1) es cuánto la abre.
// `chew` (0..1) hace que mastique después de tragar.
// Envoltorio sin recorte: el Canvas real que pinta (`paintSurface`) es más grande que este Item y
// centrado dentro de él, para que las deformaciones (aplastón al tocarlo, giro al marearse) tengan
// margen de sobra antes de toparse con el borde del lienzo — antes el Canvas medía justo el tamaño
// del cuerpo en reposo y se notaba un corte duro (las branquias al aplastarse ancho, la base al girar).
Item {
    id: root

    // Margen extra de lienzo (fracción del tamaño) reservado para esas deformaciones.
    readonly property real pad: 0.32

    property string mood: "idle"
    property real lookX: 0
    property real lookY: 0
    property bool hovered: false
    property real squish: 0
    property real mouthOpen: 0
    property real chew: 0
    property string head: "none"
    property string face: "none"
    property string neck: "none"
    property string accColor: "auto"
    property real moodT0: 0           // instante (t) en que empezó el estado actual
    // El ajolote es siempre rosado (colores originales), sin importar el esquema del wallpaper.
    property color skin: "#f4b6c2"
    property color gill: "#e0607e"
    property color ink: "#1a1a22"

    property real t: 0
    property real blink: 0
    property real spin: 0
    readonly property bool active: visible && width > 4 && opacity > 0.01

    // Dónde queda la boca (coordenadas del lienzo); la usa la isla para dirigir el archivo hacia ella.
    readonly property real mouthX: width / 2 + lookX * Math.min(width, height) * 0.08
    readonly property real mouthY: height * 0.9 - Math.min(width, height) * 0.2048 + lookY * Math.min(width, height) * 0.025

    readonly property var moodColors: ({
        idle: "#e6e9ee", working: "#3b9eff", waiting: "#f5a524", finished: "#34d399",
        happy: "#34d399", annoyed: "#a855f7", dizzy: "#f472b6", wave: "#f4829c",
        love: "#ff4d6d", surprised: "#fbbf24", hungry: "#fbbf24",
        sad: "#f4505e", tired: "#fb923c", yawn: "#94a3b8", sleeping: "#94a3b8", dance: "#c084fc"
    })
    readonly property color moodColor: moodColors[mood] || "#e6e9ee"

    // Vuelta completa al terminar una tarea; dos vueltas al marearse.
    onMoodChanged: {
        moodT0 = t;
        if (mood === "finished") { spinAnim.to = 1; spinAnim.duration = 950; spinAnim.restart(); }
        else if (mood === "dizzy") { spinAnim.to = 2; spinAnim.duration = 1300; spinAnim.restart(); }
    }
    NumberAnimation on spin {
        id: spinAnim
        running: false
        from: 0
        easing.type: Easing.InOutCubic
    }

    // Mientras está en reposo permanente (siempre visible en la esquina) basta con repintar a ~30 fps.
    property int minInterval: 0           // ms entre repintados; 0 = a la velocidad de la pantalla
    property real sinceFrame: 0
    FrameAnimation {
        running: root.active
        onTriggered: {
            root.t += frameTime;
            root.sinceFrame += frameTime * 1000;
            if (root.sinceFrame >= root.minInterval) { root.sinceFrame = 0; paintSurface.requestPaint(); }
        }
    }

    // Parpadeo aleatorio cada 2.2–5.4 s; el 22 % de las veces es doble.
    SequentialAnimation {
        id: blinkAnim
        NumberAnimation { target: root; property: "blink"; to: 1; duration: 70 }
        NumberAnimation { target: root; property: "blink"; to: 0; duration: 100 }
    }
    Timer {
        id: blinkTimer
        running: root.active
        repeat: true
        interval: 2200
        onTriggered: {
            blinkAnim.restart();
            if (Math.random() < 0.22) doubleBlink.start();
            interval = 2200 + Math.random() * 3200;
        }
    }
    Timer { id: doubleBlink; interval: 260; onTriggered: blinkAnim.restart() }

    // Parpadeo al abrirse o al pasar el mouse por encima.
    onHoveredChanged: if (hovered) blinkAnim.restart()

    function lerp(a, b, k) { return a + (b - a) * k; }
    function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }

    function heart(ctx, x, y, r) {
        ctx.beginPath();
        ctx.moveTo(x, y + r * 0.9);
        ctx.bezierCurveTo(x - r * 1.5, y - r * 0.1, x - r * 0.7, y - r * 1.2, x, y - r * 0.4);
        ctx.bezierCurveTo(x + r * 0.7, y - r * 1.2, x + r * 1.5, y - r * 0.1, x, y + r * 0.9);
        ctx.closePath();
        ctx.fill();
    }

    function star(ctx, x, y, r) {
        ctx.beginPath();
        ctx.moveTo(x, y - r);
        ctx.quadraticCurveTo(x, y, x + r, y);
        ctx.quadraticCurveTo(x, y, x, y + r);
        ctx.quadraticCurveTo(x, y, x - r, y);
        ctx.quadraticCurveTo(x, y, x, y - r);
        ctx.closePath();
        ctx.fill();
    }

    function spiral(ctx, x, y, r, rot) {
        ctx.beginPath();
        for (let i = 0; i <= 28; i++) {
            const a = rot + i * 0.42, rr = r * i / 28;
            const px = x + Math.cos(a) * rr, py = y + Math.sin(a) * rr;
            if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
        }
        ctx.stroke();
    }

    // Color del accesorio: el elegido por el usuario, o el propio de cada pieza si es "auto".
    function pick(def) { return (!accColor || accColor === "auto") ? def : accColor; }
    function shade(c, k) { return Qt.darker(c, k); }

    // Todos los accesorios se dibujan en coordenadas del cuerpo: origen en el centro de la base y la
    // cabeza sube hasta -2*bh (así se deforman con el cuerpo al respirar, aplastarse o bailar).
    function drawHead(ctx, kind, bw, bh, s) {
        if (kind === "none") return;
        const top = -2 * bh;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        if (kind === "beanie") {
            const base = top * 0.80, apex = top * 1.2;
            ctx.fillStyle = pick("#e5484d");
            ctx.beginPath();
            ctx.moveTo(-bw * 0.88, base);
            ctx.bezierCurveTo(-bw * 0.9, apex, bw * 0.9, apex, bw * 0.88, base);
            ctx.closePath();
            ctx.fill();
            ctx.fillStyle = "#f5f5f7";
            ctx.beginPath();
            ctx.roundedRect(-bw * 0.92, base - s * 0.012, bw * 1.84, s * 0.075, s * 0.035, s * 0.035);
            ctx.fill();
            ctx.beginPath();
            ctx.arc(0, apex * 0.985, s * 0.06, 0, 2 * Math.PI);
            ctx.fill();
        } else if (kind === "crown") {
            const base = top * 0.93, tipY = top * 1.2, c = pick("#fbbf24");
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.moveTo(-bw * 0.5, base);
            ctx.lineTo(-bw * 0.56, tipY);
            ctx.lineTo(-bw * 0.26, base - s * 0.02);
            ctx.lineTo(0, tipY - s * 0.025);
            ctx.lineTo(bw * 0.26, base - s * 0.02);
            ctx.lineTo(bw * 0.56, tipY);
            ctx.lineTo(bw * 0.5, base);
            ctx.closePath();
            ctx.fill();
            ctx.fillStyle = shade(c, 1.25);
            ctx.fillRect(-bw * 0.5, base - s * 0.015, bw, s * 0.04);
            ctx.fillStyle = "#ef4444";
            ctx.beginPath();
            ctx.arc(0, base + s * 0.005, s * 0.018, 0, 2 * Math.PI);
            ctx.fill();
        } else if (kind === "bow") {
            ctx.save();
            ctx.translate(-bw * 0.5, top * 0.95);
            ctx.rotate(-0.35);
            const c = pick("#ff5d9e");
            ctx.fillStyle = c;
            for (let side = -1; side <= 1; side += 2) {
                ctx.beginPath();
                ctx.moveTo(0, 0);
                ctx.lineTo(side * s * 0.15, -s * 0.085);
                ctx.lineTo(side * s * 0.15, s * 0.085);
                ctx.closePath();
                ctx.fill();
            }
            ctx.fillStyle = shade(c, 1.4);
            ctx.beginPath();
            ctx.arc(0, 0, s * 0.036, 0, 2 * Math.PI);
            ctx.fill();
            ctx.restore();
        } else if (kind === "tophat") {
            // chistera: ala, copa y cinta
            const base = top * 0.97, c = pick("#1f2937"), h = s * 0.21;
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.ellipse(-bw * 0.8, base - s * 0.025, bw * 1.6, s * 0.055);
            ctx.fill();
            ctx.fillRect(-bw * 0.48, base - h, bw * 0.96, h);
            ctx.fillStyle = shade(c, 0.8);
            ctx.beginPath();
            ctx.ellipse(-bw * 0.48, base - h - s * 0.02, bw * 0.96, s * 0.04);
            ctx.fill();
            ctx.fillStyle = (!accColor || accColor === "auto") ? "#e5484d" : shade(c, 1.6);
            ctx.fillRect(-bw * 0.48, base - s * 0.06, bw * 0.96, s * 0.045);
        } else if (kind === "catears") {
            const c = pick("#f3a6b9");
            for (let side = -1; side <= 1; side += 2) {
                ctx.fillStyle = c;
                ctx.beginPath();
                ctx.moveTo(side * bw * 0.80, top * 0.80);
                ctx.lineTo(side * bw * 0.30, top * 0.97);
                ctx.lineTo(side * bw * 0.68, top * 1.30);
                ctx.closePath();
                ctx.fill();
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.45);
                ctx.beginPath();
                ctx.moveTo(side * bw * 0.68, top * 0.88);
                ctx.lineTo(side * bw * 0.42, top * 0.98);
                ctx.lineTo(side * bw * 0.64, top * 1.17);
                ctx.closePath();
                ctx.fill();
            }
        } else if (kind === "halo") {
            const bob = Math.sin(root.t * 2) * s * 0.012, c = pick("#fde047");
            ctx.lineWidth = s * 0.07;
            ctx.strokeStyle = root.rgba(c, 0.18);
            ctx.beginPath();
            ctx.ellipse(-bw * 0.5, top * 1.18 - s * 0.03 + bob, bw, s * 0.075);
            ctx.stroke();
            ctx.lineWidth = s * 0.028;
            ctx.strokeStyle = c;
            ctx.beginPath();
            ctx.ellipse(-bw * 0.5, top * 1.18 - s * 0.03 + bob, bw, s * 0.075);
            ctx.stroke();
        } else if (kind === "horns") {
            ctx.fillStyle = pick("#ef4444");
            for (let side = -1; side <= 1; side += 2) {
                ctx.beginPath();
                ctx.moveTo(side * bw * 0.52, top * 0.90);
                ctx.quadraticCurveTo(side * bw * 0.80, top * 1.0, side * bw * 0.60, top * 1.30);
                ctx.quadraticCurveTo(side * bw * 0.52, top * 1.06, side * bw * 0.26, top * 0.97);
                ctx.closePath();
                ctx.fill();
            }
        } else if (kind === "cap") {
            // gorra con visera hacia la derecha
            const base = top * 0.80, c = pick("#3b82f6");
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.moveTo(-bw * 0.86, base);
            ctx.bezierCurveTo(-bw * 0.86, top * 1.16, bw * 0.86, top * 1.16, bw * 0.86, base);
            ctx.closePath();
            ctx.fill();
            ctx.fillStyle = shade(c, 1.35);
            ctx.beginPath();
            ctx.ellipse(bw * 0.05, base - s * 0.03, bw * 1.1, s * 0.055);
            ctx.fill();
            ctx.fillStyle = shade(c, 1.2);
            ctx.beginPath();
            ctx.arc(0, top * 1.1, s * 0.03, 0, 2 * Math.PI);
            ctx.fill();
        } else if (kind === "wizard") {
            const base = top * 0.93, c = pick("#6d28d9");
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.moveTo(-bw * 0.62, base);
            ctx.bezierCurveTo(-bw * 0.42, top * 1.2, -bw * 0.1, top * 1.42, bw * 0.38, top * 1.55);
            ctx.bezierCurveTo(bw * 0.2, top * 1.28, bw * 0.46, top * 1.0, bw * 0.62, base);
            ctx.closePath();
            ctx.fill();
            ctx.fillStyle = shade(c, 1.3);
            ctx.beginPath();
            ctx.ellipse(-bw * 0.96, base - s * 0.03, bw * 1.92, s * 0.06);
            ctx.fill();
            ctx.fillStyle = "#fde047";
            root.star(ctx, -bw * 0.12, top * 1.1, s * 0.03);
            root.star(ctx, bw * 0.22, top * 1.3, s * 0.022);
            root.star(ctx, -bw * 0.34, top * 0.99, s * 0.018);
        } else if (kind === "flower") {
            ctx.save();
            ctx.translate(-bw * 0.55, top * 0.93);
            ctx.fillStyle = pick("#ff7aa8");
            for (let i = 0; i < 5; i++) {
                const ang = i * 2 * Math.PI / 5 - Math.PI / 2;
                ctx.beginPath();
                ctx.arc(Math.cos(ang) * s * 0.05, Math.sin(ang) * s * 0.05, s * 0.036, 0, 2 * Math.PI);
                ctx.fill();
            }
            ctx.fillStyle = "#fde047";
            ctx.beginPath();
            ctx.arc(0, 0, s * 0.032, 0, 2 * Math.PI);
            ctx.fill();
            ctx.restore();
        }
    }

    function drawFace(ctx, kind, bw, bh, s, eyeY, eyeDX, faceX, er) {
        if (kind === "none") return;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        const cy = eyeY - er * 0.2;
        if (kind === "glasses") {
            const r = er * 2.7;
            ctx.strokeStyle = pick("#1e293b");
            ctx.lineWidth = Math.max(1.6, s * 0.026);
            for (let side = -1; side <= 1; side += 2) {
                ctx.beginPath();
                ctx.arc(side * eyeDX + faceX, cy, r, 0, 2 * Math.PI);
                ctx.stroke();
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.13);
                ctx.fill();
            }
            ctx.beginPath();
            ctx.moveTo(-eyeDX + faceX + r, cy);
            ctx.lineTo(eyeDX + faceX - r, cy);
            ctx.stroke();
        } else if (kind === "sunglasses") {
            const c = pick("#111827"), w = er * 5.4, h = er * 3.8;
            ctx.fillStyle = c;
            for (let side = -1; side <= 1; side += 2) {
                ctx.beginPath();
                ctx.roundedRect(side * eyeDX + faceX - w / 2, cy - h / 2, w, h, er * 1.5, er * 1.5);
                ctx.fill();
                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.5);
                ctx.lineWidth = Math.max(1, s * 0.012);
                ctx.beginPath();
                ctx.moveTo(side * eyeDX + faceX - w * 0.28, cy - h * 0.3);
                ctx.lineTo(side * eyeDX + faceX - w * 0.1, cy - h * 0.3);
                ctx.stroke();
            }
            ctx.strokeStyle = c;
            ctx.lineWidth = Math.max(1.6, s * 0.022);
            ctx.beginPath();
            ctx.moveTo(-eyeDX + faceX + w / 2, cy - h * 0.15);
            ctx.lineTo(eyeDX + faceX - w / 2, cy - h * 0.15);
            ctx.stroke();
        } else if (kind === "monocle") {
            const r = er * 2.9, ex = eyeDX + faceX;
            ctx.strokeStyle = pick("#f59e0b");
            ctx.lineWidth = Math.max(1.8, s * 0.028);
            ctx.beginPath();
            ctx.arc(ex, cy, r, 0, 2 * Math.PI);
            ctx.stroke();
            ctx.fillStyle = Qt.rgba(1, 1, 1, 0.14);
            ctx.fill();
            ctx.lineWidth = Math.max(1, s * 0.014);
            ctx.beginPath();            // cadena
            ctx.moveTo(ex + r * 0.7, cy + r * 0.7);
            ctx.quadraticCurveTo(ex + r * 1.6, cy + r * 2.5, ex + r * 0.3, -bh * 0.15);
            ctx.stroke();
        } else if (kind === "mustache") {
            ctx.fillStyle = pick("#6b4423");
            for (let side = -1; side <= 1; side += 2) {
                ctx.save();
                ctx.translate(faceX + side * s * 0.052, -bh * 0.66 - s * 0.05);
                ctx.rotate(side * -0.28);
                ctx.beginPath();
                ctx.ellipse(-s * 0.06, -s * 0.02, s * 0.125, s * 0.042);
                ctx.fill();
                ctx.restore();
            }
        }
    }

    function drawNeck(ctx, kind, bw, bh, s) {
        if (kind === "none") return;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        if (kind === "scarf") {
            const c = pick("#ef4444");
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.roundedRect(-bw * 0.86, -bh * 0.52, bw * 1.72, s * 0.08, s * 0.04, s * 0.04);
            ctx.fill();
            ctx.beginPath();            // la cola que cuelga
            ctx.roundedRect(bw * 0.38, -bh * 0.52, s * 0.07, s * 0.18, s * 0.03, s * 0.03);
            ctx.fill();
            ctx.fillStyle = Qt.rgba(1, 1, 1, 0.4);
            for (let i = 0; i < 5; i++) ctx.fillRect(-bw * 0.7 + i * bw * 0.34, -bh * 0.52, s * 0.022, s * 0.08);
            ctx.fillRect(bw * 0.38, -bh * 0.52 + s * 0.12, s * 0.07, s * 0.022);
        } else if (kind === "bowtie") {
            const c = pick("#e5484d"), y = -s * 0.075;
            ctx.fillStyle = c;
            for (let side = -1; side <= 1; side += 2) {
                ctx.beginPath();
                ctx.moveTo(0, y);
                ctx.lineTo(side * s * 0.12, y - s * 0.06);
                ctx.lineTo(side * s * 0.12, y + s * 0.06);
                ctx.closePath();
                ctx.fill();
            }
            ctx.fillStyle = shade(c, 1.4);
            ctx.beginPath();
            ctx.arc(0, y, s * 0.03, 0, 2 * Math.PI);
            ctx.fill();
        } else if (kind === "bell") {
            const c = pick("#ef4444"), y = -s * 0.085;
            ctx.fillStyle = c;
            ctx.beginPath();
            ctx.roundedRect(-bw * 0.82, y - s * 0.012, bw * 1.64, s * 0.03, s * 0.015, s * 0.015);
            ctx.fill();
            ctx.fillStyle = "#fbbf24";
            ctx.beginPath();
            ctx.arc(0, y + s * 0.04, s * 0.045, 0, 2 * Math.PI);
            ctx.fill();
            ctx.strokeStyle = "#a16207";
            ctx.lineWidth = Math.max(1, s * 0.012);
            ctx.beginPath();
            ctx.moveTo(-s * 0.04, y + s * 0.04);
            ctx.lineTo(s * 0.04, y + s * 0.04);
            ctx.stroke();
            ctx.fillStyle = Qt.rgba(1, 1, 1, 0.55);
            ctx.beginPath();
            ctx.arc(-s * 0.015, y + s * 0.025, s * 0.012, 0, 2 * Math.PI);
            ctx.fill();
        }
    }

    // Lienzo real, más grande que `root` y centrado en él (ver comentario de arriba). Todo lo que
    // sigue usa `root.width/root.height` (el tamaño nominal de siempre) para la proporción del
    // cuerpo, trasladado al centro de este lienzo más grande — así el dibujo es IDÉNTICO al de
    // antes, solo que ahora tiene margen alrededor antes de toparse con el borde real.
    Canvas {
        id: paintSurface
        anchors.centerIn: parent
        width: root.width * (1 + root.pad * 2)
        height: root.height * (1 + root.pad * 2)

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.save();
        ctx.translate((width - root.width) / 2, (height - root.height) / 2);
        const w = root.width, h = root.height, s = Math.min(w, h);
        const t = root.t, mood = root.mood;
        const rx = 0.34 * s, ry = 0.28 * s;
        const cx = w / 2, ground = h * 0.9;

        // --- movimiento según el estado
        let jump = 0, tilt = 0, scanX = 0, scanY = 0;
        if (mood === "waiting") jump = Math.abs(Math.sin(t * 6)) * s * 0.07;
        else if (mood === "finished") jump = Math.abs(Math.sin(t * 7)) * s * 0.08;
        else if (mood === "surprised") jump = Math.abs(Math.sin(t * 9)) * s * 0.05;
        else if (mood === "hungry") jump = (0.5 + 0.5 * Math.sin(t * 8)) * s * 0.035;
        else if (mood === "dance") jump = Math.abs(Math.sin(t * 5)) * s * 0.07;
        else if (mood === "working") jump = (0.5 + 0.5 * Math.sin(t * 5)) * s * 0.02;
        if (mood === "dizzy") tilt = Math.sin(t * 9) * 0.16;
        else if (mood === "love") tilt = Math.sin(t * 3) * 0.05;
        else if (mood === "annoyed") tilt = Math.sin(t * 28) * 0.03;
        else if (mood === "hungry") tilt = root.lookX * 0.1;       // inclina la cabeza hacia el archivo
        else if (mood === "dance") tilt = Math.sin(t * 5) * 0.13;   // se balancea al ritmo
        else if (mood === "tired") tilt = Math.sin(t * 1.4) * 0.05;
        if (mood === "working") { scanX = Math.sin(t * 1.8) * 0.8; scanY = -0.25; }
        const sleepy = mood === "sleeping" || mood === "yawn";
        const breathe = sleepy ? Math.sin(t * 1.3) * 0.035 : Math.sin(t * 2.2) * 0.018;
        // Bostezo: un estirón vertical que sube y baja durante 2.2 s.
        const yawnP = mood === "yawn" ? Math.min(1, (t - root.moodT0) / 2.2) : 0;
        const yawnOpen = Math.sin(Math.PI * yawnP);
        const sq = root.squish;
        const sx = 1 + 0.28 * sq - breathe * 0.5 - yawnOpen * 0.04, sy = 1 - 0.30 * sq + breathe + yawnOpen * 0.09 - (mood === "sad" ? 0.03 : 0);

        // --- halo del estado
        if (mood !== "idle") {
            // El centro (ground-ry) no está a la mitad del lienzo: queda más cerca del borde de abajo
            // que del de arriba, así que el radio tiene que acotarse a esa distancia más corta (0.38s,
            // no 0.5s) o el degradado llega vivo al borde y el `fillRect` lo corta de golpe en vez de
            // desvanecerlo — por eso se veía como una línea recta debajo de Mochi.
            const g = ctx.createRadialGradient(cx, ground - ry, 0, cx, ground - ry, s * 0.36);
            g.addColorStop(0, root.rgba(root.moodColor, mood === "annoyed" || mood === "waiting" ? 0.38 : 0.26));
            g.addColorStop(1, root.rgba(root.moodColor, 0));
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, w, h);
        }

        // --- sombra en el suelo
        ctx.fillStyle = Qt.rgba(0, 0, 0, 0.22 * (1 - jump / (s * 0.2)));
        ctx.beginPath();
        ctx.ellipse(cx - rx * 0.8, ground - s * 0.012, rx * 1.6, s * 0.05);
        ctx.fill();

        // --- cuerpo: origen en el centro de la base
        ctx.save();
        ctx.translate(cx, ground - jump - ry);
        ctx.rotate(tilt + root.spin * 2 * Math.PI);
        ctx.scale(sx, sy);
        ctx.translate(0, ry);

        // branquias
        {
            ctx.strokeStyle = root.gill;
            ctx.fillStyle = root.gill;
            ctx.lineWidth = Math.max(1.5, s * 0.042);
            ctx.lineCap = "round";
            for (let side = -1; side <= 1; side += 2) {
                for (let i = 0; i < 3; i++) {
                    const bx = side * rx * 0.86, by = -ry * 2 + ry * (0.78 + i * 0.36);
                    let wig = Math.sin(t * 3.2 + i * 1.3 + side) * 0.14;
                    if (mood === "wave" && side === 1) wig = Math.sin(t * 13 + i * 0.6) * 0.5;
                    else if (mood === "hungry") wig = Math.sin(t * 11 + i * 0.7 + side) * 0.3 - 0.3;   // se erizan
                    else if (mood === "dance") wig = Math.sin(t * 9 + i * 0.8 + side) * 0.42;
                    else if (mood === "sad" || mood === "tired" || mood === "sleeping") wig = 0.55 + Math.sin(t * 1.5 + i + side) * 0.06;  // caídas
                    const ang = -0.6 + i * 0.42 + wig;
                    const len = s * (0.15 + 0.02 * (2 - i));
                    const ex = bx + side * Math.cos(ang) * len, ey = by + Math.sin(ang) * len;
                    ctx.beginPath();
                    ctx.moveTo(bx, by);
                    ctx.lineTo(ex, ey);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(ex, ey, s * 0.027, 0, 2 * Math.PI);
                    ctx.fill();
                }
            }
        }

        // cabeza
        const xr = 0.34 * s, yr = 0.27 * s;
        const bw = rx, bh = ry;
        const grad = ctx.createLinearGradient(0, -2 * bh, 0, 0);
        grad.addColorStop(0, Qt.lighter(root.skin, 1.12));
        grad.addColorStop(1, root.skin);
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.roundedRect(-bw, -2 * bh, 2 * bw, 2 * bh, xr, yr);
        ctx.fill();
        // matiz del estado desde abajo
        if (mood !== "idle" && mood !== "wave") {
            const tg = ctx.createLinearGradient(0, 0, 0, -2 * bh);
            tg.addColorStop(0, root.rgba(root.moodColor, 0.34));
            tg.addColorStop(0.6, root.rgba(root.moodColor, 0));
            ctx.fillStyle = tg;
            ctx.beginPath();
            ctx.roundedRect(-bw, -2 * bh, 2 * bw, 2 * bh, xr, yr);
            ctx.fill();
        }
        // reflejo
        ctx.fillStyle = Qt.rgba(1, 1, 1, 0.28);
        ctx.beginPath();
        ctx.ellipse(bw * 0.25, -2 * bh + bh * 0.16, bw * 0.5, bh * 0.28);
        ctx.fill();

        // --- cara
        const lx = (mood === "working" ? scanX : root.lookX), ly = (mood === "working" ? scanY : root.lookY);
        const eyeY = -bh * 1.08 + ly * s * 0.025;
        const eyeDX = bw * 0.42;
        const faceX = lx * s * 0.035;
        let er = s * 0.044 * (root.hovered ? 1.08 : 1);
        if (mood === "waiting") er *= 1.3;
        if (mood === "surprised") er *= 0.7;
        if (mood === "hungry") er *= 1.3;
        if (mood === "dance") er *= 1.05;
        const ink = root.ink;

        // mejillas
        const blush = (mood === "love" ? 0.85 : mood === "happy" || mood === "finished" ? 0.65 : 0.4);
        ctx.fillStyle = Qt.rgba(1, 0.47, 0.59, blush);
        for (let side = -1; side <= 1; side += 2) {
            ctx.beginPath();
            ctx.ellipse(faceX * 0.6 + side * bw * 0.66 - s * 0.05, -bh * 0.78, s * 0.1, s * 0.058);
            ctx.fill();
        }

        for (let side = -1; side <= 1; side += 2) {
            const ex = side * eyeDX + faceX;
            ctx.strokeStyle = ink;
            ctx.fillStyle = ink;
            ctx.lineWidth = Math.max(1.4, s * 0.026);
            ctx.lineCap = "round";
            if (mood === "finished" || mood === "happy" || mood === "dance") {
                ctx.beginPath();
                ctx.arc(ex, eyeY + er * 0.5, er * 1.15, Math.PI * 1.12, Math.PI * 1.88);
                ctx.stroke();
            } else if (mood === "sleeping") {
                // ojos cerrados: arco hacia abajo
                ctx.beginPath();
                ctx.arc(ex, eyeY - er * 0.7, er * 1.15, 0.12 * Math.PI, 0.88 * Math.PI);
                ctx.stroke();
            } else if (mood === "yawn") {
                // ojos apretados: ">" "<"
                ctx.beginPath();
                ctx.moveTo(ex + side * er * 1.1, eyeY - er * 0.9);
                ctx.lineTo(ex - side * er * 1.1, eyeY);
                ctx.lineTo(ex + side * er * 1.1, eyeY + er * 0.9);
                ctx.stroke();
            } else if (mood === "love") {
                ctx.fillStyle = "#ff4d6d";
                root.heart(ctx, ex, eyeY, er * 1.15);
            } else if (mood === "annoyed") {
                ctx.beginPath();
                ctx.moveTo(ex - er * 1.2, eyeY - side * er * 0.55);
                ctx.lineTo(ex + er * 1.2, eyeY + side * er * 0.55);
                ctx.stroke();
            } else if (mood === "dizzy") {
                ctx.lineWidth = Math.max(1, s * 0.016);
                root.spiral(ctx, ex, eyeY, er * 1.3, t * 8 * side);
            } else {
                const open = Math.max(0.1, 1 - root.blink) * (mood === "tired" ? 0.45 : 1);
                ctx.beginPath();
                ctx.ellipse(ex - er * 0.8 + lx * er * 0.25, eyeY - er * 1.3 * open, er * 1.6, er * 2.6 * open);
                ctx.fill();
                if (mood === "sad") {
                    // cejas caídas: el extremo interior sube
                    ctx.lineWidth = Math.max(1.3, s * 0.02);
                    ctx.beginPath();
                    ctx.moveTo(ex + side * er * 1.7, eyeY - er * 2.5);
                    ctx.lineTo(ex - side * er * 1.5, eyeY - er * 3.9);
                    ctx.stroke();
                }
                if (open > 0.5) {
                    ctx.fillStyle = Qt.rgba(1, 1, 1, 0.9);
                    ctx.beginPath();
                    ctx.arc(ex + er * 0.3 + lx * er * 0.25, eyeY - er * 0.6, er * 0.32, 0, 2 * Math.PI);
                    ctx.fill();
                }
            }
        }

        // boca
        {
            const my = -bh * 0.66;
            ctx.strokeStyle = ink;
            ctx.fillStyle = ink;
            ctx.lineWidth = Math.max(1.3, s * 0.022);
            ctx.lineCap = "round";
            ctx.beginPath();
            if (mood === "yawn") {
                const mw = s * (0.05 + 0.05 * yawnOpen), mh = s * (0.03 + 0.17 * yawnOpen);
                ctx.fillStyle = "#4a1626";
                ctx.beginPath();
                ctx.ellipse(faceX - mw, my - s * 0.02 - mh * 0.5, mw * 2, mh);
                ctx.fill();
            } else if (mood === "sleeping") {
                const o = 0.5 + 0.5 * Math.sin(t * 1.3);        // respira por la boca
                ctx.fillStyle = "#7a2335";
                ctx.beginPath();
                ctx.ellipse(faceX - s * 0.022, my - s * 0.02, s * 0.044, s * (0.012 + 0.02 * o));
                ctx.fill();
            } else if (mood === "sad") {
                ctx.beginPath();
                ctx.arc(faceX, my + s * 0.045, s * 0.05, 1.18 * Math.PI, 1.82 * Math.PI);   // ceño: curva hacia arriba
                ctx.stroke();
            } else if (mood === "tired") {
                for (let i = 0; i <= 8; i++) {
                    const px = faceX - s * 0.05 + i * s * 0.0125, py = my + Math.sin(i * 1.3 + t * 2) * s * 0.009;
                    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                }
                ctx.stroke();
            } else if (mood === "dance") {
                ctx.arc(faceX, my - s * 0.02, s * 0.07, 0.05 * Math.PI, 0.95 * Math.PI);
                ctx.closePath();
                ctx.fillStyle = "#7a2335";
                ctx.fill();
            } else if (mood === "hungry") {
                // Boca abierta que sigue al archivo: se desplaza hacia él y se abre más cuanto más cerca.
                const o = Math.max(0.2, root.mouthOpen);
                const mx = faceX + lx * s * 0.045, my2 = my - s * 0.02 + ly * s * 0.025;
                const mw = s * (0.06 + 0.075 * o), mh = s * (0.045 + 0.14 * o);
                ctx.fillStyle = "#4a1626";
                ctx.beginPath();
                ctx.ellipse(mx - mw, my2 - mh * 0.5, mw * 2, mh);
                ctx.fill();
                ctx.fillStyle = "#ff7a93";                                   // lengua
                ctx.beginPath();
                ctx.ellipse(mx - mw * 0.55, my2 + mh * 0.5 - mh * 0.42, mw * 1.1, mh * 0.42);
                ctx.fill();
            } else if ((mood === "finished" || mood === "happy") && root.chew > 0.02) {
                // Mastica: la boca se abre y se cierra rápido tras tragar.
                const open = 0.25 + 0.75 * Math.abs(Math.sin(t * 15));
                const mw = s * 0.06, mh = s * 0.075 * open * root.chew;
                ctx.fillStyle = "#7a2335";
                ctx.beginPath();
                ctx.ellipse(faceX - mw, my - s * 0.02 - mh * 0.5, mw * 2, Math.max(1.5, mh));
                ctx.fill();
            } else if (mood === "finished" || mood === "happy" || mood === "love") {
                ctx.arc(faceX, my - s * 0.02, s * 0.075, 0.05 * Math.PI, 0.95 * Math.PI);
                ctx.closePath();
                ctx.fillStyle = "#7a2335";
                ctx.fill();
            } else if (mood === "annoyed") {
                ctx.moveTo(faceX - s * 0.06, my + s * 0.01);
                ctx.lineTo(faceX + s * 0.06, my - s * 0.005);
                ctx.stroke();
            } else if (mood === "surprised" || mood === "waiting") {
                ctx.ellipse(faceX - s * 0.025, my - s * 0.02, s * 0.05, s * 0.06);
                ctx.fill();
            } else if (mood === "dizzy") {
                for (let i = 0; i <= 8; i++) {
                    const px = faceX - s * 0.07 + i * s * 0.0175, py = my + Math.sin(i * 1.6 + t * 10) * s * 0.012;
                    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                }
                ctx.stroke();
            } else {
                ctx.arc(faceX, my - s * 0.025, s * 0.058, 0.18 * Math.PI, 0.82 * Math.PI);
                ctx.stroke();
            }
        }
        // accesorios
        root.drawNeck(ctx, root.neck, bw, bh, s);
        root.drawFace(ctx, root.face, bw, bh, s, eyeY, eyeDX, faceX, er);
        root.drawHead(ctx, root.head, bw, bh, s);
        ctx.restore();

        // --- insignias y partículas (sin la deformación del cuerpo)
        const bx = cx + rx * 0.88, by = ground - jump - ry * 2 * 0.98;
        if (mood === "working") {
            ctx.fillStyle = Qt.rgba(0.23, 0.62, 1, 0.95);
            ctx.beginPath();
            ctx.roundedRect(bx - s * 0.12, by - s * 0.05, s * 0.24, s * 0.1, s * 0.05, s * 0.05);
            ctx.fill();
            ctx.fillStyle = "#fff";
            for (let i = 0; i < 3; i++) {
                const k = 0.5 + 0.5 * Math.sin(t * 7 - i * 0.9);
                ctx.beginPath();
                ctx.arc(bx - s * 0.06 + i * s * 0.06, by - k * s * 0.014, s * 0.017, 0, 2 * Math.PI);
                ctx.fill();
            }
        } else if (mood === "waiting") {
            ctx.fillStyle = "#f5a524";
            ctx.beginPath();
            ctx.arc(bx, by, s * 0.075, 0, 2 * Math.PI);
            ctx.fill();
            ctx.fillStyle = "#1a1a22";
            ctx.font = "bold " + Math.round(s * 0.11) + "px sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText("!", bx, by + s * 0.005);
        } else if (mood === "finished") {
            for (let i = 0; i < 6; i++) {
                const ph = ((t * 0.9 + i / 6) % 1);
                const ang = i * 1.05 + t * 0.8;
                const rr = s * (0.25 + ph * 0.3);
                ctx.fillStyle = Qt.rgba(i % 2 ? 0.97 : 0.2, i % 2 ? 0.7 : 0.83, i % 2 ? 0.17 : 0.6, 1 - ph);
                root.star(ctx, cx + Math.cos(ang) * rr, ground - ry - Math.abs(Math.sin(ang)) * rr * 0.9 - s * 0.1, s * 0.045 * (1 - ph * 0.5));
            }
        } else if (mood === "love") {
            for (let i = 0; i < 4; i++) {
                const ph = ((t * 0.7 + i / 4) % 1);
                ctx.fillStyle = Qt.rgba(1, 0.3, 0.43, 1 - ph);
                root.heart(ctx, cx + Math.sin(ph * 5 + i * 2) * s * 0.18, ground - ry * 2 - ph * s * 0.28, s * 0.045);
            }
        } else if (mood === "sleeping") {
            // "z" que suben y se desvanecen
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            for (let i = 0; i < 3; i++) {
                const ph = ((t * 0.28 + i / 3) % 1);
                ctx.fillStyle = Qt.rgba(0.58, 0.64, 0.72, Math.sin(Math.PI * ph) * 0.9);
                ctx.font = "bold " + Math.round(s * (0.1 + 0.07 * ph)) + "px sans-serif";
                ctx.fillText(i % 2 ? "Z" : "z", cx + rx * 0.7 + ph * s * 0.12, ground - ry * 2 - ph * s * 0.34);
            }
        } else if (mood === "dance") {
            // notas musicales
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            for (let i = 0; i < 4; i++) {
                const ph = ((t * 0.6 + i / 4) % 1);
                ctx.fillStyle = Qt.rgba(0.75, 0.52, 0.99, Math.sin(Math.PI * ph));
                ctx.font = "bold " + Math.round(s * 0.15) + "px sans-serif";
                const side = i % 2 ? 1 : -1;
                ctx.fillText(i % 2 ? "\u266B" : "\u266A", cx + side * (rx * 0.9 + ph * s * 0.1), ground - ry * 1.4 - ph * s * 0.36 + Math.sin(ph * 6 + i) * s * 0.03);
            }
        } else if (mood === "sad") {
            // lágrima que cae del ojo izquierdo
            const ph = (t * 0.6) % 1;
            ctx.fillStyle = Qt.rgba(0.38, 0.65, 0.98, 0.9 * (1 - ph * 0.5));
            ctx.beginPath();
            ctx.ellipse(cx - rx * 0.46, ground - ry * 1.55 + ph * s * 0.2, s * 0.032, s * 0.05);
            ctx.fill();
        } else if (mood === "tired") {
            // gotas de sudor
            for (let i = 0; i < 2; i++) {
                const ph = ((t * 0.5 + i * 0.5) % 1);
                ctx.fillStyle = Qt.rgba(0.38, 0.8, 0.98, 0.9 * (1 - ph));
                ctx.beginPath();
                ctx.ellipse(cx + rx * (0.95 + i * 0.12), ground - ry * 2 * 0.85 + ph * s * 0.15, s * 0.03, s * 0.048);
                ctx.fill();
            }
        } else if (mood === "dizzy") {
            for (let i = 0; i < 3; i++) {
                const a = t * 5 + i * 2.1;
                ctx.fillStyle = "#f9c74f";
                root.star(ctx, cx + Math.cos(a) * rx * 0.9, ground - ry * 2.1 + Math.sin(a) * s * 0.04, s * 0.04);
            }
        }
        ctx.restore();
    }
    }
}
