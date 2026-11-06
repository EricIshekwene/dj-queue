# Round 16: timed text overlays and the text look

Eric wants several texts on a clip, each with its own start and end like CapCut, and a colour and font per text, kept out of the way
behind Advanced because he won't use it often. This file covers the data, drawing and `djq` side, then the editor.

## Data

1. **No DB rewrite, no schema bump.** The first text stays in the existing `Version` fields. A real rewrite would break Title-follow
   (nil text = follows the Title) and `{text}`. `versions.json` is a JSON blob, so `moreText` and `textLook` are new optional keys.
2. **`hasText` keeps its meaning (the first text).** Captions, agent prompts and titles stay as they are. New `hasDrawnText` asks
   whether anything shows; only Health's "No text" reason reads it, so a clip with an empty first text and a timed extra isn't flagged.
3. **`moreText` carries forward as a whole list.** nil inherits, [] is explicitly none. Merging per item across versions would make
   a removed text come back from an earlier version.
4. **`textLook` carries the same way, and an empty `TextLook()` means "back to default".** Without an explicit empty value a later
   version couldn't reset a look set on an earlier one, and the first-text fields have no other place to say it.
5. **Neither key touches `defaulted`.** `pick` would add them to the set on every clip and change every resolved JSON, so the
   resolver uses a small `carried` that only records `inherited`, and only when a value really comes from an earlier version.
6. **The cap is 12 including the first text** (`TextLayers.maxCount`), enforced in `djq` and `TextLayers.adding`.
7. **Unknown values decode to the default rather than failing.** `TextLook` and `TextLayer` have tolerant decoders: a rollback or a
   later build's font name must not turn a clip into "Saved edit can't be read". A rolled-back build ignores the new keys, and drops
   them the next time it saves that version.
8. **Extras' fields aren't optional.** A `TextLayer` holds resolved style, size and position, because it has no default to follow.

## Look

9. **`normalized` is the one canonical form.** Drawing, keys and the edit hash all read it, and the resolver applies it. "#fff" and
   "#FFFFFF", 100 % opacity, zero tracking and `.standard` can't cause a re-render, and a look that changes nothing is nil.
10. **`tracking` is a share of the font size** (-0.1…0.5), not points, so spacing follows the size slider. The last letter's kern is
    left out of the line width, or the block would sit off centre.
11. **Opacity fades the whole text as one transparency layer**, emoji included. Fading each part would show the box through the glyphs.
12. **`accent` keeps the shadow's 75 % strength.** Only its colour changes, so a coloured shadow is as soft as the default.
13. **Curated fonts are enum cases with one face each** (`TextFont.postScriptName`), bold enough for the video. The test checks every
    one is on this Mac and draws differently from the default; a face missing elsewhere falls back to the system font.

## Rules

14. **One window rule, in `PreviewKeys.layerWindows`,** shared by the renderer and every preview (S1-R5). The first text's rule is
    unchanged: an extra that starts past the trim or is inverted isn't drawn, because a per-platform trim shouldn't turn a timed text
    into a whole-clip one.
15. **On a committed trim change an extra is pulled inside the trim** (`EditorLogic.clampLayer`), the first text's rule. Only
    per-platform trims leave it out. An inverted extra stays as it is: it isn't drawn, and a trim shouldn't make it appear.
16. **Cover (S1-R6):** `coverLayers` takes what shows at the cover frame, else the first text, so one text always looks as it did.
    An empty first text with nothing showing means no text on the cover.
17. **Promotion takes the next text with words,** look and window included, and writes the whole remaining list. A blank extra is
    skipped: `text = ""` would fall back to the Title. A promoted text with no start gets `textStart = 0` so the default "first
    seconds" can't apply, and one with no end gets `TextLayers.farEnd` when an end would otherwise carry over. An inverted window
    would have lost a late start, and the next trim commit would have made it a 0.3 s flash.
