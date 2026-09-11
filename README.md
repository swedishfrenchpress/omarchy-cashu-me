# cashu.me

A minimal native Cashu wallet for Omarchy. Rust and [CDK](https://github.com/cashubtc/cdk) handle ecash; Qt/QML reuses Omarchy's installed controls, colors, fonts, and spacing. Theme changes apply while the app runs, including while its window is hidden.

**Status: working development build, tested with a local fake-payment mint. Daily-use validation and external wallet interoperability remain in progress.**

## Build and launch

Targets Omarchy 4.0.2's Quickshell component kit. Requires Rust/Cargo, a C compiler, OpenSSL development files, Quickshell, and `inotifywait`. QR input additionally uses `zbarimg`, `zbarcam`, `grim`, and `slurp`; copying uses `wl-copy`. These tools are already present on the development machine.

```sh
cargo build --release --locked
./bin/install-desktop
cashu-me
```

The installer registers this checkout in your application launcher, creates `~/.local/bin/cashu-me`, and adds a wallet icon to the right-hand Omarchy bar. It backs up `shell.json` before adding the icon and preserves your existing layout. If `shell.json` is a symlink, as a dotfiles setup usually makes it, the bar step is skipped rather than replacing the link with a regular file, and the command to add the icon yourself is printed instead. Keep the checkout at its installed location. Rebuild the release binary after updating, then quit and reopen the app. Nothing is installed into Omarchy's packaged directories.

For development, `cargo build --locked` works when no release binary exists. `./bin/cashu-me --preview` opens a separate UI preview with wallet actions disabled.

```sh
cashu-me --status
cashu-me --quit
```

Click the wallet icon to open a compact panel on that monitor. Click outside, press Escape, or use × to hide it. Use ↗ to expand into a resizable window and ↙ to return to the panel; forms and payment reviews stay intact. Right-click the bar icon, or run `cashu-me --window`, to open the window directly. The icon persists across login; the wallet starts when first opened.

Closing the panel or window keeps the unlocked wallet monitoring payments every 30 seconds. Launch again to reopen it. Ctrl+Q exits the app. Desktop locking stops the worker too. Payments reconcile after reopening. Without a wallet password, opening and desktop unlock reopen the wallet automatically; protected wallets ask for their password. Monitoring requires the app to be running and unlocked; it does not continue through logout, suspend, or reboot.

Motion choices and validation are documented in [the motion guide](docs/motion.md); `CASHU_ME_REDUCED_MOTION=1` switches to gentle fades without movement.

Settings → **Display** offers the [BIP-177](https://bips.dev/177/) bitcoin symbol (₿21,000 instead of 21,000 sats) and an optional local currency. With a currency set, every amount shows both units, and tapping the home balance swaps which one is primary. Both are display only: every mint call, and every amount actually held or sent, stays in sats regardless of what is shown.

## Using the wallet

1. Start with the introduction and choose Create Wallet. Write down the seed phrase it shows, then pick your first mint from the suggestions, add your own URL, or skip. No password or account is required. Restore Wallet takes recovery words and mint URLs instead.
2. In Mints, Add mint takes a mint URL. With no mint yet, Add mint on the wallet page offers the known mints, Minibits, Chorus OFF Mint, Antifiat, and Macadamia; see [the verified mint catalog](docs/mints.md). Adding a mint means trusting its operator to redeem its ecash.
3. Receive by creating a BOLT11 Lightning invoice or redeeming a Cashu token. Paste tokens, scan a screen region, import a QR image, or use a webcam.
4. Send by pasting a BOLT11 invoice or choosing Send ecash and entering an amount. Review the mint, amount, and maximum fee/debit before confirmation.
5. Wallet shows your total balance across mints and recent payments. History provides filters, payment details, pending invoices, and unclaimed ecash. Mints lists each balance separately and marks the mint used for new payments. Dates follow the Omarchy clock format from `~/.config/omarchy/shell.json`, without the year. Reopen a token to share it again, or reclaim it if it remains unspent.

Balances stay separate by mint. A token from an unfamiliar mint requires explicitly adding that mint first. This version uses sats and static QR codes. Large tokens can be copied as text. Lightning addresses, BOLT12, on-chain transfers, animated QR, and automatic transfers between mints are outside this milestone.

Navigation and payment flows follow [cashubtc/wallet](https://github.com/cashubtc/wallet), adapted to Omarchy's native controls. See [the UX mapping](docs/ux-reference.md). Use Ctrl+1/2/3 for Wallet/History/Mints, Ctrl+, for Settings, and the back arrow, Escape, or Alt+Left to go back. Settings is the top-left icon on the main pages, where Back appears elsewhere; Scan sits beside the expand control at the top right. Payment confirmation remains explicit.

## Settings

Settings follow [cashubtc/wallet](https://github.com/cashubtc/wallet) section for section, without its Nostr integration: **Display** (currency and the ₿ symbol), **Backup & Restore**, **App Lock**, **Payments** (Lightning address and Locked Ecash), **Privacy**, **About**, and **Delete Wallet**. Every screen is a page rather than a sheet, and confirmations use Omarchy's own dialog.

**Lightning** turns on an npub.cash Lightning address, `<npub>@npubx.cash`, whose key is derived from the seed. Payments to it are minted as ecash at the receiving mint you choose, claimed automatically or with Check for payments. No Nostr relay is ever contacted.

**Locked Ecash** shows the key derived from your seed that others can lock ecash to, a Quick lock shortcut for the send page, and device-only keys you can generate or import as an nsec, name, back up, and remove. Sending can lock a token to any key; receiving signs with every key the wallet holds, and a token locked to a key you don't hold is refused before the mint is contacted.

**Privacy** decides which checks the wallet makes on its own: incoming invoices, repeating them on a timer, sent ecash, and reading a token from the clipboard when the receive page opens.

## App Lock

In Settings → App Lock, require a password whenever you want. With it on, the wallet asks for that password when opened and after desktop lock, and again before revealing the seed phrase or a private key. Turning it off asks for the current password.

Without a password, cashu.me keeps its database key in a private local file and opens automatically with your desktop session. Anyone able to access your desktop account can open the wallet. App Lock encrypts that key and removes the local unprotected copy.

## Backup and restore

Settings → Backup & Restore → Backup seed phrase opens a full page that explains what the words are worth before a single reveal action shows them as a numbered grid together with your mint URLs; the page hides them after one minute or as soon as you leave it. Record both privately. Phrase recovery scans known mints for recoverable unspent ecash; it does not restore full history or every pending operation. There is no BIP39 passphrase field in this version.

Settings → Backup & Restore → Restore walks through the words, the mints to recover from, and each mint's result, and replaces the current wallet after a confirmation; the same flow restores at first start. Settings → Delete Wallet removes the wallet from this device after a confirmation, so you can start fresh or restore another seed. Stop using the original wallet before restoring a copy.

Wallet data lives in `$XDG_DATA_HOME/cashu-me`, normally `~/.local/share/cashu-me`. `CASHU_ME_DATA_DIR` selects a separate wallet directory for testing or migration. Do not copy live SQLite files as a substitute for the export action.

See [architecture and recovery boundaries](docs/architecture.md) and [the validation guide](docs/testing.md).

## Follow development

[PLAN.md](PLAN.md) tracks decisions, completed checks, and remaining work. Source, tests, and planning live in [swedishfrenchpress/omarchy-cashu-me](https://github.com/swedishfrenchpress/omarchy-cashu-me).

Never commit wallet state, bearer tokens, passwords, recovery phrases, or backups. Tests use temporary wallets and fake payments.

## References

- [Cashu](https://cashu.space/) and [protocol specifications](https://github.com/cashubtc/nuts)
- [Cashu Development Kit](https://github.com/cashubtc/cdk), pinned to 0.18.0
- [Cashu Wallet](https://github.com/cashubtc/wallet), primary UX reference
- [Cashu.me](https://github.com/cashubtc/cashu.me), interoperability target
- [Omarchy](https://omarchy.org/), installed native component kit

cashu.me is MIT licensed; see [LICENSE](LICENSE). Upstream components retain their respective licenses. The launcher imports installed Omarchy modules; it does not redistribute their source.
