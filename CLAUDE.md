# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cashu.me is a native Cashu ecash wallet for Omarchy (a Linux desktop environment). It uses:
- **Backend**: Rust with [Cashu Development Kit (CDK)](https://github.com/cashubtc/cdk) for wallet operations, pinned to **0.18.0**
- **Frontend**: Quickshell/QML using installed Omarchy Commons and Ui modules
- **Architecture**: Rust worker process communicates with QML frontend via newline-delimited JSON on stdin/stdout

The wallet implements controlled payments (Cashu tokens + BOLT11 Lightning), multiple explicit mints with separate balances, optional password protection (App Lock), recovery phrases, in-app restore, a npub.cash Lightning address, locked ecash (NUT-11 P2PK), and privacy controls, with Settings mirroring cashubtc/wallet minus Nostr.

## Build and Development Commands

### Core development workflow
```sh
# Check code formatting
cargo fmt --check

# Run linter with all warnings as errors
cargo clippy --locked --all-targets -- -D warnings

# Run all unit and integration tests (uses fake CDK mint)
cargo test --locked

# Build debug binary (faster, used for development)
cargo build --locked

# Build optimized release binary
cargo build --release --locked

# Install to Omarchy bar and create launcher entry
./bin/install-desktop

# Run the app (after installation)
cashu-me

# Check app status or quit it
cashu-me --status
cashu-me --quit

# Preview mode: launches separate UI without wallet functionality
./bin/cashu-me --preview
```

### Testing with fake CDK mint (end-to-end validation)

The wallet is validated against a temporary fake-payment CDK mint using Python integration tests. **Do this before making wallet changes:**

```sh
# Terminal 1: Build and install the test mint
cargo install cdk-mintd --version 0.18.0 --locked --no-default-features --features sqlite,fakewallet --root /tmp/cashu-me-test-tools
/tmp/cashu-me-test-tools/bin/cdk-mintd -w /tmp/cashu-me-local-mint config init --file tests/mint.toml --new-mint

# Terminal 2: Start the test mint (use this exact seed for test fixtures)
CASHU_ME_TEST_MINT_SEED='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about' /tmp/cashu-me-test-tools/bin/cdk-mintd -w /tmp/cashu-me-local-mint

# Terminal 3: Run integration tests
python3 tests/wallet_integration.py
python3 tests/native_wallet.py
python3 tests/ascii_field.py   # terrain parity with the reference, via qml6
```

The native wallet test (~45 seconds) verifies:
- Onboarding: create, the seed card and acknowledgement, the first mint added from the onboarding step, the handoff into the wallet, and one step into restore and back
- Automatic reopening after desktop lock
- Token send/receive and QR generation
- BOLT11 Lightning payment review
- Optional password protection
- Recovery phrase display
- Clearing sensitive views on desktop lock
- Password unlock with correct balance

## Architecture

### Rust Backend (src/)

The backend is a single long-running worker process controlled by QML through JSON RPC-style requests.

**src/main.rs** — Process entry point, security hardening, and request dispatcher:
- Disables core dumps and ptrace access to protect wallet secrets
- Manages data directory location (`$CASHU_ME_DATA_DIR`, `$XDG_DATA_HOME`, or `~/.local/share/cashu-me`)
- Reads JSON requests from stdin, dispatches to handler modules
- Generates QR codes for tokens/invoices as base64 data: URIs

**src/wallet.rs** — CDK state management and persistence (largest module):
- `Storage`: Creates/opens encrypted SQLite database with SQLCipher
- `Session`: Active wallet session tied to a database password or device key
- Database schema includes CDK state and a `chaumarchy_meta` row storing recovery phrase and mint settings
- Key wrapping via `access.sqlite` vault for optional password protection (see `src/access.rs`)
- Handles wallet creation, unlock, recovery phrase generation, and mint management
- Mint reconciliation (checks pending operations, unissued quotes, spent proofs every 30 seconds)
- Settings model persisted in the `chaumarchy_meta` settings JSON: display, privacy, Lightning address, locked-ecash device keys
- `delete()` removes every wallet file; `validate_phrase` / `restore_phrase` / `restore_mint` drive the in-app restore mint by mint; `reconcile(periodic)` thins its steps by the Privacy settings

**src/payments.rs** — Token and Lightning payment operations:
- Ecash send/receive using CDK's persisted operation record
- BOLT11 invoice creation with melt (Lightning payment) operations
- Duplicate token rejection and insufficient-funds validation
- Review state expires after 5 minutes; cancellation releases prepared operations
- Timeout handling defers to reconciliation rather than retry loops

**src/lightning.rs** — Settings → Payments → Lightning: an npub.cash Lightning address through CDK's `npubcash` feature (NIP-06 key from the seed, `<npub>@npubx.cash`, quotes minted at the receiving mint). Re-registers after every unlock; auto-claim runs from reconciliation at most every two minutes.

**src/locked.rs** — Settings → Payments → Locked Ecash: the seed key (the same NIP-06 key, written `02` + x-only like the reference), device keys generated or imported from an nsec and stored in the encrypted settings, signing keys for receive, the recipient-key parser, and the pre-flight gate that refuses a token locked to a key the wallet doesn't hold.

**src/diagnostics.rs** — Opt-in error diagnostics:
- Off unless `CASHU_ME_LOG` names a file; appends the failing operation and the underlying library message, bounded per line, created 0600
- Never records a password, recovery phrase, token, or request body
- Exists because every user-facing error is a fixed string, which otherwise makes a structural mint incompatibility indistinguishable from a transient network failure

**src/access.rs** — Password protection via key wrapping:
- Creates a separate SQLCipher vault (`access.sqlite`) to store the device key
- Enables/disables password protection without revoking previous backups
- Wrong password rejected before attempting CDK operations

### QML Frontend (ui/)

Single-threaded event loop manages all UI state and coordinates with the Rust backend via JSON.

**ui/shell.qml** — Main application window and view controller (56KB):
- Quickshell `FloatingWindow` that toggles between compact panel and expanded window modes
- Imports `qs.Commons` and `qs.Ui` from installed Omarchy shell
- `ThemeSync.qml` watches parent directory for atomic theme replacements (dark/light toggle without restart)
- Desktop lock polling every second (treats unavailable lock as locked state)
- State: home/history/mints/settings tabs, onboarding, payment review forms
- Wallet motion preferences with reduced-motion option

**ui/WalletBackend.qml** — JSON RPC bridge to Rust worker:
- Spawns Rust worker as child process with pipes for stdin/stdout
- Marshals JavaScript objects to JSON requests with incrementing IDs
- Maps responses back to callers via ID matching
- Matches each reply to the outstanding request id; restarts the worker into the locked state after an unexpected exit (bounded to 3 attempts)

**Onboarding** (in `ui/shell.qml`, the `onboarding` frame) — after cashubtc/wallet's onboarding: a live stage over a pinned action chassis, one frame for every screen before the wallet (Welcome, What is ecash?, seed phrase, first mint, unlock, and the three restore steps, which Settings → Restore also uses). Create → seed card (tap to reveal, acknowledge checkbox gates the primary) → pick your first mint (suggested rows, Add by URL, Skip) → handoff into the wallet. `app.onboardingOpen` holds the wallet back from view between create and the handoff and is never persisted: an interrupted onboarding opens the wallet next time. No password at onboarding; App Lock is optional under Settings.

**ui/AsciiField.js, ui/AsciiField.qml** — The onboarding terrain: a grid of Omarchy's mono glyphs driven by layered sine noise, ported from the reference's `AsciiField.swift` and pinned to its golden vectors by `tests/ascii_field.py`. The JS holds the pure math (terrain, vault door, pointer lens, erosion, layout mask); the QML is a Canvas renderer that shapes the seven glyphs once into a sprite sheet and blits them at 30 fps on wall-clock time, pausing whenever the field is off screen. The same component draws the handoff curtain. `CASHU_ME_ASCII_STATIC_TIME` freezes it for captures.

**ui/AsciiArt.js, tools/ascii-art.py** — The empty-state illustrations: shaded ASCII art in the mono font, a lit shape sampled onto a 26 × 13 cell grid and mapped onto a density ramp, the way classic ASCII art draws (coin with an embossed ₿, clock, magnifier, funnel). The JS is generated; edit the shapes in the tool and rerun `python3 tools/ascii-art.py`. Nerd Font glyphs, glyphs in a bordered square, box-drawing line icons and small terrain-style sprites were all tried for this and none read as a picture at that size.

**ui/Bip39.js** — The BIP-39 English wordlist (the bip39 crate's copy) for the restore step's per-word check and completions; the checksum still runs in the worker.

**ui/ClockFormat.js** — Formats dates per Omarchy's `shell.json` setting (excludes year)

**ui/MotionPreferences.qml, Motion.js** — Reduced motion comes only from `CASHU_ME_REDUCED_MOTION=1`; there is no in-app setting, matching the reference wallet

### Communication Protocol

QML sends JSON objects to Rust via stdin with these fields:
```json
{
  "id": 123,
  "method": "create_wallet",
  "password": "...",
  "url": "...",
  "amount": "...",
  "text": "...",
  "phrase": "...",
  "mint_urls": ["..."],
  "lock_to": "02…", "key_id": "...", "nickname": "...",
  "enabled": true, "auto_claim": true,
  "check_incoming": true, "repeat_checks": true, "check_sent": true, "auto_paste": true
}
```

Rust emits JSON objects to stdout with response IDs, results, and optional generated QR codes.

## Key Development Patterns

### Security

- **Passwords and secrets**: Zeroized on drop using the `zeroize` crate; never passed as command arguments or environment variables
- **Exclusive worker ownership**: File lock in data directory prevents multiple wallet instances
- **Core dump prevention**: Process disables core dumps at startup (libc `PR_SET_DUMPABLE`)
- **Device key wrapping**: Optional password protection stores device key in a separate SQLCipher vault
- **File permissions**: Wallet directory is 0700, files are 0600

**Important**: Qt/JavaScript strings, serialization buffers, and swap are outside zeroization guarantees. Full-disk encryption and a trusted desktop are separate layers.

### Testing Philosophy

- **Fake mint**: All integration tests use a temporary, locally-run CDK mint to avoid contacting real mints or moving real funds
- **Disposable wallets**: Test wallets live in temporary directories and are cleaned up after each test
- **No desktop modifications**: Tests do not change the actual theme, lock state, or application launcher
- **Offscreen rendering**: Native smoke tests use Qt's offscreen backend unless `CASHU_ME_TEST_WAYLAND=1` captures real panel rendering

### State Management

- **CDK operations**: Send and Lightning review operations stay prepared until user confirmation or 5-minute timeout
- **Background reconciliation**: Pauses during review to prevent canceling the operation being presented
- **Mint reconciliation**: On unlock and every 30 seconds, checks for incomplete operations, pending quotes/melts, and spent proofs

### Invariants worth not re-breaking

- **Every mint call needs its own timeout.** CDK bounds a request only when that mint advertises a NUT-19 cache window, otherwise it awaits unbounded (`cdk-0.18.0/src/wallet/mint_connector/http_client.rs`). The worker is one serial loop, so an unbounded call freezes the whole wallet. Use `payments::bounded`.
- **Reconciliation runs every step even when one fails.** Short-circuiting on a stuck saga blocks unissued quotes and pending melts at that mint forever.
- **Pending money is cross-mint.** `snapshot()` reports balances, history, pending sends and pending invoices across every mint, and `pending_token` / `saved_invoice` / `reclaim_token` resolve the operation's own mint rather than the selected one. Scoping any of these to the selection makes real funds unreachable from the UI.
- **Lock is cooperative, not a signal.** The UI sends `{"method":"lock"}` and the worker finishes any in-flight mint call, cancels a prepared operation if a review is open, then exits; a 120s UI fallback forces it down. Killing the worker instead abandons payments mid-flight.
- **Replies are matched by id.** The worker emits `{"id":null}` for unparseable input, which is a reply to nothing and must not release a live request.
- **Stale state**: Backups older than current balance are reconciled via seed scanning before allowing spending

## Important Files and Patterns

### Database and Encryption

- **Schema**: `chaumarchy_meta` row stores serialized recovery phrase and mint URLs alongside CDK state
- **SQLCipher**: CDK uses encrypted SQLite with SQLCipher; wrong passwords fail before any state is decoded
- **Key sources**: Device key in `device.key` (device mode) or wrapped in `access.sqlite` vault (password mode)
- **WAL mode**: CDK configures write-ahead logging for durability

### Mint Catalog

- **Verified mints**: Minibits, Chorus OFF, Antifiat, Macadamia (see `docs/mints.md` for metadata links)
- **Explicit trust**: Users must add mints explicitly; tokens from unfamiliar mints require adding the mint first
- **Custom URLs**: Users can add custom mint URLs (loopback only in tests)

### UX Reference

See `docs/ux-reference.md` for mapping between Cashubtc/Wallet flows and cashu.me's Omarchy-native controls. The wallet uses:
- Ctrl+1/2/3 for Wallet/History/Mints tabs
- Ctrl+, for Settings
- Back arrow, Escape, or Alt+Left to navigate back
- Icons for Scan and Settings in the top-right corner

### Motion and Accessibility

- `docs/motion.md`: Details on interruptible transitions, pointer feedback, and reduced-motion mode
- Quickshell environment variable `CASHU_ME_ANIMATE` controls presentation motion
- All animations have `MotionPreferences.reduceMotion` checks

## Current Limitations

**Status: working development build; production validation in progress**

- Real Lightning routing and network-failure injection are not yet tested
- Cashu.me interoperability and wallet migration remain in progress
- Physical camera input, screen-region scanning, and broad Omarchy-version compatibility need verification
- The Lightning address depends on npubx.cash being reachable; it is not exercised by the fake-mint tests
- Long-term recovery workloads (very old backups, many operations) are not yet benchmarked

See `PLAN.md` for detailed progress tracking and `docs/testing.md` for validation scope.

## Configuration and Environment

- `$CASHU_ME_DATA_DIR`: Override wallet data location (default: `~/.local/share/cashu-me`)
- `$XDG_DATA_HOME`: Falls back to this before the default
- `$CASHU_ME_ANIMATE`: Set to "1" to enable motion in preview/testing
- `$CASHU_ME_PREVIEW`: Used by preview mode to disable wallet functions
- `$CASHU_ME_WINDOW`: Set to "1" to open in window mode instead of compact panel
- `$CASHU_ME_TEST_MINT_SEED`: BIP39 seed for the fake test mint (use only the fixture in `docs/testing.md`)
- `$CASHU_ME_TEST_WAYLAND`: Set to "1" to render the actual panel on a running Wayland desktop
- `$CASHU_ME_CAMERA`: A V4L2 node for the camera scan; otherwise `bin/scan-qr` queries every `/dev/video*` and takes the first single-plane capture device, because `/dev/video0` is not always a camera (Apple's ISP lists a metadata node first)

## Dependencies

- **Rust**: 1.88+
- **Cargo**: Latest stable
- **Omarchy**: 4.0.2 with Quickshell, Commons, and Ui modules installed
- **Development tools**: C compiler, OpenSSL dev files, `inotifywait`
- **QR input** (optional): `zbarimg`, `zbarcam`, `grim`, `slurp`, `wl-copy`

## Memory Baseline

On the development machine:
- Release worker: ~15.5 MiB stripped binary, ~6.6 MiB RSS at idle (setup screen visible, wallet locked)
- UI: ~170 MiB RSS / ~84 MiB PSS (includes shared Qt libraries)
- Idle CPU: ~0.0% (short-lived lock-probe subprocesses excluded)

These are development-machine measurements; production performance depends on the deployment target.
