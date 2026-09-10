# Validation

Use fake payments and disposable directories. The tests do not contact the four suggested mints or change the user's desktop theme or lock state.

## Local checks

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked
python3 tests/native_smoke.py
```

The native smoke test uses offscreen Qt, an isolated home/runtime directory, and the installed Omarchy kit. It checks atomic dark/light theme replacement while hidden, reopening, and quitting. Native tests require permission to create local IPC sockets. Without `CASHU_ME_TEST_WAYLAND=1` it reports a skip rather than a pass, because the panel geometry and motion assertions need a real Wayland desktop and cannot run offscreen.

Set `CASHU_ME_LOG` to a file path to record why mint operations failed while
investigating; see [architecture](architecture.md) for what it does and does not
contain.

## End-to-end fake mint

Build the optional CDK mint test tool:

```sh
cargo install cdk-mintd --version 0.18.0 --locked --no-default-features --features sqlite,fakewallet --root /tmp/cashu-me-test-tools
/tmp/cashu-me-test-tools/bin/cdk-mintd -w /tmp/cashu-me-local-mint config init --file tests/mint.toml --new-mint
```

Then start it in a separate terminal using this publicly known BIP39 test fixture (never use this seed for real funds):

```sh
CASHU_ME_TEST_MINT_SEED='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about' /tmp/cashu-me-test-tools/bin/cdk-mintd -w /tmp/cashu-me-local-mint
```

It listens on loopback port 33381, advertises the name `cashu.me test mint`, and simulates Lightning payments. HTTP mint URLs are accepted only for loopback hosts. Run:

```sh
python3 tests/wallet_integration.py
python3 tests/native_wallet.py
```

The worker integration checks token send/receive, duplicate receipt, cancellation, insufficient balance, saved invoice retrieval, QR image decoding, Lightning payment, crash/restart recovery, pending token reconstruction/reclaim, interruption during review, stale backup restore, and phrase restore. Wallets and backups are temporary.

The native worker test injects test-only controls into a temporary QML copy and starts a separate fake Omarchy shell exposing lock state. It activates the actual onboarding Create wallet button with no password, checks automatic reopening after desktop lock while hidden, invoice QR display, automatic receipt while hidden, send review/confirmation, enabling the password through Security controls, phrase display, clearing sensitive views on lock, and password unlock with the right balance. It never locks the actual desktop. Allow roughly 35 seconds for the background timer.

QR decoding tests use `rsvg-convert` and `zbarimg`. Screen-region and webcam input still need physical desktop/device checks.

## Before daily use

- Test interoperability with another independent Cashu wallet, including Cashu.me.
- Inject network failure before and after mint commits, during swap/melt, and during restore; check uncertain outcomes and crash replay.
- Test insufficient/expired/unsupported Lightning invoices and fee changes against realistic backends.
- Test physical screen/camera scanning, clipboard behavior, long tokens, and malformed QR images.
- Check accessibility, narrow windows, font scaling, malformed/missing themes, and repeated theme changes.
- Review dependency advisories and obtain an independent review of fund-handling/recovery code.

Passing the local tests is a development milestone; it does not establish production safety or mint solvency.

## First resource baseline

On the development machine, Rust 1.98.0 produced a stripped release worker of 16,282,032 bytes (15.5 MiB). With the native setup screen visible and no wallet unlocked, the worker used about 6.6 MiB RSS. The UI used about 170 MiB RSS / 84 MiB PSS; shared Qt libraries contribute to RSS. A five-second idle UI CPU sample rounded to 0.0%. That sample excludes short-lived lock-probe subprocesses and is not a startup or unlocked-wallet benchmark. More representative measurements remain on the plan.

The Rust security tests cover enabling/removing optional password protection, wrong-password rejection, device-key permissions, and recovery-phrase preservation. The worker integration test additionally covers locked ecash (a token locked to Bob's seed key refused by Alice before any mint call and redeemed by Bob, a device key generated, named, received to, backed up as an nsec, imported and removed), the Privacy toggles, the password check on revealing the phrase with App Lock on, Delete Wallet, and the in-app restore with a per-mint result.

The native flow test also activates the new mint and amount forms, validates confirmed Lightning receipt on the result page, checks history filtering and detail navigation, and exercises the App Lock and Backup & Restore pages. Optional `CASHU_ME_TEST_CAPTURE` exports temporary screenshots of the main UX surfaces from the isolated fake wallet.


For panel rendering on a running Hyprland desktop, run:

```sh
CASHU_ME_TEST_WAYLAND=1 CASHU_ME_TEST_CAPTURE=/tmp/cashu-me-panel.png python3 tests/native_smoke.py
```

This opens an isolated, non-spending preview, checks panel/window transitions and dimensions, and captures only its content. The normal native wallet test also verifies a prepared payment survives expand/hide/reopen before cancellation. The installed bar button and outside-click behavior should be checked on the desktop; these are not simulated by the offscreen test.
