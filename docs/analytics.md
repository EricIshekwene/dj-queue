# Analytics (round 39, v0.31.0)

What DJ Queue can know about how posts do, where it comes from, and how it builds a history over time.

## Where the numbers come from

Everything comes through Postiz's public API with the same key, budget and rules as posting (`docs/postiz.md`):

| Call | What it returns | How DJ Queue keeps it |
|---|---|---|
| `GET /analytics/post/{postizId}?date=30` | One post's numbers **as of now**: one data point per metric, dated today | One row in `post_metric_snapshots` per pull, so each post builds a curve |
| `GET /analytics/{integrationId}?date=30` | One account's numbers: per platform either a **daily** series (one value per day) or a one-point **total** for the window | `channel_metrics`: daily values per day (a later pull of the same day wins), totals stored on the day they were asked, which is how their trend builds up |

The app never calls a platform directly, and analytics never post, schedule or change anything.

## What each platform gives (checked on DJ Lovd's channels, 2026-11-19)

| Platform | Per post | Account, per day | Account, totals only | Followers |
|---|---|---|---|---|
| TikTok | Views, Likes, Comments, Shares | – | Views, Recent Likes, Recent Comments, Recent Shares | not given |
| Instagram | Views, Reach, Likes, Comments, Shares, Saves | Reach | Views, Likes, Comments, Shares, Saves, Replies | not given |
| Facebook | Plays, Reactions, Engagement | Page Impressions, Media views, Posts Engagement, Page followers | – | new Page followers per day |
| YouTube Shorts | Views, Likes, Comments, Favorites | Estimated Minutes Watched, Average View Duration, Average View Percentage, Subscribers Gained, Subscribers Lost, Likes | – | subscribers gained and lost per day |
| Threads | Views, Likes, Replies, Reposts, Quotes | Views | Likes, Replies, Reposts, Quotes | not given |
| X | nothing | nothing | nothing | not given |

From DJ Queue itself, for every platform: when each post went out, its platform, version, repost number, its score,
and slots that were missed. `djq analytics available` prints this table plus every label actually seen in the database
(if Postiz starts sending something new, it shows there and is kept raw).

Labels map onto shared keys (`MetricKey`): Views/Plays → views, Likes/Reactions/Recent Likes → likes,
Comments/Replies → comments, Shares/Reposts → shares, Saves/Favorites → saves, Page followers/Subscribers Gained →
followers gained, Subscribers Lost → followers lost. Anything else is stored under its own label.

## When numbers are pulled

The engine's Postiz sync runs the sweep at most every 5 minutes:

- **Posts**: a published Postiz post is asked at **12 hours, 1, 3, 7, 14, 30, 60, 90, 180 and 365 days** after it went
  out (youngest age first). A post first seen late is asked once at its latest age, not once per missed age. After an
  empty answer (X today, or a post Postiz can't find on the platform) it's only asked at 30, 90, 180 and 365 days, so a
  platform that starts answering is picked up without wasting calls. Nothing is asked after a year.
- **Accounts**: each mapped channel once a day; the first pull reaches back 90 days for the daily series.
- **Budget**: analytics take at most **8 calls in any rolling hour**, only when the hour's budget has at least 8 spare
  calls above the 8 kept for posting, and **not at all while any Postiz post is being created, replaced or deleted**.
  Posting always wins.
- `djq analytics refresh` (and the Analytics screen's Refresh numbers, and ⌘K) asks what's due plus posts not asked in
  the last 6 hours, up to 12 calls, still inside the shared budget.

Typed-in numbers (Calendar Day → Numbers, Posts inspector) become "manual" snapshots and join the curves. On the first
open after the update, the views and likes posts already carried became their first snapshots.

## What the screen computes (`AnalyticsReport`)

- **Views / Likes gained** per day or week: each post's running total from its snapshots, spread evenly between two
  pulls, and before its first pull along a front-loaded curve (`1 − e^(−t/1.5 d)`, most short-form views come early).
  This is the one estimate on the screen, and the chart says so.
- **Engagement**: (likes + comments + shares + saves) ÷ views for posts from the period.
- **Followers**: net new from Facebook and YouTube only (the others don't give it).
- **Consistency**: posts per day against the target (posts per day × active platforms), current and longest streak,
  days on target, missed posts (a failure whose slot never went out and has no retry coming).
- **How posts grow**: median views by days after posting, per platform (one platform: every post in grey too).
- **What does better**: median views after 7 days, first post vs repost per platform, by version, by weekday.
- **Top clips**: views gained in the period per clip, likes, engagement, best platform, trend.
- **Each platform's own numbers**: the account series above, one small chart per platform.
