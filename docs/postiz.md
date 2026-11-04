# Postiz: the contract DJ Queue's publisher follows

Phase 2 (round 6). DJ Queue stays the brain and the record; Postiz is only the delivery truck behind the existing
`Publisher` interface (`Sources/DJQCore/Contracts.swift`). Nothing about *what* posts or *when* is decided in Postiz.
Manual stays the fallback for every platform, forever.

This file is public. It never holds a key, token, organization id or integration (channel) id. Channel ids live in the
app's settings in the local database; the key lives in the Keychain.

Sources (read 2026-11-03): docs.postiz.com/public-api (introduction, posts create/list/delete/change-status/missing,
integrations list/find-slot, uploads, webhooks, self-host config reference), the open-source server
(github.com/gitroomhq/postiz-app: `public.integrations.controller.ts`, `create.post.dto.ts`, `get.posts.dto.ts`,
`posts.repository.ts`, `schema.prisma`, `upload/*`, the instagram / tiktok / youtube / facebook / threads / x providers),
the official agent CLI (github.com/gitroomhq/postiz-agent `src/api.ts`, `PROVIDER_SETTINGS.md`) and a live, read-only
check of the connected channels and their settings schemas. "Verified" means read in source or seen live; "docs" means
the documentation says so but the source wasn't checked.

## 1. Base, auth, limits

| | |
|---|---|
| Base URL | `https://api.postiz.com/public/v1` (cloud). Self-hosted: `https://<domain>/api/public/v1`. |
| Auth header | `Authorization: <key>` — the raw key, **no `Bearer`**. Verified (agent CLI and docs). |
| Content type | `application/json`, except `POST /upload` (multipart). |
| Time | Every date is ISO 8601 **UTC** (`2026-11-10T00:00:00.000Z`). The server runs in UTC; there is no time-zone field. DJ Queue converts its America/New_York slots to UTC. |
| JSON body cap | 50 MB (`413`). Media goes through `/upload` first, posts reference it. |
| Upload cap | MP4 ≤ 1 GB, images (jpeg/png/gif/webp/avif/bmp/tiff) ≤ 10 MB; anything else `400 "Unsupported file type."` / `"File is too large."` (verified, `upload/custom.upload.validation.ts`). |
| Rate limit | Documented as both "90 requests per hour (100 on cloud)" on create-post and "30 requests per hour" per endpoint; the self-host default `API_LIMIT` is 90, the shipped docker-compose sets 30. The enforcement point isn't in the public controller. **DJ Queue budgets 25 requests per rolling hour across all calls** and treats `429` as "wait 15 min". |

Errors (docs): `400` malformed / validation (`PostValidationException`), `401` missing or invalid key, `403` wrong
organization, `404` not found (on DELETE: already deleted), `413` body too large, `429` over the limit, `5xx` retry with
backoff (a known issue returns some 500s for already-deleted posts).

## 2. Endpoints DJ Queue uses

| Method · path | Use in DJ Queue | Request | Response |
|---|---|---|---|
| `GET /is-connected` | key check (Settings, Doctor) | — | `{connected: true}` |
| `GET /integrations` | channel list, mapping, disabled/expired | `?group=` optional | `[{id, name, identifier, picture, disabled, profile, customer?}]` (`identifier` = provider, e.g. `tiktok-business`) |
| `GET /integration-settings/{id}` | settings schema + caption `maxLength` (Doctor, `djq postiz channels`) | — | `{output: {rules, maxLength, settings, tools}}` |
| `POST /upload` | upload a render (and the YouTube thumbnail) | multipart `file`; `adjust` = `"false"` (never let Postiz re-encode) | `{id, name, path, …, status}` (`ready` \| `processing`) |
| `GET /media/{id}/status` | wait for `processing` media | — | `ready` \| `processing` (+ `warning`) |
| `POST /posts` | create / schedule / draft one platform post | see §3 | `[{postId, integration}]` — one entry per `posts[]` item; no group, URL or state |
| `GET /posts?startDate=&endDate=` | status sync (one call covers every open post) | both required, ISO UTC; `customer` optional | `{posts: [{id, content, publishDate, releaseURL, releaseId, state, error, group, settings, integration{id, providerIdentifier, name, picture}, …}]}` (verified in `getPosts`; the docs omit `group` and `releaseId`) |
| `DELETE /posts/{id}` | cancel (unapprove, unqueue, skip, move, re-render) | — | `{id}`; deletes every row of the post's **group** (soft delete, `deletedAt`) and stops its workflow |
| `PUT /posts/{id}/status` | test mode: release a draft (`schedule`) or hold it (`draft`) | `{"status": "draft" \| "schedule"}` | `{id, state}` |
| `GET /posts/{id}/missing` + `PUT /posts/{id}/release-id` | link a post whose platform id came back `missing` | `{releaseId}` | `[{id, url}]` / the post |
| `GET /analytics/post/{postId}?date=<days>` | read-only views/likes per post (phase-3 groundwork) | — | provider metrics; `{missing: true}` when the release id is missing |

