# Decisions: round 32, the chosen sort wins on every list

Eric (2026-11-14): on the Queue, sort set to "Worst → best", the tiles read 44, 45, 58, 20, 44, 45, 55, 60, 62, 67, 17,
21. Fix it, check every other page's sort and filters, and make the chosen sort visibly win.

## The cause

1. **The Queue screen only sorted the clips still waiting.** Its list was the clips with a day on the Calendar, in date
   order, then the clips waiting for a day in `Settings.sort` order. Since round 31 every version post needs its own day,
   so nearly every clip has one (36 of 40 on a copy of Eric's data), and the sort reached almost nothing. All four
   layouts read the same list, so all four showed it.

## The fix

2. **Worst → best and Best → worst order every clip by score, with a day or not.** The screen uses the engine's own
   score order (`Queue.scoreOrder`, shared, so the screen and the planner can't drift): photos and photo + audio videos
   with no score first, then score, then the older set, part and start time. Search, filters and the status chips
   (Has a day · No day yet) only narrow that order; the sort wins inside each of them. The score choices still write
   Settings › Queue sort, which is the order clips get their days, as before.
3. **"Next post first" is a third choice, for the old view.** It shows posting order (the Calendar's days, then the
   clips waiting) and only changes what the screen shows, never the settings or the plan. It is remembered with the
   page's other list choices.
4. **Place numbers show only in Next post first.** They are each clip's place in the posting order; under a score order
   they would read as a jumbled count, and the date chip already says when each clip goes out.
5. **Everything that follows "the order shown" follows the sort.** ⌘A, ⇧-click ranges, the editor's ↑/↓ and
   "Pin to days…" (one a day in the order shown) all read the screen's order, so they follow the chosen sort.
6. **Dragging a card onto a clip with a day still takes that day** in any order; nothing else moves a clip. The ⋮⋮
   handle shows only in Next post first, where a drop changes the order you see; under a score order the drop changes
   the card's date chip and the card stays in its score place.
7. **"Move one place later" shows under a score order too.** A clip with no day that was moved later swaps with the
   clip after it on screen, exactly as the engine applies it (`Queue.applySkips`, shared).
8. **The Score dialog (⌘K › Score…) says which way scores post** from Settings › Queue sort; it used to say "Higher
   scores post sooner" even under Worst → best.

## The audit

9. **Score's "Set order" mixed sets together.** With more than one set left to score, its clips alternated between
   sets (ordered by part and start only) under All. Now it keeps each set together, newest set first like the set
   chips, then part and start.
10. **The rest apply their sort and filters.** Edit, Library and Score apply their sort menu to every layout
   (`listSorted`) after search, filters and status chips. Posts orders by date (newest or oldest) on every chip and
   groups a clip's posts of one day into one card in that order. Calendar's platform filter applies in every view (Day,
   3-day, Week, Month). ⌘K search ranks by match, with type chips that only narrow.
11. **The `list-sort` live check** reads the order each screen registers (the order ⌘A, ⇧-click and the editor's ↑/↓
   use) on the scratch copy of real data, and checks it on the Queue, Edit, Library, Score and Posts. Calendar and ⌘K
   have no sort to check; their filters are covered by the existing `post-at` and `search` checks.
