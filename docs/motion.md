# cashu.me motion

Reference: [Emil Kowalski’s design and animation skills](https://github.com/emilkowalski/skills), read on 2026-09-09. Implementation uses native QML and the installed Omarchy controls; no motion runtime or web dependencies.

## Review and decisions

| Before | After | Why |
| --- | --- | --- |
| Panel maps/unmaps abruptly | 200 ms entrance, 125 ms exit, opacity + scale 0.97 → 1, origin from the clicked bar icon | Spatial continuity for occasional pointer use |
| Button color feedback only | Passive press observation, scale 0.98, 100 ms press / 160 ms release | Immediate tactile feedback; existing Omarchy click, focus and color behavior remains authoritative |
| Onboarding mark: three rings, 250 ms each, 50 ms stagger | The reference wallet's ASCII terrain and onboarding chassis (see below) | The reference's onboarding, in Omarchy's own glyphs |
| Success checkmark appears abruptly | 250 ms opacity + scale 0.95 → 1, once per completion | Acknowledges confirmed success without animating the amount |
| Amounts snap to new values | `AnimatedAmount`: each digit is a clipped 0…9,0 wheel that rolls the short way in the direction the number moved over 600 ms, a new place fades in and rolls up from zero, surviving columns slide over; prefix and suffix marks stay put | Typing on the amount page and a balance change after a refresh read as one continuous number rather than a flash |
| No motion preference | `CASHU_ME_REDUCED_MOTION=1`; no in-app setting, as the reference wallet defers to the system | Removes translation/scale; keeps a gentle 125 ms fade; digit wheels snap |
| Expand tooltip binds to a signal | Uses native Omarchy tooltipText | Correct hover behavior and consistent styling |

## Onboarding

Onboarding is exempt from the restraint above, as it is in cashubtc/wallet, and nothing here is reused inside the wallet proper. The timings are the reference's:

| Element | Out | In |
| --- | --- | --- |
| Stage swap | opacity 1 → 0, 180 ms | scale 0.96 → 1, opacity 0 → 1, 280 ms, starting 100 ms after the exit begins |
| Step title and subhead | fade with the stage | y +10 → 0, 260 ms |
| Chassis container | never animates | never animates; labels change in place |
| ASCII field entrance (first launch) | — | 0.45 s after the title settles, opacity 0 → 1 over 0.9 s |
| Terrain ↔ vault morph | — | per-cell brightness lerp over 280 ms with the step swap |
| Pointer lens | release settle 0.6 s, no spring | press bloom 0.28 s with ~5% overshoot; 60 fps while pressed |
| Handoff | curtain erodes over 1 s, linear driver, level by level | curtain sweeps down over 0.45 s, gate flips at full cover, centre bloom at +0.48 s |

The field runs at 30 fps on wall-clock time (a pause never rewinds), pauses whenever the panel is hidden or the step does not show it, and costs about 10 ms a frame on the development machine, three of them terrain math. Reduced motion draws one still frame, snaps the morph, disables the lens, and skips the curtain: the gate flips at once. `CASHU_ME_ASCII_STATIC_TIME=2.5` freezes the field for captures. Blur is not used anywhere: the hidden seed phrase is masked and dimmed rather than blurred.

## Frequency and function gates

- Bar opening is occasional pointer interaction: short, reversible motion. CLI `show`/`expand`, Escape, and keyboard navigation are immediate. Window expansion transfers the same live form tree; the compositor owns window placement and its animation.
- Tabs, history rows, keyboard activation, balance updates, amounts, invoices, QR codes and recovery words do not gain decorative entrance animations. Stable financial data and quick navigation take priority.
- No bouncing, list stagger, infinite loading shimmer, blur filters, layout-size animation, snapshots of wallet contents, or delayed payment actions.
- Onboarding is the one exempt surface (above). The success mark animates only after confirmed backend completion, not when starting a request or creating an invoice.

## Implementation contract

`ui/Motion.js` is the shared duration/curve vocabulary. The ease-out is exactly `cubic-bezier(0.23, 1, 0.32, 1)`, expressed as a Qt Bezier segment. `Behavior` retargets the panel from its current opacity, with the scale derived from the same progress. The layer remains mapped for visual exit but gives up its keyboard focus and input region immediately. Desktop lock hides it immediately, bypassing visual exit. Explicit rapid toggles are not debounced; only the duplicate event from an outside-click focus-grab dismissal is suppressed.

`MotionButton` passively observes pointer presses without emitting actions or taking the native button’s exclusive grab. Keyboard activation does not trigger compression. Reduced motion leaves native color feedback intact.

`CASHU_ME_REDUCED_MOTION=1` asks for reduced motion. There is no in-app setting and no automatic reading of compositor animation settings.

## Validation and feel checks

The isolated Wayland smoke test exercises interrupted open/close, reopening, settled unmapping, immediate dismissal, reduced scale, and panel/window transfer. The native wallet regression test covers actual create/send/receive/lock flows through the new controls. Test wallets and preference directories are isolated.

Feel-check the bar toggle rapidly, click outside during entry, and run with `CASHU_ME_REDUCED_MOTION=1`. Check press/release, onboarding, and confirmed success at normal speed; numerical timing checks do not prove subjective elegance or guarantee a frame rate. The settled screenshot verifies layout, not animation smoothness.
