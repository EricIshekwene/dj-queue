# Round 40 decisions — the Score box is a real text field (v0.31.1)

Eric: the 0–100 score box "doesn't allow me to backspace or clear my entry like a normal textbox".

Cause: the box was a key-driven SwiftUI view, not a text field. Its `onKeyPress` matched SwiftUI's `.delete` (U+0008), but
the Mac's Backspace arrives as U+007F, so ⌫ did nothing; with no caret or selection there was no other way to fix a digit.

1. **A real AppKit text field (`ScoreTextField`), not a better fake.** Why: ⌫, ⌦, ⌘A, clicking the caret, ⌥/⌘ arrows
   and paste then work exactly as in every other Mac field, with nothing to re-implement.
2. **The screen's keys are routed by AppKit command (`ScoreFieldKeys`).** ↩ save & next, ⇥ / ⇧⇥ skip, ⌘⌫ exclude
   (`deleteToBeginningOfLine:`), esc empties the box. Why: commands survive keyboard remaps and are unit-tested in Core.
3. **← / → change clips only while the box is empty; with a number they move the caret.** Why: the spec asked for the
   caret first; an empty box is the moment Eric is browsing, and the hint line now says "previous/next when empty".
4. **Only 0–100 gets in; letters and spaces drop out quietly, 101 / a fourth digit beep.** Why: a pasted "72⏎" should be
   72; a number past 100 is a real mistake worth the system's beep.
5. **The box keeps no undo of its own; ⌘Z undoes the last save or exclude, as before.** ⌘A on an empty box selects
   clips, as before; with a number it selects the number. Why: ⌫ already takes digits back, and ⌘Z on Score has always
   meant "bring that clip back".
6. **No placeholder under the caret.** "0–100" shows only while the box doesn't have the cursor. Why: a centred
   placeholder sat right under a centred caret; the hint line says what to type.
7. **Same bug elsewhere:** Library's type-to-score now takes ⌫ for a digit that hasn't saved yet, and ⌘K's
   "⌫ in an empty filter goes back" matches both Backspace spellings (`KeyEquivalent.backspaceKeys`). Every other field
   (settings numbers, Score grid, text areas, the editor) was already a native field or skips while a field edits.
8. **Live check `score-field` (light + dark, hidden):** typing, ⌫, ⌦, caret arrows, a letter and 101 turned away,
   select all + ⌫, esc, empty-box arrows, ⇥ / ⇧⇥, ↩ saves 64→⌫→62, ⌘⌫ excludes, ⌘Z brings it back, Library 4⌫3.
   Stand-ins: select all is `selectAll:` sent to the field (no menu in a check); ⌘Z runs the background-window branch.