Not used: `/find-slot` (DJ Queue owns slots), `/integration-trigger` (TikTok music search; no in-app music choice),
`/clipping`, `/generate-video`, `/notifications`, `PUT /posts/{id}/settings` (only settings, not content; DJ Queue
replaces the post instead, §5).

## 3. Creating a post

`POST /posts` (`create.post.dto.ts`, verified):

```json
{
  "type": "schedule",                       // "schedule" | "draft" | "now" | "update"
  "date": "2026-11-10T00:00:00.000Z",       // required, UTC; ONE date for the whole request
  "shortLink": false,                        // required; false keeps links as written
  "tags": [],                                // required, [{value, label}]
  "posts": [{
    "integration": {"id": "<channel id from settings>"},
    "value": [{"content": "<caption>", "image": [{"id": "<media id>", "path": "<media path>", "thumbnailTimestamp": 3000}]}],
    "settings": {"__type": "<provider identifier>", "…": "…"}
  }]
}
```

- **One request per platform post.** The server strips per-post dates and uses the request's single `date`, and DJ Queue's
  slots differ per platform (FB 12:30 … TikTok 7:00 pm). Each `posts[]` item gets its own `group`; requests made
  together share a `batchId`. So one DJ Queue `PlatformPost` = one Postiz post = one group, and `DELETE /posts/{id}`
  cancels exactly that platform.
- `value` has one item (the video); more items would become a thread/comments.
- `republish: true` is required to publish an already-`PUBLISHED` post again. DJ Queue never sends it (never double-post).
- `type: "draft"` is saved but never published until `PUT /posts/{id}/status {"status":"schedule"}`.
- A 400 means the post failed the same validation as the Postiz dashboard (settings, media, length).

### Per-platform settings (live schemas, 2026-11-03)

| DJ Queue | Postiz provider (`__type`) | Required | DJ Queue defaults | Caption max |
|---|---|---|---|---|
| Instagram | `instagram-standalone` (direct IG login, **not** via the Facebook Page) | `post_type` | `post_type: "post"` (a Reel for a single video), `is_trial_reel: false`; collaborators/audio not set | 2200 |
| TikTok | `tiktok-business` | `content_posting_method, privacy_level, duet, stitch, comment, autoAddMusic, brand_content_toggle, brand_organic_toggle` | `DIRECT_POST`, `PUBLIC_TO_EVERYONE`, duet/stitch/comment `true`, `autoAddMusic: "no"`, brand toggles `false`, `video_made_with_ai: false`, `title` = DJ Queue title ≤ 90 | 2200 |
| Facebook | `facebook` (Page) | — | `post_type: "post"`, `title` = DJ Queue title | 63206 |
| YouTube Shorts | `youtube` | `title` (2–100), `type` | `type: "public"`, `selfDeclaredMadeForKids: "no"`, `title` = `{text} \| DJ Lovd` (DJ Queue's template, ≤ 100), `thumbnail` = the cover as `{id, path}`, `tags` from the hashtags (no `#`) as `[{value, label}]` (DTO shapes; not seen live — a 400 falls back to Today with Postiz's message) | 5000 |
| Threads | `threads` | — | none | 500 |
| X | `x` | — (`who_can_reply_post` documented as required by the CLI, optional in the live schema) | `who_can_reply_post: "everyone"`, `post_type: "post"` | 280 (4000 only for X Premium accounts, decided at connect time) |

