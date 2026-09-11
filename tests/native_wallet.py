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
        function create(): void { if (onboarding.step === "welcome" && chassisPrimary.enabled) chassisPrimary.clicked() }
        function unlock(): void { password.text = "temporary native test password"; if (onboarding.step === "unlock" && chassisPrimary.enabled) chassisPrimary.clicked() }
        // The seed step: reveal the words, acknowledge, and continue.
        function reveal(): void { if (onboarding.step === "seed") seedCard.clicked() }
        function acknowledge(): void { if (onboarding.step === "seed") { seedAcknowledge.clicked(); if (chassisPrimary.enabled) chassisPrimary.clicked() } }
        // The first-mint step: a URL of our own, then Continue.
        function firstMint(url: string): void { if (onboarding.step === "mint") { app.firstMintInputOpen = true; app.firstMintInput = url; if (chassisPrimary.enabled) chassisPrimary.clicked() } }
        function skipMint(): void { if (onboarding.step === "mint") chassisTertiary.clicked() }
        function restore(): void { if (onboarding.step === "welcome") chassisSecondary.clicked() }
        function protect(): void {
            app.go("settings")
            app.go("app_lock")
            app.appLockMode = "enable"
            securityPassword.text = "temporary native test password"
            securityConfirmation.text = securityPassword.text
            if (enablePasswordButton.enabled) enablePasswordButton.clicked()
        }
        function mint(): void { app.go("mints"); app.go("add_mint"); app.mintUrl = "http://127.0.0.1:33381"; if (addMintButton.enabled) addMintButton.clicked() }
        function invoice(): void { app.go("receive"); lightningChoice.clicked(); app.entryText = "64"; if (amountContinue.enabled) amountContinue.clicked() }
        function sync(): void { backend.request("sync") }
        // With App Lock on, revealing the words takes the password again.
        function phrase(): void { app.go("recovery"); revealPassword.text = "temporary native test password"; if (revealButton.enabled) revealButton.clicked() }
        function send(): void { app.tab("home"); app.go("send"); ecashChoice.clicked(); app.entryText = "8"; if (amountContinue.enabled) amountContinue.clicked() }
        function confirm(): void { if (confirmButton.enabled) confirmButton.clicked() }
        function receiveShare(): void { var token = backend.share.token; app.go("receive"); app.receiveText = token; if (receiveReview.enabled) receiveReview.clicked() }
        function reopen(): void { backend.request("show_pending_token", {operation_id: (backend.state.pending_sends || [])[0].id}) }
        function back(): void { app.back() }
        function capture(): void { surface.grabToImage(result => result.saveToFile(Quickshell.env("CASHU_ME_TEST_CAPTURE"))) }
        function navigate(destination: string): void { app.tab(destination) }
        function filter(value: string): void { app.historyFilter = value }
        function detail(): void { app.transaction = Object.assign({mint: app.selectedMint.url}, backend.state.history[0]); app.go("transaction") }
        function inspect(): string {
            return JSON.stringify({ready: backend.ready, busy: backend.busy, unlocked: backend.unlocked,
                passwordRequired: backend.state.password_required, safe: desktopLock.safeToUnlock, error: backend.error, page: app.page,
                hasPhrase: backend.recoveryPhrase !== "", hasShare: !!backend.share.token || !!backend.share.invoice,
                step: app.preWallet ? onboarding.step : "", walletVisible: app.walletVisible, handoff: handoff.visible,
                hasQr: !!backend.share.qr, hasReview: !!backend.review,
                completionAmount: backend.completion.amount || "", activityCount: app.activity.length, balance: app.selectedMint.spendable, mints: (backend.state.mints || []).length})
        }
    }
