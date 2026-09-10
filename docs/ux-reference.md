# Cashu Wallet UX adaptation

Reference: [cashubtc/wallet](https://github.com/cashubtc/wallet), inspected at
`c2d0e06a04711a527651d42ea573d50c870292b7` on 2026-09-09.

Reviewed its [product principles](https://github.com/cashubtc/wallet/blob/main/docs/product/PRODUCT.md),
[confirmation/error contract](https://github.com/cashubtc/wallet/blob/main/docs/product/confirmation-and-error-consistency.md),
and [Android/iOS screenshots](https://github.com/cashubtc/wallet/tree/main/docs/screenshots).
The reference is MIT licensed, copyright 2026 cashubtc. This implementation
adapts interaction patterns in original QML; it does not bundle its mobile code,
artwork, screenshots, or platform styling.

| Reference pattern | cashu.me adaptation |
| --- | --- |
| Wallet / History / Mints tabs | Persistent native navigation on the three main pages; Ctrl+1/2/3 shortcuts. |
| Mint selector above balance | The wallet page shows the total balance across mints, as Cashu.me does; the Mints page lists each mint's balance and marks the mint used for new payments. Receive before Send. |
| Small recent activity section | Three recent rows and View all activity. Each row is a circled direction arrow, the payment type ("Lightning received", "Ecash sent", "Lightning paid") over its time or date, and the amount in the primary unit over its conversion. Incoming amounts are iOS system green; the mint and status live on the detail page. |
| History list and transaction detail | Text search, incoming/outgoing filters, and detail pages showing amount, fee, status, date, and mint. History spans every mint; the backend supplies the 100 most recent transactions across them. Dates use the Omarchy clock format from shell.json without the year; detail pages add its time part. |
| Payment-method chooser | Invoice entry plus Scan/Send ecash choices; separate Lightning/Ecash/Scan receive choices. Unsupported methods are not offered. |
| Amount-first flow | The amount is the only large thing on the page: no input box, no cursor, no helper copy. The page takes keyboard focus and the digits roll as you type (`ui/AnimatedAmount.qml`, after rareui's AnimatedCounter). Typing happens in whichever unit the balance shows; tapping the amount swaps it, and the exact sats always show beneath a fiat figure. Over-balance turns the amount red. The available balance sits above as a caption, tappable to cycle mints when there is more than one, and a single Send or Request button sits at the bottom. Desktop keyboard entry replaces a touch keypad. |
| Task-focused sheets | Focused native pages within the existing window. A back arrow sits at the top left; Scan and Settings are icons beside the expand control at the top right. Escape and Alt+Left also go back, and confirmation is guarded. No mobile drag gestures or glass styling. |
| Backup Wallet sheet | The recovery phrase is its own page (Settings → Backup & recovery → Recovery phrase), after cashu.me's Backup Wallet sheet: a key, a warning that the words are the only way back and that anyone who sees them can spend, and one "I understand, reveal my phrase" action. Revealed, the words are a numbered three-column grid, followed by the mint URLs a restore also needs, a copy action, and Hide. Leaving the page hides the phrase at once. |
| Precise payment review | The amount in the primary unit with its conversion, the mint by name, and the maximum fee only when it is above zero, plus a specific Pay invoice/Create token/Receive ecash/Reclaim ecash action. Cancel is the only way back; the header's back arrow is hidden. |
| QR-first pending screen | QR, amount, mint, expiry, copy action; full bearer text is collapsed. Saved tokens and invoices remain accessible in History. |
| Confirmed payment result | Dedicated result page for confirmed sends, receives, and reclaim. A displayed Lightning invoice becomes Payment received only when CDK reports it issued. |
| Mint list and discovery | Mint rows with balances and selection state; four user-selected suggestions, custom URLs, and QR URL entry with explicit trust/add. |
| Settings rows | Short index linking to Backup & recovery, Security, Mints, and Display. Password remains optional. |
| Tap balance to switch units | With a local currency enabled, every amount shows the primary unit large and the other small and muted. Tapping the home balance swaps which unit is primary, everywhere. Sats stay the actual amount everywhere; fiat is a display-only estimate, and a few sats show as "<$0.01". |
| BIP-177 bitcoin symbol | Settings → Display offers "₿21,000" instead of "21,000 sats" ([bips.dev/177](https://bips.dev/177/)), applied to every amount shown, not only the home balance. |

Omarchy owns fonts, spacing, colors, control borders, focus/hover states, and
corner radius. The user's animated welcome remains. No iOS/Android palette,
SF Symbols, rounded mobile capsules, or additional payment protocols are copied.

Validation uses the actual native form actions with a fake mint, plus temporary
screenshots and theme/lifecycle checks. Camera hardware, real-network fault
injection, and external-wallet interoperability remain separate release gates.
