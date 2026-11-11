---
name: dj-queue-doctor
description: Diagnose and safely fix DJ Queue (Eric's local Mac app that plans and tracks DJ Lovd short-form posts). Use when Eric pastes a DJ Queue Doctor report, asks why a post/render/plan is wrong, or asks to check the queue. Runs `djq doctor --json`, explains each finding and applies only the safe fix for its id. Never touches source footage.
---

# DJ Queue Doctor

DJ Queue plans which DJ Lovd short-form videos post where and when, renders the final files and tracks every
platform post (TikTok, Instagram, Facebook, YouTube Shorts, Threads, X). Each platform publishes either
**Manual** (Eric posts from the Calendar, then marks it posted with its URL; the default) or through **Postiz** (round 6:
the engine schedules the render in Postiz ahead of the slot and reads the live link back; a Postiz problem sends that
platform's posts back to the Calendar to post by hand). Refer to Eric as they/them.

## Never

- Never modify, move, rename or delete anything in a session's `Video/`, `Audio/`, `Other/` or `Clips/`
  folders, or in CapCut projects. Never edit `videos.json` ids.
- Never edit `queue.sqlite` by hand while the app is running, and never delete rows. Use `djq` commands
  (they log history and tell the app to refresh).
- Never post to a platform, never run `launchctl` (except `djq agent status`), never install/load the
  LaunchAgent without Eric saying so.
- Copyright problems are Eric's call (re-upload / skip / accept). Don't fight or retry them.
- Postiz: never schedule, publish or release anything, never switch a platform to Postiz, change channels or turn
  the test run off without Eric's explicit OK (`djq postiz … --yes` is Eric's switch, not yours). Never read, print or
  ask for the Postiz API key; it lives in the Keychain and only Eric enters it (Settings → Publishing). Read-only:
  `djq postiz status`, `djq postiz channels`, any `--dry-run`.

For reading/changing clips (titles, suggestions, text, captions, bulk edits, undo) use the
`dj-queue-agent` skill (`skills/dj-queue-agent/SKILL.md`).

## Run it

```sh
djq doctor --json     # machine-readable; exit code 2 when there are errors
djq doctor            # the same as Markdown (what Eric pastes)
djq status            # how far it's scheduled, today's posts, problems, engine heartbeat
djq today | djq posts --problems | djq week [YYYY-MM-DD] | djq queue | djq health
djq schedule --dry-run  # what the scheduler would do now (`djq schedule` runs it once)
djq postiz status     # Postiz: key/connection, budget, test run, channel + route per platform
                      # (exit 0 = ready, 2 = not ready, 3 = --offline and not checked)
djq doctor --live     # the same checks after one live Postiz call (refreshes channels and the key state)
```

Doctor itself never calls Postiz: its `postiz.*` checks read stored state (settings, the jobs table, the cached
channel list, the "key refused" flag). Use `--live` only when a fresh answer matters; it spends one of the 25
calls per hour.

If `djq` isn't on PATH, the app isn't installed. A dev build (`swift build`, then `.build/debug/djq`) refuses to start
without `DJQ_ROOT` (the "DJ Video" folder) and `DJQ_HOME` (app support + logs), so it only reads a development copy.
Ids can be shortened to a unique prefix.

Each finding: `id`, `severity` (error / warning / info), `title`, `detail`, `where` (ids, paths), `fix`.
Work through errors first. Re-run `djq doctor` after each fix.

## Where things are

| What | Path |
|---|---|
| Database (single source of truth) | `~/Library/Application Support/DJ Queue/queue.sqlite` (WAL) |
| Title formatter (tag → title suggestions, upstream) | `scripts/prefill_titles.py` in the repo — the app itself never derives text (see `docs/metadata.md`) |
| Engine log (rotated, 5 MB × 3) | `~/Library/Logs/DJ Queue/engine.log` |
| Daily DB backups (keep 14) | `~/Movies/DJ Video/_app/backups/queue-YYYY-MM-DD.sqlite` |
| Sessions | `~/Movies/DJ Video/Sessions/<YYYY-MM-DD – name>/` (`videos.json` = intake source) |
| Final renders | `<session>/Ready to Post/Shortform/<video> – v<N>[ – <platform>].mp4` → moved to `Posted/Shortform/` when every post using it is done |
| Long-form | `<session>/Ready to Post/Longform/` → `Posted/Longform/` on `djq longform-posted` |
| LaunchAgent | `~/Library/LaunchAgents/com.djlovd.queue.engine.plist` (runs the app with `--agent`) |
| Export tools | `~/Movies/DJ Video/_tools/` (`pair_markers.py`, `export_clips.py`, `tag.py`) |

## How the engine behaves (so fixes don't fight it)

- Ticks every minute while the Mac is awake (and on wake / any `djq` write): intake → plan → missed →
  due → platform checks → alerts → render (one new render per tick) → move → heartbeat → backup. `djq tick` runs one by hand.
- A clip in the Queue is approved: nothing else is asked. The plan step gives every Queue clip a day by itself, up to 30
  days ahead, in Queue order, and creates its posts at once. A position today needs 30 minutes before its first platform.
  Only Eric's Send to Queue moves a clip Edit → Queue, even when it has nothing to fix.
- Each clip goes to every enabled platform at staggered times
  (FB 12:30, Threads 1:30, YT 3:00, X 5:00, IG 6:00, TikTok 7:00 pm, New York).
- The plan re-lays only when posts/day or the Queue sort changes, once. Pinned days never move.
- Late < 6 h (or still the same day) → stays due. A whole day missed → `overdue`, and that platform's
  remaining plan moves later by the days missed (never double-posts).
- A fix, re-upload or repost creates a new attempt; history is never rewritten.

## Fix for every finding id

| id | Safe fix |
|---|---|
| `manifest.parse` | `videos.json` doesn't parse. Prefer re-running `_tools/export_clips.py <session> <part> <draft_info.json>` (rewrites it, keeps ids). If you hand-fix the JSON, change only the broken syntax. Then `djq intake`. |
| `manifest.duplicateIds` | Two entries share an id. Keep the id on the entry that already has posts (`djq posts`); give the other a fresh UUID in `videos.json`; `djq intake`. |
| `files.untracked` | A clip in `Clips/` isn't in any `videos.json`. Ask Eric: export it with `export_clips.py`, or leave it (ignored). Don't move or delete it. |
| `files.missing` | Ask Eric to put the file back or undo the rename; `djq intake` relinks by fingerprint (any session). If it's gone for good: `djq exclude <video>` and, if it was planned, `djq stage <video> back`. |
| `photos.missing` | A photo post's file is gone from `Photos/Originals/<post id>/` (DJ Queue's own copy). Ask Eric to put it back at the path shown; `djq intake` brings the post back. If the photo is gone for good, Eric removes it from the post in the editor, or `djq exclude <video>`. Don't rename or replace files under `Photos/Originals/`. |
| `files.relinked` | Info only. |
| `files.duration` | File length ≠ `videos.json`. Re-export that clip with `export_clips.py --only N`, `djq intake`; the engine re-renders automatically when the edit/hash changes. |
| `plan.notReady` | A scheduled clip lost its crop/text/caption, its file, or was excluded (it stays on its day and shows the problem). Eric finishes it in the app, or takes it off the calendar: `djq stage <video> back` holds it in Edit, and the next waiting clip fills the day. |
| `plan.gaps` | Open days with clips waiting in the Queue: the scheduler should have filled them, so it looks stuck. Check the engine (`djq status`), then `djq schedule --dry-run` says what it would do and why not; `djq schedule` runs it once. The avoid-overlap setting can also leave a day open. |
| `plan.nowhereToPost` | Info: a Queue clip has history or a skip on every platform, so it never gets a day and isn't counted as waiting. Nothing to do unless Eric wants it out again: `djq repost <video> <platform>`, or `djq stage <video> back`. |
| `runway.queue` | Queue running low: few days scheduled and the Queue is about out. Nothing to fix in data: Eric sends clips to the Queue from Edit. Never send them on Eric's behalf. |
| `runway.total` | Eric needs to score videos (`djq queue` shows "in Score" / "in Edit"), finish edits, or record/export a new set. Nothing to fix in data. |
| `renders.missing` | Normal if the Mac was asleep. `djq tick` (renders one per tick, due posts first) or `djq render <video> --version N [--platform P]`. |
| `renders.failed` | Read `engine.log` for the ffmpeg error. Usual causes: crop outside the frame, trim outside the file, file missing. Eric fixes the edit; then `djq render <video> --version N`. |
| `posts.overdue` | A day passed unposted; the platform's plan already moved. Ask Eric which: post it now (`djq post-now <post>`), put it in today's slot (`djq shift-plan <post>`), or skip (`djq skip <post>` — pulls the rest back). If Eric did post it: `djq posted <post> <url>`. |
| `posts.failed` | Fix the cause first. `too_long`: Eric sets a per-platform trim (editor → Trim for X) or skips the platform; the engine re-queues by itself. A post listed here has no automatic retry coming (a post with one is `postiz.auto_retry`): a veto (copyright, policy, account, or a failure a retry can't fix), retries used up, or YouTube, where any error but the upload quota may come after the video exists: Eric checks the channel first. Then `djq fixed <post>` → new attempt next day, ≥ 3 h from that day's post. Wrongly reported: `djq reset <post>`. |
| `posts.copyright` | Eric decides: `djq copyright <post> reupload [version]` (new attempt next day), `skip` (this platform only), or `accept`. Never automatic. Other platforms are unaffected. |
| `platform.limits` | A scored video is longer than a platform allows, so it stays out of the queue. Eric adds a per-platform trim or skips that platform in the editor. Never auto-cut. |
| `engine.launchAgent` | Ask Eric to run `djq agent install --app ~/Applications/DJ\ Queue.app --load` (or Settings → Start at login). Don't load it yourself. |
| `engine.heartbeat` | The engine hasn't ticked recently: open DJ Queue / check `djq agent status`; `djq tick` runs one tick. Gaps while the Mac was off are normal (see `djq health`). |
| `db.integrity` | Stop and involve Eric. (1) Quit DJ Queue and stop the agent (Eric: `launchctl bootout gui/$(id -u)/com.djlovd.queue.engine`); make sure no `djq` is running. (2) In `~/Library/Application Support/DJ Queue/`, move `queue.sqlite`, `queue.sqlite-wal` and `queue.sqlite-shm` together into a new `broken-<date>/` folder (never delete them — a stale `-wal` left behind would replay onto the restored file). (3) Copy the newest `~/Movies/DJ Video/_app/backups/queue-YYYY-MM-DD.sqlite` to `queue.sqlite`. (4) Reopen the app; run `djq doctor`. Changes since that backup are lost — tell Eric which day it's from. |
| `db.backup` | `djq tick` makes today's backup if it's missing. If it keeps failing, check `_app/backups/` is writable. |
| `disk.free` | Tell Eric (< 50 GB). Suggest emptying Trash / archiving old raw footage. Don't delete anything yourself. Posted renders are kept by default (Settings → Cleanup). |
| `tools.ffmpeg` | Eric: `brew install ffmpeg`. |
| `tools.versions` | Info only. |
| `system.timezone` | Info for Eric; slots stay in the Settings time zone (America/New_York). |
| `capcut.markers` | Info: marker drift isn't checked automatically. By hand: run `pair_markers.py <draft_info.json>` and compare with `videos.json` `marked_start`/`marked_end`; if they moved, re-export that clip. |
| `autoupdate.watcher` | Auto-update is on but its watcher isn't loaded, so commits to main won't install. Ask Eric to run `djq autoupdate on` (reinstalls and loads it; installed app only). |
| `autoupdate.blocked` | The newest commit on main failed the gate (build or tests) and wasn't installed; the reason names the failing tests. `djq autoupdate log --run` shows the output. The fix is a code change on main (a session's job), never a data change; the watcher retries on the next commit. |
| `autoupdate.failed` | Two cases (`djq autoupdate status` / `log` say which). The last run failed before installing anything: `djq autoupdate run` retries. Or a build failed its checks after install and is **still installed** (its database migration couldn't safely be undone): Eric decides between `djq autoupdate rollback --restore-db` (loses changes since that backup) and waiting for a fixed commit. Never run either yourself. |
| `autoupdate.ready` | Info: an update has waited > 24 h for the main window to close. Eric clicks Restart & update in the banner (it waits for renders) or closes the window. |
| `autoupdate.off` | Info: Eric turned auto-update off. Leave it; `djq autoupdate on` turns it back on only if Eric asks. |
| `postiz.not_connected` | Info "Postiz not in use" while every platform is Manual: nothing to do. Warning when a platform is set to Postiz but no key is saved (its posts go to the Calendar), or with `--live` when Postiz didn't answer: tell Eric; only Eric adds the key in Settings → Publishing. For "didn't answer", check the network and re-run `djq doctor --live` later; posts Postiz already holds still go out. |
| `postiz.key_invalid` | Postiz refused the key (401/403); posts set to Postiz go to the Calendar and DJ Queue re-checks hourly. Tell Eric to save a valid key in Settings → Publishing (Postiz → Settings → Public API). Never handle the key yourself. |
| `postiz.mapping_missing` | A platform set to Postiz has no channel, or its channel isn't in Postiz any more (error when it has posts in the next 48 h). Show Eric `djq postiz map --dry-run` (auto-maps by provider; ambiguous or missing providers are listed for Eric, never guessed). Eric runs `djq postiz map` or `djq postiz map <platform> "<channel>"`. |
| `postiz.channel_disabled` | The mapped channel is disabled or its login expired in Postiz; its posts go to the Calendar. Eric reconnects it in Postiz; then `djq postiz channels` refreshes the list and the error clears. |
| `postiz.stuck` | Postiz still says QUEUE an hour after the slot. Run `djq postiz sync` (or wait for the engine's sync). If it stays, Eric checks the Postiz calendar: if Postiz can't post it, Eric deletes it there and DJ Queue puts it on the Calendar. Never post it by hand while Postiz still holds it (double post). |
| `postiz.link_missing` | Postiz published but the platform's post id came back missing, so the post has no link. `djq postiz link <post>` lists the platform's recent posts; pick the right one with Eric and `djq postiz link <post> <url>`. |
| `postiz.rate_limited` | Info: Postiz answered 429 (no calls for 15 min) or the 25-call hour is used up. Nothing to do; calls resume by themselves (deletes first, then the soonest creates). Don't loop `sync`. |
| `postiz.fallback` | Posts set to Postiz that go to the Calendar instead, each with its reason. Fix the reason first (key, channel: the other `postiz.*` findings). A post Postiz refused, one deleted in Postiz, or a test-run TikTok in the inbox stays manual: Eric posts it from the Calendar and marks it posted (`djq posted <post> <url>`). `djq reset <post>` lets Postiz try a refused or deleted one again: Eric's call. |
| `postiz.test_mode` | Info: the test run is on (TikTok → inbox, YouTube → unlisted, others → Postiz drafts), or test posts are still in Postiz. Remind Eric when the test is done; turning it off is `djq postiz test-mode off --yes` (Eric only: posts sent from then on go out for real; posts already in Postiz keep their test-run form). |
| `postiz.create_unknown` | A create was sent but no answer came back and the sync couldn't find it, so DJ Queue doesn't know whether Postiz has the post; nothing new is sent for it meanwhile. Ask Eric to check the Postiz calendar (that channel, that time) first. `djq postiz resolve <post>` makes one live look and adopts only an exact single match; otherwise it exits 2 and Eric answers: `djq postiz resolve <post> --in-postiz` (Postiz has it: recorded posted, never sent again; add the link with `djq postiz link`) or `--not-in-postiz` (on the Calendar to post by hand). Never guess which, and never post it by hand before Eric answered. |
| `postiz.delete_pending` | DJ Queue couldn't remove a post from Postiz after 3 tries; it keeps retrying and creates nothing new for that post. If the post must not go out, Eric deletes it in the Postiz calendar. |
| `postiz.auto_retry` | Info: a failed post is retrying by itself, up to 5 times per clip + platform + version, each line with its time ("Retrying Thu 8:00 am (try 2 of 5)") or what it waits for. Nothing to do, and never `djq fixed` it: that takes the retry's place. A pause, or a clip sent back to Edit, only delays it; a day late Eric gets one alert. **Warning** when it waits on a setting (the platform is on Manual or off, no usable channel or key): tell Eric, who sets it back in Settings → Publishing or posts it by hand. Don't change it for Eric. After 5 tries it's `posts.failed`. |
| `manifest`, `engine`, `db`, `runway`, `tools`, `posts.problems`, `autoupdate`, `postiz` | Group names that appear under "Passed". |

## Other safe commands

`djq reset <post>` (undo a wrong Mark posted / problem), `djq pause` / `djq resume [platform]` (kill switch),
`djq push <YYYY-MM-DD> <days>` (push the whole plan), `djq post-today <video>`, `djq repost <video> <platform>`
(needs the next version, 14-day cooldown), `djq longform-posted <video> <youtube-url>`.
