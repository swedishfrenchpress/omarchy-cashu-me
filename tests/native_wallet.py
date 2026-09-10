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
        function create(): void { if (welcome.createAction.enabled) welcome.createAction.clicked() }
        function unlock(): void { password.text = "temporary native test password"; if (unlockButton.enabled) unlockButton.clicked() }
        function protect(): void {
            app.go("settings")
            app.go("security")
            securityPassword.text = "temporary native test password"
            securityConfirmation.text = securityPassword.text
            if (enablePasswordButton.enabled) enablePasswordButton.clicked()
        }
        function mint(): void { app.go("mints"); app.go("add_mint"); app.mintUrl = "http://127.0.0.1:33381"; if (addMintButton.enabled) addMintButton.clicked() }
        function invoice(): void { app.go("receive"); lightningChoice.clicked(); app.entryText = "64"; if (amountContinue.enabled) amountContinue.clicked() }
        function sync(): void { backend.request("sync") }
        function phrase(): void { app.go("recovery"); backend.request("recovery_phrase") }
        function send(): void { app.tab("home"); app.go("send"); ecashChoice.clicked(); app.entryText = "8"; if (amountContinue.enabled) amountContinue.clicked() }
        function confirm(): void { if (confirmButton.enabled) confirmButton.clicked() }
        function back(): void { app.back() }
        function capture(): void { surface.grabToImage(result => result.saveToFile(Quickshell.env("CHAUMARCHY_TEST_CAPTURE"))) }
        function navigate(destination: string): void { app.tab(destination) }
        function filter(value: string): void { app.historyFilter = value }
        function detail(): void { app.transaction = Object.assign({mint: app.selectedMint.url}, backend.state.history[0]); app.go("transaction") }
        function inspect(): string {
            return JSON.stringify({ready: backend.ready, busy: backend.busy, unlocked: backend.unlocked,
                passwordRequired: backend.state.password_required, safe: desktopLock.safeToUnlock, error: backend.error, page: app.page,
                hasPhrase: backend.recoveryPhrase !== "", hasShare: !!backend.share.token || !!backend.share.invoice,
                hasQr: !!backend.share.qr, hasReview: !!backend.review,
                completionAmount: backend.completion.amount || "", activityCount: app.activity.length, balance: app.selectedMint.spendable, mints: (backend.state.mints || []).length})
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
                               XDG_CONFIG_HOME=str(home / ".config"),
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
                    def call(method, *args):
                        result = ipc(ui, "test", method, *args)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        # quickshell reports IPC-level failures (unknown target
                        # or function, bad arguments) on stdout with exit 0, so
                        # the status alone does not prove the call dispatched.
                        self.assertNotRegex(result.stdout, r"(?i)no such|not found|invalid|unknown",
                            f"IPC call {method} was not dispatched: {result.stdout!r}")
                        return result
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
                    self.assertFalse(json.loads(ipc(ui, "test", "inspect").stdout)["passwordRequired"])
                    # With no password, a hidden wallet should stop on desktop
                    # lock and reopen automatically when the desktop unlocks.
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    self.assertEqual(ipc(shell, "lock", "setLocked", "true").returncode, 0)
                    wait(lambda s: not s["unlocked"] and s["ready"] and not s["safe"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "false").returncode, 0)
                    wait(lambda s: s["unlocked"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    call("mint"); wait(lambda s: s["mints"] == 1 and not s["busy"])
                    call("invoice"); wait(lambda s: s["hasShare"] and s["hasQr"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    # No Refresh call: prove the hidden wallet's timer mints the invoice.
                    wait(lambda s: s["balance"] == "64", seconds=40)
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    wait(lambda s: s["page"] == "complete" and s["completionAmount"] == "64")
                    call("navigate", "history")
                    wait(lambda s: s["page"] == "history" and s["activityCount"] == 1)
                    # Assert both directions: a filter that always returned an
                    # empty list passed when only the "sent" case was checked.
                    call("filter", "sent")
                    wait(lambda s: s["activityCount"] == 0)
                    call("filter", "received")
                    wait(lambda s: s["activityCount"] == 1)
                    call("filter", "all")
                    wait(lambda s: s["activityCount"] == 1)
                    call("detail"); wait(lambda s: s["page"] == "transaction")
                    call("back"); wait(lambda s: s["page"] == "history")
                    if environment.get("CHAUMARCHY_TEST_CAPTURE"):
                        capture = Path(environment["CHAUMARCHY_TEST_CAPTURE"])
                        for page in ("home", "history", "mints", "send", "send_amount", "receive", "settings", "security"):
                            self.assertEqual(ipc(ui, "test", "navigate", page).returncode, 0)
                            wait(lambda s: s["page"] == page)
                            time.sleep(0.2)
                            call("capture")
                            time.sleep(0.2)
                            shutil.copy(capture, capture.with_name(capture.stem + "-" + page + ".png"))
                    call("send"); wait(lambda s: s["hasReview"] and not s["busy"])
                    # Presentation changes keep the same prepared payment and form tree.
                    self.assertEqual(ipc(ui, "wallet", "expand").returncode, 0)
                    wait(lambda s: s["hasReview"] and s["balance"] == "64")
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    wait(lambda s: s["hasReview"] and not s["busy"])
                    call("back"); wait(lambda s: not s["hasReview"] and not s["busy"] and s["page"] == "send_amount")
                    self.assertEqual(json.loads(ipc(ui, "test", "inspect").stdout)["balance"], "64")
                    call("send"); wait(lambda s: s["hasReview"] and not s["busy"])
                    call("confirm"); wait(lambda s: s["hasShare"] and not s["hasReview"] and not s["busy"])
                    call("protect"); wait(lambda s: s["passwordRequired"] and not s["busy"])
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