18. **Removing the only text is refused,** in `djq` and in `TextLayers.removing` (nil). "No text" is the way to say that.
19. **`TextLayers.updating` writes only what changed on the first text,** so moving it doesn't stop it following the Title. Changing
    its words turns No text off, the same as `djq text`. A window is written whole: setting only the start of a default 0-3 s
    window would drop its end.
20. **`textKey` keys the windows too once there are extras,** because then they decide what shows; for one text it stays pixels only.
    `layerKey` is pixels only, and equals `textKey` for a plain first text, so an overlay cache can hold both.

## Renderer

21. **`pipelineVersion` stays `render-3`.** New `HashInput` fields are nil and absent from the JSON when unused, so every existing
    edit hash holds. An extra's id isn't in the hash: it isn't output.
22. **`overlayGraph` with one window returns the old graph exactly.** The first label stays `[ov]` for that reason.
23. **The cover has its own stacked PNG for the ffmpeg fallback,** because the texts on the cover aren't the ones on the video.

## djq

24. **`overlay add` starts from the first text's look,** so a new text matches unless told otherwise. It takes no default position
    beyond that, and the agent guide says to give `--y`.
25. **`"default"` clears `--start`, `--end` and the look options.** The numeric range checks stay on everything else. The
    window is checked only when `--start` or `--end` is given, with no start counting as 0: a first text can hold an inverted
    window (it means the whole clip), and that mustn't block an unrelated edit.
26. **`overlays` in `djq video --json` is a new field**, and `moreText` / `textLook` also appear as stored. Nothing was renamed.
    A text is addressed by id first, then by number, because an id can be all digits.
27. **Overlay edits never send a clip to the Queue, but a Queue clip left with no text to show goes to Edit.** That's `djq text ""`
    since rounds 4 and 13, and Eric's rule is that nothing moves Edit → Queue. Refusing would make overlays stricter than the text
    field for no gain, so `djq overlay` keeps the behaviour and prints the move. This is the exception to S1-R10's "never changes".

## Proof

28. **Lossless:** every clip of a copy of the newest backup compared between a build of `main` and this branch: stored and resolved
    JSON, `textKey`, text window, overlay PNG hash, edit hash for all six platforms and validation issues are byte-identical.
29. **The render test can fail.** With the enable window forced to `between(t,0.000,99.000)`, 4 of the 6 `R16RenderTests` failed
    (10 expectations, among them "outside all windows" at 2.75 s); restored, all 47 R16 tests passed.
30. **The PNG golden runs only on the macOS build that recorded it.** System fonts change with macOS and the auto-update gate must
    not fail for that. The edit-hash and `textKey` goldens have no such dependency, so they always run.

## Editor

31. **`selectedTextRaw` is the one selection, read through `selectedText`.** The switcher, a timeline bar and the canvas all write it,
    and the getter falls back to the first text, so undo, another version or a delete can't leave a field editing nothing. A promoted
    text needs no special case: only the first text can be promoted out of, and the selection is on it.
32. **The first text keeps its own setters** (`setText`, `setVersionField`), so Title-follow and the Default markers work as before.
    The others go through `TextLayers.updating`, which also copies an inherited list into the version on its first edit.
33. **A switcher of number chips, not a select.** Twelve texts need to fit, one click beats a menu, and the tooltip says what each is.
34. **A new text is empty, with the keyboard in the field,** rather than a "New text" placeholder someone could post. The bar says
    "Empty text". It isn't drawn until it has words (S1-R7).
35. **A new text or a duplicate sharing the time of the one it copies goes 10 % lower.** On top of it neither could be read or picked.
    A duplicate goes straight after the original when there's room; when not, it stays on the same time, below.
36. **With No text on, Add and Duplicate are off, with the reason.** The field is off too, so a new text couldn't be typed into.
    The timeline shows the one "No text" bar: nothing else shows on the video, so nothing else is listed.
