# Round 28 decisions: click an empty spot to let go

Eric: clicking an empty spot anywhere in the editor (the picture, the timeline, the inspector's background) should
deselect what's selected, so the editor never feels stuck.

## Why it felt stuck

1. **A clicked trim handle kept ← / →.** Since round 24 a clicked or dragged handle takes ← / → (they move the trim, not
   the playhead) until Esc or a click on the filmstrip. A click on the picture, the inspector, the header or the
   timeline's empty space didn't let it go, so the arrows kept nudging the trim after Eric had clearly moved on.
2. **A field kept the cursor after a click on the inspector.** Round 19 made a click on the picture or the timeline end
   typing; the inspector's background did nothing, so Space still typed into the Title or caption.
3. **The selected text kept its outline** on the picture and its highlighted bar on the timeline whatever was clicked:
   there was no way to see the clip without a selection on it.
4. **Markers have no selection** (M adds or removes the one at the playhead; a marker tick scrubs). Nothing there to let
   go of.

## What a press does now (`EditorClickRelease`, unit-tested in `R28ClickAwayTests`)

5. **Header, picture and timeline:** every press lets go of a selected trim handle, the text's outline and highlighted
   bar, and a field's or list's keyboard. Whatever the press lands on selects itself again straight after (the release
   runs first, in a mouse-down monitor), so a click on a handle, a text on the picture or a text bar just moves the
   selection there, and a press into a field keeps the cursor.
6. **The inspector:** a press on a control keeps the text selected and the cursor where it is, because its controls
   work on them (a style tile edits the selected text; New group remembers the caption being typed in so Cancel goes
   straight back to it). A press on its background (the margins beside, between and below the sections, and its
   headings and labels, which take no clicks) lets go of everything, like the picture. Any press there still lets go of a trim handle. The background is an AppKit
   backdrop behind the column, so "empty" means the press reached nothing else; a SwiftUI tap behind a scroll view
   never fired.
7. **Deselecting a text hides its selection, it doesn't unpick it.** The Text section always edits one text (its number
   chips stay as they were); only the outline on the picture, the faded copy of a hidden selected text and the bar's
   highlight go. Selecting a text anywhere shows them again; a new text shows them at once.
8. **Scrubbing the filmstrip lets go of the text too.** It's a press on the timeline like any other; the alternative
   (keep the outline while scrubbing) would make the filmstrip the one spot that doesn't let go.
9. **Clicking a button while typing still keeps the cursor** (standard on the Mac, and the caption group flow depends
   on it). Esc and any click on an empty spot end typing.

## Checks

10. **New hidden check `deselect`** (light and dark, `DeselectScript`): selects a text by its bar and lets go with a
    click beside the picture; selects it on the picture; selects the end handle, lets go on the picture and proves → then
    moves the playhead, not the trim; lets go of a handle, a text and the Title's cursor from the inspector's margin
    (and checks the press really lands on the backdrop) and that Space then plays; a control in the inspector keeps the
    text; the timeline card's corner and the header's empty space let go; a freshly clicked handle still nudges and Esc
    still lets it go. The editor-keys check now finds the picture's zone by name (the inspector's zone is taller).
