# DJ Queue

Local macOS app that runs DJ Lovd's short-form posting queue: score clips, make vertical edits (crop, trim, text, cover, captions), approve a week, let the background engine render final files ahead of time, post by hand from **Today**, and track every platform post. Phase 1 (manual publisher). Spec: `~/Movies/DJ Video/_spec/DJ Queue – App Spec.md`; decisions: `DECISIONS.md`.

## Install (real use)

```sh
cd ~/code/dj-queue
scripts/build-app.sh --install     # builds, copies "DJ Queue.app" to ~/Applications, links ~/bin/djq
open ~/Applications/"DJ Queue.app"  # first launch asks to run in the background at login → Yes
```

The app reads `~/Movies/DJ Video/Sessions/*/videos.json`, keeps its database in `~/Library/Application Support/DJ Queue/`, logs to `~/Library/Logs/DJ Queue/engine.log`, and writes only to each session's `Ready to Post/Shortform`, `Posted/` folders and `~/Movies/DJ Video/_app/backups`. It never touches `Video/`, `Audio/`, `Other/`, `Clips/` or CapCut projects.

## Try it safely (dev copy)

```sh
scripts/make-devroot.sh   # ~/code/dj-queue-dev/DJ Video: copied videos.json + links to the real clips
scripts/build-app.sh
DJQ_ROOT="$HOME/code/dj-queue-dev/DJ Video" DJQ_HOME="$HOME/code/dj-queue-dev/eric-preview" \
  nohup "build/DJ Queue.app/Contents/MacOS/DJQueue" >/dev/null 2>&1 &
```

## Daily use

1. **Queue → Score** (or the Score button): watch each clip, type a number, Enter.
2. Select a clip → **Edit** (⌘E): crop, text (prefilled from the marker tag), caption template + auto hashtags, cover.
3. **Week**: check the proposal → **Approve week** (⌘↩). The engine renders the week whenever the Mac is on.
4. **Today**: drag the file into the upload page, **Copy caption**, post, **Mark posted** + paste the URL.
5. Problems (copyright, failed, missed) show as a red banner and a red badge on the menu-bar icon.

## CLI and Doctor

`djq status | queue | week | today | doctor [--json] | tick | posted <id> <url> | …` (`djq help`).
`djq doctor` prints a Markdown report to paste to an agent; the `dj-queue-doctor` skill (`skills/dj-queue-doctor/`, linked into `~/.claude-technical/skills/`) has the safe fix for every finding.

## Develop

`swift build` · `swift test` · `scripts/build-app.sh` · `DJQueueApp --snapshot <dir>` renders every screen light + dark.
Design: `design/` (`INVENTORY.md`, `DESIGN.md`, `REFS.md`), `refs/`. Architecture and contracts: `ARCHITECTURE.md`.
