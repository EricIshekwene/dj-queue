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

## Phase B — page pass and undo (F5 + F8)
26. **Every one-click data change is one journal entry (`BulkActions.record`).** It snapshots the touched clips, plus the whole plan (slots, weeks, posts) when the action can move it, plus the settings row when it changes settings, and records the batch only when something really changed. Why: the bulk journal already restored clips and the plan exactly, with conflict checks. Reusing it gives single actions the same safety ("changed since → skipped/refused") with no second undo system.
27. **`UndoHistory` (core, tested) decides what ⌘Z undoes: always the most recent entry, then the one before.** A toast's own Undo removes its entry wherever it is. Why: this fixes the round-2 bug. `lastBatchId` was set only by bulk batches, so ⌘Z after, say, "Post today" undid an older, unrelated bulk edit. Writes that aren't journaled (notes, the long-form URL, an engine backup) are not undoable and never shift the stack.
28. **The toast says what happened plus Undo ("Pinned to Thu 5 Nov · Undo"). After undoing, it says "Undone: <what>".** Why: Eric must see which change ⌘Z reverted.
29. **Confirm instead of (or before) Undo only for plan-wide or destructive actions:**
    - Rebuild week and Push plan, which ask inside AppModel, so ⌘K, ⋯ and buttons are all covered.
    - Editor › Delete vN.
    - Deleting caption templates or hashtag sets.
    - Rendering cleanup that deletes files.
    - Many-clip context-menu actions, through the existing bulk confirm sheet.

    Everything else gets Undo with no prompt. Why: asking on every click adds friction, and Undo is the calmer safety net (ChatGPT, Linear).
30. **The editor keeps its own history: a snapshot of edit + versions + title + kind before each change.** Changes less than 0.8 s apart (drags, sliders, typing a word) coalesce into one step. ⌘Z / ⇧⌘Z step through it and save. While a text field has focus, ⌘Z goes to the field's own typing undo. The app-level ⌘Z is off while the editor is open. Why: autosave every 300 ms made every reset, chip and trim permanent. Field-level undo is what an editor is expected to do.
31. **No `.help()` in the app. The lint fails on any `.help(` and on always-empty `.dsTooltip(nil)` / `.dsTooltip("")`.** The one exception is the menu-bar status item, where DSTooltip can't reach because it lives in the system menu bar. It uses a native help tag ("5 days of approved posts left · Something needs attention"), marked `// native-help-ok`. *(Review fix: an earlier global `NSInitialToolTipDelay` suppression was removed, because it also silenced the status item.)*
32. **Disabled native menu items carry their reason in the title ("Back to Queue — already posted on TikTok").** Why: macOS menus can't show hover tooltips.
33. **`DSBadge(help:)`, `DSChip(tooltip:)` and `DSChipOption.tooltip` let status chips explain themselves.** The clip card's "File missing · Relink" became "File missing", with a tooltip pointing to Health › Doctor. Why: it said "Relink" but couldn't be clicked.
34. **Eric's acceptance rule is enforced in code. Every icon-only `Button`/`Menu` needs a tooltip:**
    - `scripts/check-icon-tooltips.py` is a small Swift-aware parser of labels and modifier chains. `IconTooltipLintTests` runs it inside `swift test`, so a new offender fails the build check.
    - `DSIconButton`'s tooltip is required at compile time.
    - Grid-tile hover actions (`DSMediaActionStyle`) render the Label's own title as the tooltip (`dsTooltip(view:)`), so the most common icon-only case can't be unexplained even if a screen forgets it.
    - Why: the lint can't see a label style applied by a container, so the DS closes that gap itself.
35. **Tile overlay badges speak plainly: "Score 28", "Length 2:23", "Number 3 in the posting order", "Select for bulk actions · ⌘-click".** Why: Eric's Edit-grid example. Each badge says what the number is.
36. **Page-pass evidence comes from the real window, not mock-ups (`DJQ_TOOLTIP_PASS=1`).** Each screen, view mode and overlay is drawn in light and dark, with the first tile in its hover state (`DSClipCardDebug.hoverIds`). Every tooltip anchor is numbered from the live view tree, with a legend of what it says, and one real tooltip panel is shown. It runs in the background: no focus change, no cursor moves.
37. **Real-pointer hover was not exercised, because Eric was at the Mac** (HID idle 0–1 s every time it was checked). Proven:
    - Placement, flip and shift, the panel, light and dark, Esc, and the delay-group timing in the real window (`DJQ_TOOLTIP_PROBE`). The probe drives the same `hoverBegan`/`hoverEnded` that `.onHover` calls.
    - Every anchor's text (`DJQ_TOOLTIP_PASS`).

    Not proven: that SwiftUI's `.onHover` delivers enter/exit to those calls under a physical pointer. That is standard SwiftUI behaviour, but Eric's first hover is the real test.
38. **An editor session is ONE entry on the app's ⌘Z history ("Edits to <clip>").** When the editor opens, every clip it can reach is snapshotted (`BulkActions.begin`). When it closes, after the last write lands, the clips that changed are journaled (`commit`). In the editor, ⌘Z stays field-level. Why (review): before this, ⌘Z after closing the editor undid an older, unrelated action.
39. **Undos run on a serial queue (`UndoRunner`).** Why (review): two fast ⌘Z presses raced, the older one ran first and was skipped as "changed since", and the clip ended at an intermediate value. The test case is 10 → 50 → 60, then ⌘Z⌘Z → 10.
40. **Every tag on a card explains itself (`DSClipTag.tooltip`):**
    - Queue date/pin tag: "Next planned post day" / "Pinned to this day".
    - Edit "Cover": "Cover frame chosen in the editor".
    - Library state chips, long-form, missing file, Posts state and problem badges, and the editor crop badges.
