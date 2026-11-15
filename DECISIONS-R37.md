# Decisions: round 37, one repost control and bulk Mark repostable

Eric (2026-11-15): "allow me to mark videos as repostable in my queue or edit pages for bulk actions"; standing rule:
"whenever we're making a fix, we have to scan the whole app and see what other surfaces that fix or new feature
touches"; and about the editor showing Ready to repost, Repost and Posts stacked: "what is the point of the redundancy,
it is confusing".

## Decisions

1. **One control per version: Posts** (Never, Once, 2 times …). It's the only repost control in the editor (the
   inspector row and each row of the versions list). "Ready to repost" (round 20) and the clip-level Repost switch
   (round 36) are gone from the editor. A version's Posts always wins.
2. **The whole clip: Mark repostable / Mark not repostable**, a bulk action that asks first and has Undo, like every
   other bulk action. Repostable: every version posts `Settings › Posts per version` times (2) unless it has its own
   Posts. Not repostable: every version posts once; a version's own Posts above once goes back to once (Never stays
   Never); reposts already planned come off and the calendar closes up (round 36). One clip shows the item that changes
   it, several show both.
3. **Stored as before**: the clip-wide mark is kv `plan.repost` (planning data, nothing re-renders). Undo restores the
   mark, the versions' counts and the plan; the mark is journaled only by this action, so it never blocks or changes
   the undo of another batch.
4. **Ready to repost data stays** (`Version.repostReady`) but nothing shows or sets it; Eric had no version marked. Its
   old names point at the new action: `djq repost-ready` = `djq reposts`, filter `repost-ready` = `repostable`.
5. **"Repostable"** means some version posts more than once (marked, or a version's own Posts above once). That's what
   the filter, search and the API say.

## Surfaces (the whole-app scan)

| Surface | Before | Now |
|---|---|---|
| Editor inspector | Ready to repost row, Repost switch, Posts | Posts only |
| Versions list (popover) | Ready to repost switch + label per row, Posts | Posts per row; header copy shorter |
| Version picker (header) | green check + tooltip for a ready version | plain v1 ▾, tooltip mentions Posts |
| Queue | nothing | bulk bar ⋯ and card menu: Mark repostable / not repostable |
| Edit | nothing | bulk bar ⋯ and card menu: same |
| Library | nothing | bulk bar ⋯ and the clip menu: same |
| Calendar | nothing | clip menu: same |
| ⌘K | "ready to repost" found marked versions | "repostable" finds repostable clips; clip menu has the action |
| Filters › Reposts (Queue, Edit, Library) | Ready to repost / No version ready | Repostable / Posts once |
| Settings › Posts per version | the count when Repost is on | the count for repostable clips |
| djq | `reposts`, `repost-ready`, `videos --repost-ready`, filter `repost-ready` | `reposts`, `bulk repostable|not-repostable`, `videos --repostable`; the old names still work |
| Agent API | `repost_ready_versions`, `repost` | + `repostable` on every clip; `repost` = repostable |
| Editor open during a bulk | n/a | the Posts row follows the new mark on the next change signal |
| Live checks | `repost-ready` | `repostable` (+dark); `version-posts` updated |
| README, ARCHITECTURE, skill | Ready to repost, Repost switch | Posts + Mark repostable |