Notes that shape the build:
- **TikTok `UPLOAD`** doesn't publish: the video lands in the TikTok app inbox, must be finished there within 24 h, and
  every setting except `title` is dropped. Postiz still reports it `PUBLISHED`. TikTok Business has **no privacy field for
  videos** (`privacy_level` applies to photo posts), so "private" isn't a TikTok test option; `UPLOAD` is.
- **TikTok media is pulled by URL** from Postiz storage (Postiz's verified domain), so it must be a Postiz upload.
- **Facebook via Postiz is a Page video** (`/{page}/videos`), not a Reel. DJ Queue keeps its 90 s Facebook limit (a
  Reel-length choice); it can be raised in Settings → Limits if Page videos are fine.
- **X** has no thumbnail; links are stripped only in articles (DJ Queue never sends articles).

### What DJ Queue's cover means per platform

| Platform | Through Postiz | Shown in the editor as |
|---|---|---|
| YouTube | the cover JPG (with text when "cover includes text") is uploaded and sent as `settings.thumbnail` (needs a phone-verified channel; otherwise YouTube keeps its own frame and the post still goes out) | "Thumbnail" |
| Instagram | `thumbnailTimestamp` = cover time in ms from the start of the posted file → Reel cover frame (`thumb_offset`) | "Cover frame" |
| TikTok | `thumbnailTimestamp` → `video_cover_timestamp_ms` (DIRECT_POST only) | "Cover frame" |
| Facebook, Threads, X | not supported by Postiz; the platform picks the frame | "Platform picks" |

The frame comes from the posted file, which has the text burned in during its text window, so a cover time inside the
window shows the text.

### Platform limits (re-verified; DJ Queue defaults)

| | Length | Size | Caption | Title | Source |
|---|---|---|---|---|---|
| TikTok | 600 s (all creators: 3 min; some 5 or 10 min; per-account cap `max_video_post_duration_sec`) | 4 GB | **2200** (was 4000 in DJ Queue) | 90 | TikTok Content Posting API; Postiz schema |
| Instagram | 180 s (API allows 3 s–15 min; DJ Queue keeps Reels at 3 min) | 300 MB | 2200 | — | IG Graph API `ig-user/media` |
| Facebook | 90 s (Reel length, see above) | 4 GB | 63206 (DJ Queue keeps 2200) | — | Postiz schema |
| YouTube Shorts | 180 s (vertical ≤ 3 min = Short since 2024-10-15; longer is a regular video) | 4 GB | 5000 | 100 | YouTube Help 15424877 |
| Threads | 300 s | 1 GB | 500 | — | Threads API posts |
| X | 140 s | 512 MB | 280 | — | spec default; X's official media page was unreachable, Postiz only knows 2 and 10 min account errors |

Instagram's size cap drops from 4 GB to 300 MB; DJ Queue renders (1080×1920 H.264 at 12 Mbps) are ≈ 90 MB a minute, so a
3-minute clip fits. The X length isn't verified upstream; it stays Eric's default.

## 4. DJ Queue → Postiz mapping

| Postiz field | DJ Queue source |
|---|---|
| `posts[].integration.id` | `Settings.postiz.channels[platform]` (picked in Settings from `GET /integrations`, matched by provider) |
| media | the post's render file (`Render.outputPath`, 1080×1920 H.264, −14 LUFS / −1 dBTP, text burned in), uploaded once per render and reused by every platform post that shares it |
| `value[0].content` | `Captions.caption(for: platform, …)` — the platform's caption with its hashtags, already within the platform's limit |
| `thumbnailTimestamp` | cover time − trim start, in ms (IG, TikTok) |
| YouTube `title` / `thumbnail` | `Captions.youtubeTitle` (`{text} \| DJ Lovd`, ≤ 100) / the render's cover JPG uploaded |
| TikTok / Facebook `title` | the clip's Title (TikTok ≤ 90) |
| `date` | `PlatformPost.scheduledAt` (America/New_York slot) as UTC; a slot already in the past gets now + 3 min |
| `type` | `schedule`; `draft` in test mode for platforms without a private option (§6) |

## 5. Lifecycle and state mapping

DJ Queue's post state machine is unchanged: `planned → rendering → rendered → due → posted | failed | copyright_* |
skipped | overdue`. The publisher adds a **Postiz job** per platform post (new table, schema v5): Postiz post id, group,
media id/path, the render id and content hash it was made from, the remote state and error, and sync times.

**Submit ahead.** A tick step `publish` (after `render`) finds every post whose platform publishes through Postiz, whose
week is approved, whose render is attached, and which has no live job for its current render + content hash. It uploads
(reusing a media id already uploaded for that render) and creates the scheduled post. This closes the gap in
`Engine.due()`: submission no longer waits for the due time or depends on the render existing first. The Mac can be off
at post time.

**Change → replace.** If the render or content hash changes (re-render, edited caption/title/settings) while the remote
state is `QUEUE` or `DRAFT`: delete, then create again. If the delete fails, nothing is created (no double post).
A content-only change (caption, title, hashtags, template or Postiz settings) waits until the new content hash has
stayed the same for 2 minutes (`PostizService.settleDelay`, tracked per job in kv `postiz.settle.<job id>`; any further
edit restarts the clock, an edit back to what Postiz has clears it), so an edit burst is one replace. Postiz keeps
its copy meanwhile; one quiet "waiting for edits to settle" event per job. A new render, a move, a channel change and
every cancel stay immediate. Together with the 5-minute safety window, a content edit made from about 7 minutes
before the slot (2 min settle + 5 min) no longer reaches Postiz: Postiz posts the version it has.
Unapprove, unqueue, skip, a moved day, a paused platform or switching the platform back to Manual → delete. A post
Postiz already published is never deleted or re-sent by DJ Queue.

**Status sync.** A tick step `sync` lists posts (`GET /posts`) over the window of open jobs, at most every 10 minutes
while a job is within six hours of its slot or waiting for a result, otherwise hourly:

| Postiz | DJ Queue |
|---|---|
| `QUEUE`, before the slot | post stays `rendered` / `due` with "Scheduled in Postiz"; no manual "due" notification |
| `QUEUE`, > 60 min after the slot | still in flight; Doctor `postiz.stuck` + one alert |
| `DRAFT` | test mode: "Draft in Postiz" (release from DJ Queue or the Postiz calendar) |
| `PUBLISHED` + `releaseURL` | `posted`, `url` = `releaseURL`, `externalId` = `releaseId`, `postedAt` = `publishDate` |
| `PUBLISHED`, `releaseId` = `missing` | `posted` without a link; Doctor `postiz.link_missing` (fix: `djq postiz link`) |
| `ERROR` + `error` | `failed` with the error; text mentioning copyright / rights / music / audio claims → `copyright_blocked` (loud, never auto-retried); a clearly temporary error retries by itself (below); otherwise the existing "fixed → re-queue next day" rules apply |
| missing from the list (deleted in Postiz) | the job is closed and the post falls back to Manual (Today) with a loud note |

`error` is curated by Postiz (the platform's message when it is a known "bad body" error, otherwise null); null on
`ERROR` reads "Postiz reported an error (no details)".

**Temporary failures retry by themselves** (`PostizRetry.swift`, DECISIONS-R8.md). An `ERROR` is temporary only on clear
wording: quota, rate limit / too many requests, "try again later", "reschedule this post for a later time", temporarily
unavailable. Everything else stays a normal failure, and copyright wins over temporary, always. A temporary failure still
reads Failed and still gets its alert, with the message plus "retries tomorrow automatically". A tick step `retry` (right
after `alerts`, and only once the post's alert went out) re-queues it through `PostActions.fixed`: next day, the usual
stagger, a new attempt the publish step submits. At most 2 automatic retries per clip + platform + version (kv
`postiz.autoRetry.<clip>#<platform>#v<N>`); after that it stays Failed for Eric, and the message says so. No retry for
copyright (on this post or any job of the clip + platform), a skipped or removed post, or a platform skipped in the
editor. It waits, and stays Failed, while the clip is held in Edit or the platform isn't routed to Postiz (Manual, paused,
off, no usable channel or key). It also waits while another job of the clip + platform is open or another post is live,
and it never happens once one was published (so a repost of a clip Postiz published stays Failed for Eric). The retry
uses the Test run switch like any new post, except that a retry of a test-run post stays a test run (the attempt's id is
kept in that kv row and `submit` forces test mode for it), even after Test run is turned off. Doctor (`postiz.auto_retry`)
and `djq postiz status` show pending retries. A failure already sitting Failed when this shipped qualifies too.

