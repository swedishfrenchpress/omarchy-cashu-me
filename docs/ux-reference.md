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
| Small recent activity section | Three recent rows and View all activity. Each row is a direction arrow on a square tile with Omarchy's corner radius, the payment type ("Lightning received", "Ecash sent", "Lightning paid") over its time or date, and the amount in the primary unit over its conversion. Incoming amounts are iOS system green; the mint and status live on the detail page. |
| History list and transaction detail | Text search, incoming/outgoing filters, and detail pages showing amount, fee, status, date, and mint. History spans every mint; the backend supplies the 100 most recent transactions across them. Dates use the Omarchy clock format from shell.json without the year; detail pages add its time part. |
| Payment-method chooser | Send: the reference's "Address, invoice, or Cashu Request" field with a paste button, then Scan and Ecash rows with icons. Receive: "Paste a Cashu token" with a paste button (and auto-paste when Privacy allows), then Scan and Lightning rows. The reference's "Create an ecash request" row is not offered because it needs a Nostr transport. |
| Amount-first flow | The amount is the only large thing on the page: no input box, no cursor, no helper copy. The page takes keyboard focus and the digits roll as you type (`ui/AnimatedAmount.qml`, after rareui's AnimatedCounter). Typing happens in whichever unit the balance shows; tapping the amount swaps it, and the exact sats always show beneath a fiat figure. Over-balance turns the amount red. The available balance sits above as a caption, tappable to cycle mints when there is more than one, and a single Send or Request button sits at the bottom. Desktop keyboard entry replaces a touch keypad. |
| Task-focused sheets | Focused native pages within the existing window. The top-left icon is Settings on the three main pages and Back everywhere else, as in the reference toolbar; Scan sits beside the expand control at the top right, and there is no wordmark. Escape and Alt+Left also go back, and confirmation is guarded. No mobile drag gestures or glass styling. |
| Backup Wallet sheet | Settings → Backup & Restore → Backup seed phrase is its own page: a key, the reference's warning copy, and one "Reveal Recovery Phrase" action, which asks for the wallet password first while App Lock is on. Revealed, the words are a numbered three-column grid, followed by the mint URLs a restore also needs, "Copy Recovery Phrase", and Hide. Leaving the page hides the phrase at once. |
| Restore (words → mints → results) | The same three steps, as pages: the words in one field with a paste action and a live word count, then the mints to recover from with Add and Paste, then each mint's result with a recovered total, Retry on failure, and a forward-only Continue. From Settings it replaces the current wallet after an Omarchy confirm dialog; from onboarding it installs a new one. |
| App Lock toggle | One "Require a password" toggle in place of "Require Face ID". Turning it on reveals a new-password form on the page; turning it off asks for the current password. |
| Lightning address | Enable toggle, the address row with a status glyph and "Connected" / "Connecting" / "Needs attention", Copy address as a visible button in place of the long-press menu, Auto-claim and Receiving mint under Preferences, and Check for payments with its last-checked caption, disabled with the reference's footer when incoming checks are off in Privacy. |
| Locked Ecash | Intro, a KeyCard for the seed key (status, tap-to-copy key, Show QR, Reveal key), the "Quick lock to my key" toggle, Advanced keys (Generate, Import an nsec, the device-key list with "Device only · Used N times"), and a device-key page with Back up key, Name, and Remove Key behind a confirm dialog. "How locking works" is a row instead of a toolbar icon. The QR is the raw key, as the reference shows without a Nostr transport. |
| Privacy toggles | Check incoming invoices, Repeat checks on a timer, Check sent ecash, Paste ecash automatically, with the reference's captions and footer. WebSockets, payment requests, and crash reports are not offered: the first two are Nostr-backed and the wallet has no crash reporting. |
| Delete Wallet | The Danger row, confirmed with Omarchy's dialog using the reference's copy; the worker removes every wallet file and the app returns to onboarding. |
| Precise payment review | The amount in the primary unit with its conversion, the mint by name, and the maximum fee only when it is above zero, plus a specific Pay invoice/Create token/Receive ecash/Reclaim ecash action. Cancel is the only way back; the header's back arrow is hidden. |
| QR-first pending screen | QR, amount, expiry, label/value rows, then the copy action pinned to the bottom of the panel as a secondary button ("Copy Invoice" or "Copy"), as the reference lays it out; full bearer text is collapsed. Saved tokens and invoices remain accessible in History. |
| Confirmation toast | One ephemeral toast at the top centre in Omarchy popup chrome, 2.2 s then gone, for copies ("Copied recovery phrase", "Copied Lightning address", "Copied key"…) and a mint being added. Settings changes show no toast, as in the reference. Errors stay inline. |
| Confirmed payment result | Dedicated result page for confirmed sends, receives, and reclaim. A displayed Lightning invoice becomes Payment received only when CDK reports it issued. |
| Mint list and discovery | Mint rows with balances and selection state; four user-selected suggestions, custom URLs, and QR URL entry with explicit trust/add. |
| Settings rows | The reference's groups in order, minus Integrations: Display (Currency with its value, Use ₿ symbol), Backup & Security, Payments (Lightning, Locked Ecash), Privacy, About (two external links), Danger, and the "cashu.me · version" footer. Mints stay a tab. Pages, not sheets. |
| Currency picker | Off, then the same 26 currencies in the same order with flag, code and name and a checkmark on the active one; a BTC Price footer with "Updated Nm ago" and a refresh icon. A page rather than a sheet. |
| Tap balance to switch units | With a local currency enabled, every amount shows the primary unit large and the other small and muted. Tapping the home balance swaps which unit is primary, everywhere. Sats stay the actual amount everywhere; fiat is a display-only estimate, and a few sats show as "<$0.01". |
| BIP-177 bitcoin symbol | Settings → Display offers "₿21,000" instead of "21,000 sats" ([bips.dev/177](https://bips.dev/177/)), applied to every amount shown, not only the home balance. |

Omarchy owns fonts, spacing, colors, control borders, focus/hover states, and
corner radius. The user's animated welcome remains. No iOS/Android palette,
SF Symbols, rounded mobile capsules, or additional payment protocols are copied.

Validation uses the actual native form actions with a fake mint, plus temporary
screenshots and theme/lifecycle checks. Camera hardware, real-network fault
injection, and external-wallet interoperability remain separate release gates.
