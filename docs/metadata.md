# DJ Queue — clip metadata contract (`videos.json`)

DJ Queue is a UI over scripts: it never guesses song names or titles. Everything it shows as a guess comes from
upstream metadata that export tools or agents write into each session's `videos.json`, or that an agent adds later
with `djq suggest`. This page is the contract for those tools.

`videos.json` lives in `Sessions/<YYYY-MM-DD – name>/` and is written by the export tools (`export_clips.py`).
DJ Queue only reads it (intake runs every engine tick and on `djq intake`). Ids are stable forever — never change
them.

## Per-video fields DJ Queue reads

Existing fields (unchanged): `id`, `name`, `tags`, `type` (`short-form` / `long-form`), `content-type`
(`dj vid` / `talking`), `file`, `session`, `part`, `marked_start`, `marked_end`, `start`, `end`, `duration`,
`grace`, `audio`, `status`.

Optional:

| Field | Type | Meaning |
|---|---|---|
| `title` | string | The clip's title if the tool knows it for sure. **Seeds** DJ Queue's title only if the clip never had one. A title Eric set — or deliberately cleared — is never overwritten; a different manifest title then shows up as a suggestion (source `videos.json title`). |
| `title_suggestions` | array | Guesses for Eric to pick from, best first. Re-synced on every intake (the list in the file replaces the previous file list; suggestions added with `djq suggest` are kept). Malformed values are ignored, never fatal. |
| `text_suggestions` | array | Guesses for the **text on the video**, same shape and sync rules as `title_suggestions`. Keeps line breaks (`\n`); may include a hook. |

Each suggestion:

```json
{
  "text": "Sungba x Tshwala Bam",
  "tracks": [{"title": "Sungba", "artist": "Asake"}, {"title": "Tshwala Bam", "artist": "TitoM & Yuppe"}],
  "confidence": 0.85,
  "source": "rekordbox history"
}
```

| Key | Required | Notes |
|---|---|---|
| `text` | yes | Title suggestions: one line is best, songs joined with `x` (never an arrow; no emoji); older tools such as `prefill_titles.py` may still send line breaks. Text suggestions: the text as it appears on the video, `\n` for line breaks (`Song One\nx\nSong Two`). |
| `tracks` | no | Songs in order; `artist` optional. |
| `confidence` | no | 0…1. For title suggestions: below 0.6 the clip still counts as "needs title help" (the app offers an *Ask an agent* prompt). Text suggestions never affect it. |
| `source` | no | Where it came from (`rekordbox history`, `tracklist`, `prefill_titles.py`, …). |

Example entry:

```json
{
  "id": "5b1e0c2a-…",
  "name": "2026-10-23 – Afroween Jazz Piano – sugnba x tshwalabami",
  "tags": ["sugnba x tshwalabami"],
  "type": "short-form",
  "content-type": "dj vid",
  "file": "Clips/2026-10-23 – Afroween Jazz Piano – sugnba x tshwalabami.mp4",
  "part": 2, "start": 2412.0, "end": 2436.0, "marked_start": 2415.0, "marked_end": 2433.0,
  "duration": 24.0, "grace": 3.0, "audio": "camera",
  "title_suggestions": [
    {"text": "Sungba x Tshwala Bam", "tracks": [{"title": "Sungba"}, {"title": "Tshwala Bam"}], "confidence": 0.85, "source": "rekordbox history"}
  ],
  "text_suggestions": [
    {"text": "Sungba\nx\nTshwala Bam", "confidence": 0.85, "source": "rekordbox history"}
  ]
}
```

## How DJ Queue uses them

- **Title** (app-owned, Eric's choice; `djq title`) feeds: the overlay-text default (Settings → New clip
  defaults → Text source = Title), caption `{text}`, the YouTube title templates (default `{text} | DJ Lovd`; Settings →
  Captions & titles, round 7) and the display name everywhere.
- With no title, every screen shows the raw marker tag **verbatim**, and captions/titles use it verbatim. Nothing
  is tidied or guessed in the app.
- Title suggestions appear as chips in the editor's Title section and on Edit cards; *Accept top suggestion* (also
  `djq bulk accept-title`) copies the best one into the title.
- **Text** (the overlay on the video, per version) follows the Title until Eric types it or taps a text suggestion
  in the editor's Text section. Title and Text are separate on purpose: the Title is one clean line for lists and
  search; the Text carries line breaks and hooks. Caption `{text}` and the YouTube title use the Text on one line.
  A clip can have more texts with their own times (`djq overlay`); those are on-video only, and captions and titles keep
  reading the first text.

## Adding suggestions after intake

```sh
djq suggest --file answer.json          # [{"video_id": "…", "title_suggestions": [ … ], "text_suggestions": [ … ]}, …]
djq suggest <video> --file one.json     # {"title_suggestions": [ … ], "text_suggestions": [ … ]} or a bare [ … ] (titles)
djq agent-prompt titles --needs-title   # Markdown prompt for an agent; its answer is the file above
```

Same `text` + `source` for a clip replaces the earlier suggestion (so an agent can re-run safely).

## The upstream formatter

`scripts/prefill_titles.py` (Python 3, standard library only) is the old in-app "prefill", moved upstream. It
turns marker tags into suggestions (source `prefill_titles.py`, confidence 0.3) using the round-1 rules: split on
` x `, title-case with a replacements file, one line for short names, three lines (`Song One` / `x` /
`Song Two`) for long ones, nothing for talking clips.

```sh
python3 scripts/prefill_titles.py "Sessions/<session>/videos.json" --in-place       # keeps videos.json.bak
python3 scripts/prefill_titles.py "Sessions/<session>/videos.json" --format suggest > s.json && djq suggest --file s.json
python3 scripts/prefill_titles.py --tag "sugnba x tshwalabami" --rules rules.json  # {"replacements": {"sugnba": "Sungba"}}
python3 scripts/prefill_titles.py --self-test
```

It never sets `title`, and never touches anything but the `videos.json` you point it at.
