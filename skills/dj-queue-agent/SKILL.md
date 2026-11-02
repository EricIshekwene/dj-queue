---
name: dj-queue-agent
description: Read and change DJ Queue clips for Eric through the `djq` CLI — titles, title suggestions (song names), overlay text, captions, kind, scores, new-clip defaults and bulk edits with undo — and answer DJ Queue "Ask an agent" prompts. Use when Eric asks to look up song names for clips, fill titles, fix captions, edit many clips at once, or pastes a prompt that ends with `djq suggest --file`. Never writes SQLite directly; never touches source footage.
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

`djq` is on PATH when the app is installed (else `swift build` in the repo → `.build/debug/djq`). Dev copies:
`DJQ_ROOT` (the "DJ Video" folder) + `DJQ_HOME`. Ids can be shortened to a unique prefix.

## Read (JSON)

```sh
djq videos --json [--state S]   # S: needs_edit ready planned posting posted partial excluded missing_file | unscored scored needs-edit all
djq video <id> --json           # everything about one clip
djq week --json [YYYY-MM-DD]    # a week's plan: days → slots → posts
djq posts --json [--problems]   # last 7 days on (or unresolved problems)
djq defaults --json             # Settings → New clip defaults
djq bulk batches --json         # bulk journal (for undo)
```

`videos` items: `id, display_name, title, title_source, raw_tag, name, session, type, kind, state, score, excluded,
missing, part, duration, marked_start, marked_end, audio, file, suggestion_count, needs_title_help, issues[]`.

`video` adds: `title_tracks, title_suggestions[{id,text,tracks,confidence,source,origin}], edit` (stored overrides
only — absent/null fields follow the defaults), `resolved_edit` (effective values + `defaulted[]`), `versions`,
`resolved_v1` (effective text/caption settings + `defaulted[]`), `captions{platform: text}`, `youtube_title`,
`issues[{kind, platform, message, count, limit, countWithoutHashtags}]`, `plan`, `posts`.

## Write

```sh
djq suggest --file answer.json                 # many clips: [{"video_id": "…", "title_suggestions": [ … ]}]
djq suggest <video> --file one.json            # one clip ({"title_suggestions": [ … ]} or a bare array); --file - reads stdin
djq title <video> "Song One x Song Two" | --clear
djq text <video> "Overlay text" | --none | --default [--version N]
djq caption <video> "Caption" | --default [--platform P] [--version N]
djq kind <video> "dj vid"|talking
djq score <video> <0-100|clear>
```

Suggestion fields (same as `videos.json` `title_suggestions`, see `docs/metadata.md`): `text` (required; `\n` line
breaks; join songs with `x`, no arrows, no emoji), `tracks[{title, artist?}]`, `confidence` 0…1, `source`.
Re-sending the same `text` + `source` updates it.

## Bulk (one transaction, journaled, undoable)

```sh
djq bulk <action> [args] (--ids a,b,c | --filter F) [--dry-run] [--json]
djq bulk undo <batch> [--force]
```

Actions: `make-ready` (confirm the default crop; reports what's still missing) · `apply-defaults
[--sections frame,trim,text,cover,caption,platforms]` (clear overrides) · `score <n|clear>` · `score-adjust <±n>` ·
`kind <k>` · `exclude` · `include` · `caption-template <id|default>` · `hashtags <set,set|default>` ·
`extra-hashtags "<#a #b>"|default` · `drop-hashtags <platform>` · `skip-platform <p>` · `unskip-platform <p>` ·
`accept-title` · `title "<t>"|--clear` · `add-to-week <date>` · `pin-consecutive <date>` · `post-today` ·
`re-render`.

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

## Rules the app applies (so you don't fight them)

- Clips store only overrides; everything else follows Settings → New clip defaults (trim = Eric's markers, text
  source = Title, caption template, hashtag sets, YouTube title `{text} | DJ Lovd`, …).
- With no title the app shows the raw tag verbatim; `{text}` in captions = overlay text, else title, else raw tag.
- Over-limit captions are never shortened silently: `issues` has `captionTooLong` with `count`/`limit`/
  `countWithoutHashtags`; fix with `djq bulk drop-hashtags x --ids …` or a per-platform caption.
- A clip is ready when its crop is confirmed, its text resolves (or No text), a caption resolves, and lengths fit.
