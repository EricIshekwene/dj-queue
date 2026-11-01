## dj-queue

DJ Queue (Eric's posting app) reads what the export tools write — nothing in CapCut changes for it.

- Tools in `~/Movies/DJ Video/_tools/` (Python 3 + ffmpeg):
  - `pair_markers.py <draft_info.json>` — pairs CapCut markers into clips (same name → earliest/latest; near-matches paired; prints leftovers).
  - `export_clips.py <session dir> <part> <draft_info.json> [--grace 3] [--only N,..] [--dry]` — cuts each clip from the raw files the timeline uses (3 s grace), writes `Clips/<session> – <marker>.mp4`, and upserts the session's `videos.json`.
  - `tag.py "Tag1,Tag2" files…` — Finder tags.
- `<session>/videos.json` is the app's intake source. Each video's `id` is permanent (the join key for scores, edits and posts); re-exporting keeps existing ids, so re-export rather than hand-editing, and never change an id.
- After exporting, run `djq intake` (or just wait — the app ticks every minute) and `djq doctor` to confirm: new clips appear unscored in the queue; renamed/moved clips relink by fingerprint; untracked `.mp4`s in `Clips/` are reported, never touched.
- The app never writes to `Video/`, `Audio/`, `Other/`, `Clips/` or CapCut projects. Problems in the app → the `dj-queue-doctor` skill.
