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
| `DELETE /posts/{id}` | cancel (unschedule, unqueue, skip, move, re-render) | — | `{id}`; deletes every row of the post's **group** (soft delete, `deletedAt`) and stops its workflow |
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
| YouTube Shorts | `youtube` | `title` (2–100), `type` | `type: "public"`, `selfDeclaredMadeForKids: "no"`, `title` = `{text} \| DJ Lovd` (DJ Queue's template, ≤ 100), `thumbnail` = the cover as `{id, path}`, `tags` from the hashtags (no `#`) as `[{value, label}]` (DTO shapes; not seen live — a 400 falls back to the Calendar with Postiz's message) | 5000 |
| Threads | `threads` | — | none | 500 |
| X | `x` | — (`who_can_reply_post` documented as required by the CLI, optional in the live schema) | `who_can_reply_post: "everyone"`, `post_type: "post"` | 280 (4000 only for X Premium accounts, decided at connect time) |

**Photo posts (round 21, `PostizPayload.photoSpec`).** Same request, with one `image` entry per photo
(`[{id, path}, …]`, posting order, no `thumbnailTimestamp`, no thumbnail upload). Each photo is uploaded once per
render as `image/jpeg` and cached in `postiz_media` as `photo1`, `photo2`, …. The photos go up before the post is
claimed, as many as the hourly budget allows, and the post is created once every photo is cached: a carousel larger than
an hour's budget (TikTok takes 35, the default budget is 25) finishes in the next hour, and the posts behind it aren't
held up by it. A carousel longer than a platform takes sends its first photos there. Instagram takes photos from 4:5 to
1.91:1 only, so a 9:16 photo post can't be sent to the Queue while Instagram is on for it (DECISIONS-R21 D20).