**Missed slots.** A Postiz post isn't "missed" while Postiz still holds it: the overdue/shift logic applies only to
manual posts and to Postiz posts that never got a job (they fall back to the Today screen). Retries follow the existing
rules: `fixed`, by hand or from the `retry` step, makes a new attempt the next day, which the publish step submits again.

**Fallback.** Per platform: no key, an invalid key, no mapped channel, a disabled channel or a create that fails
validation → that platform's post goes to Today exactly as today, with the reason. Manual never goes away.

**Budget.** All calls share the 25-per-hour budget. Order: deletes, creates for the soonest slots, sync, analytics.
Approving a week of 6 platforms is 6–7 uploads + 42 creates, so it spreads over about two hours; the render horizon
(7 days) leaves plenty of time.

## 6. Test mode (one switch)

"Test run" in Settings → Publishing, shown as a badge on every affected post:
- TikTok → `content_posting_method: "UPLOAD"` (lands in the TikTok inbox as a draft).
- YouTube → `type: "unlisted"`.
- Instagram, Facebook, Threads, X → Postiz `type: "draft"` (nothing reaches the platform until released).

Postiz reports a TikTok `UPLOAD` as `PUBLISHED` although nothing is public yet, so a test-mode TikTok post reads
"In your TikTok inbox: finish it in the app, then Mark posted with the link" and stays a manual step until marked. A
test-mode YouTube post that publishes is recorded as posted (unlisted) with a Test badge. Turning test mode off never
changes posts already made; they keep their badge.

