# Round 25 — text boxes that keep the cursor (v0.17.1)

Eric: the text boxes "tweak out", especially when clicking to place the cursor or adding a new line.

What was wrong (reproduced by the hidden `text-fields` check before the fix):
- **Text on the video:** after any edit in the middle of the text (Return, or typing where you clicked), the cursor
  jumped to the end, so the next keys landed in the wrong place. The box was bound straight to the editor model, which
  redraws the whole editor on every key.
- **An emptied box:** Return or a space typed first brought the clip's Title back into the box, because text made only
  of spaces and new lines counted as "nothing typed".

Decisions:
- D1. `DSTextArea` (every multi-line box: Text, caption, a platform's caption, templates, notes, post sheets) owns its
  text while you type and hands each change on; a change from anywhere else (⌘Z, Reset, another clip or version)
  replaces what it shows. Why: one fix in the shared component covers every box, the same rule the caption field
  already followed (round 7).
- D2. Blank typed text stays as typed. A box you emptied keeps its empty lines or spaces and never fills itself with the
  Title; "Follow the Title" and Reset still bring the Title back. Blank text draws nothing and counts as no text, as
  before. Why: the box must never change what you're typing.
- D3. No look change. Mobbin references (Buffer's Create Post composer, Base44's Edit post dialog) keep the caret where
  you put it and grow the box downward without moving the page, which is what the checks now hold DJ Queue to.

Check: `scripts/live-checks.sh <dir> text-fields text-fields-dark` clicks mid-line, presses Return at the end, in the
middle and in an emptied box, and types where it clicked, in the Text box, the caption and a bare text area, sampling
the caret, the box height, its scroll and its place on the page every 8 ms.
