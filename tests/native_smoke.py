"""Exercise the actual QML app with isolated theme files and no desktop changes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[1]
OMARCHY = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"


class NativeSmoke(unittest.TestCase):
    def test_theme_replacement_and_background_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="chaumarchy-smoke-") as temporary:
            base = Path(temporary)
            home = base / "home"
            runtime = base / "runtime"
            runtime.mkdir(mode=0o700)
            current = home / ".local/state/omarchy/current"
            theme = current / "theme"
            theme.mkdir(parents=True)
            (theme / "colors.toml").write_text('background = "#112233"\nforeground = "#eeeeee"\n')
            (theme / "shell.toml").write_text("")
            ui = base / "ui"
            shutil.copytree(PROJECT / "ui", ui)
            shutil.copy(PROJECT / "data/suggested-mints.json", ui / "suggested-mints.json")
            for module in ("Commons", "Ui"):
                (ui / module).symlink_to(OMARCHY / module, target_is_directory=True)
            source = (ui / "shell.qml").read_text()
            (ui / "shell.qml").write_text(source.replace('    id: app\n', '''    id: app
    IpcHandler {
        target: "test"
        function capture(path: string): void { surface.grabToImage(result => result.saveToFile(path)) }
        function geometry(): string { return JSON.stringify({width: surface.width, height: surface.height, panel: !!panelLoader.item && surface.parent === panelLoader.item.body}) }
    }
''' , 1))
            environment = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                               QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic", CHAUMARCHY_PREVIEW="1")
            environment.pop("WAYLAND_DISPLAY", None)
            environment.pop("DISPLAY", None)
            environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
            if os.environ.get("CHAUMARCHY_TEST_WAYLAND") == "1":
                environment["QT_QPA_PLATFORM"] = "wayland"
                environment["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / os.environ["WAYLAND_DISPLAY"])
            log_path = base / "qml.log"
            with log_path.open("w+") as log:
                process = subprocess.Popen(["quickshell", "-p", str(ui)], env=environment,
                                           stdout=log, stderr=log)
                try:
                    def ipc(method):
                        return subprocess.run(["quickshell", "ipc", "-p", str(ui), "call", "--", "wallet", method],
                                              env=environment, text=True, capture_output=True, timeout=3)

                    def await_status(predicate):
                        deadline = time.monotonic() + 8
                        while time.monotonic() < deadline:
                            self.assertIsNone(process.poll(), log_path.read_text())
                            response = ipc("status")
                            if response.returncode == 0:
                                try:
                                    state = json.loads(response.stdout)
                                except json.JSONDecodeError:
                                    state = None
                                if state and predicate(state):
                                    return state
                            time.sleep(0.1)
                        self.fail("State did not converge. " + log_path.read_text())

                    await_status(lambda state: state["background"] == "#112233" and state["visible"])
                    self.assertEqual(ipc("hide").returncode, 0)
                    await_status(lambda state: not state["visible"])
                    # Replace the directory, as Omarchy theme switching does.
                    next_theme = current / "next-theme"
                    next_theme.mkdir()
                    (next_theme / "colors.toml").write_text('background = "#f1e2d3"\nforeground = "#102030"\n')
                    (next_theme / "shell.toml").write_text("")
                    theme.rename(current / "old-theme")
                    next_theme.rename(theme)
                    await_status(lambda state: state["background"] == "#f1e2d3" and state["foreground"] == "#102030")
                    self.assertEqual(ipc("show").returncode, 0)
                    await_status(lambda state: state["visible"])
                    self.assertEqual(ipc("expand").returncode, 0)
                    await_status(lambda state: state["visible"] and state["presentation"] == "window")
                    self.assertEqual(ipc("show").returncode, 0)
                    await_status(lambda state: state["visible"] and state["presentation"] == "panel")
                    if environment["QT_QPA_PLATFORM"] == "wayland":
                        time.sleep(0.2)
                        geometry = subprocess.run(["quickshell", "ipc", "-p", str(ui), "call", "--", "test", "geometry"], env=environment, text=True, capture_output=True, check=True)
                        dimensions = json.loads(geometry.stdout)
                        self.assertTrue(dimensions["panel"])
                        self.assertGreater(dimensions["width"], 250)
                        self.assertLess(dimensions["width"], 460)
                        if os.environ.get("CHAUMARCHY_TEST_CAPTURE"):
                            subprocess.run(["quickshell", "ipc", "-p", str(ui), "call", "--", "test", "capture", os.environ["CHAUMARCHY_TEST_CAPTURE"]], env=environment, check=True)
                            time.sleep(0.3)
                    self.assertEqual(ipc("quit").returncode, 0)
                    self.assertEqual(process.wait(timeout=5), 0)
                    output = log_path.read_text()
                    self.assertNotIn("ReferenceError", output)
                    self.assertNotIn("TypeError", output)
                    self.assertNotIn("Failed to load configuration", output)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