## 7. Auth for the app

**Recommendation: a Postiz public API key in the Keychain**, entered in Settings → Publishing ("Postiz API key", service
`DJ Queue Postiz`, account `postiz`). Why: it doesn't expire, needs no browser or callback server, and is the method the
public API documents. The OAuth device flow is for agents; its refresh handling would be new code to keep alive in a
background app, for no gain on a single-user Mac. The app reads the key only at call time, never logs it, never puts it
in the database, events, Doctor output or `djq` JSON. Reads go through `/usr/bin/security` so a rebuilt (ad-hoc signed)
app doesn't trigger a Keychain prompt on every update. Agents keep using the Postiz MCP connector.

## 8. How DJ Queue implements it (round 6, `Sources/DJQCore/Postiz/`)

- **Settings → Publishing** (`Settings.publishing`): publisher per platform (Manual default), Postiz channel id per
  platform, test mode, the §3 options, `apiBase` (https only; anything else falls back to the cloud base) and
  `hourlyBudget` (25, at least 10). The stored row decodes field by field, so a bad value never resets Settings.
- **Jobs** (schema v5, `postiz_jobs`): one row per Postiz post. At most one open job per platform post (unique partial
  index). Phases `creating` → `live` → (`deleting`) → `closed`. Close reasons: published, inbox (test-mode TikTok),
  error, copyright, vanished, rejected — final, the post is never submitted again by itself (`reset` releases error,
  rejected, vanished) — and replaced, cancelled, interrupted (not final). `postiz_media` caches the media per render.
- **One clip, one platform, one Postiz post.** Jobs carry a *lineage* (clip + platform, or clip + platform + version for
  a repost). Planner moves give a post a new id; the lineage stays. Nothing is created for a lineage while another of
  its jobs is open (not confirmed deleted, or unconfirmed) or once one was published (a later post of that lineage is
  then recorded as posted with that link). The check runs inside the claim's `BEGIN IMMEDIATE`, so two engines can't
  both pass.
