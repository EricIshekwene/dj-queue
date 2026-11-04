---
name: dj-queue-agent
description: Read and change DJ Queue clips for Eric through the `djq` CLI — titles, title suggestions (song names), overlay text, captions, kind, scores, new-clip defaults, bulk edits with undo and Postiz status, previews and drafts — and answer DJ Queue "Ask an agent" prompts. Use when Eric asks to look up song names for clips, fill titles, fix captions, edit many clips at once, or pastes a prompt that ends with `djq suggest --file`. Never writes SQLite directly; never touches source footage.
---

# DJ Queue agent guide

DJ Queue (Eric's Mac app for DJ Lovd short-form posts) is a **UI over scripts**: the app never guesses text. Song
names / titles come from metadata that agents provide; Eric picks. Refer to Eric as they/them. For diagnosing
problems use the `dj-queue-doctor` skill.

## Never

- Never open `queue.sqlite` with sqlite3 or any other writer. Every change goes through `djq` (it validates, logs
  history and signals the app to refresh).
- Never modify, move or delete session source files (`Video/`, `Audio/`, `Other/`, `Clips/`, CapCut projects) or
  `videos.json` ids.
- Suggestions are your default write. Set a **title** (`djq title`) only when Eric asks you to choose.
- Don't post, approve weeks or change Settings unless Eric says so.
- **Postiz: never schedule or publish without Eric's explicit OK.** On your own you may only read
  (`djq postiz status`, `djq postiz channels`) and preview (`--dry-run`, `djq postiz test <video> --dry-run`) or make
  Postiz **drafts** (`djq postiz test <video> --draft`, nothing reaches a platform). Never read, print or ask for the
  Postiz API key (Keychain only; Eric enters it in Settings → Publishing).

`djq` is on PATH when the app is installed (else `swift build` in the repo → `.build/debug/djq`). Dev copies:
`DJQ_ROOT` (the "DJ Video" folder) + `DJQ_HOME`. Ids can be shortened to a unique prefix.

## Read (JSON)

```sh
djq videos --json [--stage S] [--state S]   # stage: score edit queue scheduled posted
                                            # state (stored): needs_edit ready planned posting posted partial excluded missing_file | unscored scored needs-edit all
djq video <id> --json           # everything about one clip
djq week --json [YYYY-MM-DD]    # a week's plan: days → slots → posts
djq posts --json [--problems]   # last 7 days on (or unresolved problems)
djq defaults --json             # Settings → New clip defaults
djq bulk batches --json         # bulk journal (for undo)
```

`videos` items: `id, display_name, title, title_source, raw_tag, name, session, type, kind, state, score, excluded,
missing, part, duration, marked_start, marked_end, audio, file, suggestion_count, text_suggestion_count, needs_title_help, issues[],
held_in_edit, stage, reasons[]`. `stage` is what Eric sees (`score`/`edit`/`queue`/`scheduled`/`posted`, null for
long-form, excluded, or unscored with a missing file); `reasons` are the Edit reason chips ("No crop", "Too long for
X", "File missing", "Sent back from Queue", …). `state` keeps its stored values for compatibility (`needs_edit` =
Edit, `ready` = Queue), but say the stage name to Eric — never "ready", "needs edit" or "unready".
`held_in_edit`: sent back to Edit from the Queue ("Back to Edit"); it stays in Edit with the reason "Sent back from
Queue" until it's sent to the Queue again.

`video` adds: `title_tracks, title_suggestions[{id,text,tracks,confidence,source,origin}]`, `text_suggestions` (same
shape, for the text on the video), `edit` (stored overrides
only — absent/null fields follow the defaults), `resolved_edit` (effective values + `defaulted[]`), `versions`,
`resolved_v1` (effective text/caption settings + `defaulted[]`), `captions{platform: text}`, `youtube_title`,
`issues[{kind, platform, message, count, limit, countWithoutHashtags}]`, `plan`, `posts`.

## Write

```sh
djq suggest --file answer.json                 # many clips: [{"video_id": "…", "title_suggestions": [ … ], "text_suggestions": [ … ]}]
djq suggest <video> --file one.json            # one clip ({"title_suggestions": [ … ], "text_suggestions": [ … ]} or a bare
                                               # array of title suggestions); --file - reads stdin
djq title <video> "Song One x Song Two" | --clear
djq text <video> "Overlay text" | --none | --default [--version N]
djq caption <video> "Caption" | --default [--platform P] [--version N]
djq kind <video> "dj vid"|talking
djq score <video> <0-100|clear>
```

Suggestion fields (same as `videos.json` `title_suggestions` / `text_suggestions`, see `docs/metadata.md`): `text`
(required), `tracks[{title, artist?}]`, `confidence` 0…1, `source`. Re-sending the same `text` + `source` updates it.
Either list may be left out.

- **Title** (`title_suggestions`): the song names on one line, joined with `x` (no arrows, no emoji). It names the
  clip on every screen and in search. Eric picks it.
- **Text on the video** (`text_suggestions`): what goes on screen. Usually the song names laid out on lines with `x`
  alone between them (`"Song One\nx\nSong Two"`); short pairs may stay on one line. A hook ("Piano is sweet!!") is
  a separate, lower-confidence suggestion. Eric taps one in the editor's Text section; it becomes that version's text.
  Use `djq text` only when Eric asks you to set it.

## Stages: move a clip back or forward

A short clip's stage: **Score** (no score) → **Edit** (scored, something still missing, sent back, or its file is
missing) → **Queue** (nothing missing; a day in a proposed week still counts) → **Scheduled** (in an approved week,
not fully posted) → **Posted**. Readiness IS the stage: the Queue only ever holds clips with nothing missing. When a
Queue clip stops being valid (crop cleared, a platform limit lowered, file missing) the engine moves it to Edit by
itself on its next tick and after every `djq` write, logging "Moved to Edit: <reasons>"; it returns to the Queue
when it's valid again (unless it was sent back by hand). A Scheduled or pinned clip that becomes invalid stays on its
day and shows the problem (Doctor `plan.notReady`, "can't post" notification) — fix it or swap it. A draft-week day
whose clip left the Queue is refilled from the Queue.

