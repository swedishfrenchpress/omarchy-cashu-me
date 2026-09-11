import QtQuick
import "AsciiField.js" as Field

// The onboarding terrain: a grid of Omarchy's own mono glyphs driven by the
// noise in AsciiField.js, drifting on wall-clock time. One instance sits
// behind the Welcome and Restore steps (masked, morphing into the vault
// door); a second, full-bleed one is the handoff curtain that carries the
// wallet in at the end of onboarding.
//
// Time is always derived from the wall clock, never a frame counter, so a
// pause never rewinds or replays: the terrain simply is where the clock
// says it is. The frame loop runs at 30 fps, 60 while the pointer presses
// the field, and stops whenever the field is not on screen.
//
// Glyphs are shaped once into a sprite sheet (one cell per glyph, at its
// level's ink) and blitted per cell: shaping 1,200 one-character strings a
// frame cost three times what the terrain math does, and the sprites bring
// a frame to a few milliseconds.
Item {
    id: field
    // The clock runs only while the owner says the field is on screen.
    property bool active: true
    property bool reducedMotion: false
    // Freezes the terrain at a moment, for deterministic captures.
    property real staticTime: NaN
    property color ink: "#cacccc"
    property bool dark: true
    property string fontFamily: "monospace"
    // Welcome ↔ Restore morph: 0 terrain, 1 vault door.
    property real vaultMix: 0
    property real vaultCenterY: 0
    // Handoff exit, 0 intact → 1 gone. Only the curtain sets it.
    property real erosion: 0
    // Layout mask (see Field.resolve); null draws the whole layer.
    property var mask: null
    // Curtain mode: the sweep reveal and the top bias ride the erosion.
    property bool curtain: false
    property real sweep: 1
    property color scrim: "transparent"
    // The pointer lens. Off under reduced motion and for the curtain, whose
    // one bloom is fired by the handoff itself.
    property bool lensEnabled: false

    readonly property bool hasStaticTime: !isNaN(staticTime)
    readonly property bool clockRuns: active && visible && opacity > 0 && !reducedMotion && !hasStaticTime
    property real startTime: Date.now() / 1000
    property real frozenT: NaN
    property var touch: Field.createTouch()
    property bool pressed: false

    readonly property var spriteGlyphs: [Field.levelGlyph[0], Field.levelGlyph[1], Field.levelGlyph[2], Field.currencyGlyphs[0], Field.currencyGlyphs[1], Field.currencyGlyphs[2], Field.peakGlyph]
    readonly property var spriteLevel: [0, 1, 2, 3, 3, 3, 4]
    property bool spritesReady: false
    // Fired after every frame, for tests and benchmarks.
    signal painted()

    function requestPaint() { canvas.requestPaint() }
    function now() { return Date.now() / 1000 }
    function currentT() { return (now() - startTime) * Field.speed }
    function frameT() { return hasStaticTime ? staticTime : (!isNaN(frozenT) ? frozenT : currentT()) }

    // Programmatic press and release, for the handoff's centre bloom.
    function pressAt(x, y) { Field.touchPressOrMove(touch, x, y, now()) }
    function releaseLens() { Field.touchRelease(touch, now()); pressed = false }

    onClockRunsChanged: {
        frozenT = clockRuns ? NaN : currentT()
        // Never carry a stale lens across a pause.
        Field.touchReset(touch)
        pressed = false
        if (!clockRuns) requestPaint()
    }
    onVaultMixChanged: if (!clockRuns) requestPaint()
    onMaskChanged: if (!clockRuns) requestPaint()
    onInkChanged: sprites.requestPaint()
    onDarkChanged: sprites.requestPaint()
    onFontFamilyChanged: sprites.requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: { if (!clockRuns) frozenT = currentT(); sprites.requestPaint() }

    // The sprite sheet: seven glyphs, each in its level's ink. Kept on
    // screen at zero opacity so the scene graph keeps it drawable.
    Canvas {
        id: sprites
        width: Field.cellW * field.spriteGlyphs.length
        height: Field.cellH
        opacity: 0
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            ctx.font = Field.fontSize + "px \"" + field.fontFamily + "\""
            ctx.textAlign = "center"
            ctx.textBaseline = "middle"
            var ramp = field.dark ? Field.rampDark : Field.rampLight
            for (var i = 0; i < field.spriteGlyphs.length; i++) {
                ctx.fillStyle = Qt.rgba(field.ink.r, field.ink.g, field.ink.b, ramp[field.spriteLevel[i]])
                ctx.fillText(field.spriteGlyphs[i], i * Field.cellW + Field.cellW / 2, Field.cellH / 2)
            }
        }
        onPainted: { field.spritesReady = true; canvas.requestPaint() }
    }

    Timer {
        interval: field.pressed ? 16 : 33
        repeat: true
        running: field.clockRuns
        onTriggered: canvas.requestPaint()
    }

    MouseArea {
        anchors.fill: parent
        enabled: field.lensEnabled && field.clockRuns
        cursorShape: Qt.ArrowCursor
        onPressed: mouse => { field.pressed = true; Field.touchPressOrMove(field.touch, mouse.x, mouse.y, field.now()) }
        onPositionChanged: mouse => { if (pressed) Field.touchPressOrMove(field.touch, mouse.x, mouse.y, field.now()) }
        onReleased: field.releaseLens()
        onCanceled: field.releaseLens()
    }

    Canvas {
    id: canvas
    anchors.fill: parent
    onPainted: field.painted()
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0 || !field.spritesReady) return
        var t = frameT()
        var w = width, h = height
        var cellW = Field.cellW, cellH = Field.cellH, scale = Field.terrainScale
        var cols = Math.ceil(w / cellW) + 1
        var rows = Math.ceil(h / cellH) + 1
        var mix = Math.min(1, Math.max(0, vaultMix))
        var e = Math.min(1, Math.max(0, erosion))
        var m = mask
        var floorAlpha = Field.layout.bottomFloorAlpha
        var vaultX = w / 2, vaultY = vaultCenterY
        var vaultReach = Field.vault.extentRadius * Field.vault.extentRadius

        // The lens envelope and glide, advanced once per frame. A zero
        // envelope short-circuits every warp branch below.
        var wall = now()
        Field.touchAdvance(touch, wall)
        var k = Field.touchK(touch, wall)
        var tx = touch.x, ty = touch.y

        // Curtain: the opaque scrim under the same reveal as the glyphs,
        // painted in 2 px strips so the soft edge reads as a gradient.
        if (curtain) {
            var scrimA = Field.scrimOpacity(e)
            if (scrimA > 0) {
                for (var sy = 0; sy < h; sy += 2) {
                    var sf = (sy + 1) / h
                    var sa = scrimA * Field.sweepAlpha(sf, sweep) * Field.topBiasAlpha(sf, e)
                    if (sa <= 0.002) continue
                    ctx.fillStyle = Qt.rgba(scrim.r, scrim.g, scrim.b, sa)
                    ctx.fillRect(0, sy, w, 2)
                }
            }
        }

        var erosionByLevel = [1, 1, 1, 1, 1]
        if (e > 0) for (var l = 0; l < 5; l++) erosionByLevel[l] = Field.erosionAlpha(l, e)

        var buckets = [[], [], [], [], []]
        var half = cellW / 2
        // Rows above the mask's clear line multiply to nothing; skip them.
        var startRow = 0
        if (m) startRow = Math.max(0, Math.floor(m.clearEnd * h / cellH) - 1)
        for (var row = startRow; row < rows; row++) {
            var py = row * cellH + cellH / 2
            var f = py / h
            var rowAlpha = m ? Field.maskAlpha(f, m, mix, floorAlpha) : 1
            if (curtain) rowAlpha *= Field.sweepAlpha(f, sweep) * Field.topBiasAlpha(f, e)
            if (rowAlpha <= 0.002) continue
            var sy0 = (row + 0.5) * scale
            for (var l2 = 0; l2 < 5; l2++) buckets[l2].length = 0
            for (var col = 0; col < cols; col++) {
                var px = col * cellW + cellW / 2
                var sampleX = (col + 0.5) * scale
                var sampleY = sy0
                var warpedPx = px, warpedPy = py
                if (k > 0) {
                    // Samples are displaced toward the pointer, so the
                    // visible terrain flees it, rotated by the swirl so it
                    // flows around the pointer as it goes. Glyph positions
                    // never move; only the sampling warps.
                    var dx = px - tx, dy = py - ty
                    var d = Math.sqrt(dx * dx + dy * dy)
                    var fd = Field.displacement(d, k)
                    if (fd > 0) {
                        var theta = Field.swirlAngle(fd)
                        var cosT = Math.cos(theta), sinT = Math.sin(theta)
                        var inv = fd / d
                        warpedPx = px - (dx * cosT - dy * sinT) * inv
                        warpedPy = py - (dx * sinT + dy * cosT) * inv
                        sampleX = warpedPx / cellW * scale
                        sampleY = warpedPy / cellH * scale
                    }
                }
                var level
                if (mix <= 0) {
                    level = Field.displayLevel(Field.brightness(sampleX, sampleY, t))
                } else if (mix >= 1) {
                    // Settled vault: outside its reach the living ink alone
                    // never clears the first threshold, so skip the trig.
                    var vx = warpedPx - vaultX, vy = warpedPy - vaultY
                    if (vx * vx + vy * vy > vaultReach) continue
                    level = Field.displayLevel(Field.vaultBrightness(warpedPx, warpedPy, vaultX, vaultY, t))
                } else {
                    // Mid-morph: one brightness field lerping into the other
                    // per cell. The glyphs never crossfade; the landscape
                    // deforms.
                    var terrain = Field.brightness(sampleX, sampleY, t)
                    var vaultB = Field.vaultBrightness(warpedPx, warpedPy, vaultX, vaultY, t)
                    level = Field.displayLevel(terrain + (vaultB - terrain) * mix)
                }
                if (level < 0) continue
                buckets[level].push(px)
            }
            var rowTop = row * cellH
            for (var lv = 0; lv < 5; lv++) {
                var points = buckets[lv]
                if (points.length === 0) continue
                // The level's ink is baked into its sprite; the mask and the
                // erosion ride globalAlpha, one change per level per row.
                var alpha = rowAlpha * erosionByLevel[lv]
                if (alpha <= 0.002) continue
                ctx.globalAlpha = alpha
                if (lv === Field.currencyLevel) {
                    for (var i = 0; i < points.length; i++) ctx.drawImage(sprites, (3 + Field.currencyGlyphIndex(points[i], py)) * cellW, 0, cellW, cellH, points[i] - half, rowTop, cellW, cellH)
                } else {
                    var sx = (lv === Field.peakLevel ? 6 : lv) * cellW
                    for (var j = 0; j < points.length; j++) ctx.drawImage(sprites, sx, 0, cellW, cellH, points[j] - half, rowTop, cellW, cellH)
                }
            }
        }
    }
    }
}
