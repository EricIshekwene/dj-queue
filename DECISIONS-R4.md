# Round 4 decisions

## Session A — tooltips, undo, v0.4.0 (2026-11-02)
1. The editor session's undo entry covers only what the editor owns (kind, title, edit, versions), and it is split around any journaled action taken while the editor is open: edits so far become their own entry, the action keeps its own, and the session restarts after the action (also after a toast Undo). ⌘Z then unwinds edits₂ → action → edits₁ with nothing skipped. Why: the r4 review showed the fold made ⌘Z undo half of a "Remove from queue".
2. Not fixed: the editor-session journal assumes the editor closes without animation (none does today). Why: no current path is affected; changing the close path touches every navigation and isn't worth the risk for this release.
3. Badges are now linted like icon-only buttons; the component gallery is exempt because it shows the bare component. Why: S2 says badges explain themselves too.
4. Snapshot evidence for a few modes/states (Score list, Edit single, paused, empty, problem tooltips) stays a documented gap rather than new pass cases. Why: the code walk covers them and the release isn't blocked on screenshots of hover bubbles.
5. Captions "Add template" / "Add set" stay without undo. Why: harmless additions that can be deleted (with confirmation).
6. Splitting the editor session first flushes the on-screen editor's debounced save (review r4 L6), so an edit made just before an action lands in the right entry. This last small fix was checked by tests, not by another review round. Why: it only adds a flush before a wait that was already there.
7. A toast Undo pressed after further editor edits stays "skipped · changed since" (review r4 L7). Why: it's conservative (nothing is lost), and it behaved this way before this release.

## Session B — stage = readiness, one list header, Filters popover, edited previews, v0.5.0 (2026-11-02)

### Stage = readiness (S1)
1. One wording source, `DJQCore/StageWording.swift`, names stages, neighbours and Edit reasons for the app and `djq`. Why: the app and djq had their own copies of the same strings.
2. The stage control names the real neighbour. Queue back is "Back to Edit" (was "Remove from queue"; it still holds the clip in Edit and removes unposted days), Edit forward is "Send to Queue", Scheduled back is "Back to Queue". Why: Eric asked for the neighbour's name.
3. The "Send to queue" label on a Queue card had one root cause: the Queue list included every clip on an upcoming draft-week day, even one that had fallen back to Edit. The new `queueClips` drops Score/Edit-stage clips, and the Queue screen, sidebar count and snapshots use it. Why: draft weeks don't make a clip Scheduled.
4. Display names: `needs_edit` "In Edit", `ready` "In Queue", `planned` "Scheduled". Render state `rendered` reads "Rendered" (was "Ready"). Stored values and JSON keys are unchanged. Why: readiness is the stage, and "Rendered" is the word the tooltip pass already uses for render files.
5. No schema change. Edit reason chips come from Validation. Why: a stored reason could go stale.
6. Auto-move: `Revalidation` re-derives every short, included clip in Edit, Queue or missing-file state. It runs as the tick step "stages", after every djq write (`Revalidation.afterWrite`), inside Settings batches (states only), and after New clip defaults saves and template deletes. Why: limit changes, cleared crops and missing files now move a clip out of the Queue in every path.
7. A clip that becomes valid again goes back to the Queue automatically, unless it was sent back by hand. Why: Queue = ready, and the hold is Eric's choice.
8. A scored clip whose file is missing sits in Edit with "File missing" and a Relink fix, and both stage moves are blocked. Unscored + missing has no stage (Library only). Why: S1 wants it visible with the reason, and you can't score a clip you can't watch.
9. Scheduled (approved week) and pinned clips that become invalid stay put and show the problem. A pinned clip logs "Can't post on <day>: <reasons>". Why: pinned never moves, and a silent unschedule would surprise.
10. An unpinned draft-week day (from today on, no posts) whose clip leaves the Queue is dropped and refilled from the queue order. `approveWeek` re-checks states first and runs in one transaction. Why: draft weeks are planner territory, and approval must never schedule a clip that isn't ready.
11. Draft-day refills happen outside the undo journal, and each tick takes the write lock for a short, mostly-read pass. Why: accepted at current scale (about 60 short clips, ≈0.1 s).
12. djq output uses stage names: `videos --json` adds `stage` and `reasons[]`, there's a new `--stage` filter, and `stage --json` adds titles and blockers. Existing keys are unchanged. Why: same words as the app, and JSON stays compatible.

### One list header + Filters popover (S3, S4)
13. The header has two rows plus an applied row. Row 1: title + count · search · view modes · primary. Row 2: page chips · Filters · sort. Row 3: applied chips + Clear all. Why: it keeps the S3 order without overflowing 880 pt columns.
14. The count reads "N" or "N of M" instead of "41 ready". Why: no readiness words.
15. Page chips: Edit shows missing reasons with counts (blocks tinted danger). Queue shows "Has a day" / "No day yet", meaning a draft or approved week. Posts shows Problems / Scheduled / Posted, with Platform as a Filters section. Score has a chip per session, and Library is as before, plus a Stage filter. Why: "Scheduled" means an approved week everywhere else, so the Queue chips got their own words.
16. Filters options are chips per section. Nothing is highlighted until applied, and the trigger only adds a count. Why: S4 says unapplied filters never look highlighted.
17. Clear all clears filters and search. The page chip and sort stay. Why: those are the page's view, not filters.
18. Search, page chip, filters and sort persist per page in UserDefaults (`djq.list.<page>`). A remembered session that's gone reads "Removed session". Why: it's a UI preference. There's no unit test, because the type lives in the app target, which the test target can't import.
19. ⌘F is a hidden window shortcut in the screen scaffold, so the system Edit menu stays intact. On Week it opens Next up and focuses its search. Why: there's no find bar in DJ Queue.
20. The editor's "Ready" badge reads "Nothing to fix". The runway reads "21 d in Queue".

### Edited previews (S6)
21. The preview stamp hashes edits.updated_at, the versions' updated_at, the defaults generation and the clip-row fields that feed defaults (title, kind, markers, file). Why: any change that alters the posted clip must refresh the lists.
22. One editor-exit path, in the `editor` didSet, covers Done, sidebar, ⌘-number, ⌘K and stage moves. Leaving by sidebar doesn't mark a Fix post fixed. Why: Done keeps its own meaning.
23. Video = the existing proxy, with the text overlay drawn as a layer only in the text window. Covers bake the text in when cover-includes-text is on. Why: the editor's own method, with no re-encode on text edits.
24. The overlay cache is a cost-capped LRU (64 MB) in DJQCore, keyed by text, not clip. Evicted overlays redraw only when a preview starts playing (≤4). Why: NSCache can't be tested for "under the cap", and grids must never thrash.
25. A proxy request made while the same clip is encoding queues a follow-up job, and a proxy whose name doesn't match the current edit is dropped. Why: the old crop must never loop.
26. The renderer and the lists share `PreviewKeys.textWindow` and `Media.coverComposite`. Render output is unchanged (pixel check 0.0076). Why: one geometry, no drift.
27. Quick look and the Library dialog open on Edited with an Original toggle. Quick look plays the current render file when one exists. Why: Eric wants to see what will post.
28. Cover JPGs are named per version and text, and older covers of the same clip are pruned. Why: thumbs/ mustn't grow with every text edit.

### Process
29. Commit d09447a ("wip: phase C wiring") went to main without the Co-Authored-By trailer. Why: history isn't rewritten, and the next commit carries the work properly.
