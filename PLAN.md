# Chaumarchy — project plan

Last updated: 2026-09-08

**Status: discovery and planning. This is a living planning record, not an approved implementation specification.**

## Goal

Build a lean, native desktop Cashu wallet for personal daily use on Omarchy. Reuse Omarchy's design as much as practical and follow theme changes while the wallet is open. Keep the interface minimal: balance, Send, Receive, History, and essential Settings.

## Confirmed decisions

| Area | Decision |
| --- | --- |
| Wallet engine | Cashu Development Kit (CDK), in Rust. The user selected CDK; Coco is no longer under consideration. |
| Desktop surface | Standalone native app window, not a shell panel or a browser wrapper. |
| UI direction | Qt/QML using Omarchy's design; the exact component reuse and backend bridge still require investigation. |
| Theme behavior | Follow Omarchy theme changes live, including relevant typography, spacing, and control styling. |
| Audience | Personal daily wallet first, hosted in a public repository. Broader distribution is not a first-release requirement. |
| Payments | Send and redeem Cashu tokens; create and pay Lightning invoices. BOLT11 is the initial invoice target. |
| Mints | Multiple mints, explicitly selected by the user; no automatic transfers between mints. |
| Protection | Password-encrypted wallet; unlock on launch and lock with the desktop. Exact encryption and lifecycle design remain open. |
| Recovery | Recovery phrase plus mint list, and an encrypted full backup file. |
| Local project | `~/Documents/github/cashu-wallet` |
| Project name | Chaumarchy. |
| GitHub | Public repository: `swedishfrenchpress/chaumarchy`, created by the user; publish planning before wallet implementation. |

Cashu.me is an interaction reference, not a requirement to replicate its complete feature set.

## Findings that shape the design

- The inspected machine runs Omarchy 4.0.2 with Quickshell and Qt 6. Omarchy has QML controls and shared color/style components, rather than only a color palette.
- The local shared kit is under `/usr/share/omarchy/shell/Ui` and `/usr/share/omarchy/shell/Commons`. These packaged files must not be edited by this project.
- Active theme files on this installation are under `~/.local/state/omarchy/current/theme`. Shell styling also supports a user override at `~/.config/omarchy/shell.toml`.
- The shell's color components load theme files at startup and receive runtime theme changes through IPC. Importing the components into a separate app will not alone establish live theme updates. Verify directory replacement, font changes, and user overrides in the integration design.
- CDK provides wallet and SQLite components and advertises deterministic recovery support. Its APIs and the chosen release must be inspected and pinned before implementation; no runtime-size or performance claims have been validated yet.
- Seed recovery and full backup restoration are distinct. Seed recovery relies on known mints and their recovery support; a phrase is not a complete history or pending-operation backup. Restoration must reconcile saved data against current mint state.
- CDK source inspected at commit `1368c131a8f65e08b008e752e0494f895606b17c` (workspace version 0.18.0): `cdk-sqlite` has a `sqlcipher` feature and accepts a database path plus password. It configures WAL, full synchronization, and memory-backed temporary storage. Verify encryption at runtime and failure with an incorrect key; passing a password alone must never be accepted as proof that SQLCipher is enabled.
- CDK documents calling `recover_incomplete_sagas()` after wallet construction for interrupted swap/send/receive/melt operations. Pending mint quotes require separate reconciliation through `mint_unissued_quotes()`. Recovery requires network access; an unavailable mint must not turn reserved funds into spendable funds.
- CDK default features include capabilities beyond this wallet. Plan to disable default features and explicitly enable the required wallet and encrypted SQLite features after resolving the release version.
- Quickshell supports a normal standalone `FloatingWindow` and managed child processes with stdin/stdout communication. A separate Quickshell window plus a Rust/CDK child process is the current architectural recommendation for directly reusing Omarchy's controls. This is not yet a validated integration or a committed implementation choice.

