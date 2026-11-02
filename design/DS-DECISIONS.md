# Design-system decisions (round 2, R2-DS)

Eric was away and delegated every call. Each line gives the decision and a one-line reason. Tokens follow the locked `design/DESIGN-v2.md` §2. Where this file differs from DESIGN-v2, the difference is listed under "Deviations".

## Structure
1. **New folder `Sources/DJQueueApp/DesignSystem/`, exposed as `DS.color` / `DS.radius` / `DS.space` / `DS.type` / `DS.elevation` / `DS.motion` / `DS.size`.** These are lowercase extensions on the round-1 `enum DS`. Why: both systems compile side by side until the screens move over. Old `DS.Radius`, `DS.Font` and so on keep working.
2. **The tokens file is named `DSTokens.swift`, not `Tokens.swift`.** Why: SwiftPM rejects two files with the same name in one target (`Design/Tokens.swift` already exists).
3. **Every component has a `DS` prefix** (`DSButton`, `DSCard`, …). Why: no clashes with the round-1 `Card`, `Chip`, `EmptyState` and `KeyHint`.
4. **The gallery forces states through the `dsForcedState` environment value.** Why: hover, pressed and focused can then be rendered statically for snapshots, without test-only component APIs.
5. **Snapshot hook: one line in `SnapshotRunner.run`.** With `DJQ_SNAPSHOT_GALLERY=1`, `DSGallerySnapshot.run` runs instead. Why: it reuses the existing `--snapshot` launch path and needs no DB.
6. **The gallery renders with AppKit `cacheDisplay` at 1x by default.** `DJQ_SNAPSHOT_WINDOW=1` switches to window-server capture. Why: window capture returns a blank image when the display is asleep (Eric was away). `cacheDisplay` doesn't draw AVPlayer frames, so the PNGs show posters, not playing video.
7. **Gallery media is local only.** `DJQ_GALLERY_MEDIA=<folder>` supplies covers and a proxy. Without it, the gallery draws gradient placeholders. Why: the repo is public, so no footage or third-party images are committed.

## Tokens (from DESIGN-v2 §2)
8. **Colour names follow Eric's brief; the values are DESIGN-v2's.** Mapping: background=`bg.app`, sidebar=`bg.sidebar`, canvas=`bg.canvas`, surface/surfaceRaised=`surface.raised`, surfaceSunken=`surface.sunken`, hover=`fill.hover`, selected=`fill.selected`, border=`border.subtle`, borderStrong=`border.strong`, text*, primary/primaryText, accent, status colours plus `*Tint` (10 % light / 16 % dark), scrim.
9. **No platform colours.** `DSPlatformIcon` is an SF Symbol glyph (music.note, camera, person.2, play.rectangle, at, xmark) plus a state dot. Why: DESIGN-v2 §2.1, and no brand colours or logos in a public repo.
10. **Radii are xs 6 · sm 10 · md 12 · lg 16 · xl 20 · capsule.** Why: DESIGN-v2 §2.2 overrides the brief's "sm 8".
11. **Spacing is 2 · 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48**, named hair…xxxl. Why: DESIGN-v2 §2.3.
12. **Type: display 28 regular, title 20, headline 15, body 14, callout 13, caption 12, micro 11, score 22 rounded tabular, mono 12.** Added `stat` (28 semibold rounded) for big numbers in `DSStat`. Why: DESIGN-v2 has no token for a bold large number.
13. **Elevation: e0–e3. Shadow colours resolve to clear in dark mode.** Why: DESIGN-v2 §2.5 ("shadows on dark read as dirt").
14. **Motion: hover 120 ms, layout spring 0.30/0.85, popover 150 ms, fade 200 ms.** Under Reduce Motion, every animation becomes a 200 ms fade and `dsMove` transitions become opacity only.

