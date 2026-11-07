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
- Don't post or change Settings unless Eric says so.
- **Never send a clip to the Queue unless Eric says so in words.** A clip in the Queue is approved and posts by itself:
  `djq stage <video> forward` from Edit, `djq requeue`, `djq bulk requeue` and `djq bulk make-ready` are Eric's Send to Queue.
  Your edits never move a clip to the Queue, however complete they make it (`sent_to_queue` in `--json` says if Eric sent it).
- **Postiz: never schedule or publish without Eric's explicit OK.** On your own you may only read
  (`djq postiz status`, `djq postiz channels`) and preview (`--dry-run`, `djq postiz test <video> --dry-run`) or make
  Postiz **drafts** (`djq postiz test <video> --draft`, nothing reaches a platform). Never read, print or ask for the
  Postiz API key (Keychain only; Eric enters it in Settings → Publishing).

`djq` is on PATH when the app is installed. A dev build (`swift build`, `.build/debug/djq`) refuses to start without
`DJQ_ROOT` (the "DJ Video" folder) + `DJQ_HOME`, so it only works on a dev copy. Ids can be shortened to a unique prefix.

## Read (JSON)

```sh
djq videos --json [--stage S] [--state S]   # stage: score edit queue scheduled posted
                                            # state (stored): needs_edit ready planned posting posted partial excluded missing_file | unscored scored needs-edit all
djq video <id> --json           # everything about one clip
djq week --json [YYYY-MM-DD]    # a week's plan: days → slots → posts (read-only)
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
djq youtube-title <video> "Title" | --template <id|name|default> | --default [--version N]
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

### More texts on a clip, with their own times and look (round 16)

A clip can show up to 12 texts, each in its own window. Number 1 is the first text, the one `djq text` writes, so
Title-follow, `{text}`, No text and YouTube titles all keep reading it. The rest are extras.

```sh
djq overlay list <video> [--version N] [--json]
djq overlay add <video> "<text>" [--start S] [--end S] [--x 0-1] [--y 0-1] [--style box|outline|shadow] [--size 8-400]
                [--align left|center|right] [--color #hex] [--background #hex] [--font <name>] [--opacity 0.1-1]
                [--tracking -0.1-0.5] [--version N] [--json]
djq overlay set <video> <number|id> ["<text>"] [same options]     # "default" clears --start, --end or a look option
djq overlay remove <video> <number|id> [--version N]
```

- `--start` and `--end` are seconds from the trim start. No `--start` = from the start of the trim, no `--end` = to its end.
- Address a text by number (1 = first) or by the `id` in `djq overlay list`. Numbers shift when one is removed, ids don't.
  An id is tried before a number.
- `--background` is the box fill, the outline colour or the shadow colour, by style. `--tracking` is letter spacing as a
  share of the font size. Fonts: `default rounded serif mono impact futura avenir-next helvetica-neue arial-black georgia didot
  marker-felt american-typewriter`.
- A new text starts with the first text's style, size, position and look. Give `--y` so it doesn't sit on top of it.
- `djq overlay remove <video> 1` moves the next text into first place. On the only text it refuses: use `djq text --none`.
- `djq text --none` hides every text and keeps the extras stored; turning it off brings them back.
- In JSON: `overlays` in `djq video --json` (`number`, `id`, `text`, `start`, `end`, `x`, `y`, `style`, `size`, `align`, `color`,
  `background`, `font`, `opacity`, `tracking`, `drawn`, `shows_from`, `shows_to`), and `moreText` / `textLook` in `versions` and
  `resolved_v1`, present only when used. `drawn` is false for an empty text, under No text, or when the window misses the trim.
- A per-platform trim that ends before a text starts just leaves that text out of that platform's video.
- Bulk Apply defaults (text section) clears the extras and the look too; `djq bulk undo` brings them back.
- Editing texts never sends a clip to the Queue. The one move it can cause is out of the Queue: a Queue clip left with no
  text to show goes to Edit with the reason "No text", as with `djq text ""`, and `djq overlay` prints that it left (on stderr
  with `--json`). Only Eric's Send to Queue brings it back. Edits also change the edit hash, so a scheduled clip renders again
  before it posts.

### Captions, hashtag groups, YouTube titles (round 7)

- A written caption (`djq caption`) is posted **exactly as written** — nothing is appended. Put the hashtags in it, or
  write `{hashtags}` where the clip's hashtags (its groups + extra tags) should go. Caption templates can also use `{title}` and `{link}`. Each platform has a hashtag cap (Settings → Platforms): over it, that platform keeps the first tags in caption order, so put the tags that matter first. A template can hold typed tags too, a tag appears once, and `#1` isn't a hashtag. `--default` goes back to the
  template. `djq video <id>` prints the caption as it posts.
- Hashtag groups are **Eric's own** (Settings → Captions & titles); none ship and new clips get none unless Eric sets
  default groups. Don't create, edit or delete groups unless Eric asks:
  `djq hashtag-groups [--json]` · `add "<name>" "<#a #b>"` · `edit <id|name> [--name N] [--tags "<#a #b>"]` ·
  `delete <id|name>` (undoable: each prints `djq bulk undo <batch>`).
- Caption templates: `djq caption-templates [--json]` · `add "<name>" "<template>"` · `edit <id|name> [--name N] [--template T]` ·
  `delete <id|name>`. `\n` in a template is a new line; hashtags can be typed in beside `{hashtags}`.
- Changing a clip's groups or extra tags (`djq bulk hashtags` / `extra-hashtags`) swaps the hashtags **inside** a
  written caption in place (no duplicates); template captions follow by themselves; per-platform captions stay as
  written.
- YouTube titles come from a template (`djq title-templates [--json]` · `add "<name>" "<template>"` · `edit` ·
  `delete` · `default <id>`), default `{text} | DJ Lovd`. `djq youtube-title <video> --template <id>` picks one for a
  clip; a typed title (`djq youtube-title <video> "…"`) wins over any template.

## Stages: move a clip back or forward

A short clip's stage: **Score** (no score) → **Edit** (scored, something still missing, sent back, or its file is
missing, or nothing to fix but not sent yet) → **Queue** (Eric sent it; approved, waiting for a day) → **Posted**.
**Scheduled** is a status, not a step: the clip has a day on the Calendar, not fully posted. The engine gives every Queue
clip a day by itself, up to 30 days ahead, and creates its posts at once. Only Eric's Send to Queue moves a clip
Edit → Queue: a clip with nothing to fix stays in Edit until then, with no reason chip. When a Queue clip stops
being valid (crop cleared, a platform limit lowered, file missing) the engine moves it to Edit by itself on its next
tick and after every `djq` write, logging "Moved to Edit: <reasons>"; it stays there until Eric sends it again. A
Scheduled or pinned clip that becomes invalid stays on its day and shows the problem (Doctor `plan.notReady`, "can't
post" notification) — fix it or take it off.

```sh
djq stage <video…> [--json]                         # each clip's stage, its controls ("‹ Back to Score" · "Send to Queue ›") or why not, and why it's in Edit
djq stage <video…> back|forward [--dry-run] [--json]
```

`--json` rows: `id, display_name, stage, back, forward` ("→ Edit" or why not), plus `back_title`/`forward_title`
(the app's button words: Edit "Back to Score"/"Send to Queue", Queue "Back to Edit", Scheduled "Back to
Edit"/"Mark posted…"), `back_blocked`/`forward_blocked` and `reasons[]` (Edit only).

- back: Edit → Score ("Back to Score") clears the score · Queue and Scheduled → Edit ("Back to Edit") = `unqueue` (below;
  refused once any platform posted) · Posted: none (use `repost` / `reset`). A clip whose file is missing can't move
  ("File missing — relink it first").
- forward: Score: none (set a score with `djq score`) · Edit → Queue ("Send to Queue", Eric's word only) clears "sent
  back" and confirms the default crop; if anything is still missing the clip stays in Edit, unsent, and the result says
  exactly what · Queue: none ("Clips in the Queue schedule themselves") · Scheduled → Posted: only by marking its posts
  posted.
- One batch each (`moves{<video id>: {from, to, note}}`, plus `unplanned` for back); undo with `djq bulk undo`.

## Back to Edit / Send to Queue (formerly "Remove from queue")

```sh
djq unqueue <video…> [--dry-run] [--json]   # Back to Edit (held there); its unposted slots/posts are removed
djq requeue <video…> [--dry-run] [--json]   # Send to Queue, any Edit clip (Eric's word only); if something's missing it stays in Edit
```

`unqueue` sets the clip's `held_in_edit` flag and takes it out of the plan with the planner's own rules: its slots
from today on that have nothing posted (a pinned slot loses its pin), and every post of it still in flight
(planned/rendering/rendered/due/overdue, retries and reposts too) are removed. Posted/failed/skipped posts and
history stay; other clips keep their days (nothing is reshuffled, and waiting clips fill the gap). `--json` prints the bulk result
(`batchId, changed, skipped, summary…`, see below) plus `unplanned{<video id>: [{videoId, date, platforms[], pinned}]}`; undo it with
`djq bulk undo <batch>` (flag, slots, weeks and posts come back exactly). Both are also `djq bulk unqueue|requeue`
(with `--filter`). Only when Eric asks — `--dry-run` first and tell Eric which days would go.

## Bulk (one transaction, journaled, undoable)

```sh
djq bulk <action> [args] (--ids a,b,c | --filter F) [--dry-run] [--json]
djq bulk undo <batch> [--force]
```

Actions: `make-ready` (Send to Queue with defaults, Eric's word only: confirms the default crop, sends every clip with nothing left to fix, and reports what's still missing) · `apply-defaults
[--sections frame,trim,text,cover,caption,platforms]` (clear overrides) · `score <n|clear>` · `score-adjust <±n>` ·
`kind <k>` · `exclude` · `include` · `caption-template <id|default>` (rewrites a written caption from the template) ·
`crop-offset <percent> [--own]` (moves the crop from the frame's centre, negative = left; clips with a crop keep it unless `--own`; clips with a post that went out are skipped) ·
`caption [--template <id|default>] [--add a,b] [--remove c]` (template and several groups as one undo; `--add` keeps the clip's other
groups and puts these after them in the order given; `--template` replaces a written caption; clips with scheduled or posted posts are skipped) ·
`hashtags <group,group|default>` · `extra-hashtags "<#a #b>"|default` · `youtube-title-template <id|default>` ·
`drop-hashtags <platform>` · `skip-platform <p>` · `unskip-platform <p>` ·
`accept-title` · `title "<t>"|--clear` · `pin-consecutive <date>` · `post-today` ·
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

Each platform publishes **Manual** (the default: Eric posts from the Calendar) or through **Postiz** (the engine schedules
the render in Postiz ahead of the slot and reads the live link back; any Postiz problem sends that platform's posts
back to the Calendar to post by hand). Contract: `docs/postiz.md`. Every live call shares a budget of 25 per hour with the app, so don't
loop. Channel ids appear only with `--ids`; the key never appears anywhere.

```sh
djq postiz status [--json] [--offline] [--ids]   # key/connection (one live check unless --offline), budget, test run,
                                                 # per platform: publisher, channel (name + provider), route, posts in
                                                 # Postiz and their states, last sync. Exit 0 = connected + six mapped,
                                                 # 2 = not ready, 3 = --offline and not checked
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
djq postiz resolve <post> --in-postiz|--not-in-postiz   # Doctor postiz.create_unknown: Eric's answer after
                                                 # checking the Postiz calendar (plain `resolve` = one live look)
```

A change that makes scheduled posts go out for real (a platform to Postiz with a channel, a new channel, test run
off) is refused without `--yes`, and so is a `djq bulk undo` that would do the same (exit 2). `--yes` is Eric's word, not yours: ask first, quoting what the dry run printed.
`djq postiz test` never schedules real posts (not even with `--yes`); real posts go out only from clips in the Queue.
Switching a platform back to Manual is always safe (the engine removes its waiting posts from Postiz).
Problems show up in `djq doctor` as `postiz.*` findings (the `dj-queue-doctor` skill has the fix for each).

## Auto-update (installs, not data)

`djq autoupdate status [--json]` says whether commits to main install themselves, which build is installed, and
whether one is ready (waiting for Eric's window to close) or blocked (failing tests, reason included). `djq autoupdate
log [--run]` shows what happened. Leave `on`/`off`, `run` and `rollback` to Eric or a build session unless Eric asks:
they change which app is installed. `rollback` is refused when the database is newer than the kept build unless
`--restore-db`, which loses changes since that backup — never run it on your own.

## Slot times

```sh
djq slot <platform>                 # show it
djq slot youtube 08:00 --dry-run    # what would move
djq slot youtube 08:00              # set it and re-time; prints `djq bulk undo <batch>`
```

Sets the slot (Settings → Schedule) and moves that platform's unposted future posts onto it, one undo. The publish step
replaces what Postiz holds. Pinned posts, automatic retries, posts within 30 minutes of going out and posts whose new time
is that close or has passed stay put, and the command lists each with why. An automatic retry moves only when a post lands
next to it. Other platforms don't move. Only when Eric asks.

YouTube has a quiet window: nothing is scheduled from 02:00 up to 07:00 UTC, and a slot landing there goes at 07:30 UTC.
Postiz's shared YouTube quota resets at 07:00 UTC and is usually gone by the afternoon (`docs/postiz.md` §5a), so a morning
slot is the safe one.

## Rules the app applies (so you don't fight them)

- Clips store only overrides; everything else follows Settings → New clip defaults (trim = Eric's markers, text
  source = Title, caption template, hashtag groups (none by default), YouTube title template `{text} | DJ Lovd`, …).
- With no title the app shows the raw tag verbatim; `{text}` in captions = overlay text, else title, else raw tag.
- Over-limit captions are never shortened silently: `issues` has `captionTooLong` with `count`/`limit`/
  `countWithoutHashtags`; fix with `djq bulk drop-hashtags x --ids …` or a per-platform caption.
- A clip can be in the Queue when its crop is confirmed, its text resolves (or No text), a caption resolves, every
  posting platform's limits fit, its file exists, and it wasn't sent back by hand; otherwise it's in Edit and
  `reasons` says why.
