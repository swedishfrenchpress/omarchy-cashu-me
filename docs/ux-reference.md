# Cashu Wallet UX adaptation

Reference: [cashubtc/wallet](https://github.com/cashubtc/wallet), inspected at
`c2d0e06a04711a527651d42ea573d50c870292b7` on 2026-09-09.

Reviewed its [product principles](https://github.com/cashubtc/wallet/blob/main/docs/product/PRODUCT.md),
[confirmation/error contract](https://github.com/cashubtc/wallet/blob/main/docs/product/confirmation-and-error-consistency.md),
and [Android/iOS screenshots](https://github.com/cashubtc/wallet/tree/main/docs/screenshots).
The reference is MIT licensed, copyright 2026 cashubtc. This implementation
adapts interaction patterns in original QML; it does not bundle its mobile code,
artwork, screenshots, or platform styling.

| Reference pattern | Chaumarchy adaptation |
| --- | --- |
| Wallet / History / Mints tabs | Persistent native navigation on the three main pages; Ctrl+1/2/3 shortcuts. |
| Mint selector above balance | The wallet page shows the total balance across mints, as Cashu.me does; the Mints page lists each mint's balance and marks the mint used for new payments. Receive before Send. |
| Small recent activity section | Three recent rows and View all activity; direction, amount, and status remain explicit. |
| History list and transaction detail | Date grouping, text search, incoming/outgoing filters, and detail pages showing amount, fee, status, date, and mint. History spans every mint; the backend supplies the 100 most recent transactions across them. Dates use the Omarchy clock format from shell.json without the year; detail pages add its time part. |
| Payment-method chooser | Invoice entry plus Scan/Send ecash choices; separate Lightning/Ecash/Scan receive choices. Unsupported methods are not offered. |
| Amount-first flow | Large sats entry, mint selector, available balance, and a distinct review step. Desktop keyboard entry replaces a touch keypad. |
| Task-focused sheets | Focused native pages within the existing window. A back arrow sits at the top left; Scan and Settings are icons beside the expand control at the top right. Escape and Alt+Left also go back, and confirmation is guarded. No mobile drag gestures or glass styling. |
| Precise payment review | Mint, amount, maximum fees and total, plus a specific Pay invoice/Create token/Receive ecash/Reclaim ecash action. |
| QR-first pending screen | QR, amount, mint, expiry, copy action; full bearer text is collapsed. Saved tokens and invoices remain accessible in History. |
| Confirmed payment result | Dedicated result page for confirmed sends, receives, and reclaim. A displayed Lightning invoice becomes Payment received only when CDK reports it issued. |
| Mint list and discovery | Mint rows with balances and selection state; four user-selected suggestions, custom URLs, and QR URL entry with explicit trust/add. |
| Settings rows | Short index linking to Backup & recovery, Security, and Mints. Password remains optional. |

Omarchy owns fonts, spacing, colors, control borders, focus/hover states, and
corner radius. The user's animated welcome remains. No iOS/Android palette,
SF Symbols, rounded mobile capsules, or additional payment protocols are copied.

Validation uses the actual native form actions with a fake mint, plus temporary
screenshots and theme/lifecycle checks. Camera hardware, real-network fault
injection, and external-wallet interoperability remain separate release gates.
