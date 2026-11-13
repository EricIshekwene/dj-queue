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
  `djq post-at` is Eric's Send to Queue as well (it sends the clip and puts it on the calendar at that minute): never run it
  unless Eric says so, with the day and time in their words. `--dry-run` is always fine.
- **Postiz: never schedule or publish without Eric's explicit OK.** On your own you may only read
  (`djq postiz status`, `djq postiz channels`) and preview (`--dry-run`, `djq postiz test <video> --dry-run`) or make
  Postiz **drafts** (`djq postiz test <video> --draft`, nothing reaches a platform). Never read, print or ask for the
  Postiz API key (Keychain only; Eric enters it in Settings → Publishing).

- **Photo posts follow the same rule.** `djq photo add` only makes the post; it lands in Edit and stays there until
  Eric sends it. Never edit, move or delete anything under `Photos/Originals/` (DJ Queue's own copies) or
  `Photos/Stills/` (the videos DJ Queue makes from a photo and an audio file, round 23).

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

Round 21: every item also has `media` (`"video"` or `"photo"`) and `photos[{id, file, width, height}]` (empty for a
video; posting order, the first is the cover). See "Photo posts" below.

Round 23: a video DJ Queue made from one photo and an audio file has `still {audio_name, audio_seconds, fit, photo{id,
file, width, height}}` and `media: "video"`; the key is absent on everything else. See "Photo with audio" below.

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

A clip can show up to 32 texts, each in its own window (round 26; it was 12). Number 1 is the first text, the one `djq text` writes, so
Title-follow, `{text}`, No text and YouTube titles all keep reading it. The rest are extras.

```sh
djq overlay list <video> [--version N] [--json]
djq overlay add <video> ["<text>"] [--start S] [--end S] [--x 0-1] [--y 0-1] [--style box|outline|shadow] [--size 8-400]
                [--align left|center|right] [--color #hex] [--background #hex] [--font <name>] [--opacity 0.1-1]
                [--tracking -0.1-0.5] [--countdown 2-10|off] [--version N] [--json]
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
- **Countdown (round 26):** `--countdown N` makes one text show N, …, 2, 1 in equal steps across its window, in one
  slot. Turning it on with no `--start` takes the last N seconds before `--end` (or before where the text ends; a new
  text: the end of the trim), one second a number; `--start S` alone gives S to S+N. A new count on a countdown keeps its
  window unless `--end` is given. The text is optional: empty or without `{n}` the number shows alone; `{n}` is where
  the number goes (`"Next song in {n}"`). `--countdown off` makes it a plain text again and keeps its window. Text 1 and
  photo posts can't count down, and a countdown never moves into text 1 (`remove 1` refuses when only countdowns follow).
  Taking the audio off a photo video turns its countdowns into plain texts with their first number. A quiz question (question, 3-2-1, wrong options red, right one green) is 4 texts this
  way instead of 6: `djq overlay add <video> --countdown 3 --end 9 --y 0.5 --size 140`.
- `djq overlay remove <video> 1` moves the next text into first place (never a countdown). On the only text it refuses: use `djq text --none`.
- `djq text --none` hides every text and keeps the extras stored; turning it off brings them back.
- In JSON: `overlays` in `djq video --json` (`number`, `id`, `text`, `start`, `end`, `x`, `y`, `style`, `size`, `align`, `color`,
  `background`, `font`, `opacity`, `tracking`, `drawn`, `shows_from`, `shows_to`, and `countdown` when it counts down), and `moreText` / `textLook` in `versions` and
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

### Versions: ready to repost, and bulk edits (round 20)

```sh
djq repost-ready <video> [--version N] [--off]   # mark (or unmark) a text version ready to repost; default v1
djq repost-ready --list [--json]                 # every clip with a version ready to repost
djq videos --repost-ready [--json]               # same filter on the clip list (also --state repost-ready, bulk --filter repost-ready)
```

- Marking a version ready only marks it: the clip's stage, Queue, slots and posts don't change, and nothing is scheduled.
  The repost round will pick ready versions a platform hasn't had yet. Mark versions only when Eric asks.
- `repost_ready_versions` is on every clip in `djq videos --json`; `repostReady: true` on the version in `djq video --json`.
- Long-form is never reposted (refused). A version that doesn't exist is refused.
- Bulk edits on a clip with several versions reach every version except captions. Crop, trim, cover, aspect and
  platforms are one edit per clip (round 30: a version can also have its own trim, see below). Caption changes (template, groups, extras, YouTube title, parts, drop hashtags) land
  on v1; a later version that took its caption from v1 keeps it as it was (`captionsOwn: true` on that version: it
  stops inheriting captions, and anything it doesn't set follows the defaults). `apply-defaults --sections text`
  resets the text look and place on every version and keeps each version's words.
- Round 27: every version from v2 on is its own copy (`standalone: true` in `djq video --json`). Nothing carries
  forward between versions: editing v1 never changes v2 and the other way round; what a version doesn't set follows
  the defaults. `djq text|caption|youtube-title --version N` on a version that doesn't exist yet makes it as a full
  copy of the one before, then applies the change. A copy never carries "Ready to repost".

### Trim per version (round 30)

```sh
djq trim <video> [--json]                                  # each version's trim: its own, or the clip's
djq trim <video> --in S --out S [--version N] [--json]     # the clip's trim, or version N's own (one side alone keeps the other)
djq trim <video> --default [--version N] [--json]          # the clip's trim back to the default (+ its per-platform trims
                                                           # cleared); with --version, v N follows the clip's trim again
```

- Seconds are absolute in the clip file. A version with its own trim renders, posts, gets its cover and has its
  platform length checked on it, and its texts' `--start/--end` count from its own start. The clip's per-platform
  trims never reach a version with its own trim.
- Versions without their own trim share the clip's. Changing the clip's trim never changes a version that has its own.
- `djq video --json` has `version_trims` (`version, trim_in, trim_out, duration, own, clip_default, platform_trims`);
  `djq overlay list` prints the version's trim and each text carries `trim_in`, `trim_out`, `own_trim` in `--json`.
- Every change is one `djq bulk undo` step. A copy of a version takes its own trim; `bulk apply-defaults --sections trim`
  clears every version's own trim. Set trims only when Eric asks.

## Photo posts (round 21)

A photo post is one photo, or a carousel of several, that DJ Queue treats like a clip: same list, same editor ideas,
same stages minus Score. In `--json` it is an item with `media: "photo"`, `duration: 0`, `photos[...]` and no score.

```sh
djq photo add <file>… [--title "<title>"] [--json]   # one post from every file, in the order given (a carousel when several)
djq photo add <file>… --separate [--json]             # a post per file
djq photo list [--json]                               # every photo post (the same items as `djq videos`)
```

- JPEG, PNG, HEIC, WebP and TIFF. Each file is **copied** into `~/Movies/DJ Video/Photos/Originals/<post id>/`; the
  file you point at is never moved or changed. A file that can't be used is listed under `skipped` with the reason;
  exit 1 when no post was made. A post holds at most 35 photos.
- The post lands in **Edit** with no score (photos skip Score), no text on the picture, a centred 4:5 crop and
  YouTube Shorts off. It never goes to the Queue by itself: `djq requeue <id>` / `djq stage <id> forward` are Eric's
  Send to Queue, on Eric's word only, like any clip. Never send one because you added it.
- What works on it: `title`, `caption`, `text` and `overlay` (a text shows on a range of photos: `--start 1 --end 3`
  is photos 2–3, since photo N is the unit N-1…N), `bulk` caption, title and platform actions, `stage`, `unqueue`,
  `requeue`, `render` (one JPEG per photo in `Photos/Ready to Post/Shortform/`), `postiz test`.
- What doesn't: `bulk crop-offset` skips it ("photos are cropped in the editor"), YouTube can't be turned on for it
  (`bulk unskip-platform youtube` says why), `stage <id> back` from Edit ("Photos have no Score stage"), and it needs
  no title help (`needs_title_help` is false: there is no song to look up).
- A carousel longer than a platform takes sends its first photos there: X 4, Instagram 10, Facebook 10, Threads 20,
  TikTok 35. That is a notice, not a problem.
- Shapes: 4:5 (the default), 1:1, 16:9 and 9:16. Instagram doesn't take 9:16 photos, so a 9:16 post with Instagram on
  has the reason "Wrong shape for Instagram" and stays in Edit until Eric picks another shape or turns Instagram off
  for it. Don't choose for Eric.
- Captions: `{set}` and `{tag}` are empty for a photo post, and `{text}` is the text on the picture, else the Title,
  else nothing (never the file name). Give it a title or a written caption when the template leans on those.

## Photo with audio (round 23)

One photo plus an audio file becomes a video (the photo held for the length of the audio), and the item is then a
clip: `media: "video"`, a `duration`, `still{…}`, the clip editor, per-platform trims, YouTube Shorts included.

```bash
djq photo add <photo>… --audio <file> [--fit whole|fill] [--title "<title>"] [--json]   # a video per photo, each with this audio
djq photo audio <id> <file> [--fit whole|fill] [--json]   # add audio to a photo post with ONE photo (same id), or change a made video's audio
djq photo audio <id> --fit whole|fill [--json]            # only how the photo sits in the video (made again from its own audio)
djq photo audio <id> --remove [--json]                    # take the audio off: a photo post again
```

- Audio: MP3, M4A/AAC, WAV, AIFF, FLAC, CAF, or the sound of an MP4/MOV; 1 second to 20 minutes. Both files are only
  read; DJ Queue keeps its own copies in `Photos/Stills/<id>/` (the audio as AAC). Making a video takes a few seconds.
  A photo under 200 px on its short side is refused.
- `fit` (`still.fit`): `whole` (the default) shows the whole photo in a 9:16 video over a blurred copy of itself; its
  crop is the whole frame, so there is no "No crop". `fill` makes the video at the photo's shape and Eric picks the
  9:16 crop in the editor ("No crop" until then). Don't change the fit unless Eric asks; a change resets the crop.
  A `whole` video is always exactly 9:16; where New clip defaults ask for another shape its edit says `aspect` 9:16
  itself. Leave that as it is.
- Adding audio keeps the id, title, caption, hashtag groups and texts. The photo's crop, its shape and "shows on photos"
  ranges go (it is 9:16, and each text shows for the whole clip until timed), and YouTube is no longer forced off. A carousel is refused ("Audio goes on a post with one photo").
- `photo audio` works only while the item is in Edit with no day and no post ("Send it back to Edit first"). Each
  change is one batch: `djq bulk undo <batch>`. No undo, forced or not, changes what a scheduled or posted item is
  (photo post or video, which audio, which fit) or the posts planned for it: such an item is skipped with "It's
  scheduled or posted now: send it back to Edit first", the batch's plan part is left as it is, and `--force` doesn't
  help. Send it back to Edit, then undo again.
- It needs no score, starts with no text, `{set}` and `{tag}` are empty, and `needs_title_help` is false: don't look up
  a song for it. With YouTube on and nothing to name it (no Title, no text on it, no typed YouTube title) it has the
  reason "No title" and stays in Edit: ask Eric for the title.
- A long track is "Too long for …" on the short platforms like any clip; the fix is the trim (Eric picks the part).
  `bulk crop-offset` skips it ("a photo with audio is cropped in the editor").
- As always: nothing here sends it to the Queue.

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

## Post at a set time (round 21)

```sh
djq post-at <video> "<YYYY-MM-DD HH:MM>" [--dry-run] [--json]   # every platform posts at that minute (Settings time zone); Eric's word only
djq post-at <video> --clear [--dry-run] [--json]                # back on the regular schedule: it gets the next open day
```

A set time sits outside posts per day: it takes none of the day's regular places, no other clip moves, and the scheduler
never shifts it. The time must be 10 minutes ahead or more. YouTube from 7 pm to midnight Pacific goes at 00:30 Pacific, and
`--dry-run` says so before anything is written (`plan.platforms[{platform, at, moved, retry}]`, `plan.skipped`, `plan.notes`,
`plan.blocker`). A time is refused when Postiz sends a copy within 10 minutes ("too late to change").
A clip still in Edit is sent to the Queue by this command; if something is left to fix it stays in Edit and the blocker
says what. Undo with the `djq bulk undo <batch>` it prints. `djq week` marks the slot "set time 3:15 PM", and `plan[].exactAt`
in `djq video --json` carries the time (absent on a regular day).

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

YouTube has a quiet window: nothing is scheduled from 7 pm up to midnight Pacific (10 pm–3 am New York), and a slot
landing there goes at 00:30 Pacific. Postiz's shared YouTube quota resets at midnight Pacific (07:00 UTC in summer, 08:00
UTC in winter) and is usually gone by the afternoon (`docs/postiz.md` §5a), so a morning slot is the safe one. A failed
post retries by itself with no limit; a channel whose Postiz sign-in broke is one "Reconnect … in Postiz" item and its
posts wait for it. Never `djq fixed` either.

## Rules the app applies (so you don't fight them)

- Clips store only overrides; everything else follows Settings → New clip defaults (trim = Eric's markers, text
  source = Title, caption template, hashtag groups (none by default), YouTube title template `{text} | DJ Lovd`, …).
- With no title the app shows the raw tag verbatim; `{text}` in captions = overlay text, else title, else raw tag.
- Over-limit captions are never shortened silently: `issues` has `captionTooLong` with `count`/`limit`/
  `countWithoutHashtags`; fix with `djq bulk drop-hashtags x --ids …` or a per-platform caption.
- A clip can be in the Queue when its crop is confirmed, its text resolves (or No text), a caption resolves, every
  posting platform's limits fit, its file exists, and it wasn't sent back by hand; otherwise it's in Edit and
  `reasons` says why.
- A photo post needs less: its photo files, a caption that resolves and fits each platform. No score, no crop to
  confirm (Send to Queue writes the centred one down), no text rule, no length, and nothing about YouTube.