```sh
djq stage <video…> [--json]                         # each clip's stage, its controls ("‹ Back to Edit" · "Schedule ›") or why not, and why it's in Edit
djq stage <video…> back|forward [--dry-run] [--json]
```

`--json` rows: `id, display_name, stage, back, forward` ("→ Edit" or why not), plus `back_title`/`forward_title`
(the app's button words: Edit "Back to Score"/"Send to Queue", Queue "Back to Edit"/"Schedule", Scheduled "Back to
Queue"/"Mark posted…"), `back_blocked`/`forward_blocked` and `reasons[]` (Edit only).

- back: Edit → Score ("Back to Score") clears the score · Queue → Edit ("Back to Edit") = `unqueue` (below) ·
  Scheduled → Queue ("Back to Queue") removes its unposted days from the plan; it goes back to the Queue (refused once
  any platform posted) · Posted: none (use `repost` / `reset`). A clip whose file is missing can't move ("File missing
  — relink it first").
- forward: Score: none (set a score with `djq score`) · Edit → Queue ("Send to Queue") clears "sent back" and confirms
  the default crop (make-ready); if anything is still missing the clip stays in Edit and the result says exactly what · Queue →
  Scheduled pins it to the next open day of this or next week (a draft week must still be approved — the note says
  so) · Scheduled → Posted: only by marking its posts posted.
- One batch each (`moves{<video id>: {from, to, note}}`, plus `unplanned` for back); undo with `djq bulk undo`.

## Back to Edit / Send to Queue (formerly "Remove from queue")

```sh
djq unqueue <video…> [--dry-run] [--json]   # Back to Edit (held there); its unposted slots/posts are removed
djq requeue <video…> [--dry-run] [--json]   # Send to Queue: clears the hold; Queue if nothing is missing, else stays in Edit
```

`unqueue` sets the clip's `held_in_edit` flag and takes it out of the plan with the planner's own rules: its slots
from today on that have nothing posted (a pinned slot loses its pin), and every post of it still in flight
(planned/rendering/rendered/due/overdue, retries and reposts too) are removed. Posted/failed/skipped posts and
history stay; other clips keep their days (nothing is reshuffled or backfilled). `--json` prints the bulk result
(`batchId, changed, skipped, summary…`, see below) plus `unplanned{<video id>: [{videoId, date, platforms[], pinned}]}`; undo it with
`djq bulk undo <batch>` (flag, slots, weeks and posts come back exactly). Both are also `djq bulk unqueue|requeue`
(with `--filter`). Only when Eric asks — `--dry-run` first and tell Eric which days would go.

## Bulk (one transaction, journaled, undoable)

```sh
djq bulk <action> [args] (--ids a,b,c | --filter F) [--dry-run] [--json]
djq bulk undo <batch> [--force]
```

Actions: `make-ready` (confirm the default crop; reports how many go to the Queue and what's still missing) · `apply-defaults
[--sections frame,trim,text,cover,caption,platforms]` (clear overrides) · `score <n|clear>` · `score-adjust <±n>` ·
`kind <k>` · `exclude` · `include` · `caption-template <id|default>` · `hashtags <set,set|default>` ·
`extra-hashtags "<#a #b>"|default` · `drop-hashtags <platform>` · `skip-platform <p>` · `unskip-platform <p>` ·
`accept-title` · `title "<t>"|--clear` · `add-to-week <date>` · `pin-consecutive <date>` · `post-today` ·
`re-render` · `unqueue` · `requeue`.

Always `--dry-run` first on more than a few clips and show Eric the summary. Every result prints its batch id;
`undo` refuses clips (or a plan) changed again since unless `--force` — don't force without Eric.

## Answering an "Ask an agent" prompt

`djq agent-prompt titles --needs-title` (or the app's *Ask an agent* button) produces a Markdown prompt listing
clips with raw tag, current title/suggestions, part, marker times on the part timeline, duration, audio source and
file path. To answer:

1. Identify the songs READ-ONLY from rekordbox (history for the set date, crates, the part timeline), tracklists,
   the clip/set recordings, and your own knowledge.
2. Write the JSON array the prompt shows (one entry per clip, `video_id` from the headings).
3. Run `djq suggest --file <that file>` and tell Eric how many clips got suggestions and which stayed uncertain.

Low certainty → still suggest, with a low `confidence` and the reason in `source`.

## Postiz (publishing, round 6)

Each platform publishes **Manual** (the default: Eric posts from Today) or through **Postiz** (the engine schedules
the render in Postiz ahead of the slot and reads the live link back; any Postiz problem sends that platform's posts
back to Today). Contract: `docs/postiz.md`. Every live call shares a budget of 25 per hour with the app, so don't
loop. Channel ids appear only with `--ids`; the key never appears anywhere.

```sh
djq postiz status [--json] [--offline] [--ids]   # key/connection (one live check unless --offline), budget, test run,
                                                 # per platform: publisher, channel (name + provider), route, posts in
                                                 # Postiz and their states, last sync. Exit 0 = connected + six mapped
djq postiz channels [--json] [--cached] [--refresh] [--ids]   # Postiz's channels + caption limit each (vs DJ Queue's)
djq postiz map --dry-run [--json]                # what auto-mapping by provider would set (instagram-standalone,
                                                 # tiktok-business, threads, facebook, x, youtube); ambiguous or missing
                                                 # providers are listed, never guessed
djq postiz test <video> --dry-run [--json]       # the six request bodies for a clip (needs a finished render), no call
djq postiz test <video> --draft                  # Postiz drafts only (OK without asking; tell Eric they're in Postiz)
djq postiz link <post>                           # a post Postiz published without a link: the platform's recent posts
djq postiz sync                                  # one sync now (asks DJ Queue's engine when it's running)
```

Only with Eric's explicit OK (they change Settings → Publishing and print exactly what changes; preview with
`--dry-run`, undo with `djq bulk undo <batch>`):

```sh
djq postiz map [--yes] | djq postiz map <platform> "<channel name>" | djq postiz map <platform> --clear
djq postiz publisher <platform|all> manual|postiz [--yes]
djq postiz test-mode on|off [--yes]              # test run: TikTok → inbox, YouTube → unlisted, others → Postiz drafts
djq postiz link <post> <url>                     # records the link (after Eric confirms which post it is)
djq postiz release <post> --yes                  # test run: a Postiz draft goes out for real at its time
```

A change that makes approved posts go out for real (a platform to Postiz with a channel, a new channel, test run
off) is refused without `--yes`. `--yes` is Eric's word, not yours: ask first, quoting what the dry run printed.
`djq postiz test` never schedules real posts (not even with `--yes`); real posts go out only from an approved week.
Switching a platform back to Manual is always safe (the engine removes its waiting posts from Postiz).
Problems show up in `djq doctor` as `postiz.*` findings (the `dj-queue-doctor` skill has the fix for each).

## Auto-update (installs, not data)

`djq autoupdate status [--json]` says whether commits to main install themselves, which build is installed, and
whether one is ready (waiting for Eric's window to close) or blocked (failing tests, reason included). `djq autoupdate
log [--run]` shows what happened. Leave `on`/`off`, `run` and `rollback` to Eric or a build session unless Eric asks:
they change which app is installed. `rollback` is refused when the database is newer than the kept build unless
`--restore-db`, which loses changes since that backup — never run it on your own.

## Rules the app applies (so you don't fight them)

- Clips store only overrides; everything else follows Settings → New clip defaults (trim = Eric's markers, text
  source = Title, caption template, hashtag sets, YouTube title `{text} | DJ Lovd`, …).
- With no title the app shows the raw tag verbatim; `{text}` in captions = overlay text, else title, else raw tag.
- Over-limit captions are never shortened silently: `issues` has `captionTooLong` with `count`/`limit`/
  `countWithoutHashtags`; fix with `djq bulk drop-hashtags x --ids …` or a per-platform caption.
- A clip can be in the Queue when its crop is confirmed, its text resolves (or No text), a caption resolves, every
  posting platform's limits fit, its file exists, and it wasn't sent back by hand; otherwise it's in Edit and
  `reasons` says why.
