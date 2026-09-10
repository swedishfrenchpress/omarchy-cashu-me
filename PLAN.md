# cashu.me — project plan

Last updated: 2026-09-09

**Status: first working CDK wallet milestone implemented; controlled payment, recovery, and native lifecycle tests pass. Daily-use readiness remains in progress.**

## Goal and confirmed decisions

A lean, native Cashu wallet for personal use on Omarchy, with the desktop's controls and live theme. The primary UX reference is now cashubtc/wallet; its flows are adapted to Omarchy native controls within the existing payment scope.

| Area | Decision |
| --- | --- |
| Name and repository | cashu.me; `swedishfrenchpress/omarchy-cashu-me` (renamed from `chaumarchy` on 2026-09-10). Local checkout is `~/Documents/github/cashu.me`. Machine identifiers use `cashu-me`: crate, binary, launcher, data folder, plugin id, and the `CASHU_ME_` env prefix. |
| Engine | Rust CDK, selected by the user over Coco; pinned CDK and cdk-sqlite 0.18.0 with default features disabled. |
| Native interface | Compact Quickshell panel opened from a right-hand Omarchy bar icon, expandable into a window. Installed Omarchy Commons and Ui modules; private pipe to the Rust worker. |
| Appearance | Use Omarchy controls, typography, spacing, and colors; follow theme replacement without restarting the app. |
| Home | Selected mint, balance, Send/Receive, recent history, pending invoices/ecash, Settings. |
| Payments | Cashu tokens and BOLT11 Lightning invoices, in sats, with explicit review and confirmation. |
| Mints | Multiple explicit mints, separate balances, no automatic transfers. Minibits, Chorus OFF, Antifiat, Macadamia, and custom URLs. |
| Protection | Optional password under Settings → App Lock. New wallets start with a private device key and open automatically. Desktop lock stops the worker and clears sensitive views. |
| Window lifecycle | Closing keeps an unlocked wallet monitoring in the background. Lock stops it; unlock reconciles; Quit exits. |
| Recovery | Recovery phrase with mint URLs, plus encrypted full backup with a separate password. No overwrite during restore. |
| QR input | Paste, screen region, saved image, and webcam. Static QR generation; oversized tokens remain shareable as text. |

## Implemented and verified

- [x] Refine motion using Emil Kowalski’s guidance: interruptible panel entrance/exit, pointer press feedback, staggered intro, confirmed-success acknowledgment, and reduced motion.
- [x] Bar-first compact panel, outside-click dismissal, expand/return without recreating payment state, and persistent user plugin installation.
- [x] Establish the public repository and record planning before wallet implementation.
- [x] Reuse installed Omarchy controls without modifying packaged source.
- [x] Native preview and atomic dark/light theme replacement while hidden.
- [x] Encrypted CDK storage, wrong-password rejection, private file permissions, exclusive worker ownership.
- [x] Four suggested mint URLs verified through public metadata; explicit mint trust and capability checks.
- [x] Token send/receive, duplicate rejection, review cancellation, and insufficient-funds handling.
- [x] BOLT11 invoice creation/payment, maximum fee review, history, saved invoices, and QR generation.
- [x] Unclaimed token reopening and reclaim after worker crash/restart.
- [x] Recovery after termination while a send awaits confirmation.
- [x] Independently encrypted full backup, no overwrite, stale-backup reconciliation to current balance.
- [x] Phrase-plus-mint recovery to the current balance after prior payments.
- [x] QR image round trip through the actual decoder; screen and camera controls connected.
- [x] Native UI with real worker: hidden-window automatic receipt, payment review, phrase display, simulated desktop lock clearing, and password unlock.
- [x] Release build and local desktop installation mechanism.
- [x] Build/run/recovery documentation and reproducible test-mint instructions.
- [x] Settings → Display: BIP-177 bitcoin symbol (₿) applied to every shown amount, and an optional local currency with a periodically fetched best-effort exchange rate. Tapping the home balance cycles it between bitcoin and the selected currency; sats remain the only amount ever held or sent.

These checks use disposable wallets and a loopback CDK fake-payment mint. No real funds were used. See [docs/testing.md](docs/testing.md) for commands and test scope.

## Implementation choices

The inspected machine uses Omarchy 4.0.2. Shared QML modules are imported from `/usr/share/omarchy/shell`; the launcher prepares private cache symlinks. A parent-directory inotify watch catches atomic theme replacement. Shared components retain their font and shell override behavior.

SQLCipher contains CDK's state and versioned app metadata. Runtime encryption is checked before opening the CDK database. Full backups are published only after encrypted export, a persisted recovery requirement, and disk flushing. Restored wallets cannot spend until all known mints reconcile. Seed-only recovery does not promise full history or complete pending-operation recovery.

CDK's public prepared-operation APIs handle review, confirmation, and cancellation. Its persisted operation records provide restart recovery and pending token reconstruction. Background reconciliation checks unfinished operations, mint quotes, melts, pending proofs, and spent proofs. General shell IPC never carries wallet secrets.