Sources: [CDK](https://github.com/cashubtc/cdk), [NUT-09 signature restoration](https://github.com/cashubtc/nuts/blob/main/09.md), [NUT-13 deterministic secrets](https://github.com/cashubtc/nuts/blob/main/13.md), and read-only inspection of the installed Omarchy shell.

## Open questions

Resolve these through source inspection where possible, and user discussion for product choices. Do not silently treat suggestions as approved requirements.

### Native architecture and desktop integration

- How should Qt/QML call CDK: an in-process Rust bridge or a private local backend process? Compare packaging, failure isolation, and implementation complexity.
- Can the Omarchy controls be reused directly in a standalone window, or should a minimal subset be adapted with appropriate license attribution? Determine dependency and update compatibility.
- Which theme notification or file-watching mechanism handles atomic theme replacement, fonts, overrides, and malformed or missing theme files reliably?
- Should closing the window exit completely, or keep pending-payment monitoring running? What happens to in-flight operations when the desktop locks?
- What measurable startup, idle CPU, memory, and installation-size targets define "lean" on this machine?

### Payment experience

- Agree on the home layout, mint selector, history details, keyboard navigation, and send/receive review screens.
- Choose QR input methods: paste/text, image import, screen capture, camera; decide whether animated QR support is required initially.
- Define onboarding and mint trust: initial mint selection, unfamiliar mints in received tokens, unsupported capabilities, and removing a mint with funds.
- Define fees, available versus reserved balance, pending token sharing, reclaim behavior, expired invoices, and uncertain payment outcomes.
- Confirm first-release boundaries for Lightning addresses, BOLT12, payment requests, on-chain transfers, P2PK, Tor, and protocol URL handling.

### Storage and recovery

- Inspect CDK's persisted operation state, transaction boundaries, counter tracking, and recovery behavior before choosing the storage integration.
- Choose reviewed encryption and password-derivation dependencies; specify protection of database journals, temporary files, exports, and secrets in memory.
- Define lock timing, password changes, forgotten-password recovery, backup password handling, and safe behavior during pending payments.
- Define the versioned full-backup contents and restore process, including stale backups, spent tokens, counters, pending operations, and history.
- Define supported phrase recovery and known-mint entry, and explain recovery limits without promising full recovery from the phrase alone.
- Set clipboard and notification behavior for bearer tokens, recovery phrases, balances, and other sensitive data.

### Repository and release

- Preserve the license supplied in the user's repository and check attribution requirements when reusing upstream components.
- Choose the build and local installation approach after the native architecture is settled.
- Agree on the validation gate before real funds are used and what requires manual verification.

## Proposed implementation milestones

These are sequencing proposals. Detailed acceptance criteria and GitHub Issues follow after the open decisions are settled.

1. **Finish the specification.** Inspect CDK and Qt integration, agree on user flows and security/recovery behavior, and commit a decision-complete implementation plan.
2. **Native interface and theme integration.** Build the minimal window with synthetic wallet data. Demonstrate theme changes without losing form state, usable keyboard navigation, and the agreed resource targets.
3. **Encrypted wallet foundation.** Integrate CDK, persistent state, explicit mint selection, unlocking, and single-instance behavior. Validate persistence and desktop lock behavior.
4. **Payments and history.** Implement token and BOLT11 flows against a controlled test mint. Verify fees, reservation, reconciliation, and history through failures and restarts.
5. **Backup and recovery.** Implement encrypted full export/import and phrase-plus-mint recovery. Verify stale backups, wrong passwords, corruption, and interruption without overwriting a working wallet.
6. **Daily-use readiness.** Complete fault testing, Cashu.me interoperability checks, local installation, and user documentation before the agreed real-funds validation.

## Validation scenarios to preserve

- Sending and receiving tokens; duplicate imports and already-spent tokens; insufficient funds and unfamiliar mints.
- Lightning invoices paid, expired, rejected, or left uncertain after a timeout; fees and returned change.
- App termination, network loss, desktop lock, and restart during every payment phase; prevent duplicate spending and false success states.
- Export and restore after payments; phrase recovery with known mints; corrupted or outdated backups and incorrect passwords.
- Rapid theme changes, light and dark themes, font scaling, missing theme files, and existing user overrides.
- No secrets or bearer tokens in logs, repository files, notifications, or unintended temporary files.

## Progress

- [x] Confirm personal-use audience and standalone native window.
- [x] Choose CDK and initial payment scope.
- [x] Choose explicit multiple-mint selection, wallet password, and both recovery methods.
- [x] Inspect the installed Omarchy theme and component structure.
- [x] Establish this planning record and repository scaffold.
- [ ] Finish CDK persistence, recovery, and native integration investigation.
- [ ] Resolve product and security questions with the user.
- [ ] Answer the current product questions: home layout, QR input methods, and behavior when closing the window.
- [ ] Agree on the complete implementation specification.
- [ ] Create milestone issues from the agreed specification.
- [ ] Implement and validate the wallet.

## Planning workflow

Update this file whenever a decision is agreed. Move resolved questions into confirmed decisions, refine milestone acceptance criteria, and commit the change with a descriptive message. Use GitHub Issues for actionable work once the specification is agreed. Keep wallet implementation separate from planning commits.

### Decision history

- **2026-09-08:** Selected standalone native UI, personal daily use, Cashu tokens plus Lightning invoices, explicit multiple-mint selection, password protection, and phrase plus full-file recovery.
- **2026-09-08:** User selected CDK instead of Coco and requested a public GitHub repository before implementation.
- **2026-09-08:** Authorized repository creation and recording the current plan; wallet implementation remains pending further planning.
- **2026-09-08:** User named the project Chaumarchy and created `swedishfrenchpress/chaumarchy`. Use that repository and preserve its initial commit and license; retain the requested local folder name `cashu-wallet`.
