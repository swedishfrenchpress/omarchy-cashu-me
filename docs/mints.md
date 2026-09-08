# Suggested mints

The project owner selected these four mints for onboarding. The machine-readable catalog is [suggested-mints.json](../data/suggested-mints.json). Listing a mint does not automatically add or trust it in a wallet.

| Display name | Cashu base URL | Identity reported by the mint |
| --- | --- | --- |
| Minibits | `https://mint.minibits.cash/Bitcoin` | Minibits mint |
| Chorus OFF Mint | `https://mint.chorus.community` | Chorus OFF Mint; description identifies the Oslo Freedom Forum 2024 |
| Antifiat | `https://antifiat.cash` | antifiat mint |
| Macadamia | `https://mint.macadamia.cash` | macadamia Mint; description identifies the default mint for macadamia Wallet |

## Verification

On 2026-09-08, read-only HTTPS GET requests to each mint's `/v1/info` endpoint succeeded. All four advertised BOLT11 minting and melting in `sat`, with neither operation disabled, and NUT-09 restoration support. No invoices were created and no funds were sent.

Primary sources: [Minibits metadata](https://mint.minibits.cash/Bitcoin/v1/info), [Chorus metadata](https://mint.chorus.community/v1/info), [Antifiat metadata](https://antifiat.cash/v1/info), [Macadamia metadata](https://mint.macadamia.cash/v1/info). These are self-reported mint capabilities, not a solvency audit or a successful payment test.

Preserve the capitalized `/Bitcoin` path for Minibits. Chorus also advertises USD and EUR; Chaumarchy's initial payment flows use sats. Read current capabilities, limits, and fees when adding a mint and preparing payments rather than treating this verification snapshot as live status.

## Onboarding behavior

Show these suggestions in the owner's requested order, plus an option to enter a custom mint URL. Show the selected mint's full URL and fetched information before the user explicitly adds it. Do not automatically add all four or silently switch an unavailable mint to a different one. The interface preview does not yet connect to or add mints.