## Components
15. **All buttons are capsules**, sizes 28 / 34 / 40 (shadcn sm / default / lg). Variants are primary (near-black), secondary, outline (border.strong), ghost, destructive (soft red) and destructiveSolid (confirm sheets only). Why: DESIGN-v2 §1.2–1.3.
16. **A disabled control stays hoverable and explains why.** `disabledReason:` makes the control look disabled, blocks the action and shows the reason as a tooltip. Why: decision #6/#7 ("disabled says why"). A `.disabled` view doesn't reliably show tooltips.
17. ~~**Tooltips are native `.help()`.**~~ **Superseded in round 3 by `design/TOOLTIPS-DECISIONS.md`:** `DSTooltip` is a real hover bubble in a floating, click-through panel. It is positioned from the trigger's screen frame (Base UI flip + shift), so containers can't clip it. It has a delay group, keycaps and disabled reasons. `.dsTooltip` keeps its signature, so every call site upgraded automatically.
18. **Inputs use a surface.sunken fill, border.strong and r.sm. Search fields are capsules. The caption text area uses the composer look (surface.raised, r.lg).** Focus shows an accent ring. Why: DESIGN-v2 §1.3 and §7.
19. **Checkboxes are rounded squares in forms and 20 pt circles for selecting clips. Checked = accent.** Why: DESIGN-v2 §4.
20. **Selected card or tile = a 2 pt text.primary ring plus fill.selected**, not blue. Why: DESIGN-v2 §4. Blue stays reserved for toggle-on, focus, links and checked boxes.
21. **Select is native `Menu` behind a DS trigger.** Why: native keyboard, type-ahead and accessibility (DESIGN-v2 §1.8 says don't hand-roll replacements). Context menus stay native.
22. **The bulk bar is surface.raised (not inverse dark), 48 pt, e2**, laid out as ✕ · count · divider · ≤4 ghost actions · `trailing` slot for More ▾ and the primary capsule. Why: DESIGN-v2 §5 (Cosmos reference). My first draft used an inverse bar like Recraft. I replaced it.
23. **Attention card (`DSAttentionCard`; `DSBanner` is an alias) replaces the full-width red bar.** Why: DESIGN-v2 §3.
24. **`DSClipCard` is one component with four modes (`DSViewMode`: wide = "Cards", grid, single, list; toolbar order Cards · Grid · Single · List).** It is data-agnostic through `DSClip`. It never shows versions, hides platform icons when the list is empty, and a missing file gets a danger chip and no autoplay. Title suggestions are outlined chips (`onAcceptSuggestion`). Queue cards can show a drag handle. Why: DESIGN-v2 §4.
25. **Autoplay budget (`DSPlaybackBudget.shared`, max 4)**: the focused card (`isPriority`) wins, then the order of requests. A preview is "visible" from `onAppear`/`onDisappear` plus `onScrollVisibilityChange(0.3)`. Only one preview can be audible at a time, and nothing auto-unmutes. Note: "nearest to the viewport centre" is approximated by the visibility threshold plus request order. Screens can raise priority for the focused card.
26. **Single mode has a hover scrubber.** Seek uses the player's periodic time observer.

## Deviations from DESIGN-v2 (kept)
- **Segmented thumb is a capsule, not r.sm.** Why: a 10 pt-radius thumb inside a capsule track shows mismatched corners at the ends. Colours and fills match the spec (track surface.sunken, thumb fill.selected).
- **Secondary button variant kept** (surface.sunken fill). DESIGN-v2 only names primary/ghost/outline. Why: shadcn parity. Use it rarely.
- **Dialog title uses `headline` (15), not `title` (20).** Why: 20 pt overwhelms a 480 pt confirmation sheet. The settings modal's section title is also `headline` in DESIGN-v2.
- **Dark-mode hover equals surface.raised (#2F2F2F) per spec**, so a ghost-button hover on raised dark surfaces is invisible. `fillHover` (#383838) is used for secondary-button hover so pressed and hover stay visible. Screens should use `DS.color.selected` for hover on raised surfaces in dark mode if this matters.

## Reconciliation with R2-RESEARCH
- I built a first pass from my own Mobbin research (ChatGPT settings, dialogs, menus; Recraft/Higgsfield bulk bars; NotebookLM view toggle, saved in `refs/r2-ds/`). After DESIGN-v2 locked, I adopted its tokens exactly (decisions 8–14) and its component rules (15–25). Its references are copied locally to `refs/r2/` (gitignored).
