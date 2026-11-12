# Round 24 decisions: trim handles and timeline markers (2026-11-12)

Eric: the trim handles weren't sensitive enough, so shortening a clip was very hard; then: let me add markers in the
timeline, with a shortcut, and make anything I drag snap to them. Mobbin references: Vimeo, VEED and Magnific (zoom
−/+ and Fit at the right of the transport), Whatnot, Posh, Retro and Facebook (chevron handles inside the trim), Loom
(a time readout while trimming), Riverside (pins in the ruler).

- D1 Handles are drawn inside the trim (14 pt, chevron) with a grab area from 10 pt outside to 8 pt past the handle
  inside; on a short trim the inner part shrinks so the two never cover each other. Why: the old 11 pt handle sat
  outside the trim and was easy to miss.
- D2 A drag follows the pointer's movement from the press (it used to jump to the pointer, then snap). The snap no
  longer sticks: the handle lets go of a marker once the pointer is 8 pt past it.
- D3 ⌥ while dragging a trim handle = a tenth of the speed and no snapping; on the playhead and ruler ⌥ only turns
  snapping off. Text bars keep their snapping (not asked for; kept small).
- D4 Clicking or dragging a handle selects it; ← / → then move that edge by Eric's arrow step and ⇧ by one frame (the
  same mapping as the playhead), Esc or a click on the film lets it go, and the transport says which edge is selected.
- D5 Zoom: − / + buttons, = / - keys, a trackpad pinch; Fit shows the whole file and, at fit, the same button zooms to
  the trim. Sideways scrolling over the tracks pans, and an overview bar shows only while zoomed. A file whose trim is
  under a third of it opens zoomed on the trim with ~35 % room either side; other clips open on the whole file as
  before. Not remembered per clip.
- D6 M toggles a marker at the playhead (within half a frame it removes the one there); the flag button does the same.
  Markers are pins in a new time ruler: click to go there, drag to move. Each marker change is its own undo step.
- D7 Markers live in `Edit.marks` (absolute seconds in the clip file, sorted, JSON key `marks`, left out when empty), so
  no migration and no stored row changes. They aren't in `Renderer.HashInput`, so adding one never re-renders anything.
  An older build reading a clip ignores them (and drops them if it saves that clip's edit).
- D8 Trim handles, playhead clicks/drags, text bar edges and moves, and the per-platform trim lanes all snap to markers.
- D9 No `djq` command for markers yet: they're an editing aid with no effect on posts. Easy to add if an agent needs them.
