"""Parity for the onboarding ASCII field against cashubtc/wallet's fixtures.

`ui/AsciiField.js` is run through Qt's own `qml6` tool (offscreen), so the
functions under test are the ones the wallet draws with. The terrain and
currency vectors are the reference's `docs/product/ascii-field-vectors.json`
(generated from the web TypeScript); the vault, morph and erosion vectors are
the ones its Swift and Kotlin tests pin. If this test disagrees with the
reference, fix the port.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
VECTORS = json.loads((PROJECT / "tests/ascii-field-vectors.json").read_text())

# `docs/product/ascii-field-vault-mock.py` output for a vault centred at
# (195, 300): (px, py, t) -> brightness.
VAULT = [
    (195.0, 154.0, 2.5, 178.07999999999998),   # outer ring top
    (195.0, 300.0, 2.5, 227.44),               # hub: stencil peak
    (195.0, 258.0, 2.5, 35.48),                # face fill above the wheel
    (243.0, 300.0, 2.5, 182.99999999999977),   # horizontal spoke
    (195.0, 208.0, 2.5, 173.88),               # inner ring top
    (287.0, 300.0, 2.5, 182.99999999999955),   # inner ring on the spoke axis
    (261.0, 300.0, 2.5, 181.87999999999968),   # mid-spoke
    (247.0, 248.0, 2.5, 37.44),                # off-spoke face fill
    (316.0, 300.0, 2.5, 194.64),               # bolt centre
    (309.0, 235.0, 2.5, 58.72),                # between bolts
    (195.0, 450.0, 2.5, 126.40727272727273),   # face edge below the wheel
    (30.0, 60.0, 2.5, -9.24),                  # far outside: living ink alone
    (201.0, 307.0, 0.0, 38.56),                # +half-cell stencil boundary
    (189.0, 293.0, 0.0, 207.84),               # -half-cell stencil boundary
    (219.0, 244.0, 2.5, 205.32),               # stencil top bar, right reach
    (159.0, 300.0, 2.5, 202.52),               # stencil left bar
]

DRIVER = '''
import QtQuick
import "%s" as Field

QtObject {
    Component.onCompleted: {
        var out = {terrain: [], currency: [], vault: [], erosion: [], warp: {}, layout: {}}
        var v = %s
        v.terrain.forEach(function(s) {
            var f = Field.fractal(s.x, s.y, s.t), b = Field.brightness(s.x, s.y, s.t)
            out.terrain.push({f: f, b: b, level: Field.pickLevel(b)})
        })
        v.currency.forEach(function(s) { out.currency.push(Field.currencyGlyphs[Field.currencyGlyphIndex(s.px, s.py)]) })
        v.vault.forEach(function(s) { out.vault.push(Field.vaultBrightness(s[0], s[1], 195, 300, s[2])) })
        var sx = 219 / Field.cellW * Field.terrainScale, sy = 328 / Field.cellH * Field.terrainScale
        var tb = Field.brightness(sx, sy, 2.5), vb = Field.vaultBrightness(219, 328, 195, 300, 2.5)
        out.mixed = {terrain: tb, vault: vb, mixed: tb + (vb - tb) * 0.5, level: Field.displayLevel(tb + (vb - tb) * 0.5)}
        for (var level = 0; level <= 4; level++) {
            var row = []
            for (var step = 0; step <= 200; step++) row.push(Field.erosionAlpha(level, step / 200))
            out.erosion.push(row)
        }
        out.erosionPins = [Field.erosionAlpha(0, 0.24), Field.erosionAlpha(2, 0.50), Field.erosionAlpha(4, 0.76)]
        var k = []
        for (var i = 0; i <= 40; i++) k.push(Field.pressEnvelope(i / 100, 0))
        out.warp.press = k
        var rel = []
        for (var j = 0; j <= 70; j++) rel.push(Field.releaseEnvelope(j / 100, 1))
        out.warp.release = rel
        var slope = 0
        for (var d = 1; d < 120; d++) slope = Math.max(slope, Math.abs(Field.displacement(d + 0.5, 1.0529) - Field.displacement(d - 0.5, 1.0529)))
        out.warp.maxSlope = slope
        out.warp.rim = [Field.displacement(0, 1), Field.displacement(120, 1), Field.displacement(60, 1)]
        out.layout.tall = Field.resolve(590, 140, 120, 0)
        out.layout.cramped = Field.resolve(300, 140, 120, 0)
        out.layout.mask = [Field.maskAlpha(0.1, out.layout.tall, 0, 0.25), Field.maskAlpha(0.6, out.layout.tall, 0, 0.25), Field.maskAlpha(0.999, out.layout.tall, 0, 0.25)]
        console.log("RESULT " + JSON.stringify(out))
        Qt.quit()
    }
}
'''


class AsciiFieldParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.qml = shutil.which("qml6") or shutil.which("qml")
        if not cls.qml:
            raise unittest.SkipTest("qml6 is not installed")
        library = (PROJECT / "ui/AsciiField.js").as_uri()
        payload = json.dumps({"terrain": VECTORS["terrain"], "currency": VECTORS["currency"], "vault": VAULT})
        with tempfile.TemporaryDirectory(prefix="cashu-me-ascii-") as temporary:
            driver = Path(temporary) / "driver.qml"
            driver.write_text(DRIVER % (library, payload))
            # Qt logs to the journal when stderr is not a terminal; force it back.
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
            result = subprocess.run([cls.qml, str(driver)], capture_output=True, text=True, timeout=60, env=env)
        line = next((l for l in (result.stdout + result.stderr).splitlines() if "RESULT " in l), None)
        if line is None:
            raise AssertionError("no result from qml6:\n" + result.stdout + result.stderr)
        cls.out = json.loads(line[line.index("RESULT ") + len("RESULT "):])

    def test_terrain_matches_web_vectors(self):
        self.assertGreaterEqual(len(VECTORS["terrain"]), 40)
        for expected, got in zip(VECTORS["terrain"], self.out["terrain"]):
            self.assertAlmostEqual(got["f"], expected["f"], places=6, msg=str(expected))
            self.assertEqual(got["b"], expected["b"], expected)
            self.assertEqual(got["level"], expected["level"], expected)

    def test_currency_hash_matches_web_vectors(self):
        self.assertGreaterEqual(len(VECTORS["currency"]), 10)
        for expected, got in zip(VECTORS["currency"], self.out["currency"]):
            self.assertEqual(got, expected["glyph"], expected)

    def test_vault_matches_design_mock(self):
        for (px, py, t, expected), got in zip(VAULT, self.out["vault"]):
            self.assertAlmostEqual(got, expected, places=6, msg=f"vault({px}, {py}, t={t})")

    def test_morph_lerp_matches_parity_vector(self):
        mixed = self.out["mixed"]
        self.assertEqual(mixed["terrain"], 151)
        self.assertAlmostEqual(mixed["vault"], 58.44, places=6)
        self.assertAlmostEqual(mixed["mixed"], 104.72, places=6)
        self.assertEqual(mixed["level"], 1)

    def test_erosion_shape(self):
        rows = self.out["erosion"]
        eps = 1e-9
        for level, row in enumerate(rows):
            self.assertAlmostEqual(row[0], 1, places=9)
            self.assertAlmostEqual(row[-1], 0, places=9)
            previous = 1.0
            for alpha in row:
                self.assertLessEqual(alpha, previous + eps, f"level {level} rose")
                self.assertTrue(0 <= alpha <= 1)
                previous = alpha
        for step in range(201):
            for level in range(1, 5):
                self.assertGreaterEqual(rows[level][step], rows[level - 1][step] - eps)
        self.assertAlmostEqual(rows[0][100], 0, places=9)
        self.assertGreater(rows[4][100], 0.99)
        for pin in self.out["erosionPins"]:
            self.assertAlmostEqual(pin, 0.5, places=9)

    def test_lens_envelopes_never_flip_into_attraction(self):
        warp = self.out["warp"]
        for k in warp["press"] + warp["release"]:
            self.assertGreaterEqual(k, 0)
        self.assertAlmostEqual(warp["press"][0], 0, places=9)
        self.assertGreater(max(warp["press"]), 1.05)
        self.assertLess(max(warp["press"]), 1.06)
        self.assertAlmostEqual(warp["press"][28], 1, places=9)
        self.assertAlmostEqual(warp["release"][0], 1, places=9)
        self.assertAlmostEqual(warp["release"][60], 0, places=9)
        # No fold: the warped sampling stays monotone even at the overshoot.
        self.assertLess(warp["maxSlope"], 1)
        self.assertEqual(warp["rim"][0], 0)
        self.assertEqual(warp["rim"][1], 0)
        self.assertAlmostEqual(warp["rim"][2], 36, places=9)

    def test_layout(self):
        tall, cramped, mask = self.out["layout"]["tall"], self.out["layout"]["cramped"], self.out["layout"]["mask"]
        self.assertFalse(tall["suppressed"])
        self.assertTrue(cramped["suppressed"])
        self.assertLess(tall["clearEnd"], tall["opaqueEnd"])
        self.assertLess(tall["opaqueEnd"], tall["bottomFadeStart"])
        self.assertLess(tall["bottomFadeStart"], tall["bottomFadeEnd"])
        self.assertLessEqual(tall["vaultOpaqueEnd"], tall["opaqueEnd"])
        self.assertGreaterEqual(tall["vaultOpaqueEnd"], tall["clearEnd"])
        self.assertEqual(mask[0], 0)
        self.assertEqual(mask[1], 1)
        self.assertAlmostEqual(mask[2], 0.25, places=9)


if __name__ == "__main__":
    unittest.main()
