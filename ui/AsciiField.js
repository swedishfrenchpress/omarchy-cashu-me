.pragma library

// The onboarding terrain, vault door, pointer lens and erosion curve as pure
// functions, after cashubtc/wallet's `AsciiField.swift` / `AsciiField.kt`
// (MIT, copyright 2026 cashubtc), which themselves port the cashu.space
// hero. Same coefficients, same order of operations, same magic numbers:
// `tests/ascii_field.py` drives these functions against the reference's
// golden vectors, so a wallet on Omarchy draws the same terrain as one on a
// phone. Only the glyph shapes differ, and those are Omarchy's own mono face.
//
// Everything here is free of view state. The renderer (`AsciiField.qml`)
// samples it per cell; the tests call it directly.

// ---- Terrain
// Cells are 12x14 px. The terrain is texture, not text: the grid never scales
// with Omarchy's font size, or the composition would change with it.
var cellW = 12
var cellH = 14
var fontSize = 12
var terrainScale = 0.13
var contourSpacing = 0.08
// Half the web's 0.9. This screen is stared at while someone decides whether
// to trust the app with money; the field is ambient texture, not a show.
var speed = 0.45

var levelMin = [40, 90, 140, 200, 216]
var levelGlyph = ["·", "/", ","]
var currencyGlyphs = ["$", "¥", "€"]
var peakGlyph = "₿"
var currencyLevel = 3
var peakLevel = 4
// The wallet's one divergence from the web terrain: more ₿. Cells in the
// top of the currency band draw the peak glyph; `pickLevel` stays verbatim.
var peakBoostMin = 208

function noise(x, y, t) {
    return Math.sin(0.8 * x + 0.3 * t) * Math.cos(0.6 * y + 0.2 * t) * 0.5
        + 0.25 * Math.sin(1.6 * x + 1.2 * y + 0.15 * t)
        + Math.sin(0.3 * x - 0.4 * t) * Math.cos(0.4 * y + 0.25 * t) * 0.6
        + 0.3 * Math.sin(0.5 * (x + y) + 0.35 * t)
        + Math.sin(2.5 * x + 0.1 * t) * Math.cos(2.8 * y - 0.12 * t) * 0.15
}

function fractal(x, y, t) {
    return noise(x, y, t)
        + 0.4 * noise(2.2 * x, 2.2 * y, 0.7 * t)
        + 0.15 * noise(4.5 * x, 4.5 * y, 0.4 * t)
}

// Brightness 0..255 at noise coordinates (x, y). Cells near a contour line
// (height modulo the spacing) brighten, so ridgelines emerge from the plain.
function brightness(x, y, t) {
    var r = Math.min(1, Math.max(0, (fractal(x, y, t) + 1.8) / 3.6))
    var s = (r % contourSpacing) / contourSpacing
    var onContour = s < 0.12 || s > 0.88
    var b = onContour ? Math.round(200 * r + 55) : Math.round(140 * r)
    if (onContour) {
        // Steeper terrain sharpens its contour line.
        var gx = noise(x + 0.01, y, t) - noise(x - 0.01, y, t)
        var gy = noise(x, y + 0.01, t) - noise(x, y - 0.01, t)
        var d = 12 * Math.sqrt(gx * gx + gy * gy)
        if (d > 0.5) b = Math.min(255, b + Math.round(40 * d))
    }
    return b
}

// Highest level whose threshold `b` clears; -1 draws nothing.
function pickLevel(b) {
    for (var i = levelMin.length - 1; i >= 0; i--) if (b >= levelMin[i]) return i
    return -1
}

function displayLevel(b) {
    return b >= peakBoostMin ? peakLevel : pickLevel(b)
}

// Stable spatial hash: a cell always keeps the same currency, so motion comes
// from the terrain crossing thresholds rather than random shimmer. Verbatim
// the web's `Math.imul` / `>>>` arithmetic.
function currencyGlyphIndex(px, py) {
    var col = Math.floor(px / cellW) | 0
    var row = Math.floor(py / cellH) | 0
    var hash = (Math.imul(col, 31) ^ Math.imul(row, 17)) | 0
    var mixed = Math.imul(hash ^ (hash >>> 13), 1274126177)
    return (mixed >>> 0) % 3
}

