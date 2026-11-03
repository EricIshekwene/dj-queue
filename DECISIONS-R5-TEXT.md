# Round 5: suggestions for the text on the video (decisions)

Eric found that the editor's agent suggestions applied to the Title, and said suggestions for the Text on the video are what matter.

1. **Title and Text stay separate fields.** Why: 25 of Eric's 63 clips already have Text that differs from the Title, mostly the song names split over lines and once a hook. The Title is one clean line that names the clip on every screen and in search; merging would put line breaks and hooks into every list.
2. **Text suggestions get their own table (`text_suggestions`, schema v4), shaped like `title_suggestions`.** Why: additive and lossless (no table rebuild to widen a UNIQUE constraint); the two lists sync and replace independently.
3. **`djq suggest`, `videos.json` and `djq video --json` carry `text_suggestions` next to `title_suggestions`; a bare array is still title suggestions.** Why: old answers and tools keep working.
4. **The Ask-an-agent prompt asks for both lists: a one-line title, and the text on the video (songs laid out on lines, an optional hook as a lower-confidence extra).** Why: one agent run fills both sections. Text suggestions don't change "needs title help".
5. **The editor's Text section shows the chips under the text box; a tap sets that version's text (it stops following the Title); the chosen chip has a check.** With none, a quiet "No text suggestions yet" row with Ask an agent. The Title section's label becomes "Title suggestions". Why: the chips sit next to what they change, so it's clear which field they fill.
6. **The text box grows to the text's lines (2–5).** Why: a three-line layout was cut off after two lines.
