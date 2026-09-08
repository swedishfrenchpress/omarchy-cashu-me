# Chaumarchy

A minimal native Cashu wallet for Omarchy, planned around a Rust CDK backend and a Qt/QML interface that follows the desktop's theme.

**Status: native interface preview. Payments, encryption, recovery, and QR scanning are not connected yet.**

## Run the native preview

On Omarchy with Quickshell and `inotifywait` installed:

```sh
./bin/chaumarchy
./bin/chaumarchy --status
./bin/chaumarchy --quit
```

Closing the window leaves the preview process running; run the launcher again to reopen it. Use Settings → Quit or Ctrl+Q to exit. This currently exercises the window lifecycle only; payment monitoring will arrive with the CDK backend.

The launcher uses the installed Omarchy `Commons` and `Ui` QML modules through symlinks in a private cache directory. It does not modify the Omarchy installation. Theme updates are watched and applied without reloading the application. This integration currently targets the inspected Omarchy 4.0.2 component kit.

Run the isolated native lifecycle/theme test with:

```sh
python3 tests/native_smoke.py
```

The test uses temporary theme files and an offscreen window, so it does not change your desktop theme. It requires permission to create a local IPC socket.

## Follow the project

[PLAN.md](PLAN.md) is the source of truth for confirmed decisions, open questions, milestones, and progress. Changes to the plan are committed here before implementation. Milestones will become GitHub Issues once their requirements are agreed.

The first version targets personal everyday use: send and receive Cashu tokens and Lightning invoices, view history, manage mints, and back up or restore the wallet.

## Development boundaries

Do not commit wallet databases, recovery phrases, bearer tokens, credentials, or backup files. Use synthetic fixtures for tests. Product and security planning continues alongside the interface; fund-handling code must wait for its requirements and recovery tests.

## References

- [Cashu](https://cashu.space/)
- [Cashu protocol specifications](https://github.com/cashubtc/nuts)
- [Cashu Development Kit](https://github.com/cashubtc/cdk)
- [Cashu.me — interaction reference](https://github.com/cashubtc/cashu.me)
- [Omarchy](https://omarchy.org/)

See [LICENSE](LICENSE) for the project license.
