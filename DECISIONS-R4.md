# Round 4 decisions

## Session A — tooltips, undo, v0.4.0 (2026-11-02)
1. The editor session's undo entry covers only what the editor owns (kind, title, edit, versions), and it is split around any journaled action taken while the editor is open: edits so far become their own entry, the action keeps its own, and the session restarts after the action (also after a toast Undo). ⌘Z then unwinds edits₂ → action → edits₁ with nothing skipped. Why: the r4 review showed the fold made ⌘Z undo half of a "Remove from queue".
2. Not fixed: the editor-session journal assumes the editor closes without animation (none does today). Why: no current path is affected; changing the close path touches every navigation and isn't worth the risk for this release.
3. Badges are now linted like icon-only buttons; the component gallery is exempt because it shows the bare component. Why: S2 says badges explain themselves too.
4. Snapshot evidence for a few modes/states (Score list, Edit single, paused, empty, problem tooltips) stays a documented gap rather than new pass cases. Why: the code walk covers them and the release isn't blocked on screenshots of hover bubbles.
5. Captions "Add template" / "Add set" stay without undo. Why: harmless additions that can be deleted (with confirmation).
6. Splitting the editor session first flushes the on-screen editor's debounced save (review r4 L6), so an edit made just before an action lands in the right entry. This last small fix was checked by tests, not by another review round. Why: it only adds a flush before a wait that was already there.
7. A toast Undo pressed after further editor edits stays "skipped · changed since" (review r4 L7). Why: it's conservative (nothing is lost), and it behaved this way before this release.