// ---- Erosion
// The handoff's exit dissolves the field by its own material: the dotted
// plain thins first, ridgelines hold, and the ₿ peaks are the last glyphs
// standing. Windows overlap so the field thins continuously.
var erosionStagger = 0.13
var erosionWindow = 0.48

function erosionAlpha(level, e) {
    var u = Math.min(1, Math.max(0, (e - level * erosionStagger) / erosionWindow))
    return 1 - u * u * (3 - 2 * u)
}

// ---- Vault
// The restore step's material: a procedural vault door through the same
// glyph ramp, its ink modulated by the live terrain at the same cell so the
// welcome ridgelines keep crawling through the door. Grid units are pixels.
// Authored at fixed size: the vault recenters, never scales.
var vault = {
    outerRadius: 146, outerWidth: 11, outerBrightness: 196,
    innerRadius: 92, innerWidth: 9, innerBrightness: 168,
    faceRadius: 152, faceBrightness: 52,
    spokeMinDistance: 24, spokeMaxDistance: 96, spokeBrightness: 176, spokeArcWidth: 8,
    boltRadius: 121, boltHalfWidth: 8, boltBrightness: 212,
    stencilPeakBrightness: 221, stencilCurrencyBrightness: 202,
    liveGain: 0.28, livePivot: 128,
    extentRadius: 157,
    stencilCols: 9, stencilRows: 11,
    stencil: [
        "....2....",
        ".222222..",
        ".2....22.",
        ".2.....2.",
        ".2....22.",
        ".222222..",
        ".2....22.",
        ".2.....2.",
        ".2....22.",
        ".222222..",
        "....2...."
    ]
}

function ringProfile(d, radius, width) {
    return Math.max(0, 1 - Math.abs(d - radius) / width)
}

function vaultBrightness(px, py, cx, cy, t) {
    var v = vault
    var dx = px - cx, dy = py - cy
    var d = Math.sqrt(dx * dx + dy * dy)
    var b = 0
    if (d < v.faceRadius) b = v.faceBrightness
    b = Math.max(b, v.outerBrightness * ringProfile(d, v.outerRadius, v.outerWidth))
    b = Math.max(b, v.innerBrightness * ringProfile(d, v.innerRadius, v.innerWidth))
    var ang = Math.atan2(dy, dx)
    if (d > v.spokeMinDistance && d < v.spokeMaxDistance) {
        var a = (ang + Math.PI) % (Math.PI / 3)
        var arc = Math.min(a, Math.PI / 3 - a) * d
        b = Math.max(b, v.spokeBrightness * Math.max(0, 1 - arc / v.spokeArcWidth))
    }
    var a12 = (ang + Math.PI) % (Math.PI / 6)
    var tangential = Math.min(a12, Math.PI / 6 - a12) * v.boltRadius
    var boltD = Math.sqrt((d - v.boltRadius) * (d - v.boltRadius) + tangential * tangential)
    if (boltD < v.boltHalfWidth) b = Math.max(b, v.boltBrightness)
    // Stencil indexing rounds half toward +∞, as the reference pins.
    var col = Math.floor(dx / cellW + 0.5) + (v.stencilCols >> 1)
    var row = Math.floor(dy / cellH + 0.5) + (v.stencilRows >> 1)
    if (row >= 0 && row < v.stencilRows && col >= 0 && col < v.stencilCols) {
        var c = v.stencil[row].charAt(col)
        if (c === "2") b = Math.max(b, v.stencilPeakBrightness)
        else if (c === "1") b = Math.max(b, v.stencilCurrencyBrightness)
    }
    var tb = brightness(px / cellW * terrainScale, py / cellH * terrainScale, t)
    return b + v.liveGain * (tb - v.livePivot)
}