- **Tick**: `… alerts → retry → render → publish → sync → …`. *publish* first deletes open jobs that must go (post removed or
  re-planned, terminal or marked posted by hand, moved, edited, render changed, platform off/paused, Manual, global
  pause, channel changed), then creates for every Postiz-routed post with its render attached within the render
  horizon, soonest first. The same "settings allow Postiz" check decides both (no delete/create churn).
- **Delete retries** (budget used up, 5xx, …) run every tick but are logged once per job and kind of failure
  (`postiz.deleteRetry:<job id>:<kind>` in `sent_notifications`).
- **Near the slot** (from 5 min before it): Postiz's copy is never *replaced* — an edit, a new render or a re-plan
  is logged and Postiz keeps what it has. A *cancel* there first reads the post's current state (one `GET /posts`):
  published → recorded, never deleted; otherwise (including "not listed") DELETE, a 404 counting as done.
- **Test mode is frozen per job**: switching Test run changes only posts submitted afterwards (§6).
- **Handed to Today**: a post whose manual "due" notice went out (or that was missed, posted now or shifted by hand)
  stays Manual for good, across re-renders, even when the key or channel comes back (Eric may already have posted
  it); only a reset sends it through Postiz again. Later posts follow the platform's route.
- **Test-run drafts** an hour past their slot are notified (release, or post by hand).
  *sync* lists posts over the open jobs' window (10 min while hot, else hourly), maps §5, probes a refused key hourly,
  refreshes the channel list every 6 h and pulls analytics daily.
- **Due / missed**: a post with an open job, or routed to Postiz with no final job, gets no manual "due" notification;
  a post with an open job is never overdue or shifted. Everything else is exactly as before (Today).
- **A create whose outcome is unknown** (5xx, timeout, an unreadable 2xx, a database error while recording it): the
  claim stays and blocks the lineage. The sync step adopts the one Postiz post with the same channel, the exact date
  sent and the exact caption (two open jobs on one channel never share a minute). None or several → unconfirmed
  (`isUnconfirmed`): a critical notice (daily), Doctor `postiz.create_unknown`, and nothing is sent again until Eric
  checks the Postiz calendar and decides, offline: `resolveUnconfirmed(postId:inPostiz:)` (`djq postiz resolve
  --in-postiz | --not-in-postiz`). A request that never left the Mac (`notSent`) and a claim whose create was never
  sent are released at once / after 10 min. If the platform is switched off Postiz meanwhile, the post reaches Today
  with "check the Postiz calendar first".
- **Budget** (kv `postiz.budget`, `BEGIN IMMEDIATE`): creates leave 1 call/hour for sync, analytics leave 8; uploads
  count. `429` → no calls for 15 min; `401`/`403` → "key refused" (kv), no calls except an hourly probe, notified once,
  cleared by a successful call or saving the key.
- **Key**: `/usr/bin/security find-generic-password … -w` to read (stdout only; exit 44 = no key, other failures are
  "locked or refused"); saving runs `security -i` with the `add-generic-password -U …` line on stdin, so the key never
  appears in a process argument list and the item trusts `/usr/bin/security` (no prompt after rebuilds). Requests
  print redacted, redirects are never followed, uploads stream from a temp file (stale ones are swept).
- **Tests and dev runs** never reach Postiz or the Keychain: `PostizLive.disabled` turns the real transport and the
  real `security` runner off. It is on in tests (the fixture), with `DJQ_POSTIZ_OFFLINE=1`, and in any process with
  `DJQ_HOME`/`DJQ_ROOT` set unless `DJQ_POSTIZ_LIVE=1`; every test injects fakes.

## 9. Not supported / follow-ups

- Webhooks exist ("fires when a post publishes", set up in the Postiz UI) but the payload isn't documented and DJ Queue
  has no public endpoint; polling is used.
- No per-platform `date` in one request; no edit of content in place through a documented route (DJ Queue replaces).
- Analytics: read-only pull of views/likes into the post's metrics; no auto-repost yet (phase 3).
- One-way Notion sync of posts stays a phase-2 follow-up.
