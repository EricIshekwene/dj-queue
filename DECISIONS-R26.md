# Round 26 decisions: 32 texts on a clip, and a countdown text

Eric's quiz versions ("Can you DJ like me? / guess the next song") need a header, per question a question, a 3-2-1
countdown, the wrong options in red and the right one in green, and a closing text: 20 texts for three questions, past
the old cap of 12.

1. **The cap is 32** (`TextLayers.maxCount`). Eric asked for at least 24, or 32 for room. 32 fits a three-question quiz
   with plain 3-2-1 texts (20) with room, and a four-question one with countdowns (1 + 4 × 4 + 1 = 18).
2. **Nothing else assumed 12.** The renderer already takes one PNG input per text and chains one `overlay` per input;
   a 24-text render is now a real ffmpeg test (`R26RenderTests`). `djq overlay add`, its help line and the editor's Add
   text reason read `maxCount`. Bulk Apply defaults (text) clears the extras as one list and undo restores the list,
   whatever its length. The text switcher's number chips wrap (32 is five rows in the inspector). The timeline keeps
   four lanes, with more texts sharing the last one, as before; the trim-handles round owns the
   timeline.
3. **Found while checking: the editor canvas could drop texts past about 19.** Its image cache holds ~160 MB, about 19
   full-size text images, and the canvas was rebuilt from the cache after drawing, so drawing the 20th evicted an image
   still on screen. `refreshOverlay` now holds the on-screen and cached images before it draws. The hidden check adds
   texts up to 32 and asserts every one has its image, and toggles No text on 31 texts and asserts all come back.
   Memory: what's on the canvas is held (8 MB a text at 1080 wide), so a 32-text clip holds about 260 MB while open,
   and each countdown number is an image too (a quiz with three 3-counts: 26 images). 32 texts of 10-counts would be
   about 2.5 GB; nobody builds that, so there's no extra cap, but cropping the editor's text images to their bounds is
   the follow-up if it ever matters. An old picture shown while a text's new one draws is marked a placeholder and is
   never taken as the new key's image (review finding: a quick second edit could otherwise freeze the old pixels).
   List tiles: their overlay cache went from 64 MB to 256 MB (about 2 MB a 540-wide image), so 32-text tiles don't
   evict each other.
4. **A countdown is one text** (the optional ask, built because it fits the quiz). `--countdown N` (2–10) shows N, …, 1
   in equal steps of its window, one second each by default, ending at `--end`. Rendered by expanding into plain texts in
   `PreviewKeys.layerWindows`, the one window rule every preview and the renderer share, so preview == export. Inner
   step boundaries sit on the millisecond and each number ends 10 µs before the next (the filter graph prints such a
   time with six decimals), so at any frame rate a frame shows exactly one number.
5. **Words around the number with `{n}`.** An empty text, or one with no `{n}`, shows the number alone; `"Next song in
   {n}"` shows the words. Chosen over appending the number so the typed words can sit anywhere.
6. **Not on text 1, not on photo posts.** Text 1 is the Title-follow / `{text}` / YouTube-title text, and a countdown
   there would put "{n}" into captions. Removing text 1 never promotes a countdown. A photo has no time to count in.
7. **Editor control: Countdown · Off / 3 / 5 / 10** under the text field of any text after the first, like a camera's
   self-timer (Mobbin reference: Future Pro's Timer Off · 5s · 10s). Turning it on gives the text one second a number,
   ending where it ended; changing the count or turning it off keeps its window; the bar reads "3 · 2 · 1". A count set
   through `djq` that isn't one of those gets its own segment. `djq overlay set --countdown N` on a countdown keeps its
   window too, unless `--end` is given. Duplicate copies the countdown; Delete on text 1 says why when only countdowns
   follow it (one can't become text 1).
8. **Remove audio.** A photo video's countdown becomes a plain text with its first number when it turns back into a
   photo post (a photo has no time to count in, and the editor hides Countdown on photos).
9. **Edit hashes.** `countdown` is absent from stored JSON and from the render hash when nil: existing clips don't
   re-render and the golden hash tests are unchanged.

Not covered by a check: the step-to-step change while playing (the hidden checks seek, they don't play), which the
render test covers for the export.
Pre-existing: on the newest seed (r25 backup) 11 checks in `text-layers` fail on main as well as on this branch
(colour swatch default, end-grip drag, the version-inheritance block); they are about that seed's clips, not this round.

## v0.19.1: the hidden checks fit the newest seed

10. **Not a v0.18.0 regression.** On the 11-12 seed, `text-layers` failed 11–14 checks and the tooltip probe one, on
    v0.17.1 just the same. Every Edit clip in that seed already has a v2, none has a confirmed crop, and the first is a
    3-minute file (a point on the film strip is 0.18 s, more than the drags' tolerance). The checks now pick the
    shortest file, read version numbers from the clip, tap the swatch that is the style's default, and wait for typed
    keys to land; the tooltip probe counts the hovered Edit tile's fix button when no Edit clip is plain. Nothing in the
    app changed. text-layers 166/166 and tooltip pass, screen-guard clean.