37. **Show from / to commit on ↩ and on blur,** so typing "1.5" doesn't land "1" first. A time that doesn't parse says so and writes nothing.
38. **A window is written whole for the first text too,** matching decision 19: setting one end of a default window would drop the other.
39. **Undo:** clicks (add, delete, swatch, font, drop on the canvas, typed time) are one step each. Drags, sliders and the colour
    panel coalesce like every other drag.
40. **Drags are an AppKit surface (`EditorDragSurface`), not `DragGesture`.** SwiftUI gestures and taps don't see events sent to a
    window, so a script could never drive them, and "verified in the real app" would have meant "called the model". The Crop dialog
    made the same choice. The filmstrip's scrub and `DSToggle` stay SwiftUI, so the script calls what they call and says so.
41. **`keepInsideTrim` skips an inverted first-text window.** It means the whole clip, and clamping would make it a 0.3 s flash.
42. **`textBars` shows an extra the trim leaves out as a sliver at the end,** so it can still be seen and picked up, instead of vanishing.

## Canvas and lists

43. **One image per text, in a 160 MB cache keyed by `layerKey`.** The key has no time in it, so moving a text in time draws nothing,
    and dragging or typing in one never redraws the rest (the script checks image identity). 160 MB holds a full clip of 12 at
    1080 wide with room for what's being typed.
44. **An edited text keeps its old image until the new one lands,** as the single overlay did.
45. **Block bounds are stored with the image,** because the Zones canvas reads them on every playhead tick while playing.
46. **Only the selected text dims when hidden in Zones.** Dimming all of them would show every text at once and hide what plays.
47. **Lists: one `CALayer` per text under one 30 Hz observer**, compared by key and window, so a SwiftUI update of a preview costs an
    equality check. `overlayMissing` is true when any text's image is gone, and `reloadOverlay` draws just those.
48. **The Crop dialog draws the cover's texts:** its still is the cover frame, so it follows S1-R6 through `AppModel.textOverlays`.

## Collapsible rows

49. **`EditorDisclosures` is a shared object,** because `EditorView` makes a new model each time the editor opens and the state must
    outlive it, and a static starts empty at launch, which is the rule. `scrollTarget`'s `didSet` opens the section, so every path that
    lands on one (mini-index, the to-fix chip, `writePlatformCaption`, scripts) opens it without knowing about rows.
50. **What's inside a closed section isn't built,** so a closed Cover loads no frames.
51. **The problem replaces the summary on a closed row,** as the first issue of that section. Closing can't hide one.

## Proof

52. **`DJQ_TEXT_LAYERS_SCRIPT`** drives the real window and `AppModel`. Which text shows at each time is decided by comparing the
    canvas and the exported frame with the text's own image, under its solid pixels: both must agree with the windows.
53. **On a locked Mac** the window server draws nothing, so the script says so and captures the view tree. The player is black there,
    but the texts are real, so the check still means what it says. The side-by-sides with real video need an unlocked screen.

## For the editor branch (done)

- Edit through `TextLayers.updating / adding / removing`; for "Duplicate" use `TextLayers.new(text:like:start:end:)`.
- `EditorModel.newVersion(copying:)` needs `TextLayers.copyAdvanced(into:from:)` in its older-version branch.
- On a committed trim, map the raw `versions[i].moreText` through `EditorLogic.clampLayer`, only where it's non-nil: the resolved
  list would turn inherited lists into frozen copies and nil into []. Widen the `where` in `EditorModel.keepInsideTrim`, which
  skips a version with no first-text timing.
- Promotion changes a text's id to `TextLayer.firstId`, so a selection on the promoted text must follow it.
- `EditorModel` line "if !r.hasText && !r.noText" and `EditorTimeline`'s `r.hasText` should become `hasDrawnText` or per-layer.
- `.look` on a layer is normalised when resolved; `TextLook.defaultColor(style)` and `defaultAccent(style)` give what a swatch shows
  with no custom colour. `TextLook.swatches`, `opacityRange` and `trackingRange` are the control limits.
- A talking clip defaults to No text, so a text added there stays hidden until No text is off.