See [docs/architecture.md](docs/architecture.md) for the detailed lifecycle and boundaries.

## Next milestone: daily-use readiness

The following work remains explicit; passing the first integration suite does not close these tasks.

- [ ] Interoperate with Cashu.me or another independent wallet.
- [ ] Inject network loss before and after mint commits, during Lightning payment, and during restore; verify replay and uncertain outcomes.
- [ ] Test real-world fees, expired/unsupported invoices, malformed responses, and multiple mints under failure.
- [ ] Manually validate screen-region, physical webcam, and clipboard behavior.
- [ ] Review keyboard/accessibility behavior, narrow windows, large histories, fonts, missing/malformed themes, and repeated changes.
- [ ] Record release startup, idle CPU, memory, and installed-size measurements; choose resource targets using those measurements.
- [ ] Review dependency advisories and fund-handling/recovery code independently.
- [ ] Complete the remaining checks before considering a real-funds validation.

## Deferred scope

Lightning addresses, BOLT12, on-chain transfers, animated QR, automatic cross-mint transfer, protocol URL registration, and broader Linux distribution packaging are not implemented. Mint removal and large-history navigation need product/retention decisions before adding destructive controls. These are scope boundaries for this milestone, not claims that the user rejected future support.

## Planning workflow

This file is the progress tracker. Keep its checkboxes, decisions, and next milestone current alongside commits; README describes the behavior available now. Detailed test evidence belongs in the tests and validation guide. GitHub Issues can be added when a separate issue board becomes useful.

### Decision history

- **2026-09-08:** Selected standalone native UI, personal daily use, Cashu tokens plus Lightning invoices, explicit multiple-mint selection, password protection, and phrase plus full-file recovery.
- **2026-09-08:** User selected CDK instead of Coco and requested a public GitHub repository before implementation.
- **2026-09-08:** Authorized repository creation and recording the current plan; wallet implementation remains pending further planning.
- **2026-09-08:** User named the project Chaumarchy and created `swedishfrenchpress/chaumarchy`. Use that repository and preserve its initial commit and license; retain the requested local folder name `cashu-wallet`.
- **2026-09-10:** User renamed the project to cashu.me everywhere. The repository became `swedishfrenchpress/omarchy-cashu-me`, the checkout `~/Documents/github/cashu.me`, and machine identifiers `cashu-me` (crate, binary, launcher, data folder, plugin id, `CASHU_ME_` env prefix). The on-disk `chaumarchy_meta` table and backup alias keep their names so existing wallets and backups still open, and a wallet folder created under the old name moves into place once on first start.
- **2026-09-08:** User selected recent history on home, all proposed QR input methods, and continued background monitoring when the window closes. Started the native interface milestone; payment and security questions remain open.
- **2026-09-08:** User confirmed locking with the desktop and requested Minibits, Chorus OFF Mint, Antifiat, and Macadamia as onboarding suggestions. Verified their public metadata and recorded the catalog; this does not add them to a live wallet.

- **2026-09-09:** User asked to continue building. Implemented the working CDK wallet milestone and controlled tests; retained daily-use validation as an open milestone.

- **2026-09-09:** User reported stalled setup and changed the onboarding requirement: a simple animated Omarchy-style introduction, with no password gate. Password protection is optional under Security. Device-mode wallets reopen automatically after desktop unlock; protected wallets require their password. Added actual UI-button and security-transition regression tests.

- **2026-09-09:** User selected `cashubtc/wallet` as the primary UX reference. Adapted its main navigation, payment choices, amount/review steps, QR layout, history/detail navigation, mint list, and settings hierarchy. Preserved Omarchy styling and the optional-password onboarding. Mapping and source revision are in `docs/ux-reference.md`.

- **2026-09-09:** User requested a display setting for the BIP-177 bitcoin symbol and an optional local currency, plus tap-to-cycle on the home balance, following cashubtc/wallet and cashu.me's UX. Added Settings → Display with both toggles; the currency list and its exchange rate are fetched with the same per-call timeout discipline as every other network call this worker makes, and are best-effort only — a failed fetch leaves the display in sats rather than surfacing a wallet error. Neither setting changes a mint's unit or any stored/sent amount.
- **2026-09-10:** Settings rebuilt after cashubtc/wallet's Settings, section for section, without Nostr: Display (26 currencies, price footer), Backup & Restore (seed page, three-step in-app restore that replaces the wallet), App Lock (a password), Lightning (npub.cash address through CDK's `npubcash` feature), Locked Ecash (seed key, device keys, lock on send, gate on receive), Privacy, About, Delete Wallet. Removed the custom settings not in the reference: encrypted file backup export/import, Reduce motion, Lock wallet, Quit, and the Mints row. Pages instead of sheets; Omarchy's confirm dialog for confirmations.
