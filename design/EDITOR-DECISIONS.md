# Editor decisions (round 2, R2-EDITOR)

Eric delegated every decision for this round. Each line gives the call and a one-line reason. The binding spec is `design/DESIGN-v2.md` §7 (editor) and §8 (phone mocks). Where this file differs from it, the difference is listed under "Deviations".

## Layout
1. **The editor is a full-window takeover: a 52 pt header, the `bg.canvas` canvas, a floating timeline card at the bottom left, and a 340 pt floating inspector on the right (r.lg, e1, inset 12).** Why: DESIGN-v2 §7 and the Arcade reference. Every surface floats on the calm canvas.
2. **The canvas switch has three modes: Frame · Zones · Preview.** Why: the brief asks for a "Zones | Preview" switch, and DESIGN-v2 keeps Frame (crop on the dimmed source) as its own mode. Three short labels fit one capsule.
3. **The default canvas mode is Zones, and the last-used mode is remembered.** Why: Zones shows the real output with the text you can drag, which is what most edits need. Frame is one click away, and so is the inspector's "Edit on canvas".
4. **The inspector is one scrolling column (Title · Frame · Text · Caption · Cover · Platforms) with a sticky mini-index.** Sections that hold a validation problem get a warning dot in the index. Why: no tabs, so nothing missing is hidden (§7). The dot is how the index shows what needs work.
5. **The header holds ‹ Back · Title (click to rename) · ‹ › clip with "n of N" · the validation chip · save state · version picker `v1 ▾` · Done (the only primary).** The validation chip jumps to the first problem's section. Why: §7. Versions belong only in the editor.
6. **Kind (DJ vid / Talking) lives in the Title section.** Why: it's clip identity, and it changes the text default ("No text" for talking clips).

## Defaults vs Custom (#10)
7. **A field shows a "Custom" tag with ↺ only when it differs from the New clip default. A field that follows the default shows nothing.** Why: the brief says "else nothing". This overrides DESIGN-v2's tertiary "Default" tag and keeps the column quiet.
8. **Picking a value equal to the default clears the override** (aspect, cover text, and trim handles snapped back to the markers). Why: the clip should store only real changes, and the tag then disappears on its own.
9. **On v2+, a value carried forward from an earlier version shows "from v1" instead of a reset.** ↺ appears only when this version itself sets the field. Why: resetting an inherited value would do nothing.
10. **Resetting the crop says it will need confirming again.** Why: an unconfirmed crop makes the clip not ready (R2-CORE), so the consequence is spelled out.

## Title (#2/#3 revised)
11. **The Title section, top to bottom:** the current Title (or the raw tag with a "Raw tag" badge), suggestion chips (text + matched tracks + confidence in tertiary), a free text field, "Use raw tag", "Ask an agent", then Kind. Why: the brief's order. Choosing a title is the first job on a new clip.
12. **Suggestion chips are two-line capsules.** The chosen one shows a check plus `fill.selected`. Why: matched tracks and confidence need their own line to stay readable at 340 pt. DSSuggestionChip is one line, so this is a local variant.
13. **"Ask an agent" becomes a warning-tint callout above the chips when `AgentPrompts.needsTitleHelp`, and a ghost button otherwise.** It copies `AgentPrompts.titles(for:[id])` and confirms with a toast. Why: prominent only when the metadata can't answer.
14. **The title field commits on ↩, on blur, or with "Set".** Clearing it calls `setTitle(nil)`, which stores R2-CORE's tombstone. Why: a title change cascades to the overlay text, caption and YouTube title, so it should never commit per keystroke.
15. **The overlay text has no prefill and no derivation.** The Text field shows the resolved text (from the Title, per `defaults.textSource`) with the hint "Follows the Title". Why: north star #9.

## Trim (#5)
16. **The filmstrip shows the whole clip file.** The handles start on the markers (the resolved default trim). The grace seconds beyond the markers are a striped, dimmed "Grace" band the handles can be dragged into. Handles snap to the markers. Why: #5. Grace is visibly extendable, and snapping makes returning to the default exact.
17. **"Trim to markers" appears in the transport row and in the Frame section's Trim field when the trim is custom.** Why: the reset sits where you look while trimming.
18. **The trim handles stay yellow.** Why: DESIGN-v2 §7 locks "yellow trim handles". They're the one tool colour on the canvas.

## Safe zones (#4)
19. **The dead "Safe zones" toggle is gone.** Under the Zones canvas there are multi-select chips: None plus all six platforms. Each chip carries its overlay tint as a legend dot. Why: #4.
20. **The safe-zone selection is a view preference stored in UserDefaults per aspect.** It starts from `defaults.safeZonePlatforms` and is remembered across clips. It's not clip data. Why: the brief says remembered across videos and per-aspect, and where the UI covers the video doesn't depend on the clip.
21. **Each platform gets its own subtle, non-brand tint** (violet, teal, amber, green, pink, cyan at 24 % fill and an 85 % hairline) plus one name tag. The tags stack so they never overlap. Why: three platforms at once must stay distinguishable without brand colours.
22. **Card platforms cover nothing.** Threads shows a "Threads shows the whole video" note. X hatches the top and bottom it crops ("X crops tall clips to 4:5"). Why: the most useful truth about each card platform.
23. **The safe-zone chips live under the canvas only, not in the inspector's Platforms section.** That section shows a hint pointing there. Why: it's a view setting, so keeping it out of the clip's data column avoids implying it is saved on the clip.

