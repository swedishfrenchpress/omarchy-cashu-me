"""End-to-end wallet checks against a local CDK fake-payment mint only.

Start the mint with tests/mint.toml before running this test. Every wallet uses
temporary storage. Nothing is sent to the onboarding suggestions.
"""
import json
import base64
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
MINT = "http://127.0.0.1:33381"
PASSWORD = "temporary test wallet password"


class Worker:
    def __init__(self, directory):
        self.directory = directory
        self.sequence = 0
        self.process = subprocess.Popen([str(PROJECT / "target/debug/cashu-me-wallet")],
            env=dict(os.environ, CASHU_ME_DATA_DIR=str(directory)), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.read()

    def read(self, timeout=30):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            raise AssertionError("Wallet worker did not respond in time")
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("Wallet worker exited unexpectedly")
        return json.loads(line)

    def call(self, method, **fields):
        self.sequence += 1
        request = {"id": self.sequence, "method": method, **fields}
        self.process.stdin.write((json.dumps(request) + "\n").encode())
        while True:
            response = self.read()
            if response.get("id") == self.sequence:
                return response

    def ok(self, method, **fields):
        response = self.call(method, **fields)
        if "error" in response:
            raise AssertionError(f"{method}: {response['error']}")
        return response["result"]

    def state(self):
        self.ok("status")
        while True:
            response = self.read()
            if response.get("event") == "state":
                return response["state"]

    def confirm(self, method, **fields):
        review = self.ok(method, **fields)
        return self.ok("confirm_payment", review_id=review["review_id"])

    def close(self, kill=False):
        if self.process.poll() is None:
            self.process.kill() if kill else self.process.terminate()
            self.process.wait(timeout=5)
        for pipe in [self.process.stdin, self.process.stdout, self.process.stderr]:
            pipe.close()


class WalletIntegration(unittest.TestCase):
    def test_payments_locked_ecash_delete_and_restore(self):
        with urllib.request.urlopen(MINT + "/v1/info", timeout=3) as response:
            info = json.load(response)
        self.assertEqual(info["name"], "cashu.me test mint", "Refusing to test against an unidentified mint")
        workers = []
        with tempfile.TemporaryDirectory(prefix="cashu-me-wallet-test-") as temporary:
            directory = Path(temporary)
            try:
                alice = Worker(directory / "alice"); workers.append(alice)
                bob = Worker(directory / "bob"); workers.append(bob)
                for worker in [alice, bob]:
                    worker.ok("create", password=PASSWORD)
                    worker.ok("add_mint", url=MINT)
                # The mint page reads what the mint reports, for added and
                # suggested mints alike; removing one forgets it and its default.
                info = alice.ok("mint_info", url=MINT)["mint_info"]
                self.assertEqual((info["name"], info["added"]), ("cashu.me test mint", True))
                self.assertTrue(any(nut["nut"] == "9" and nut["supported"] for nut in info["nuts"]))
                self.assertIn("bolt11", info["receive_methods"])
                self.assertIn("error", alice.call("mint_info", url="https://127.0.0.1:1"))
                bob.ok("remove_mint", url=MINT)
                self.assertEqual(bob.state()["mints"], [])
                self.assertIsNone(bob.state()["selected"])
                bob.ok("add_mint", url=MINT)
                invoice = alice.ok("create_invoice", amount="128")
                self.assertTrue(invoice["invoice"].startswith("ln"))
                self.assertTrue(invoice["qr"].startswith("data:image/svg+xml;base64,"))
                svg = base64.b64decode(invoice["qr"].split(",", 1)[1])
                png_path = directory / "invoice.png"
                subprocess.run(["rsvg-convert", "-o", str(png_path)], input=svg, check=True)
                scanned = subprocess.run([str(PROJECT / "bin/scan-qr"), "image", str(png_path)], capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(scanned.stdout)["text"], invoice["invoice"])
                self.assertEqual(alice.ok("show_invoice", operation_id=invoice["quote_id"])["invoice"], invoice["invoice"])
                time.sleep(2)
                alice.ok("sync")
                self.assertEqual(alice.state()["mints"][0]["spendable"], "128")

                review = alice.ok("send_ecash", amount="16")
                self.assertEqual(review["review"]["amount"], "16")
                alice.ok("cancel_payment", review_id=review["review_id"])
                self.assertEqual(alice.state()["mints"][0]["reserved"], "0")
                sent = alice.confirm("send_ecash", amount="16")
                # A token longer than one frame ships NUT-16 animated QR frames.
                self.assertTrue(sent["qr"].startswith("data:image/svg+xml;base64,"))
                self.assertGreaterEqual(len(sent.get("qr_frames", [])), 2)
                received = bob.confirm("receive_token", text=sent["token"])
                self.assertEqual(received["amount"], "16")
                duplicate = bob.ok("receive_token", text=sent["token"])
                self.assertIn("error", bob.call("confirm_payment", review_id=duplicate["review_id"]))
                self.assertEqual(bob.state()["mints"][0]["spendable"], "16")
                alice.ok("sync")

                # Locked ecash (NUT-11): a token locked to Bob's seed key is
                # refused by Alice before any mint call and redeemed by Bob.
                bob_key = bob.state()["locked"]["seed_key"]
                self.assertTrue(bob_key.startswith("02") and len(bob_key) == 66)
                self.assertIn("error", alice.call("send_ecash", amount="4", lock_to="not a key"))
                review = alice.ok("send_ecash", amount="4", lock_to=bob_key)
                self.assertEqual(review["review"]["locked_to"], bob_key)
                locked = alice.ok("confirm_payment", review_id=review["review_id"])
                self.assertIn("error", alice.call("receive_token", text=locked["token"]))
                review = bob.ok("receive_token", text=locked["token"])
                self.assertEqual(review["review"]["locked_to"], "Your key")
                self.assertEqual(bob.ok("confirm_payment", review_id=review["review_id"])["amount"], "4")
                # A device key: generated, named, received to, backed up as an
                # nsec, imported elsewhere, and removed.
                key_id = bob.ok("generate_key")["key_added"]
                bob.ok("rename_key", key_id=key_id, nickname="Test key")
                device = bob.state()["locked"]["device_keys"][0]
                self.assertEqual((device["id"], device["nickname"], device["used_count"]), (key_id, "Test key", 0))
                locked = alice.confirm("send_ecash", amount="2", lock_to=device["pubkey"])
                review = bob.ok("receive_token", text=locked["token"])
                self.assertEqual(review["review"]["locked_to"], "Test key")
                bob.ok("confirm_payment", review_id=review["review_id"])
                self.assertEqual(bob.state()["locked"]["device_keys"][0]["used_count"], 1)
                self.assertIn("error", bob.call("reveal_key", key_id=key_id, password="incorrect password"))
                nsec = bob.ok("reveal_key", key_id=key_id, password=PASSWORD)["nsec"]
                self.assertTrue(nsec.startswith("nsec1"))
                self.assertIn("error", alice.call("import_key", text="nsec1notakey"))
                imported = alice.ok("import_key", text=nsec)["key_added"]
                self.assertEqual(alice.state()["locked"]["device_keys"][0]["pubkey"], device["pubkey"])
                alice.ok("remove_key", key_id=imported)
                self.assertEqual(alice.state()["locked"]["device_keys"], [])
                self.assertEqual(bob.ok("locked_request", key_id="")["pubkey"], bob_key)
                bob.ok("set_quick_lock", enabled=True)
                self.assertTrue(bob.state()["locked"]["quick_lock"])
                # Privacy toggles persist and thin out reconciliation.
                alice.ok("set_privacy", check_incoming=True, repeat_checks=False, check_sent=True, auto_paste=False)
                privacy = alice.state()["privacy"]
                self.assertEqual((privacy["repeat_checks"], privacy["auto_paste"]), (False, False))

                pending = alice.confirm("send_ecash", amount="8")
                alice.close(kill=True)
                alice = Worker(directory / "alice"); workers.append(alice)
                self.assertIn("error", alice.call("unlock", password="incorrect password"))
                alice.ok("unlock", password=PASSWORD)
                alice.ok("sync")
                # The pending send's history row carries its operation id, so the
                # detail page can show the token and reclaim it.
                linked = [row for row in alice.state()["history"] if row.get("operation_id") == pending["operation_id"]]
                self.assertEqual(len(linked), 1)
                reopened = alice.ok("show_pending_token", operation_id=pending["operation_id"])
                self.assertTrue(reopened["token"].startswith("cashu"))
                self.assertEqual(reopened["amount"], "8")
                self.assertEqual(reopened["mint"], MINT)
                reclaimed = alice.ok("reclaim_token", operation_id=pending["operation_id"])
                self.assertEqual(reclaimed["amount"], "8")
                # History remembers the send as reclaimed, not failed.
                self.assertTrue(any(row["reclaimed"] and row["amount"] == "8" for row in alice.state()["history"]))

                invoice = bob.ok("create_invoice", amount="10")
                paid = alice.confirm("pay_invoice", text=invoice["invoice"])
                self.assertTrue(paid["paid"])
                alice.ok("sync")
                history = alice.state()["history"]
                self.assertTrue(any(row["kind"] == "Lightning" and row["status"] == "completed" for row in history))
                expected = alice.state()["mints"][0]["spendable"]
                # With App Lock on, the words need the password again.
                self.assertIn("error", alice.call("recovery_phrase", password="incorrect password"))
                phrase = alice.ok("recovery_phrase", password=PASSWORD)["phrase"]
                # Termination during review must release the prepared reservation
                # on recovery, without creating an unconfirmed outgoing token.
                alice.ok("send_ecash", amount="4")
                alice.close(kill=True)
                alice = Worker(directory / "alice"); workers.append(alice)
                alice.ok("unlock", password=PASSWORD)
                alice.ok("sync")
                self.assertEqual(alice.state()["mints"][0]["spendable"], expected)
                self.assertEqual(alice.state()["mints"][0]["reserved"], "0")

                # Settings → Danger → Delete Wallet, then the in-app restore:
                # words validated first, then the wallet installed and each
                # mint recovered on its own with a per-mint result.
                self.assertIn("error", alice.call("validate_phrase", phrase="invalid words"))
                alice.ok("validate_phrase", phrase=phrase)
                self.assertIn("error", alice.call("restore_phrase", phrase=phrase, mint_urls=[MINT]))
                # Deleting an open wallet ends the worker so CDK's pool cannot
                # recreate the database behind it; the next start sweeps up.
                self.assertTrue(alice.ok("delete_wallet")["worker_exits"])
                alice.process.wait(timeout=10); alice.close()
                alice = Worker(directory / "alice"); workers.append(alice)
                self.assertFalse(alice.state()["exists"])
                self.assertFalse((directory / "alice" / "wallet.sqlite").exists())
                self.assertFalse((directory / "alice" / "access.sqlite").exists())
                self.assertFalse((directory / "alice" / "device.key").exists())
                alice.ok("restore_phrase", phrase=phrase, mint_urls=[MINT], password="")
                self.assertTrue(alice.state()["restoring"])
                result = alice.ok("restore_mint", url=MINT)
                self.assertEqual(result["recovered"], expected)
                state = alice.state()
                self.assertFalse(state["restoring"])
                self.assertFalse(state["password_required"])
                self.assertEqual(state["mints"][0]["spendable"], expected)
                self.assertEqual(state["mints"][0]["name"], "cashu.me test mint")
                self.assertIn("error", alice.call("send_ecash", amount="99999999"))
                # The forgotten-password way out: a locked wallet can be deleted
                # without opening it, and a fresh one created after.
                bob.close()
                bob = Worker(directory / "bob"); workers.append(bob)
                self.assertTrue(bob.state()["password_required"])
                bob.ok("delete_wallet")
                self.assertFalse(bob.state()["exists"])
                bob.ok("create", password="")
                self.assertFalse(bob.state()["password_required"])
            finally:
                for worker in workers:
                    worker.close()


if __name__ == "__main__":
    unittest.main()
