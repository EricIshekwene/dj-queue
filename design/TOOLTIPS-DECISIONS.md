# Tooltip decisions (round 3, F5)

Eric delegated these calls. Each decision gives a one-line reason. The component lives in `Sources/DJQueueApp/DesignSystem/DSTooltip.swift`, with the pure rules in `Sources/DJQCore/TooltipLogic.swift` (tested in `TooltipLogicTests`). The page-by-page inventory is in `design/TOOLTIPS-AUDIT.md`. This file replaces DS-DECISIONS #17 ("tooltips are native `.help()`").

## Research
1. **Anatomy follows Base UI Tooltip (Provider → Root → Trigger → Positioner → Popup, Arrow optional) with shadcn styling (inverse `bg-primary`/`text-primary-foreground`, `rounded-md`, `text-xs`, `px-3 py-1.5`, fade + zoom-in, Kbd inside).** Why: these are the libraries Eric named, and they already shape every other DS component.
2. **Mobbin check (refs saved in `refs/tooltips/`, gitignored).**
   - Superhuman's command tooltip: a dark bubble with inline keycaps, 1–2 short lines. Adopted.
   - Docusign: a side tooltip with an arrow. The arrow is not adopted.
   - Kajabi and WRITER: disabled features that explain why. Adopted as the second line of the bubble.
   - X: a grey disabled button with no reason. The anti-pattern Eric hit.
   - Mobbin rarely captures hover states (ChatGPT, Linear and Figma searches returned no tooltip frames), so the ChatGPT/Linear details (no arrow, about 6 pt offset, about 500 ms delay, instant hand-off) come from the libraries above and from those products' public behaviour.

## Behaviour
3. **One delay group for the whole app: 500 ms to open, then instant hand-off for 400 ms (Base UI `Provider delay`/`timeout`; Radix uses 700/300).** Why: 500 ms is between Base UI's 600 and Radix's skip window. It is long enough not to flash while the pointer crosses a toolbar, and short enough for "what is this?" moments. The hand-off has no animation (Base UI `data-instant`).
4. **Closes on press, scroll, any key (Esc included), app switch, window move or resize, and a sheet opening. A pressed trigger stays closed until the pointer leaves it.** Why: Radix and Base UI behaviour. After a click the bubble would only cover the result. Any key closes it, not just Esc, because DJ Queue is keyboard-heavy (digits score, ↩ saves). Press, scroll and key also end the delay group, so the next tooltip waits the full delay.
5. **Scroll: closes, then whatever ends up under the pointer opens after the full delay once scrolling stops.**
6. **Nested triggers (a card tooltip around a button tooltip): the innermost wins. Leaving it falls back to the outer one (hover stack).** Why: Week cards and their platform icons both carry tooltips.
7. **Shows only while DJ Queue is the active app and the trigger's window has no sheet or modal over it.** Why: native macOS behaviour. A background window must not pop bubbles over other apps.

