import QtQuick 2.12

Item {
    id: root
    anchors.fill: parent
    visible: false

    property var specs: []
    property string mode: "generic"
    property string baseUrl: ""
    property point cursorPos: Qt.point(-1, -1)
    property bool cursorValid: cursorPos.x >= 0 && cursorPos.y >= 0
    property bool cursorInside: true

    property int maxTotal: mode === "accurate" ? 800 : 320
    readonly property int perSystemCap: mode === "accurate" ? 260 : 150
    readonly property real rateCap: mode === "accurate" ? 260 : 110

    property var _systems: []
    property point _prevCursor: Qt.point(-1, -1)

    readonly property var _defaultFallbackSpec: ({
        rate: 75,
        life_min: 0.45,
        life_max: 0.85,
        size_min: 6,
        size_max: 16,
        spread: 4,
        vel: 18,
        color: [130, 200, 255],
        color2: [255, 140, 220],
        blend: "additive",
        emit_shape: "sphererandom",
        attract: true,
        attract_scale: 350,
        attract_threshold: 40,
        drag: 2.5,
        overbright: 1.35
    })

    onSpecsChanged: rebuild()
    onModeChanged: rebuild()
    onVisibleChanged: {
        if (visible && _systems.length === 0) rebuild();
    }

    Item { id: texHost; visible: false }

    Component {
        id: texComp
        Image {
            cache: true
            asynchronous: true
            fillMode: Image.Stretch
            smooth: true
        }
    }

    Component {
        id: tintComp
        Canvas { visible: false }
    }

    function rebuild() {
        for (let c = texHost.children.length - 1; c >= 0; c--)
            texHost.children[c].destroy();
        const nextSys = [];
        const srcList = (specs && specs.length > 0) ? specs : [{ name: "default_glow", spec: _defaultFallbackSpec }];
        for (let i = 0; i < srcList.length; i++) {
            const entry = srcList[i];
            const sp = (entry && entry.spec) ? entry.spec : _defaultFallbackSpec;
            const sys = {
                spec: sp,
                pts: [],
                acc: 0,
                img: null,
                variants: null,
                tintDone: false
            };
            if (mode === "accurate" && sp.texture && baseUrl !== "") {
                sys.img = texComp.createObject(texHost, { source: baseUrl + "/" + sp.texture });
            }
            nextSys.push(sys);
        }
        _systems = nextSys;
        canvas.requestPaint();
    }

    function rand(a, b) { return a + Math.random() * (b - a); }

    function paletteFor(sp) {
        if (sp.tint && sp.tint.length === 3) return [sp.tint];
        const c1 = sp.color || [130, 200, 255];
        const c2 = sp.color2 ? sp.color2 : c1;
        const steps = 6;
        const out = [];
        for (let i = 0; i < steps; i++) {
            const t = i / (steps - 1);
            out.push([
                Math.round(c1[0] + (c2[0] - c1[0]) * t),
                Math.round(c1[1] + (c2[1] - c1[1]) * t),
                Math.round(c1[2] + (c2[2] - c1[2]) * t)
            ]);
        }
        return out;
    }

    function buildVariants(sys) {
        const img = sys.img;
        const pal = paletteFor(sys.spec);
        sys.tintDone = true;
        if (!pal || !img || img.width < 2 || img.height < 2) return;
        try {
            sys.variants = [];
            for (let v = 0; v < pal.length; v++) {
                const cv = tintComp.createObject(texHost, { width: img.width, height: img.height });
                if (!cv || !cv.isAvailable) continue;
                const tctx = cv.getContext("2d");
                if (!tctx) continue;
                tctx.reset();
                tctx.drawImage(img, 0, 0);
                tctx.globalCompositeOperation = "multiply";
                tctx.fillStyle = "rgb(" + pal[v][0] + "," + pal[v][1] + "," + pal[v][2] + ")";
                tctx.fillRect(0, 0, cv.width, cv.height);
                tctx.globalCompositeOperation = "destination-in";
                tctx.drawImage(img, 0, 0);
                sys.variants.push(cv);
            }
        } catch (e) {
            sys.variants = null;
        }
    }

    Timer {
        id: stepTimer
        interval: 16
        repeat: true
        running: root.visible && root._systems.length > 0
        onTriggered: root.step()
    }

    function step() {
        const dt = 0.016;
        let total = 0;
        for (let i = 0; i < _systems.length; i++)
            total += _systems[i].pts.length;

        const curX = root.cursorPos.x;
        const curY = root.cursorPos.y;
        const prevX = root._prevCursor.x >= 0 ? root._prevCursor.x : curX;
        const prevY = root._prevCursor.y >= 0 ? root._prevCursor.y : curY;
        const moveDist = root.cursorValid ? Math.hypot(curX - prevX, curY - prevY) : 0;
        if (root.cursorValid)
            root._prevCursor = Qt.point(curX, curY);

        for (let s = 0; s < _systems.length; s++) {
            const sys = _systems[s];
            const sp = sys.spec;
            const accurate = mode === "accurate" && sys.img && sys.img.status === Image.Ready;
            if (accurate && !sys.tintDone) buildVariants(sys);
            const sprites = accurate && sys.variants && sys.variants.length > 0;
            const dying = !root.cursorInside;

            if (!dying && root.cursorValid && total < root.maxTotal) {
                const boost = Math.min(3.5, 1.0 + moveDist / 18.0);
                sys.acc += Math.min(sp.rate || 60, root.rateCap) * boost * dt;
                const spawnCount = Math.min(Math.floor(sys.acc), root.perSystemCap - sys.pts.length);
                for (let k = 0; k < spawnCount && total < root.maxTotal; k++) {
                    sys.acc -= 1;
                    const tInterp = spawnCount > 1 ? (k / spawnCount) : 1.0;
                    const baseX = prevX + (curX - prevX) * tInterp;
                    const baseY = prevY + (curY - prevY) * tInterp;
                    const c1 = sp.color || [130, 200, 255];
                    const c2 = sp.color2 ? sp.color2 : c1;
                    const lf = rand(sp.life_min || 0.4, sp.life_max || 0.85);
                    const spread = sp.spread !== undefined ? sp.spread : 4;
                    const ang = Math.random() * Math.PI * 2;
                    const rad = Math.random() * spread;
                    const sx = baseX + Math.cos(ang) * rad;
                    const sy = baseY + Math.sin(ang) * rad;
                    const vel = sp.vel !== undefined ? sp.vel : 16;
                    const vx = rand(-vel, vel);
                    const vy = rand(-vel, vel) - vel * 0.12;
                    sys.pts.push({
                        x: sx,
                        y: sy,
                        vx: vx,
                        vy: vy,
                        life: lf,
                        maxLife: lf,
                        size: rand(sp.size_min || 6, sp.size_max || 15),
                        r: Math.round(rand(c1[0], c2[0])),
                        g: Math.round(rand(c1[1], c2[1])),
                        b: Math.round(rand(c1[2], c2[2])),
                        rot: Math.random() * Math.PI * 2,
                        spin: rand(-2.0, 2.0),
                        vi: sprites ? Math.floor(Math.random() * sys.variants.length) : 0
                    });
                    total++;
                }
                if (sys.acc > 4) sys.acc = 0;
            }

            for (let p = sys.pts.length - 1; p >= 0; p--) {
                const pt = sys.pts[p];
                pt.life -= dt * (dying ? 3.0 : 1.25);
                if (pt.life <= 0) {
                    sys.pts.splice(p, 1);
                    continue;
                }
                pt.x += pt.vx * dt;
                pt.y += pt.vy * dt;
                pt.vx *= 0.92;
                pt.vy *= 0.92;
                pt.rot += pt.spin * dt;
            }
        }
        canvas.requestPaint();
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d");
            if (!ctx) return;
            ctx.reset();
            for (let s = 0; s < root._systems.length; s++) {
                const sys = root._systems[s];
                const sp = sys.spec;
                const accurate = root.mode === "accurate" && sys.img && sys.img.status === Image.Ready;
                ctx.globalCompositeOperation = (sp.blend === "additive") ? "lighter" : "source-over";
                const pts = sys.pts;
                for (let i = 0; i < pts.length; i++) {
                    const p = pts[i];
                    const a = Math.max(0, Math.min(1, p.life / p.maxLife));
                    if (accurate) {
                        const ob = sp.overbright ? sp.overbright : 1.0;
                        ctx.globalAlpha = Math.min(1, a * (0.65 + 0.25 * ob));
                        const src = (sys.variants && sys.variants.length > 0)
                                    ? sys.variants[p.vi % sys.variants.length]
                                    : sys.img;
                        ctx.save();
                        ctx.translate(p.x, p.y);
                        ctx.rotate(p.rot || 0);
                        ctx.drawImage(src, -p.size / 2, -p.size / 2, p.size, p.size);
                        ctx.restore();
                    } else {
                        const r = Math.max(1.0, p.size * (0.35 + 0.65 * a));
                        const col = p.r + "," + p.g + "," + p.b;
                        const grad = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
                        grad.addColorStop(0, "rgba(255,255,255," + (0.9 * a).toFixed(3) + ")");
                        grad.addColorStop(0.35, "rgba(" + col + "," + (0.8 * a).toFixed(3) + ")");
                        grad.addColorStop(1, "rgba(" + col + ",0)");
                        ctx.fillStyle = grad;
                        ctx.beginPath();
                        ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
                        ctx.fill();
                    }
                }
            }
            ctx.globalAlpha = 1;
            ctx.globalCompositeOperation = "source-over";
        }
    }
}
