# Round 5 decisions: video-preview tooltips (v0.6.1)

Eric's report: hovering the round buttons on a video preview showed an empty tooltip bubble, and moving away flashed the text for a second. Details and cause: `design/TOOLTIPS-DECISIONS.md` #41.

1. **One plain-text tooltip path.** The view-based tooltip (`dsTooltip(view:)`, `richLabel`) is removed instead of repaired. Why: the bubble is drawn in its own panel, outside the trigger's view tree, so only values (strings) can cross safely; removing the API lets the compiler stop it coming back.
2. **`DSMediaActionButton` with a required tooltip** replaces raw `Button`s under a container label style. Why: the lint can't see a container's style, so the requirement lives in the type (review F2).
3. **Instant hand-off only to the trigger under the pointer.** Why: leaving a nested trigger handed the bubble to its parent before the parent's own exit arrived (the flash).
4. **The live probe is the visual check and it fails the run.** Every tooltip type on every page, light and dark, hover and after-leave, rendered-text pixels measured, a nested-trigger fixture, and coverage asserts. Proven both ways: on v0.6.0 it fails on exactly the preview buttons; with the hand-off guard removed, the nested case fails.
5. **Probe and page-pass windows are in front, click-through and non-activating.** Why: macOS doesn't draw a fully covered window's SwiftUI layers, so background captures came back blank. They never take focus or answer the user's pointer.