// ---- Pointer lens
// The warp under a pressed pointer. Distances are grid pixels.
var warp = {
    radius: 120,
    radiusBloomFloor: 0.75,
    maxDisplacement: 36,
    pressDuration: 0.28,
    releaseDuration: 0.6,
    backOvershoot: 1.2,
    swirlMax: 0.35,
    followTau: 0.07
}

function bloomedRadius(k) {
    return warp.radius * (warp.radiusBloomFloor + (1 - warp.radiusBloomFloor) * Math.min(1, k))
}

// Zero in value and slope at the pointer and at the rim, so contours never
// kink at the lens boundary and the warped sampling never folds.
function displacement(d, k) {
    if (k <= 0 || d <= 0) return 0
    var r = bloomedRadius(k)
    if (d >= r) return 0
    var s = d / r
    var e = s * (1 - s)
    return warp.maxDisplacement * k * 16 * e * e
}

// easeOutBack, clamped at zero: even a microscopically negative envelope
// would flip the lens into attraction.
function backOut(u) {
    var c = Math.min(1, Math.max(0, u))
    var q = c - 1
    return Math.max(0, 1 + (warp.backOvershoot + 1) * q * q * q + warp.backOvershoot * q * q)
}

function pressEnvelope(elapsed, k0) {
    return k0 + (1 - k0) * backOut(elapsed / warp.pressDuration)
}

// A settle, deliberately not a spring.
function releaseEnvelope(elapsed, k0) {
    var v = 1 - Math.min(1, Math.max(0, elapsed / warp.releaseDuration))
    return k0 * v * v * v
}

function swirlAngle(f) {
    return warp.swirlMax * f / warp.maxDisplacement
}

function followFactor(dt) {
    return 1 - Math.exp(-dt / warp.followTau)
}

// Mutable lens state, read by the frame loop. `now` is wall-clock seconds.
function createTouch() {
    return {phase: "idle", x: 0, y: 0, targetX: 0, targetY: 0, phaseStart: 0, k0: 0, lastAdvance: 0}
}

function touchPressOrMove(touch, x, y, now) {
    touch.targetX = x
    touch.targetY = y
    if (touch.phase === "pressed") return
    // A landing pointer snaps the lens under it; the bloom starts there.
    touch.x = x
    touch.y = y
    touch.lastAdvance = now
    // Ramp from the current envelope, so a re-press mid-decay doesn't snap
    // the lens shut and reopen it from zero.
    touch.k0 = touchK(touch, now)
    touch.phaseStart = now
    touch.phase = "pressed"
}

function touchRelease(touch, now) {
    if (touch.phase !== "pressed") return
    touch.k0 = touchK(touch, now)
    touch.phaseStart = now
    touch.phase = "released"
}

function touchReset(touch) {
    touch.phase = "idle"
}

// Advances the position glide; once per frame before sampling. Keeps
// gliding through the release settle so a flick drifts to rest.
function touchAdvance(touch, now) {
    if (touch.phase === "idle") return
    var dt = Math.min(0.1, Math.max(0, now - touch.lastAdvance))
    touch.lastAdvance = now
    var a = followFactor(dt)
    touch.x += (touch.targetX - touch.x) * a
    touch.y += (touch.targetY - touch.y) * a
}

function touchK(touch, now) {
    if (touch.phase === "idle") return 0
    if (touch.phase === "pressed") return pressEnvelope(now - touch.phaseStart, touch.k0)
    var k = releaseEnvelope(now - touch.phaseStart, touch.k0)
    if (k <= 0) touch.phase = "idle"
    return k
}

// ---- Layout
// Where the field is clear, opaque, and fading, as fractions of the layer
// height. The layer always spans the whole onboarding frame; the mask shapes
// what shows. Everything is the reference's `AsciiFieldLayout`, with the
// vault centred in the space below the restore step's entry card rather
// than below the header, since the desktop restore step has content there.
var layout = {
    minBand: 160,
    maxBand: 300,
    bandFraction: 0.26,
    suppressionThreshold: 120,
    maskFade: 0.30,
    fullFade: 0.30,
    bottomFadeReach: 48,
    bottomFadeUnderlap: 40,
    bottomFloorAlpha: 0.25
}

