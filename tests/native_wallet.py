"""Actual QML/worker integration; fake shell lock and temporary wallet only."""
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

# These test controls are injected only into a temporary copy. Production IPC
# never exposes wallet operations, balances, passwords, phrases, or tokens.
CONTROLS = '''
    IpcHandler {
        target: "test"
        function create(): void { backend.request("create", {password: "temporary native test password"}) }
        function unlock(): void { backend.request("unlock", {password: "temporary native test password"}) }
        function mint(): void { backend.request("add_mint", {url: "http://127.0.0.1:33381"}) }
        function invoice(): void { backend.request("create_invoice", {amount: "64"}) }
        function sync(): void { backend.request("sync") }
        function phrase(): void { app.page = "settings"; backend.request("recovery_phrase") }
        function send(): void { backend.request("send_ecash", {amount: "8"}) }
        function confirm(): void { backend.request("confirm_payment", {review_id: backend.reviewId}) }
        function capture(): void { testContent.grabToImage(result => result.saveToFile(Quickshell.env("CHAUMARCHY_TEST_CAPTURE"))) }
        function inspect(): string {
            return JSON.stringify({ready: backend.ready, busy: backend.busy, unlocked: backend.unlocked,
                safe: desktopLock.safeToUnlock, error: backend.error, page: app.page,
                hasPhrase: backend.recoveryPhrase !== "", hasShare: !!backend.share.token || !!backend.share.invoice,
                hasQr: !!backend.share.qr, hasReview: !!backend.review,
                balance: app.selectedMint.spendable, mints: (backend.state.mints || []).length})
        }
    }
'''


class NativeWallet(unittest.TestCase):
    def test_worker_payments_and_desktop_lock(self):
        with tempfile.TemporaryDirectory(prefix="chaumarchy-native-wallet-") as temporary:
            base = Path(temporary)
            home = base / "home"
            runtime = base / "runtime"; runtime.mkdir(mode=0o700)
            theme = home / ".local/state/omarchy/current/theme"; theme.mkdir(parents=True)
            (theme / "colors.toml").write_text('background = "#112233"\nforeground = "#eeeeee"\n')
            (theme / "shell.toml").write_text("")
            ui = base / "ui"; shutil.copytree(PROJECT / "ui", ui)
            shutil.copy(PROJECT / "data/suggested-mints.json", ui / "suggested-mints.json")
            for module in ("Commons", "Ui"):
                (ui / module).symlink_to(OMARCHY / module, target_is_directory=True)
            source = (ui / "shell.qml").read_text()
            source = source.replace("Controls.ScrollView {", "Controls.ScrollView {\n id: testContent", 1)
            (ui / "shell.qml").write_text(source.replace('    id: app\n', '    id: app\n' + CONTROLS, 1))
            shell = base / "omarchy/shell"; shell.mkdir(parents=True)
            (shell / "shell.qml").write_text('''import Quickshell
import Quickshell.Io
ShellRoot {
    id: root
    property bool locked: false
    IpcHandler {
        target: "lock"
        function isLocked(): bool { return root.locked }
        function setLocked(value: bool): void { root.locked = value }
    }
}
''')
            environment = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="generic", CHAUMARCHY_PREVIEW="0",
                OMARCHY_PATH=str(shell.parent), CHAUMARCHY_DATA_DIR=str(base / "wallet"),
                CHAUMARCHY_BACKEND=str(PROJECT / "target/debug/chaumarchy-wallet"))
            for key in ("WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
                environment.pop(key, None)
            processes = []
            with (base / "qml.log").open("w+") as log:
                try:
                    for path in (shell, ui):
                        processes.append(subprocess.Popen(["quickshell", "-p", str(path)], env=environment, stdout=log, stderr=log))
                    def ipc(path, target, method, *args):
                        return subprocess.run(["quickshell", "ipc", "-p", str(path), "call", "--", target, method, *args],
                            env=environment, text=True, capture_output=True, timeout=5)
                    def call(method):
                        self.assertEqual(ipc(ui, "test", method).returncode, 0)
                    def wait(predicate, seconds=15):
                        deadline = time.monotonic() + seconds
                        while time.monotonic() < deadline:
                            response = ipc(ui, "test", "inspect")
                            if response.returncode == 0:
                                state = json.loads(response.stdout)
                                self.assertFalse(state["error"], state["error"])
                                if predicate(state): return state
                            time.sleep(0.1)
                        self.fail("UI state did not converge: " + (base / "qml.log").read_text())
                    wait(lambda s: s["ready"] and s["safe"])
                    if environment.get("CHAUMARCHY_TEST_CAPTURE"):
                        call("capture")
                        time.sleep(0.3)
                        self.assertTrue(Path(environment["CHAUMARCHY_TEST_CAPTURE"]).is_file(), (base / "qml.log").read_text())
                    call("create"); wait(lambda s: s["unlocked"] and not s["busy"])
                    call("mint"); wait(lambda s: s["mints"] == 1 and not s["busy"])
                    call("invoice"); wait(lambda s: s["hasShare"] and s["hasQr"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    # No Refresh call: prove the hidden wallet's timer mints the invoice.
                    wait(lambda s: s["balance"] == "64", seconds=40)
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    call("send"); wait(lambda s: s["hasReview"] and not s["busy"])
                    call("confirm"); wait(lambda s: s["hasShare"] and not s["hasReview"] and not s["busy"])
                    call("phrase"); wait(lambda s: s["hasPhrase"] and not s["busy"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "true").returncode, 0)
                    wait(lambda s: not s["unlocked"] and not s["hasPhrase"] and not s["hasShare"] and s["ready"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "false").returncode, 0)
                    wait(lambda s: s["safe"])
                    call("unlock"); wait(lambda s: s["unlocked"] and s["balance"] == "56" and not s["busy"])
                    if environment.get("CHAUMARCHY_TEST_CAPTURE"):
                        call("capture")
                        deadline = time.monotonic() + 5
                        while not Path(environment["CHAUMARCHY_TEST_CAPTURE"]).exists() and time.monotonic() < deadline:
                            time.sleep(0.1)
                        self.assertTrue(Path(environment["CHAUMARCHY_TEST_CAPTURE"]).is_file())
                    self.assertEqual(ipc(ui, "wallet", "quit").returncode, 0)
                    self.assertEqual(processes[1].wait(timeout=5), 0)
                    output = (base / "qml.log").read_text()
                    for error in ("ReferenceError", "TypeError", "Failed to load configuration", "temporary native test password", "cashuB"):
                        self.assertNotIn(error, output)
                finally:
                    for process in processes:
                        if process.poll() is None:
                            process.terminate()
                            try: process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
