# Chaumarchy motion

Reference: [Emil Kowalski’s design and animation skills](https://github.com/emilkowalski/skills), read on 2026-09-09. Implementation uses native QML and the installed Omarchy controls; no motion runtime or web dependencies.

## Review and decisions

| Before | After | Why |
| --- | --- | --- |
| Panel maps/unmaps abruptly | 200 ms entrance, 125 ms exit, opacity + scale 0.97 → 1, origin from the clicked bar icon | Spatial continuity for occasional pointer use |
| Button color feedback only | Passive press observation, scale 0.98, 100 ms press / 160 ms release | Immediate tactile feedback; existing Omarchy click, focus and color behavior remains authoritative |
| Onboarding mark takes 1100 ms with all rings together | 250 ms per ring, 50 ms stagger, short transform offset | First-use delight with no interaction delay |
| Success checkmark appears abruptly | 250 ms opacity + scale 0.95 → 1, once per completion | Acknowledges confirmed success without animating the amount |
| Amounts snap to new values | `AnimatedAmount`: each digit is a clipped 0…9,0 wheel that rolls the short way in the direction the number moved over 600 ms, a new place fades in and rolls up from zero, surviving columns slide over; prefix and suffix marks stay put | Typing on the amount page and a balance change after a refresh read as one continuous number rather than a flash |
| No motion preference | Settings → Reduce motion, persisted independently of wallet keys | Removes translation/scale; keeps a gentle 125 ms fade; digit wheels snap |
| Expand tooltip binds to a signal | Uses native Omarchy tooltipText | Correct hover behavior and consistent styling |

## Frequency and function gates

- Bar opening is occasional pointer interaction: short, reversible motion. CLI `show`/`expand`, Escape, and keyboard navigation are immediate. Window expansion transfers the same live form tree; the compositor owns window placement and its animation.
- Tabs, history rows, keyboard activation, balance updates, amounts, invoices, QR codes and recovery words do not gain decorative entrance animations. Stable financial data and quick navigation take priority.
- No bouncing, list stagger, infinite loading shimmer, blur filters, layout-size animation, snapshots of wallet contents, or delayed payment actions.
- Onboarding has a one-time stagger. The success mark animates only after confirmed backend completion, not when starting a request or creating an invoice.

## Implementation contract

`ui/Motion.js` is the shared duration/curve vocabulary. The ease-out is exactly `cubic-bezier(0.23, 1, 0.32, 1)`, expressed as a Qt Bezier segment. `Behavior` retargets the panel from its current opacity, with the scale derived from the same progress. The layer remains mapped for visual exit but gives up its keyboard focus and input region immediately. Desktop lock hides it immediately, bypassing visual exit. Explicit rapid toggles are not debounced; only the duplicate event from an outside-click focus-grab dismissal is suppressed.

`MotionButton` passively observes pointer presses without emitting actions or taking the native button’s exclusive grab. Keyboard activation does not trigger compression. Reduced motion leaves native color feedback intact.

Preferences live in `$XDG_CONFIG_HOME/chaumarchy/appearance.ini` (normally `~/.config/chaumarchy/appearance.ini`). `CHAUMARCHY_REDUCED_MOTION=1` forces reduced motion. This is an app preference, not an automatic reading of compositor animation settings.

## Validation and feel checks

The isolated Wayland smoke test exercises interrupted open/close, reopening, settled unmapping, immediate dismissal, reduced scale, and panel/window transfer. The native wallet regression test covers actual create/send/receive/lock flows through the new controls. Test wallets and preference directories are isolated.

Feel-check the bar toggle rapidly, click outside during entry, and open Settings → Reduce motion. Check press/release, onboarding, and confirmed success at normal speed; numerical timing checks do not prove subjective elegance or guarantee a frame rate. The settled screenshot verifies layout, not animation smoothness.
