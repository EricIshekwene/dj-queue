# DJ Queue

A native macOS app that runs my DJ content pipeline: it turns raw 4K clips from a DJ set into vertical short-form videos, plans what posts where and when across six platforms, renders the final files in the background, and tracks every post — including missed slots, failures and copyright blocks.

Built for my own use as DJ Lovd (TikTok, Instagram, Facebook, YouTube Shorts, Threads, X). SwiftUI + AVFoundation + SQLite + ffmpeg, 187 automated tests. Designed, specified and shipped with a team of AI coding agents that I directed — v1 in one day, then a full redesign the next — see [How it was built](#how-it-was-built).

![Queue](docs/screenshots/queue.jpg)

## What it does

The app follows a clip's life — **Score → Edit → Queue → Week → Today** — with one job and one primary action per screen, on a calm, rounded design system modelled on ChatGPT's look and shadcn/ui component anatomy.

- **Intake** — watches my session folders; every clip exported from my CapCut markers shows up automatically. Renamed files are re-found by content fingerprint; deleted files are flagged, never lost.
- **Score & queue** — I score each clip 0–100 on a large autoplaying preview; the queue orders the backlog worst → best (to warm up new accounts) or best → worst. Every list has Cards / Grid / Single / List views and one shared header (search, view modes, page chips, one Filters popover with removable chips, sort; remembered per page, ⌘F to search). Lists show each clip as it will post: small background-generated proxies carry the crop and trim, the text overlay is drawn live during its window, and covers include the text.
- **Vertical editor** — crop a 4K 16:9 frame to 9:16, trim starting on my original markers (with grace to extend), overlay text, captions with per-platform limits, a cover frame, versions for reposts, multi-platform safe zones and realistic phone previews of each platform's UI with the real caption and handle.
- **No intelligence in the app, by design** — the app is a UI over scripts. Song names and titles come from metadata my agents write (`title_suggestions` in the manifest) and show up as chips; when a name is ambiguous, *Ask an agent* copies a ready-made prompt. Outside agents read and change everything through the `djq` CLI (JSON in/out), documented as a Claude skill.
- **Stage = readiness** — there are no Ready / Needs edit labels: a clip in Edit isn't ready, the Queue only ever holds ready clips, and a queued clip that becomes invalid (crop cleared, a platform limit changed, file missing) moves back to Edit by itself with a chip saying why. Any clip can move one stage back or forward from wherever it is (e.g. *Back to Edit* from the Queue; a scheduled clip can go back to the Queue), with the reason shown when a move isn't allowed (nothing already posted is ever pulled back) and one-step undo.
- **Every control explains itself** — every icon-only button and badge has a tooltip (label, shortcut, and why it's disabled), enforced by a lint in the test suite; every data-changing click has Undo or asks first, and ⌘Z always undoes the most recent action (a whole editor session counts as one).
- **Defaults + bulk editing** — new-clip defaults for frame, trim, text, cover, captions and platforms (clips store only overrides, so changing a default updates every untouched clip); bulk actions with a confirmation sheet showing exactly what changes and one-step undo.
- **Weekly approval** — the app proposes the next 7 days; I drag, swap, pin and approve. Only approved weeks ever post.
- **Background engine** — runs at login, renders the approved week ahead of time (1080×1920 H.264, loudness-normalised to −14 LUFS), and notifies me when each platform post is due.
- **Manual publisher (phase 1)** — a Today screen: drag the file into the upload page, copy the platform-specific caption, mark posted with the URL. Built behind a `Publisher` interface so an API publisher (Postiz) can replace it later without touching the rest.
- **Failure handling** — missed slots shift that platform's plan without ever double-posting; failed posts re-queue the next day after a fix; copyright blocks are shown loudly and never auto-retried.
- **Doctor** — `djq doctor` checks everything (manifests, missing files, renders, overdue posts, runway, DB integrity, disk, tools) and prints a report an AI agent can act on, paired with a skill that documents the safe fix for every finding.

| Score | Edit |
|---|---|
| ![Score](docs/screenshots/score.jpg) | ![Edit](docs/screenshots/edit.jpg) |
| **Editor — platform previews** | **Editor — safe zones** |
| ![Editor previews](docs/screenshots/editor-preview.jpg) | ![Editor zones](docs/screenshots/editor-zones.jpg) |
| **Week** | **Today** |
| ![Week](docs/screenshots/week.jpg) | ![Today](docs/screenshots/today.jpg) |
| **Queue — stage moves** | **Posts — one card per clip and day** |
| ![Queue stage menu](docs/screenshots/queue-stage-menu.jpg) | ![Posts](docs/screenshots/posts.jpg) |
| **Library** | **Settings — new clip defaults** |
| ![Library](docs/screenshots/library.jpg) | ![Settings](docs/screenshots/settings-defaults.jpg) |

*Screenshots use sample data and titles.*

## Architecture

```mermaid
flowchart LR
  subgraph Disk["~/Movies/DJ Video (read-only sources)"]
    VJ[videos.json manifests] --> CL[4K clips]
  end
  subgraph App["DJ Queue.app (launched at login)"]
    UI[SwiftUI window + menu bar]
    ENG[Engine loop<br/>every 60 s / on wake]
  end
  CLI[djq CLI]
  DB[(SQLite<br/>single source of truth)]
  R[Renderer<br/>Core Text overlay + ffmpeg]
  P[Publisher protocol<br/>Manual now · Postiz later]
  VJ -- intake --> ENG
  UI <--> DB
  CLI <--> DB
  ENG <--> DB
  ENG --> R --> OUT[Ready to Post/Shortform]
  ENG --> P --> N[Notifications · Today screen]
```

- **One process, three roles.** A LaunchAgent starts the app in agent mode at login; the same process hosts the engine loop, the menu-bar item and (on demand) the main window. macOS only delivers notifications from an app bundle, which drove this design. A file lock guarantees one engine per database; the CLI shares the same WAL-mode SQLite file.
- **Core library (`DJQCore`)** holds everything testable: models, store, intake, validation, captions, planner, engine, renderer, Doctor. The app and the CLI are thin shells over it.
- **Data model.** Videos (identity from the manifest; app-owned fields like score are never overwritten by intake), edits, text versions with carry-forward, weekly plans, and platform posts with an append-only history. A fix or repost creates a new attempt; history is never rewritten.

## Engineering highlights

- **Preview equals export.** Overlay text (including colour emoji) is rendered once with Core Text into a transparent PNG; the editor draws that exact image over the player and ffmpeg composites the same image into the final video. Measured difference between the editor preview and a frame grabbed from the rendered MP4: ~1.5/255 (codec noise).

  ![Preview vs export](docs/screenshots/preview-vs-export.jpg)
  *Editor preview (left), frame from the exported MP4 (middle), difference ×8 (right).*

- **Loudness.** Two-pass EBU R128 normalisation so a phone-mic clip and a clean desk-feed clip play at the same volume (−11.2 and −13.2 LUFS sources → −14.1 LUFS both, true peak ≤ −1 dBTP).
- **Never double-post.** Every planner operation (approve, swap, move, push, skip, reset, missed-day shifts) goes through one placement rule; an invariant check runs after every operation in the tests, and a reviewer fuzzed 80 × 60 random operations with zero violations.
- **Time is hard.** Slots are scheduled in America/New_York; a reviewer-found bug where every slot was an hour off on the DST change day is covered by a test.
- **Crash-safe background work.** Kernel `flock` per render plus atomic status claims, so the app and the CLI can't render the same file; ffmpeg timeouts; failed renders back off instead of starving the queue.
- **Never touch source footage.** The app writes only to its own output folders; enforced in review and checked in the final acceptance run.

## How it was built

I wrote the product spec, then directed AI coding agents (Claude Code) through a structured process I use for larger builds:

1. **Design before code** — an inventory of every screen, control and state (~110 slots), a locked visual reference per slot, and one decision page with 28 product/design questions and pictures (text styles rendered on real frames from my footage). I answered once; the answers became binding (`DECISIONS.md`).
2. **Contracts, then parallel work** — a foundation layer and an API contract (`ARCHITECTURE.md`), then four agents building in parallel on separate branches with disjoint file ownership: renderer, engine + CLI + Doctor, main UI, editor.
3. **Independent review on every branch** — a fresh reviewer agent per milestone checked spec fidelity and code quality, with probes. Real bugs caught this way: a double-post path after a missed day, an edit hash that would have re-rendered and overwritten files whenever a platform was toggled, a DST off-by-an-hour, trim handles that stuck, crop maths 1 px off the export.
4. **Integration and a final end-to-end review** against the spec's acceptance criteria on my real clips, with screenshots of every screen beside its reference, then ship.
5. **Round 2 — redesign from my own usage notes.** After scoring my first set I staged 14 changes (too "rectangly", no bulk editing, unclear controls, the app guessing names). They were turned into a new design lock (`design/DESIGN-v2.md`), a SwiftUI design system (`design/DESIGN-SYSTEM.md`), a core rework (defaults with override semantics, bulk ops with an undo journal, proxies, an agent API) and rebuilt screens — again in parallel branches with independent reviews, a lossless schema migration verified against my real data, and a final end-to-end review. Decisions are logged in `DECISIONS-R2.md` and `design/*-DECISIONS*.md`.
6. **Round 3 — fixes from daily use**, same process: stage moves back/forward, Remove from queue, grid clips that play (with sound) only on hover, grouped post cards, a quieter paused state. A reviewer caught a real data bug before it shipped (removing a partly posted clip from the queue would have dropped its remaining platforms).

The commit history shows that flow (`Co-Authored-By` lines mark agent-written commits). Design artifacts are in `design/` (`INVENTORY.md`, `DESIGN.md`, `REFS.md`, text-style mockups) and the decision page is `DECISIONS.html` (its third-party reference images aren't published).

## Run it

Requires macOS 15+, a Swift 6 toolchain (Xcode or Command Line Tools) and `ffmpeg` (`brew install ffmpeg`).

```bash
swift build && swift test                  # 208 tests
scripts/build-app.sh                       # builds "build/DJ Queue.app" with the djq CLI inside
scripts/build-app.sh --install             # copies to ~/Applications and links ~/bin/djq (keeps the replaced build)
```

**Auto-update (v0.6.0+).** Once installed, every commit to `main` installs itself. A LaunchAgent watches the branch; the
runner builds and tests the commit in a scratch checkout (never the working tree or the real database), backs up the
database, installs, restarts the engine and checks that every clip's id, score and title survived and Doctor found no
new errors. A failed check rolls back to the previous build. Docs-only commits are skipped. With the window open it
waits as **Update ready** (What's new · Restart & update · Later); failing tests show **Update blocked**.

```bash
djq autoupdate status                      # on/off, installed build, main, ready/blocked, last result
djq autoupdate on | off                    # load / unload the watcher
djq autoupdate run                         # check main now (the same path a commit takes)
djq autoupdate rollback [--restore-db]     # back to the kept previous build
djq autoupdate log [--run]                 # the log, or the last run's build and test output
```

The app reads session folders at `~/Movies/DJ Video/Sessions/<date – name>/videos.json` (written by my CapCut export scripts). To run against a scratch copy instead of real data, set `DJQ_ROOT` (the "DJ Video" folder) and `DJQ_HOME` (database and logs) and launch the binary inside the bundle directly. `DJQueueApp --snapshot <dir>` renders every screen in light and dark.

## Layout

```
Sources/DJQCore/        core library — models, store, intake, captions, validation
  Render/               Core Text overlay, media helpers, ffmpeg renderer
  Engine/               queue, planner, scheduling, post actions, engine loop, Doctor
Sources/djq/            CLI
Sources/DJQueueApp/     SwiftUI app — queue, week, today, library, posts, health, settings, editor, menu bar
Tests/DJQCoreTests/     Swift Testing suite
Sources/DJQueueApp/DesignSystem/  tokens + components (shadcn-style anatomy in SwiftUI)
skills/                 Claude skills: Doctor report, agent access via djq, djq-daddy build process (plan → review → ship)
scripts/prefill_titles.py  upstream title-suggestion formatter for agents
design/                 inventory, design specs v1/v2, design system, decision logs
```

## Status

Phase 1 (manual publishing) is in daily use (v0.6.0), redesigned in round 2 and refined in rounds 3 and 4 (tooltips and undo everywhere; stage = readiness, one list header with a Filters popover, lists that show the edited clip; auto-update on every commit to main). Next: a Postiz publisher so posts go out with the Mac off, analytics and opt-in reposting of underperforming posts.

## License

MIT — see [LICENSE](LICENSE).