| DJ Queue | Photos per post | Settings sent for a photo post |
|---|---|---|
| Instagram | 10 | `post_type: "post"` (a feed post; a carousel with several). No `is_trial_reel`. |
| TikTok | 35 | The video keys without `video_made_with_ai`: `content_posting_method` (Eric's setting; `UPLOAD` in a test run), `privacy_level`, `duet`, `stitch`, `comment`, `autoAddMusic: "no"` (never a library track), the brand toggles, `title` = the Title. |
| Facebook | 10 | `post_type: "post"`, no `title`. |
| Threads | 20 | none |
| X | 4 | `who_can_reply_post`, `post_type: "post"` |
| YouTube Shorts | 0 | Never sent: a photo post has no YouTube post, and asking for its payload is an error. |

Test run is as for videos: Instagram, Facebook, Threads and X become drafts, TikTok goes to the inbox.

Notes that shape the build:
- **TikTok `UPLOAD`** doesn't publish: the video lands in the TikTok app inbox, must be finished there within 24 h, and
  every setting except `title` is dropped. Postiz still reports it `PUBLISHED`. TikTok Business has **no privacy field for
  videos** (`privacy_level` applies to photo posts), so "private" isn't a TikTok test option; `UPLOAD` is.
- **TikTok media is pulled by URL** from Postiz storage (Postiz's verified domain), so it must be a Postiz upload.
- **Facebook via Postiz came back as a `/reel/` link** on the first live post (2026-11-04). DJ Queue's 90 s Facebook limit
  stays Eric's choice (Settings → Limits).
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

Hashtag caps (v0.8.3, editable in Settings → Platforms): Threads 1, YouTube 60, Instagram 30, others none. The caption Postiz
receives is already capped; sources are in `DECISIONS-R7.md`.

| | Length | Size | Caption | Title | Source |
|---|---|---|---|---|---|
| TikTok | 600 s (all creators: 3 min; some 5 or 10 min; per-account cap `max_video_post_duration_sec`) | 4 GB | **2200** (was 4000 in DJ Queue) | 90 | TikTok Content Posting API; Postiz schema |
| Instagram | 180 s (API allows 3 s–15 min; DJ Queue keeps Reels at 3 min) | 300 MB | 2200 | — | IG Graph API `ig-user/media` |
| Facebook | 90 s (Eric's choice, see above) | 4 GB | 63206 (DJ Queue keeps 2200) | — | Postiz schema |
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

**Submit ahead.** A tick step `publish` (after `render`) finds every post whose platform publishes through Postiz,
whose render is attached, and which has no live job for its current render + content hash. It uploads
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
Back to Edit, unqueue, skip, a moved day, a re-laid plan, a paused platform or switching the platform back to Manual → delete. A post
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
| `ERROR` + `error` | `failed` with the error; text mentioning copyright / rights / music / audio claims → `copyright_blocked` (loud, never auto-retried); anything else retries by itself unless a retry can't help (below); then the existing "fixed → re-queue next day" rules apply |
| missing from the list (deleted in Postiz) | the job is closed and the post falls back to Manual (the Calendar) with a loud note |

`error` is curated by Postiz (the platform's message when it is a known "bad body" error, otherwise null); null on
`ERROR` reads "Postiz reported an error (no details)".

**Failed posts retry by themselves** (`PostizRetry.swift`, DECISIONS-R9.md). Eric never audits a failure a retry can fix.
An `ERROR` with a release link or id, `missing` included, counts as published on every platform: the platform has the
post and a later step failed, so it's never sent again. Any other `ERROR` retries unless it's on the veto list. Unknown
and empty errors retry. That's an accepted risk off YouTube: a failure after the platform took the post may carry no id,
and then a retry double-posts (DECISIONS-R9.md #35). The veto list:

- copyright, always, on this post or any job of the clip + platform (`copyright_blocked`, never retried);
- policy, rights, account and paid-limit words (violates, DMCA, Content ID, trademark, licensed, song, sound, Community
  Standards, flagged, ban, suspended, restricted, disabled, spam, upgrade, plan, subscription, storage, …);
- what the same post would hit again: too long, too large, format, codec, aspect ratio, validation (invalid, missing,
  required, bad request, 400, 413), a bare 403;
- a platform that says it has the post or may have, in any wording (already, duplicate, published, posted, live,
  permalink, created but, even "could not be posted").

Platform codes count as words: `duration_check_failed` and `FileSizeExceeded` both match. "Exceeds" vetoes a size, never
a rate or a quota.

Round 22 reads two kinds before the veto (`PostizService.classify`), unless a policy word is there too:

- first, a size, length, type or format word (too large, exceeds, duration, format, codec, file type, …) always stays;
- **media** (a media word: media, file, url, upload, download, fetch; and a "gone" word: expired, not found, 404, an
  invalid url or link, couldn't be retrieved/fetched): Postiz couldn't get the file. It retries on every platform on the
  usual backoff, and the retry uploads the media again. On YouTube only wording about fetching the source media counts,
  never a status, processing, response or after-upload step;
- **sign-in**, read narrowly (tokens, OAuth, invalid_grant, re-authorize, reconnect, an expired login or session, 401,
  unauthorized, refreshNeeded, a disabled channel; never a bare permission, refresh or "disabled"): the channel's login.
  Its posts wait for the channel (below, **Sign-in**).

YouTube keeps its guard: otherwise only the upload quota retries ("daily upload quota" / `defaultVideoInsertPerDayPerProject`,
and not with a thumbnail or an uploaded video in the message), because any other YouTube error may come after the video
exists and a retry would double-post. Those say so in the message and stay with Eric.

**When.** A retryable failure stores its next-retry time at once (kv `postiz.autoRetry.<clip>#<platform>#v<N>`), counted
from when it happened (the job's `remoteDate`), not from when the Mac noticed:

| Retry | Time after the failure |
|---|---|
| 1st | +1 h |
| 2nd | +6 h |
| 3rd, 4th, … (no end) | the platform's next slot time from Settings at least an hour after the failure |

There is no cap (round 22): a retryable failure re-queues until the post goes out. A failure an older build gave up on
after five tries (its message ends in "automatic retries used up…") re-queues by itself, and the note comes off.

The YouTube quota skips those: every try goes to YouTube's next slot time from Settings that is at least 30 minutes after
the next midnight Pacific following the failure, and an hour after the failure (§5a). A retry never lands within `retryStaggerHours` of another post on the platform that went out or still will (a
failed or skipped post doesn't count, so +1 h isn't pushed away from its own failure). A quota retry moves earlier if it
must, down to 30 minutes after the reset; any other moves later.

**Fresh media.** Every automatic retry uploads its media again (a cached upload made before the retry is ignored), and
any cached upload older than three days is uploaded again at create. If Postiz refuses a create over its media while a
cached upload was used, the cache goes and the next pass uploads and creates again, once, with no refusal, fallback or
notification; a second refusal with fresh media is a normal refusal.

**Ahead of time.** The sync step that reads the `ERROR` makes the new attempt in the same transaction, through
`PostActions.fixed`, with `scheduledAt` = that time. The publish step submits it, so Postiz sends it with the Mac off. If
the Mac slept through the time, the attempt is made on wake and goes out at now + 3 min. An attempt the Mac couldn't
submit in time never goes overdue and never lands on the Calendar as a task: the publish step moves it to now + 3 min (past the gap). A
400 on create or a copy deleted in Postiz still hands it to the Calendar, as for any post.

**No audit.** A post with a retry coming isn't in `problems()`: no alert, no red badge, no Doctor error. The Calendar, Posts,
the inspector and the menu bar read "Retrying Thu 8:00 am" (`PostizDisplayState.retrying`): one calm chip, no try count,
no error text; the inspector keeps the error behind Details. A vetoed failure, or a retry ruled out later (published,
copyright, platform skipped in the editor) are loud: Failed, alert, Fixed.

**Sign-in.** A sign-in error, or a channel Postiz lists as `disabled` or `refreshNeeded`, opens a wait for that platform
(kv `postiz.signIn.<platform>`). It is one item for Eric, "Reconnect TikTok in Postiz · 3 posts wait" (Posts → Problems,
the attention card, the menu bar, `djq posts --problems`, `djq status`, Doctor `postiz.sign_in`), and one notification per
platform per outage (`postiz.signIn:<platform>:<since>`, whose action opens Postiz). Its posts don't fall back to Manual
and don't each show a failure: nothing goes to Postiz on that channel, a post past its time is never missed, and a
failure's retry waits ("Waits for sign-in"). It ends when the channel list (read every 30 minutes during an outage) shows
the channel healthy, or when a post goes out on it; with no word from the list, one post is tried every 6 hours. A create
refused with sign-in wording is a wait only when the list, read again then, flags the channel. For a day after a wait
ends, posts whose time passed meanwhile go to Postiz the stagger gap apart.

**Keeps failing.** A retry failing with the same error (not YouTube's quota) for 7 days keeps retrying and shows one calm
item, "Keeps failing on TikTok: <reason>" (Posts → Problems, one notification, Doctor `postiz.auto_retry` as a warning).

**Waiting.** Paused (all or the platform), the platform off Postiz (Manual, off, no usable channel or key), the clip sent
back to Edit, the channel's sign-in, or another job of the clip + platform open: no retry. It reads "Retry waits" with the reason,
and runs once when that ends, at now + 3 min if its time passed. An attempt already in Postiz is deleted there by the usual
pause rules and comes back the same way. Remove from queue takes the attempt out of the plan: its failure waits again,
and Send to queue brings it back without using a try. Doctor warns (`postiz.auto_retry`) when a retry waits on a setting,
because a platform left on Manual never brings it back. A day past its time a waiting retry sends one calm note and keeps
waiting (`postiz.retryWaits:<post>`; none for a sign-in wait, whose one item says it). An attempt nothing stops that still can't be sent (the clip went invalid) goes back
to Eric after a day plus about an hour awake: it stops being a retry and goes overdue, with the reason. Scheduled → Queue
is Eric taking the clip out, so no retry: a failure still waiting reads "Unscheduled". Removing the day takes its automatic
attempt too. Mark posted on a failed row skips
its live attempt, and the publish step deletes that from Postiz.

Eric's Fixed works on a failure whose retry waits, and that attempt replaces the retry. Once the retry's attempt exists,
the failure is handled and Fixed refuses, so there's never a second attempt. There is no limit on retries per clip +
platform + version. It never happens once a job of the clip + platform was published or closed
in the TikTok inbox. A retry of a test-run post stays a test run (the attempt's id is kept in the kv row and `submit`
forces test mode for it), even after Test run is turned off. Doctor (`postiz.auto_retry`) and `djq postiz status` list
every retry with its time or what it waits for. Manual posts never retry by themselves.

The quota error that started this is Postiz's shared Google project (`defaultVideoInsertPerDayPerProject`), not Eric's
channel (§5a).

**Missed slots.** A Postiz post isn't "missed" while Postiz still holds it: the overdue/shift logic applies only to
manual posts and to Postiz posts that never got a job (they fall back to the Calendar). Eric's `fixed` makes a new
attempt the next day, which the publish step submits again. An automatic retry has its own time (above) and is never missed.

**Fallback.** Per platform: no key, an invalid key, no mapped channel or a create that fails validation → that platform's
post goes to the Calendar to post by hand, with the reason. A channel that needs signing in again doesn't fall back
(round 22): its posts wait for it (**Sign-in**). Manual never goes away.

**Budget.** All calls share the 25-per-hour budget. Order: deletes, creates for the soonest slots, sync, analytics.
A week of clips on 6 platforms is 6–7 uploads + 42 creates, so it spreads over about two hours; the render horizon
(7 days) leaves plenty of time. The calendar is filled 30 days ahead (round 13), but nothing goes to Postiz beyond the
render horizon. A plan that re-lays (posts/day or Queue sort changed) cancels and re-creates what moved, in the same budget;
a slot with a post less than an hour away stays where it is, and nothing is created for a clip + platform until the delete
of its earlier copy is confirmed.

## 5a. YouTube's quota and the quiet window

Postiz support, 2026-11-05: YouTube uploads share one Postiz-wide quota. It resets at 07:00 UTC and is often used up hours
before. They said to avoid 02:00–07:00 UTC, and that a failed upload never reached YouTube, so a retry can't duplicate it.

Round 22 correction: 07:00 UTC was the summer time of the real reset, midnight Pacific. From 1 November (PST) it is 08:00
UTC, and every quota retry at 07:30 UTC landed at 11:30 pm Pacific, on the day whose quota was gone: a post failed six
times while the regular 8:00 am New York slot went out daily. The window now follows `America/Los_Angeles`.

Our own results: quota failures at 15:00, 16:27 and 18:00 New York on three days; success at 05:00 and 08:00 New York. The
safe time is the morning after the reset, not just outside their window.

| What | Rule |
|---|---|
| Reset | Midnight Pacific (`America/Los_Angeles`): 07:00 UTC in summer, 08:00 UTC in winter. |
| Quiet window | From 7 pm up to midnight Pacific, nothing on YouTube is scheduled. A time that lands there moves to 00:30 Pacific (`YouTubeWindow.clear`, the one helper). In New York that's 10 pm–3 am all year, moved to 3:30 am (Settings says it in Eric's clock). Other platforms don't change. A shift keeps a moved post on 00:30 Pacific across both DST changes. |
| Quota retry | YouTube's next slot time from Settings, at least 30 minutes after the next Pacific midnight and an hour after the failure, then the usual stagger. |
| Where it applies | Slot times, staggered extras, retries, a plan shift, and every create (`remoteDate`), so a late slot or Post now on YouTube inside the window waits for 00:30 Pacific too. A retry whose time passed while the Mac slept goes at now + 3 min, unless that's inside the window. Posts stored under the old rule that now sit in the window (07:30 UTC in winter) are moved out by the engine's plan step. |

`djq slot youtube 08:00` puts the slot there and moves the unposted future posts with it (`PostActions.setSlot`, undo with
`djq bulk undo`). The publish step replaces the copies Postiz holds, as for any move, two calls each; when that's more than
the hour's budget has left, the command says so and the last posts catch up within the hour. Pinned posts, posts within
30 minutes of going out (the undo needs that lead) and posts whose new time is that close or has passed stay where they
are, and the command names each one. An automatic retry stays too, unless a post lands within the stagger of it, and then
it moves earlier, down to the reset. The Settings control changes only the slot; `djq slot` at the same time then brings
the existing posts onto it.

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
- **Handed to the Calendar**: a post whose manual "due" notice went out (or that was missed, posted now or shifted by hand)
  stays Manual for good, across re-renders, even when the key or channel comes back (Eric may already have posted
  it); only a reset sends it through Postiz again. Later posts follow the platform's route.
- **Test-run drafts** an hour past their slot are notified (release, or post by hand).
  *sync* lists posts over the open jobs' window (10 min while hot, else hourly), maps §5, probes a refused key hourly,
  refreshes the channel list every 6 h and pulls analytics daily.
- **Due / missed**: a post with an open job, or routed to Postiz with no final job, gets no manual "due" notification;
  a post with an open job is never overdue or shifted. Everything else is exactly as before (the Calendar).
- **A create whose outcome is unknown** (5xx, timeout, an unreadable 2xx, a database error while recording it): the
  claim stays and blocks the lineage. The sync step adopts the one Postiz post with the same channel, the exact date
  sent and the exact caption (two open jobs on one channel never share a minute). None or several → unconfirmed
  (`isUnconfirmed`): a critical notice (daily), Doctor `postiz.create_unknown`, and nothing is sent again until Eric
  checks the Postiz calendar and decides, offline: `resolveUnconfirmed(postId:inPostiz:)` (`djq postiz resolve
  --in-postiz | --not-in-postiz`). A request that never left the Mac (`notSent`) and a claim whose create was never
  sent are released at once / after 10 min. If the platform is switched off Postiz meanwhile, the post reaches the Calendar
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