'''


class NativeWallet(unittest.TestCase):
    def test_worker_payments_and_desktop_lock(self):
        with tempfile.TemporaryDirectory(prefix="cashu-me-native-wallet-") as temporary:
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
                QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="generic", CASHU_ME_PREVIEW="0",
                OMARCHY_PATH=str(shell.parent), CASHU_ME_DATA_DIR=str(base / "wallet"),
                CASHU_ME_BACKEND=str(PROJECT / "target/debug/cashu-me-wallet"))
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
                    def snap(name, settle=0.2):
                        # grabToImage saves asynchronously and fails silently
                        # when the surface has no window, so wait for a fresh
                        # file rather than copying whatever was there before.
                        # Only the floating window is visible offscreen; the
                        # compact panel is a layer-shell surface with no
                        # compositor here, so `show` leaves nothing to grab.
                        self.assertEqual(ipc(ui, "wallet", "expand").returncode, 0)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            status = ipc(ui, "wallet", "status")
                            if status.returncode == 0 and json.loads(status.stdout)["presentation"] == "window": break
                            time.sleep(0.1)
                        capture = Path(environment["CASHU_ME_TEST_CAPTURE"])
                        before = capture.stat().st_mtime_ns if capture.is_file() else None
                        time.sleep(settle); call("capture")
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            if capture.is_file() and capture.stat().st_mtime_ns != before: break
                            time.sleep(0.1)
                        else:
                            self.fail("no fresh capture for " + name + ": " + (base / "qml.log").read_text())
                        time.sleep(0.1)
                        shutil.copy(capture, capture.with_name(capture.stem + "-" + name + ".png"))
                    wait(lambda s: s["ready"] and s["safe"])
                    # The welcome field fades in 0.45 s after the title settles.
                    if environment.get("CASHU_ME_TEST_CAPTURE"): snap("onboarding-welcome", settle=1.6)
                    # Restore from Welcome is one step in and one step back.
                    call("restore"); wait(lambda s: s["step"] == "restore_seed")
                    if environment.get("CASHU_ME_TEST_CAPTURE"): snap("onboarding-restore", settle=0.6)
                    call("back"); wait(lambda s: s["step"] == "welcome")
                    # Onboarding, after cashubtc/wallet: create, then the seed
                    # phrase behind a tap-to-reveal card and an acknowledgement,
                    # then the first mint, then the handoff into the wallet.
                    call("create"); wait(lambda s: s["unlocked"] and not s["busy"] and s["step"] == "seed")
                    self.assertFalse(json.loads(ipc(ui, "test", "inspect").stdout)["walletVisible"])
                    call("reveal"); wait(lambda s: s["hasPhrase"] and not s["busy"])
                    if environment.get("CASHU_ME_TEST_CAPTURE"): snap("onboarding-seed", settle=0.4)
                    call("acknowledge"); wait(lambda s: s["step"] == "mint" and not s["hasPhrase"])
                    if environment.get("CASHU_ME_TEST_CAPTURE"): snap("onboarding-mint", settle=0.4)
                    call("firstMint", "http://127.0.0.1:33381")
                    wait(lambda s: s["mints"] == 1 and s["walletVisible"] and not s["handoff"] and s["page"] == "home" and not s["busy"])
                    self.assertFalse(json.loads(ipc(ui, "test", "inspect").stdout)["passwordRequired"])
                    # With no password, a hidden wallet should stop on desktop
                    # lock and reopen automatically when the desktop unlocks.
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    self.assertEqual(ipc(shell, "lock", "setLocked", "true").returncode, 0)
                    wait(lambda s: not s["unlocked"] and s["ready"] and not s["safe"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "false").returncode, 0)
                    wait(lambda s: s["unlocked"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    call("invoice"); wait(lambda s: s["hasShare"] and s["hasQr"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    # No Refresh call: prove the hidden wallet's timer mints the invoice.
                    wait(lambda s: s["balance"] == "64", seconds=40)
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    wait(lambda s: s["page"] == "complete" and s["completionAmount"] == "64")
                    call("navigate", "history")
                    wait(lambda s: s["page"] == "history" and s["activityCount"] == 1)
                    # Assert both ways: a filter that always returned an empty
                    # list passed when only the excluding case was checked.
                    call("filter", "pending")
                    wait(lambda s: s["activityCount"] == 0)
                    if environment.get("CASHU_ME_TEST_CAPTURE"): snap("history_empty")
                    call("filter", "completed")
                    wait(lambda s: s["activityCount"] == 1)
                    call("filter", "all")
                    wait(lambda s: s["activityCount"] == 1)
                    call("detail"); wait(lambda s: s["page"] == "transaction")
                    call("back"); wait(lambda s: s["page"] == "history")
                    if environment.get("CASHU_ME_TEST_CAPTURE"):
                        for page in ("home", "history", "mints", "send", "send_amount", "receive", "settings", "app_lock"):
                            self.assertEqual(ipc(ui, "test", "navigate", page).returncode, 0)
                            wait(lambda s: s["page"] == page)
                            snap(page)
                    # An ecash send goes from the amount straight to the token,
                    # as the reference does; the prepared review is confirmed
                    # unseen, so the share arrives with no review ever shown.
                    call("send"); wait(lambda s: s["hasShare"] and not s["hasReview"] and not s["busy"] and s["balance"] == "56")
                    # Presentation changes keep the same prepared operation and
                    # form tree: receiving the wallet's own token opens a review.
                    call("receiveShare"); wait(lambda s: s["hasReview"] and not s["busy"])
                    self.assertEqual(ipc(ui, "wallet", "expand").returncode, 0)
                    wait(lambda s: s["hasReview"] and s["balance"] == "56")
                    self.assertEqual(ipc(ui, "wallet", "hide").returncode, 0)
                    self.assertEqual(ipc(ui, "wallet", "show").returncode, 0)
                    wait(lambda s: s["hasReview"] and not s["busy"])
                    call("back"); wait(lambda s: not s["hasReview"] and not s["busy"] and s["page"] == "receive")
                    self.assertEqual(json.loads(ipc(ui, "test", "inspect").stdout)["balance"], "56")
                    # Back on the pending token for the lock to clear.
                    call("reopen"); wait(lambda s: s["hasShare"] and not s["busy"])
                    call("protect"); wait(lambda s: s["passwordRequired"] and not s["busy"])
                    call("phrase"); wait(lambda s: s["hasPhrase"] and not s["busy"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "true").returncode, 0)
                    wait(lambda s: not s["unlocked"] and not s["hasPhrase"] and not s["hasShare"] and s["ready"])
                    self.assertEqual(ipc(shell, "lock", "setLocked", "false").returncode, 0)
                    wait(lambda s: s["safe"])
                    call("unlock"); wait(lambda s: s["unlocked"] and s["balance"] == "56" and not s["busy"])
                    if environment.get("CASHU_ME_TEST_CAPTURE"):
                        call("capture")
                        deadline = time.monotonic() + 5
                        while not Path(environment["CASHU_ME_TEST_CAPTURE"]).exists() and time.monotonic() < deadline:
                            time.sleep(0.1)
                        self.assertTrue(Path(environment["CASHU_ME_TEST_CAPTURE"]).is_file())
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
