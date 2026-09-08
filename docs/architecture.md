# Architecture and recovery boundaries

## Native UI

A standalone Quickshell `FloatingWindow` imports `qs.Commons` and `qs.Ui` from the installed Omarchy shell through private cache symlinks. It uses the actual controls and typography rather than reproducing a palette. `ThemeSync.qml` watches the parent of the active theme directory so atomic theme replacements work. Shared Omarchy components retain their font and shell-override watchers.

There is no browser, HTTP wallet service, or listening wallet socket. General shell IPC supports only show, hide, status, and quit. Its status excludes balances, tokens, and phrases. A Rust worker is a managed child with private newline-delimited JSON stdin/stdout. Passwords and tokens are not command arguments or environment variables. QR scanning returns decoded text through a child pipe; zbar's D-Bus reporting is disabled.

Closing hides the window. Desktop locking is polled through Omarchy's lock IPC every second, with a two-second timeout. An unavailable shell is treated as locked. Locking stops the wallet worker and clears sensitive UI views. This is bounded polling, not an instantaneous lock notification. Unlock starts a fresh worker. Device-mode wallets reopen automatically when the desktop unlocks, including while hidden. Password-protected wallets require their password again. There is no persistent unlocked background daemon after Quit.

## Encrypted state

CDK and `cdk-sqlite` 0.18.0 are pinned with default features disabled and wallet/SQLCipher support enabled. The encrypted SQLite database contains CDK state and a versioned `chaumarchy_meta` row with the phrase and mint settings. SQLCipher's runtime availability and password acceptance are checked before CDK migrations. Tests verify that ordinary SQLite headers and the phrase are absent from the database file, incorrect passwords fail, and wallet files use mode 0600 in a 0700 directory.

New wallets use an independent random database key. In device mode it is stored in `device.key` (0600), so there is no protection from someone with access to the desktop account. Optional Security password protection wraps this key in a small SQLCipher `access.sqlite` vault, publishes and flushes that vault, then removes `device.key`. Disabling protection verifies the current password, durably publishes the device key, then removes the vault. An interrupted transition always leaves a usable key source; the password vault takes precedence when both exist. A successful password unlock finishes cleanup after an interrupted enable. This is key wrapping: it does not revoke keys or backups someone previously copied. Earlier wallets encrypted directly with a password remain readable.

One worker owns each data directory through an exclusive file lock. CDK configures durable WAL-backed storage. Backup export uses SQLCipher to create a private encrypted file, marks it as requiring restoration, flushes it, then publishes it without overwriting an existing destination. Backups use an independently chosen password. Import follows the same publication procedure so a published imported file already carries its recovery requirement.

The worker disables core dumping and ptrace access. Known request password, phrase, and token strings are zeroized on drop; terminating the worker releases CDK pools and their password copies. This is not a claim of complete memory erasure: Qt/JavaScript strings, serialization buffers, dependency allocations, swap, and a compromised desktop remain outside that guarantee. Full-disk encryption and a trusted desktop are separate from wallet-file encryption.

## Payments

CDK prepared operations remain alive while the user reviews a send or Lightning payment. A matching confirmation is required; cancellation releases the prepared operation. Review expires after five minutes. Background reconciliation pauses during review so it cannot cancel the operation being presented. Only one request is processed at a time.

Ecash sends use CDK's persisted operation record. An unclaimed token can be reconstructed after restart. Reclaim asks the mint to revoke the saved send; an already-redeemed token cannot be reclaimed. Lightning reviews show the amount plus the prepared operation's fees and mint fee reserve. A response is called successful only when CDK reports the melt as paid. A timeout is presented as unresolved and requires reconciliation, rather than another payment attempt.

On unlock and every 30 seconds, each mint runs CDK recovery for incomplete operations, unissued mint quotes, pending melts, pending proofs, and spent-proof checks. Failed checks retain a retry status. Balances from an unreachable mint can be stale. Locally reserved/pending funds remain separate from spendable funds.

## Restoration

Full backups include operation history, pending state, known mints, counters, and the phrase. Imported copies are quarantined from spending until all their mints finish seed scanning and reconciliation. Scanning discovers recoverable outputs missing from an older backup; spent-proof checks remove stale saved balance. A phrase restore starts from known mint URLs and the same deterministic seed, also requiring reconciliation before spending.

Cashu recovery is mint-dependent. A phrase alone does not recover the mint list, full transaction history, BIP39 passphrases used elsewhere, arbitrary imported secrets, or every pending Lightning operation. Funds at an unavailable or dishonest mint are not guaranteed recoverable. Do not operate multiple restored copies of the same seed concurrently. Losing an encrypted backup's password requires a separately recorded phrase and mint URLs; Chaumarchy has no password-reset service.

## Current limits

Tests cover controlled fake payments and selected interruptions. Real Lightning routing, Cashu.me interoperability, physical camera input, all network-failure phases, malformed mint responses, long-term recovery workloads, and broad Omarchy-version compatibility remain release gates. The installed Omarchy component API is not a stable cross-distribution interface. Resource measurements belong to this installation, not a general performance guarantee.