// Returns null when the space between the header and the chassis is too
// short for the field to be anything but a squashed smear.
function resolve(height, headerClearance, chassisInset, vaultRegionTop) {
    var L = layout
    var band = Math.min(Math.max(L.minBand, L.bandFraction * height), L.maxBand)
    var available = height - headerClearance - chassisInset
    var suppressed = Math.min(band, available) < L.suppressionThreshold
    var h = Math.max(height, band + chassisInset)
    var bandTop = h - chassisInset - band
    var bandClearEnd = bandTop / h
    var bandOpaqueEnd = (bandTop + L.maskFade * band) / h
    var fullClearEnd = Math.min(headerClearance / h, bandClearEnd)
    var fullOpaqueEnd = Math.min(fullClearEnd + L.fullFade, bandOpaqueEnd)
    var regionTop = Math.max(headerClearance, vaultRegionTop || 0)
    var vaultCenterY = (regionTop + h - chassisInset) / 2
    var vaultTop = (vaultCenterY - vault.extentRadius) / h
    return {
        suppressed: suppressed,
        clearEnd: fullClearEnd,
        opaqueEnd: fullOpaqueEnd,
        bottomFadeStart: (h - chassisInset - L.bottomFadeReach) / h,
        bottomFadeEnd: (h - chassisInset + Math.min(L.bottomFadeUnderlap, chassisInset)) / h,
        vaultOpaqueEnd: Math.max(fullClearEnd, Math.min(vaultTop, fullOpaqueEnd)),
        vaultCenterY: vaultCenterY
    }
}

// The mask as a function of the row's vertical fraction `f`: clear behind
// the header, a ramp to opaque (shortening toward the vault's top edge as
// `vaultMix` settles), then a fade to a faint floor across the chassis edge
// so the field keeps running, very subtly, behind the buttons.
function maskAlpha(f, r, vaultMix, floorAlpha) {
    var opaqueEnd = r.opaqueEnd + (r.vaultOpaqueEnd - r.opaqueEnd) * Math.min(1, Math.max(0, vaultMix))
    var a
    if (f <= r.clearEnd) a = 0
    else if (f >= opaqueEnd) a = 1
    else a = (f - r.clearEnd) / (opaqueEnd - r.clearEnd)
    var bottom
    if (f <= r.bottomFadeStart) bottom = 1
    else if (f >= r.bottomFadeEnd) bottom = floorAlpha
    else bottom = 1 + (floorAlpha - 1) * (f - r.bottomFadeStart) / (r.bottomFadeEnd - r.bottomFadeStart)
    return a * bottom
}

// ---- Handoff curtain
// A soft-edged reveal sweeping top to bottom, then a screen-anchored top
// bias that deepens with the erosion so the field clears from the top down.
var curtain = {sweepEdge: 0.30, scrimClear: 0.42, topBiasDepth: 0.55}

function sweepAlpha(f, sweep) {
    var maskHeight = 1 + curtain.sweepEdge
    var offset = (sweep - 1) * maskHeight
    return Math.min(1, Math.max(0, (offset + maskHeight - f) / curtain.sweepEdge))
}

function topBiasAlpha(f, erosion) {
    if (f >= curtain.topBiasDepth) return 1
    return (1 - erosion) + erosion * (f / curtain.topBiasDepth)
}

// Smoothstepped so the scrim neither snaps at the start nor lingers.
function scrimOpacity(erosion) {
    var u = Math.min(1, Math.max(0, erosion / curtain.scrimClear))
    return 1 - u * u * (3 - 2 * u)
}

// The zinc ramp as opacities on Omarchy's foreground: asymmetric between
// light and dark paper on purpose, as the site mirrors its hex array.
var rampLight = [0.17, 0.37, 0.56, 0.68, 0.75]
var rampDark = [0.25, 0.32, 0.44, 0.63, 0.83]
