# Decisions: round 39, Analytics (v0.31.0)

Eric (2026-11-19): a full Analytics dashboard. The system exists for posting consistency, so performance **over time**
is the point: trends, cadence and consistency, per-clip and per-version curves, reposts against first posts. Show what
data each platform actually gives. Keep local snapshots so history builds up even where a platform only gives totals.
Build the whole thing without stopping for review. Contract and data table: [`docs/analytics.md`](docs/analytics.md).

## Decisions (each taken without asking, with why)

1. **Snapshots, not overwrites.** Postiz's post analytics are "as of now" totals, so every pull is kept as its own row
   (`post_metric_snapshots`) and account numbers per day (`channel_metrics`). Why: it's the only way to get a curve.
2. **Additive tables, no schema step.** Created on open (`CREATE TABLE IF NOT EXISTS`); the schema number stays 12.
   Why: an older build ignores them, so `djq autoupdate rollback` stays a plain swap with no database restore.
3. **Pull at set ages** (12 h, 1, 3, 7, 14, 30, 60, 90, 180, 365 days), not on a timer. Why: short-form grows in its
   first days; this gives the curve's shape at about 10 calls per post per year, which fits the shared budget at three
   posts a day on six platforms.
4. **Posting always wins the budget.** At most 8 analytics calls an hour, only from spare budget, and none while any
   Postiz post is being created, replaced or deleted. Why: Eric's posts must never wait for a chart. (A real-budget test
   caught analytics taking calls an edit needed; this rule is what fixed it.)
5. **X is asked only monthly after an empty answer.** Postiz returns nothing for X today; X posts still count for
   consistency, and if Postiz starts answering the numbers appear.
6. **Accounts once a day**, the first pull 90 days back. One-point totals (TikTok) are stored per day asked, so their
   line grows from install day on.
7. **One estimate, labelled.** Daily views spread evenly between two pulls and, before the first pull, along a
   front-loaded curve. Everything else is counted. The chart caption says so. Medians of "how posts grow" never go
   down (older ages have only older posts behind them; cumulative views can't fall).
8. **TikTok Studio pattern for the top**: six metric tiles (Views, Likes, Engagement, Followers, Posts, Views / post),
   each with its change against the same-length period before and a sparkline; clicking one charts it below. Why: one
   chart, low cognitive load, every headline number visible (Mobbin: TikTok Studio, X account overview).
9. **Consistency gets its own card**: streaks, days posted, days on target (posts per day × active platforms), missed,
   and a GitHub-style year grid (Mobbin: Base44 activity). Then **posts per week above views per week** as two aligned
   charts, never a dual axis (data-viz rule).
10. **Missed** means a failed or overdue post whose slot never went out and has no retry coming. A retried failure
    that later posted isn't a miss, and a platform Eric skipped isn't either. Why: Eric's rule that fixable failures
    are never shown as problems.
11. **Platform colours on charts only.** The app has none (DESIGN-v2 §2.1); charts split by platform need them. The
    data-viz reference categorical slots 1–6, light and dark validated against our surfaces (#FFFFFF, #2F2F2F) for
    colour-blind and normal-vision separation. Every chart has a legend with names; the main chart has a table view.
    Colour follows the platform whatever the filter.
12. **Period choices 7D, 30D, 90D, All**; over 92 days the timeline goes weekly. Remembered per Mac.
13. **Analytics sits in Browse before Health**, so Health moves from ⌘7 to ⌘8. Why: browsing screens stay together.
14. **Doctor's `analytics` finding is info only** (no pull for 3 days with posts waiting). The cause (key, budget,
    engine) has its own check, and posting doesn't depend on it.
15. **Existing numbers carried over.** On first open, views and likes posts already had (round 6's daily pull or typed
    in) became each post's first snapshot.
16. **Not built**: a menu-bar number (the menu bar is about what's going out), agent-API `views` on every clip (the
    clip list would need a snapshot query per call; `djq analytics clip` has it), hour-of-day analysis (posting times
    are fixed slots, so there's nothing to compare yet).

## Surfaces

| Surface | Now |
|---|---|
| Sidebar | **Analytics** (⌘7), Health ⌘8 |
| Analytics screen | period, platform chips (the legend), Refresh numbers; metric tiles → main chart (chart or table); Consistency; Posting and views by week; How posts grow; What does better (Reposts, Versions, Weekday); Top clips (click opens the clip); Each platform's own numbers; What each platform gives |
| Library | **Most views** sort; an "N views" tag on clips that posted |
| Queue, Calendar, Posts cards | the same views tag |
| Calendar Day | a posted post's button reads "1.2K views" and opens its numbers over time (type in still works) |
| Posts inspector | the post's views over time, when it was last pulled and next pulled, then the fields |
| Clip previews (Library quick look, ⌘K Preview) | a Performance strip: views, likes, posts, per platform, Open Analytics |
| ⌘K | Go to Analytics, Analytics: Last 7 / 30 / 90 days / All time, Refresh analytics numbers |
| djq | `djq analytics [--range] [--platform] [--json]`, `analytics clip`, `analytics post`, `analytics available`, `analytics refresh` |
| Doctor + doctor skill | `analytics` (info) |
| Engine | the sweep inside the Postiz sync |
| Live checks | `analytics` (+ dark): real clicks on tiles, a chip and a top clip; 30D and Library's sort are labelled stand-ins |

## For Eric to try by hand

- Hover the main chart, the weekly charts and the curves: a line and a tooltip follow the pointer (live checks can't
  move a pointer).
- The period control (7D · 30D · 90D · All) and Library › Sort › Most views (the checks set these the way the control
  does).
- History starts now: until posts reach 1, 3 and 7 days with pulls behind them, curves and comparisons stay thin.
