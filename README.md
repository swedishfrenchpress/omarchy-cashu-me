# Chaumarchy

A minimal native Cashu wallet for Omarchy, planned around a Rust CDK backend and a Qt/QML interface that follows the desktop's theme.

**Status: planning. No wallet implementation exists yet.**

## Follow the project

[PLAN.md](PLAN.md) is the source of truth for confirmed decisions, open questions, milestones, and progress. Changes to the plan are committed here before implementation. Milestones will become GitHub Issues once their requirements are agreed.

The first version targets personal everyday use: send and receive Cashu tokens and Lightning invoices, view history, manage mints, and back up or restore the wallet.

## Development boundaries

Do not commit wallet databases, recovery phrases, bearer tokens, credentials, or backup files. Use synthetic fixtures for future tests. Wallet implementation begins after the outstanding planning decisions are resolved.

## References

- [Cashu](https://cashu.space/)
- [Cashu protocol specifications](https://github.com/cashubtc/nuts)
- [Cashu Development Kit](https://github.com/cashubtc/cdk)
- [Cashu.me — interaction reference](https://github.com/cashubtc/cashu.me)
- [Omarchy](https://omarchy.org/)

See [LICENSE](LICENSE) for the project license.
