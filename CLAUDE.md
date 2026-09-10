# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cashu.me is a native Cashu ecash wallet for Omarchy (a Linux desktop environment). It uses:
- **Backend**: Rust with [Cashu Development Kit (CDK)](https://github.com/cashubtc/cdk) for wallet operations, pinned to **0.18.0**
- **Frontend**: Quickshell/QML using installed Omarchy Commons and Ui modules
- **Architecture**: Rust worker process communicates with QML frontend via newline-delimited JSON on stdin/stdout

The wallet implements controlled payments (Cashu tokens + BOLT11 Lightning), multiple explicit mints with separate balances, optional password protection, recovery phrases, and encrypted backups.

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
```

The native wallet test (~35 seconds) verifies:
- Onboarding and wallet creation
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
- Backup export/import with independent encryption

**src/payments.rs** — Token and Lightning payment operations:
- Ecash send/receive using CDK's persisted operation record
- BOLT11 invoice creation with melt (Lightning payment) operations
- Duplicate token rejection and insufficient-funds validation
- Review state expires after 5 minutes; cancellation releases prepared operations
- Timeout handling defers to reconciliation rather than retry loops

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

**ui/Welcome.qml** — Onboarding flow:
- Create wallet, restore from phrase, or import backup
- Password entry for protected wallets
- Optional security password setup

**ui/ClockFormat.js** — Formats dates per Omarchy's `shell.json` setting (excludes year)

**ui/MotionPreferences.qml, Motion.js** — Manages `reduceMotion` setting:
- Respects user's accessibility preference
- Controls whether transitions use movement or opacity-only fades

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
  "mint_urls": ["..."]
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
- No password-reset service; losing an encrypted backup's password requires a separately recorded phrase and mint URLs
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
