---
name: dj-queue-doctor
description: Diagnose and safely fix DJ Queue (Eric's local Mac app that plans and tracks DJ Lovd short-form posts). Use when Eric pastes a DJ Queue Doctor report, asks why a post/render/plan is wrong, or asks to check the queue. Runs `djq doctor --json`, explains each finding and applies only the safe fix for its id. Never touches source footage.
---

# DJ Queue Doctor

DJ Queue plans which DJ Lovd short-form videos post where and when, renders the final files and tracks every
platform post (TikTok, Instagram, Facebook, YouTube Shorts, Threads, X). Phase 1 publishing is manual: Eric
posts, then marks each post done with its URL. Refer to Eric as they/them.

## Never

- Never modify, move, rename or delete anything in a session's `Video/`, `Audio/`, `Other/` or `Clips/`
  folders, or in CapCut projects. Never edit `videos.json` ids.
- Never edit `queue.sqlite` by hand while the app is running, and never delete rows. Use `djq` commands
  (they log history and tell the app to refresh).
- Never post to a platform, never run `launchctl` (except `djq agent status`), never install/load the
  LaunchAgent without Eric saying so.
- Copyright problems are Eric's call (re-upload / skip / accept). Don't fight or retry them.

For reading/changing clips (titles, suggestions, text, captions, bulk edits, undo) use the
`dj-queue-agent` skill (`skills/dj-queue-agent/SKILL.md`).

## Run it

```sh
djq doctor --json     # machine-readable; exit code 2 when there are errors
djq doctor            # the same as Markdown (what Eric pastes)
djq status            # runway, today's posts, problems, engine heartbeat
djq today | djq posts --problems | djq week [YYYY-MM-DD] | djq queue | djq health
```

If `djq` isn't on PATH, build it from the repo
(`swift build`, then `.build/debug/djq`). Ids can be shortened to a unique prefix.
For a development copy set `DJQ_ROOT` (the "DJ Video" folder) and `DJQ_HOME` (app support + logs).

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
- Only approved weeks have posts. One video per day goes to every enabled platform at staggered times
  (FB 12:30, Threads 1:30, YT 3:00, X 5:00, IG 6:00, TikTok 7:00 pm, New York).
- Late < 6 h (or still the same day) → stays due. A whole day missed → `overdue`, and that platform's
  remaining plan moves later by the days missed (never double-posts).
- A fix, re-upload or repost creates a new attempt; history is never rewritten.

## Fix for every finding id

| id | Safe fix |
|---|---|
| `manifest.parse` | `videos.json` doesn't parse. Prefer re-running `_tools/export_clips.py <session> <part> <draft_info.json>` (rewrites it, keeps ids). If you hand-fix the JSON, change only the broken syntax. Then `djq intake`. |
| `manifest.duplicateIds` | Two entries share an id. Keep the id on the entry that already has posts (`djq posts`); give the other a fresh UUID in `videos.json`; `djq intake`. |
| `files.untracked` | A clip in `Clips/` isn't in any `videos.json`. Ask Eric: export it with `export_clips.py`, or leave it (ignored). Don't move or delete it. |
| `files.missing` | Ask Eric to put the file back or undo the rename; `djq intake` relinks by fingerprint (any session). If it's gone for good: `djq exclude <video>` and, if it was planned, `djq remove-slot <slot>` or `djq skip-next <video>`. |
| `files.relinked` | Info only. |
| `files.duration` | File length ≠ `videos.json`. Re-export that clip with `export_clips.py --only N`, `djq intake`; the engine re-renders automatically when the edit/hash changes. |
| `plan.notReady` | A planned video lost its crop/text/caption (or was excluded). Eric finishes the edit in the app, or take it out: `djq remove-slot <slot>` then `djq pin <ready-video> <date>` (`skip-next` only defers it a slot). |
| `plan.gaps` | An approved day has no post. `djq pin <ready-video> <YYYY-MM-DD>` (see `djq queue`), or `djq week --rebuild <monday>` then Eric approves. |
| `runway.approved` | Show Eric `djq week <next-monday>` (propose with `--propose`); Eric approves (`--approve`). Don't approve on their behalf unless told. |
| `runway.total` | Eric needs to score videos (`djq queue` shows "to score"), finish edits, or record/export a new set. Nothing to fix in data. |
| `renders.missing` | Normal if the Mac was asleep. `djq tick` (renders one per tick, due posts first) or `djq render <video> --version N [--platform P]`. |
| `renders.failed` | Read `engine.log` for the ffmpeg error. Usual causes: crop outside the frame, trim outside the file, file missing. Eric fixes the edit; then `djq render <video> --version N`. |
| `posts.overdue` | A day passed unposted; the platform's plan already moved. Ask Eric which: post it now (`djq post-now <post>`), put it in today's slot (`djq shift-plan <post>`), or skip (`djq skip <post>` — pulls the rest back). If Eric did post it: `djq posted <post> <url>`. |
| `posts.failed` | Fix the cause first. `too_long`: Eric sets a per-platform trim (editor → Trim for X) or skips the platform; the engine re-queues by itself. Otherwise `djq fixed <post>` → new attempt next day, ≥ 3 h from that day's post. Wrongly reported: `djq reset <post>`. |
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
| `manifest`, `engine`, `db`, `runway`, `tools`, `posts.problems` | Group names that appear under "Passed". |

## Other safe commands

`djq reset <post>` (undo a wrong Mark posted / problem), `djq pause` / `djq resume [platform]` (kill switch),
`djq push <YYYY-MM-DD> <days>` (push the whole plan), `djq post-today <video>`, `djq repost <video> <platform>`
(needs the next version, 14-day cooldown), `djq longform-posted <video> <youtube-url>`.