## Platform preview (#8)
24. **Preview draws a generic phone mock per platform from `PlatformUI` geometry.** TikTok, Instagram Reels, Facebook Reels and YouTube Shorts get feed overlays. Threads and X get post cards. All content is real: `Captions.caption(for:)` with `PlatformUI.previewCaption` truncation, the YouTube title, the per-platform handle, the live player plus the overlay text PNG. Why: #8. There are no logos or brand colours (DESIGN-v2 §8).
25. **‹ › step through platforms, and the chips pick one.** "One | Compare 3" shows the current platform plus the next two side by side, and clicking a phone in Compare focuses it. Why: the brief asks for both stepping and a compare row.
26. **The sound line is "Original audio", or the Title's tracks when the clip has them.** The display name is "DJ Lovd". Why: real data only, never a guessed song.
27. **The phone-mock drawing was built by a leaf on `agent/r2-editor-mock`** (one file, `EditorPhoneMock.swift`, with a DEBUG gallery). Why: it's a self-contained drawing task, so it could be built in parallel and reviewed against the refs.

## Caption (#6)
28. **One labelled length line ("182 characters · from the template"), with the per-platform breakdown in its tooltip.** Warnings appear only at 90 % of a platform's limit or over: "Close to the X limit · 260/280" (no actions), or "Too long for X · 312/280" with **Drop hashtags for X** and **Write an X caption**. Why: #6 and #9 (nothing shortened silently).
29. **"Drop hashtags for X" writes `Captions.withoutHashtags` as X's own caption and confirms with a toast.** It is disabled, with the reason ("Still 290/280 without hashtags…"), when that wouldn't fix it. Why: disabled controls say why, and the action must actually fix the problem.
30. **"Write an X caption" seeds X's own caption from the current one and opens "Captions for one platform".** Why: you edit instead of starting from blank.
31. **The validation chip and the index dots recompute crop/text/length issues live from the in-memory edit.** Store issues cover the rest. Why: the chip must react while typing, not 300 ms after a save.
32. **Platform names are shown in full everywhere.** "YouTube" is used only in the tight chip rows; tooltips say "YouTube Shorts". Why: #6/#7, names not codes.

## Engineering
33. **Pure rules went into core `EditorLogic`** (override-equals-default, posting toggles, caption length level, grace zones), tested in `EditorLogicR2Tests`. Why: `swift test` covers them, and the app target has no tests.
34. **Snapshots run through `EditorSnapshot.run`** (`DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`), using a throwaway DB copy and a throwaway UserDefaults suite. The hook in `SnapshotRunner` is owned by R2-SCREENS. `DJQ_EDITOR_LIVE=<s>` opens the real editor with a live player for a window capture. Why: the editor can be verified without the rest of the app or the engine.
35. **Small local building blocks** (`EditorField`, `EditorCustomTag`, `EditorSectionView`, `EditorHint`, `EditorTintChip`, `EditorMiniIndex`, `Platform.editorZoneTint`/`editorShortName`) live in `Editor/` and are built from DS tokens and components. Why: DesignSystem/ belongs to R2-DS. These are candidates to promote.

## Deviations from DESIGN-v2
- **No "Default" tag on default fields** (the brief overrides it, see 7).
- **The mode is called "Zones" and the third is "Preview" (not "Safe zones" / "Phone").** Why: the brief's names, and they're shorter.
- **The safe-zone chips are multi-select under the canvas only** (DESIGN-v2 also lists them in the Platforms section, see 23).
- **The timeline is a floating card (r.lg, e1) rather than a full-width band.** Why: it matches the floating inspector and the Arcade reference.

## Review fixes (NEEDS_FIX round)
36. **The typed Title draft lives on the model and commits in `flush()`.** `flush()` runs on clip switch (⌘] / ‹ ›), Done / ⌘↩, ↩ and blur. Why: keyboard shortcuts and buttons don't blur the field, so the draft was being lost. `DJQ_EDITOR_SELFTEST=1` checks both paths.
37. **Clicking a value equal to what the field falls back to stores nil** (style, alignment, size, hashtag sets compared as a set, extra hashtags, caption template). DSSegmented skips assigning an unchanged value. Why: a no-op click must not create a "Custom" override.
38. **Clearing the Text field leaves an explicit empty text (`noText = false`) instead of refilling the Title.** "Follow the Title" (and ↺) is the explicit reset. Turning "No text" off goes back to following the default when nothing was typed. Why: deleting text must not look ignored.
39. **`load()` reads the store on the save queue, after any pending writes, and never on the main thread.** Snapshot mode stays synchronous. The canvas shows a spinner while loading. Why: the main thread no longer blocks on SQLite or on the save queue.
40. **The cover filmstrip regenerates when a trim drag ends, not on every tick.** Why: it was churning the CPU while dragging.
41. **[DS] Soft-disabled DSButton/DSIconButton read as dimmed and non-interactive to VoiceOver**, with the reason as the hint (`dsAccessibilityDisabled`). DSSlider gains `accessibilityName:`, and the Size slider passes "Text size". Why: accessibility. The changes are backward compatible.
