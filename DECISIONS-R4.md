# Round 4 decisions

## Session A — tooltips, undo, v0.4.0 (2026-11-02)
1. The editor session's undo entry covers only what the editor owns (kind, title, edit, versions). Score, excluded and held change only through actions that journal themselves, so a stage move or score made while the editor is open keeps its own ⌘Z entry instead of being folded into "Edits to X". Why: the r4 review showed the fold made ⌘Z undo half of a "Remove from queue".
2. Not fixed: the editor-session journal assumes the editor closes without animation (none does today). Why: no current path is affected; changing the close path touches every navigation and isn't worth the risk for this release.
3. Badges are now linted like icon-only buttons; the component gallery is exempt because it shows the bare component. Why: S2 says badges explain themselves too.
4. Snapshot evidence for a few modes/states (Score list, Edit single, paused, empty, problem tooltips) stays a documented gap rather than new pass cases. Why: the code walk covers them and the release isn't blocked on screenshots of hover bubbles.
5. Captions "Add template" / "Add set" stay without undo. Why: harmless additions that can be deleted (with confirmation).
