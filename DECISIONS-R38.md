# Decisions: round 38, a repostable clip carries its count; a version's Posts overrides it

Eric (2026-11-16), correcting v0.29.0: "for an entire video I can mark it as repostable … if I mark it as repostable and
give it a repost count of 3, then every single version inside that post should post 3 times. The overrides were only for
specific versions … I can override it by going to one of the versions and saying, oh, I only want this to be posted
once, or 5 … it seems like you're mixing 2 functionalities."

## Decisions

1. **Two layers.** The clip: *Repostable* with a count (×2 … ×9). Every version of the clip posts that many times. The
   version: *Posts*, an override for that version only (Never, Once, 5 times …); until it's set, the version follows the
   clip ("Clip setting"), and ↺ puts it back. Not repostable: every version posts once, except the versions with their
   own Posts.
2. **Where the clip layer lives:** at the top of the editor (*Repostable · Whole clip*, a switch, and *Each version posts
   ×N* once it's on), and in bulk: *Mark repostable ▸ ×2 / ×3 / ×4 / ×5* and *Mark not repostable* on the Queue, Edit,
   Library, Calendar and ⌘K menus (asks first, Undo). One clip shows its current count checked.
3. **The version layer** shows which it is: in the editor "v1 posts" with a *Clip setting* or *Override* badge and ↺; in
   the versions list "Posts · clip" or "Posts · own".
4. **Overrides survive the clip changing.** Mark not repostable no longer clears a version's own Posts (v0.29.0 did): an
   override is Eric's per-version choice. A lower clip count, or not repostable, takes the reposts it no longer asks for
   off the calendar (round 36's rule) and the calendar closes up.
5. **Settings › Posts per version** is the count a clip starts at when it's marked without picking one (the editor's
   switch, `djq reposts <clip> on`). It never changes a clip that already has a count.
6. **Stored as** kv `plan.repost` = `[clip id: count]`. Round 37's list of ids reads as the Settings count. Undo restores
   the clip's count; old round-37 journals restore the mark at the Settings count.
7. **A clip that finished posting before round 31** keeps its one post unless Eric marks it repostable: marking it is his
   explicit choice, so its versions then post the clip's count.

## Surfaces

| Surface | Now |
|---|---|
| Editor inspector | Repostable · Whole clip (switch, ×N), then "vN posts" (Clip setting / Override, ↺) |
| Versions list | "Posts · clip" / "Posts · own" per row, ↺ on an override; header copy |
| Queue, Edit, Library bulk bars and card menus, Calendar menu, ⌘K | Mark repostable ▸ ×2–×5, Mark not repostable |
| Filters › Reposts, ⌘K "repostable" | unchanged (some version posts more than once) |
| djq | `reposts <clip> on [2-9]|off`, `bulk repostable [2-9]`, `djq video` "(repostable ×N)", `--json` `repost_count` |
| Agent API | `repost_count` on a clip |
| Settings › Posts per version | the starting count |
| Planner | `PostUnits.count(…, repostCount:)`: own ?? clip count ?? once |
| Live checks | `repostable` (+dark) drives the switch, the clip count, a version override, ↺, bulk ×3 / ×2 / not |