## Positioning (the round-2 failure)
8. **The popup is a borderless, non-activating, click-through `NSPanel` (one, reused) at `.popUpMenu` level. It is not an in-view overlay.** Why: round 2's overlay bubble was clipped by cards, scroll views and the sidebar, and sat under siblings (DS-DECISIONS #17). A separate window can't be clipped. It never takes focus (`canBecomeKey` false), ignores the mouse, joins all spaces and full screen, and is hidden from VoiceOver.
9. **Not a child window.** Why: it closes on any press or window move, so it never needs to follow a moving parent. A child window would also tie its ordering to one window, but tooltips appear over sheets, the menu bar popover and the main window alike.
10. **Geometry comes from an invisible AppKit anchor view behind the trigger.** Its screen rect is its own `bounds ∩ visibleRect`, because under SwiftUI an embedded view's `visibleRect` is the enclosing clip region (found in the live probe), so the intersection is needed.
11. **Hover comes from SwiftUI `.onHover`, not from an `NSTrackingArea`.** Why:
    - The live probe showed that `.inVisibleRect` tracking on an embedded view covers the whole scroll region.
    - Tracking areas ignore z-order, so a card under the in-window Settings modal would still fire.
    - SwiftUI hover respects z-order, clipping and in-window modals, and it fires on soft-disabled DS controls.
    - DS controls are never `.disabled`, they are "soft-disabled" (DS-DECISIONS #16), so disabled triggers keep their tooltip.
12. **Placement (Base UI Positioner): preferred side (default top), centre aligned, 6 pt offset.**
    - Flip to the opposite side, then to the other two sides, if the main axis doesn't fit.
    - Then shift along the cross axis and clamp.
    - The collision boundary is the trigger's window ∩ the screen's visible frame, inset 6 pt (Base UI collisionPadding 5). If the bubble can't fit in a tiny window, the boundary becomes the screen.
    - Why the window, not the screen: like a web app's viewport, the bubble stays inside the app. The toolbar's tooltips flip below instead of floating over the title bar or the menu bar.
13. **No arrow.** Why: ChatGPT and Linear have none, Base UI makes it optional, and with a 6 pt offset the bubble is unambiguous. An arrow would also need re-aiming after every shift.
14. **Width: natural up to 280 pt, then wrap. Label ≤ 3 lines, reason ≤ 4 lines** (`DSTooltipFit` layout measures it). Why: shadcn's `max-w-xs`-ish width. Long copy is a sign the label should change.

## Look
15. **Inverse bubble: near-black #0D0D0D with white text in light mode, #ECECEC with near-black text in dark mode. Radius `sm` (10). Caption 12 medium for the label, caption 12 at 72 % for the reason. Padding 10×6.** Why: DESIGN-v2 inverse tokens (`inverseSurface`/`inverseText`) and the shadcn `bg-primary` tooltip.
16. **Keycaps: one cap per key ("⇧⌘K" → ⇧ ⌘ K), micro 11 on 14 % white, radius 4** (`TooltipKeys.split`, shadcn `KbdGroup`). Why: it reads faster than a glued string, and it is the pattern used by Superhuman and shadcn.
17. **Shadow only in light mode (window shadow, `e2`-like). None in dark mode.** Why: DS rule "no shadows in dark".
18. **Motion: 120 ms ease-out fade plus a 4 pt slide away from the trigger. With Reduce Motion it fades only. A delay-group hand-off has no animation.** Why: DS motion tokens (`fast`, hover).

## API
19. **`.dsTooltip(_ label: String?, shortcut: String? = nil, disabledReason: String? = nil, side: .top, forceVisible: false)`.** A nil or empty label with no reason means no tooltip, so call sites can pass optionals. The round-2 spelling `.dsTooltip(_, shortcut:, edge:)` still compiles, so the 86 existing call sites upgraded with no screen edits.
20. **Disabled = label, then the reason on its own line, and no keycaps.** Why: Kajabi/WRITER pattern and DESIGN-v2 rule 6. The shortcut doesn't work while disabled, so showing it would mislead. With a reason and no label, the reason becomes the label.
21. **`DSIconButton(icon, tooltip:)`: the tooltip is non-optional (compile time) and asserted non-empty in debug. It is also the VoiceOver label.** `DSButton(title, tooltip:)`: the tooltip is optional because the title is the label.
    - Labelled buttons show "title + keycaps" when they have a `shortcut`, and "title + reason" when disabled.
    - A `DSButton` with an empty title asserts a tooltip in debug.
    - Why: icon-only controls must explain themselves (DESIGN-v2 rule 6). Labelled ones speak only when there is more to say.
22. **VoiceOver gets the same text as the trigger's accessibility hint ("label. reason"). The native `.help()` is not used.** Why: on macOS `.help()` also draws the system tooltip, so every control would show two bubbles. The hint gives VoiceOver the same information. Phase B replaces the remaining 51 `.help(…)` calls, then raises `NSInitialToolTipDelay`.
23. **`forceVisible` draws the bubble in place, hung off the trigger's edge, for the gallery and snapshots.** The real panel can't be captured by `cacheDisplay`.

## Evidence
24. **Gallery page "Tooltips" (`DSGalleryPage.tooltips`, `ds-08-tooltips-{light,dark}.png`)** shows the anatomy on four sides, the content variants, wrapping, the in-context toolbar, ⋯ and bulk bar, a collision demo drawn from the production `TooltipPlacement` output, and the behaviour and writing rules.
25. **Live probe (`DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1 DJQueueApp --snapshot <dir>`)** runs against the real main window on a throwaway copy of the dev DB.
    - It runs in the background: it never activates the app, never moves the user's cursor, and keeps its panel just above its own window.
    - It drives hover per case and captures the window server's composite of the main window plus the panel. Cases:
      - Toolbar at the window's top edge (flips below).
      - Delay-group hand-off (~110 ms including the probe's 80 ms poll, versus ~600 ms for a first open).
      - Esc closes and stays closed.
      - Sidebar status near the bottom-left.
      - Collapsed-sidebar row with keycaps.
      - Dark Week.
      - Window flush with the screen's top-right corner.
    - It writes `probe.json` with every frame and the inside-window/inside-screen checks.
    - Limitation: SwiftUI hover doesn't react to events posted to the app's own queue, so the probe forwards each synthetic move to the same hover entry points (`hoverBegan`/`hoverEnded`) that `.onHover` calls. A real-pointer pass happens in Phase B, when the machine is free.
