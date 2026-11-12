# DJ Queue

A native macOS app that runs my DJ content pipeline: it turns raw 4K clips from a DJ set into vertical short-form videos, takes photo posts and carousels too, plans what posts where and when across six platforms, renders the final files in the background, and tracks every post — including missed slots, failures and copyright blocks.

Built for my own use as DJ Lovd (TikTok, Instagram, Facebook, YouTube Shorts, Threads, X). SwiftUI + AVFoundation + SQLite + ffmpeg, ~1,050 automated tests. Designed, specified and shipped with a team of AI coding agents that I directed — v1 in one day, then a full redesign the next — see [How it was built](#how-it-was-built).

![Queue](docs/media/queue.jpg)

## See it move

Recorded off screen from the app's own click-through checks: each frame is a real step the check clicks, types or scrubs through.

| Timed texts — add a second and third text, each with its own time and look | Playback — each text shows only in its own window |
|---|---|
| ![Adding timed texts in the editor](docs/media/timed-text.gif) | ![Scrubbing through a clip with three timed texts](docs/media/timed-text-playback.gif) |
| **⌘K — search everything** (a caption, a week, a setting) | **Captions on many clips at once** |
| ![Searching clips, weeks and settings from ⌘K](docs/media/search.gif) | ![Bulk caption dialog](docs/media/bulk-captions.gif) |
| **Caption in the editor** — template, hashtag groups, live preview | **Send to Queue** — the one step out of Edit |
| ![Editing a caption in the editor](docs/media/editor-caption.gif) | ![Sending a clip to the Queue](docs/media/send-to-queue.gif) |
| **Phone previews** — the real caption and handle on each platform's UI | **Preview equals export** — the editor canvas (left) beside frames of the rendered MP4 (right) at 2, 5, 7.5, 10 and 18 s |
| ![Platform previews: TikTok, Instagram, Facebook, YouTube, Threads, X](docs/media/platform-previews.gif) | ![Editor canvas beside the exported MP4 as timed texts come and go](docs/media/preview-vs-export.gif) |
| **Editor keys** (v0.13.0) — Space plays right after typing, ← → jump 2 s (5 s here), ↓ opens the next clip | **Arrow keys jump** — pick the step and try it on the strip, in Settings → Playback or beside Play |
| ![Space, arrow jumps and ↓ in the editor](docs/media/editor-keys.gif) | ![Settings → Playback, Arrow keys jump with its try-it strip](docs/media/settings-arrow-keys.jpg) |

**Versions and reposts (v0.14.0).** Each text version of a clip can be marked *Ready to repost*, so the repost cycle can pick it up; marking one never moves the clip or schedules anything. Bulk edits reach every version except captions, and the bulk dialogs say so.

| Ready to repost — a switch for the version you're editing, and on each version | Bulk edits on clips with several versions |
|---|---|
| ![Marking v2 ready to repost in the editor](docs/media/repost-ready.gif) | ![Reset to defaults says what reaches every version](docs/media/bulk-versions.jpg) |
| **Every version in one list** | **Filters › Reposts: Ready to repost** |
| ![Version list with Ready to repost switches](docs/media/repost-versions.jpg) | ![Library filtered to clips with a version ready to repost](docs/media/repost-filter.jpg) |

**Photo posts and set-time posts (v0.15.0).** A photo, or a carousel of several, goes through the same life as a clip: add it, edit it (shape, a crop per photo, texts on the photos you pick, caption, hashtag groups), send it to the Queue with no score, and track it on the Calendar. YouTube Shorts is skipped because it takes video only, and a carousel longer than a platform allows sends its first photos there and says so. Any Queue item, photo or clip, can also go out at an exact day and minute, outside the regular schedule, without moving anything else.

| Add photos — pick or drop them, one carousel or a post per photo | The photo editor — crop each photo, put a text on photos 2–3, reorder, platform notes |
|---|---|
| ![Adding three photos as a carousel and stepping through them](docs/media/photo-import.gif) | ![Editing a carousel: crop, text on a range of photos, new cover](docs/media/photo-editor.gif) |
| **Post at a set time** — pick the day and minute, see when each platform goes out, then it's on the Calendar | **The dialog** — quick times, the time in your zone, one row per platform |
| ![Setting a time for a photo post and seeing it on the Calendar](docs/media/post-at.gif) | ![Post at a set time dialog](docs/media/post-at-dialog.jpg) |
| **A crop per photo** — the whole photo with the crop, thirds grid and zoom | **Instagram and 9:16** — said before the Queue, with the two fixes one click away |
| ![Cropping one photo of a carousel](docs/media/photo-editor-crop.jpg) | ![The 9:16 note for Instagram with its one-click fixes](docs/media/photo-editor-shape.jpg) |
| **Calendar** — set-time items show their own time with a clock mark beside the regular plan | **A clip at a set time** — YouTube stays out of its quiet hours, and the dialog says where it moves |
| ![Calendar week with photo posts at set times](docs/media/calendar-set-time.jpg) | ![YouTube moved out of the quiet window](docs/media/post-at-youtube.jpg) |
| **Photos in Edit** — a Photo or Carousel mark where clips show their kind, and no score | **Preview equals export** — the editor canvas (left) beside the posted JPEG (right) |
| ![Photo posts in the Edit list](docs/media/photos-in-edit.jpg) | ![Editor canvas beside the exported JPEG](docs/media/photo-preview-export.jpg) |

**Failed posts heal themselves (v0.16.0).** A post that fails goes back through the queue by itself until it's out: an hour later, six hours later, then the platform's next open slot each day, with freshly uploaded media and no limit on tries. YouTube's upload quota resets at midnight Pacific, so its retries go to the next YouTube slot after that. While it waits you see one calm *Retrying Thu 8:00 am* chip and nothing to do. Only what the app can't fix asks for you: a copyright or policy block, a file a platform won't take, or a channel whose Postiz sign-in broke, which is one *Reconnect* item per channel while its posts wait and then go out on their own. *Post now* on a Postiz platform now sends it through Postiz.

| Retrying is a quiet chip, never a red error | One item per channel that needs signing in again |
|---|---|
| ![Posts list and inspector with a retrying post](docs/media/self-healing.gif) | ![Reconnect Threads in Postiz, posts wait](docs/media/self-healing-signin.jpg) |

**Photo with audio (v0.17.0).** Pick a photo and an audio file and DJ Queue makes a video of that photo, as long as the audio. The whole photo shows by default, in a 9:16 video over a blurred copy of itself, so a flyer or a square photo loses nothing; Fill the frame crops it like a clip instead. From then on it is a clip: the clip editor (trim, timed texts, cover, captions), the Queue with no score, the same loudness as every clip, and every platform a video posts to, YouTube Shorts included. Add audio from a photo post's editor or its ⋯ menu, or choose it in the import sheet and every photo becomes its own video. Change the audio or take it off again while nothing of it is scheduled; each step has Undo. The photo and the audio you picked are only read.

| Add audio — the photo's editor carries on as the clip editor; change the audio or take it off again | Photos with audio in one go — each photo becomes its own video |
|---|---|
| ![The editor as a photo post gets its audio: no audio yet, the video being made, the clip editor with the audio's name and length, then the audio changed and removed](docs/media/photo-audio.gif) | ![The import sheet with an audio file chosen for two photos](docs/media/photo-audio-import.jpg) |
| **Whole photo or Fill the frame** — one switch under the audio; Fill asks for the crop, Whole has nothing to fix, also after zooming in and Crop's Reset | **The post** — the whole photo over a blurred copy of itself, with a timed text |
| ![Switching between Whole photo and Fill the frame in the editor, then zooming the crop in and resetting it](docs/media/photo-audio-fit.gif) | ![A frame of the rendered post: the whole photo across the middle of a 9:16 video](docs/media/photo-audio-whole.jpg) |

**Text boxes keep the cursor (v0.17.1).** Click anywhere in a text box and type, or press Return in the middle of a line, and the cursor stays where you put it. Before, every edit in the middle of the Text on the video sent the cursor to the end, and a Return in an emptied box brought the Title back into it. One fix in the shared text box covers the Text, the caption, each platform's own caption, templates and notes, and a hidden check clicks, types and presses Return in each of them, watching the cursor, the box's height and its scroll every 8 ms.

| Return in the middle of a line, in the Text and the caption | The cursor stays right after the new line |
|---|---|
| ![Typing three lines in the Text box, clicking after "Afro" and pressing Return, then the same in the caption](docs/media/text-fields.gif) | ![The Text box split at the click, with the cursor at the start of the new line and the video showing the four lines](docs/media/text-fields-split.jpg) |

**32 texts and a countdown (v0.18.0).** A clip can now hold 32 timed texts (it was 12), enough for a quiz version with a header, three questions and a closing line. Any text after the first can be a **countdown**: pick Countdown 3 (or 5, or 10) and that one text shows 3, 2, 1, a second each, ending where the text ends, so a 3-2-1 takes one slot instead of three. Leave the text empty for just the number, or type `Next song in {n}` to put words around it. The export draws exactly what the editor shows, one number per frame. Agents use `djq overlay add <video> --countdown 3 --end 9`.

| Countdown 3 on one text: 3, 2, 1, then words around the number | 32 texts on one clip |
|---|---|
| ![Stepping through a countdown text in the editor: 3, then 2, then 1, then "Next in 1"](docs/media/countdown.gif) | ![The editor with all 32 text chips and the texts on the video](docs/media/thirty-two-texts.jpg) |

## What it does

The app follows a clip's life — **Score → Edit → Queue → Calendar** — with one job and one primary action per screen, on a calm, rounded design system modelled on ChatGPT's look and shadcn/ui component anatomy.

- **Intake** — watches my session folders; every clip exported from my CapCut markers shows up automatically. Renamed files are re-found by content fingerprint; deleted files are flagged, never lost.
- **Score & queue** — I score each clip 0–100 on a large autoplaying preview; the queue orders the backlog worst → best (to warm up new accounts) or best → worst. Every list has Cards / Grid / Single / List views and one shared header (search, view modes, page chips, one Filters popover with removable chips, sort; remembered per page, ⌘F to search). Lists show each clip as it will post: small background-generated proxies carry the crop and trim, the text overlay is drawn live during its window, and covers include the text. Small previews show their cover and play only under the pointer; large ones play by themselves.
- **Search everything** — ⌘K finds clips (by caption, overlay text, hashtags, notes and file name too), posts, weeks ("12 nov"), sessions, every setting and every action from anywhere in the app, literally and without guessing. ⌘F stays a filter for the list on screen.
- **Keyboard-first editor** — Space plays or pauses even right after typing (a click on the picture or Esc lets go of the field), ← / → jump by a step you choose (2 s by default, ⇧ for one frame) with a try-it strip in Settings, and ↑ / ↓ move to the previous or next clip.
- **Photo posts** — add one photo or a carousel (JPEG, PNG, HEIC, WebP, TIFF; the app keeps its own copy and never touches the original). The same editor opens in a photo mode: a shape for the post (4:5 by default), a crop per photo, the same texts and looks shown on the photos you choose, captions, templates and hashtag groups, with the canvas drawn by the code that makes the posted JPEGs. Photos need no score.
- **Photo with audio** — one photo plus an audio file (MP3, M4A, WAV, AIFF, FLAC, or the sound of a video; up to 20 minutes) becomes a real video file in a few seconds: the whole photo in a 9:16 frame over a blurred copy of itself, or filling the frame with your own crop. It then behaves as a clip everywhere, marked "Photo + audio", needs no score, and asks for a title before it goes to YouTube. `djq photo add <photo> --audio <file>` does the same from the command line.
- **Post at a set time** — an exact day and minute for any Queue item, on every platform at once, outside the posts-per-day plan. It never takes a regular place, nothing else moves for it, and the scheduler never shifts it.
- **Vertical editor** — crop a 4K 16:9 frame to 9:16, trim starting on my original markers (with grace to extend), overlay text (up to 32 timed texts like CapCut, each with its own start, end, font and colours, tucked behind a collapsed Advanced row, and a countdown text that shows 3, 2, 1 in one slot), captions with per-platform limits, a cover frame, versions for reposts (each one marked *Ready to repost* when it's done), multi-platform safe zones and realistic phone previews of each platform's UI with the real caption and handle.
- **No intelligence in the app, by design** — the app is a UI over scripts. Song names and titles come from metadata my agents write (`title_suggestions` in the manifest) and show up as chips; when a name is ambiguous, *Ask an agent* copies a ready-made prompt. Outside agents read and change everything through the `djq` CLI (JSON in/out), documented as a Claude skill.
- **Stage = readiness** — there are no Ready / Needs edit labels: a clip in Edit isn't ready, the Queue only ever holds ready clips, and a queued clip that becomes invalid (crop cleared, a platform limit changed, file missing) moves back to Edit by itself with a chip saying why. Any clip can move one stage back or forward from wherever it is (e.g. *Back to Edit* from the Queue; a scheduled clip can go back to the Queue), with the reason shown when a move isn't allowed (nothing already posted is ever pulled back) and one-step undo.
- **Every control explains itself** — every icon-only button and badge has a tooltip (label, shortcut, and why it's disabled), enforced by a lint in the test suite; every data-changing click has Undo or asks first, and ⌘Z always undoes the most recent action (a whole editor session counts as one).
- **Defaults + bulk editing** — new-clip defaults for frame, trim, text, cover, captions and platforms (clips store only overrides, so changing a default updates every untouched clip); bulk actions with a confirmation sheet showing exactly what changes and one-step undo, a Caption dialog that sets a template and several hashtag groups on many clips with a live preview, and a Crop dialog that moves many clips at once and checks them one by one.
- **Queue is the last step** — only my Send to Queue moves a clip out of Edit, and being in the Queue is my approval: the engine keeps every Queue clip on the calendar up to 30 days out, and I can drag, swap, pin or unschedule anything before it goes.
- **Calendar** — Day, 3 Day, Week and Month views of the videos going out and where each one posts, with a filter per platform.
- **Background engine** — runs at login, renders scheduled posts ahead of time (1080×1920 H.264, loudness-normalised to −14 LUFS), and notifies me when each platform post is due.
- **Manual publisher (phase 1)** — the Calendar's Day view: drag the file into the upload page, copy the platform-specific caption, mark posted with the URL. Built behind a `Publisher` interface.
- **Postiz publisher (phase 2, v0.7.0)** — per platform, Manual or Postiz. Once a clip is scheduled and a render exists, the engine uploads it and schedules it in Postiz at the slot, so posts go out with the Mac off; edits, re-renders and plan changes replace or cancel the Postiz post, and the engine syncs back the state, the live link, failures and copyright blocks. A one-switch Test run (TikTok inbox, YouTube unlisted, Postiz drafts for the rest), a request budget, and a fallback to the Calendar for any platform Postiz can't take. Contract: [`docs/postiz.md`](docs/postiz.md); first-run checklist: [`docs/postiz-test.md`](docs/postiz-test.md).
- **Failure handling** — missed slots shift that platform's plan without ever double-posting. A post that fails retries by itself until it goes out (+1 h, +6 h, then the platform's next slot every day; YouTube's quota on its next slot after midnight Pacific), with fresh media and the retry already in Postiz so it goes out with the Mac off; it shows one calm "Retrying Thu 8:00 am" chip and nothing to audit. A channel whose Postiz sign-in broke is one "Reconnect TikTok in Postiz" item while its posts wait and then go out by themselves. Only copyright blocks and failures a retry can't fix ask for you.
- **Doctor** — `djq doctor` checks everything (manifests, missing files, renders, overdue posts, runway, DB integrity, disk, tools) and prints a report an AI agent can act on, paired with a skill that documents the safe fix for every finding.

## Screens

| Score | Edit |
|---|---|
| ![Score](docs/media/score.jpg) | ![Edit](docs/media/edit.jpg) |
| **Editor — timed texts on the timeline** | **Editor — safe zones per platform** |
| ![Editor with three timed texts](docs/media/editor.jpg) | ![Editor safe zones](docs/media/editor-zones.jpg) |
| **Editor — platform previews side by side** | **Captions on many clips** |
| ![Editor platform previews](docs/media/editor-preview.jpg) | ![Bulk caption dialog](docs/media/bulk-caption.jpg) |
| **Calendar: Week** | **Calendar: Month** |
| ![Calendar, Week view](docs/media/calendar-week.jpg) | ![Calendar, Month view](docs/media/calendar-month.jpg) |
| **Calendar: Day** | **⌘K search** |
| ![Calendar, Day view](docs/media/calendar-day.jpg) | ![Command palette](docs/media/search.jpg) |
| **Posts — one card per clip and day** | **Library** |
| ![Posts](docs/media/posts.jpg) | ![Library](docs/media/library.jpg) |
| **Settings — new clip defaults** | **Settings — captions and hashtag groups** |
| ![Settings, new clip defaults](docs/media/settings-defaults.jpg) | ![Settings, captions](docs/media/settings-captions.jpg) |
| **Queue in dark mode** | **Edit — cards** |
| ![Queue, dark](docs/media/queue-dark.jpg) | ![Edit cards](docs/media/edit-cards.jpg) |

*Screens and clips are captured off screen from a scratch copy of my clips, with sample titles mixed in; nothing in them posts. `scripts/live-checks.sh` captures them and `scripts/readme-media.sh` turns the captures into these files.*

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
  P[Publisher protocol<br/>Manual · Postiz]
  VJ -- intake --> ENG
  UI <--> DB
  CLI <--> DB
  ENG <--> DB
  ENG --> R --> OUT[Ready to Post/Shortform]
  ENG --> P --> N[Notifications · Calendar · Postiz]
```

- **One process, three roles.** A LaunchAgent starts the app in agent mode at login; the same process hosts the engine loop, the menu-bar item and (on demand) the main window. macOS only delivers notifications from an app bundle, which drove this design. A file lock guarantees one engine per database; the CLI shares the same WAL-mode SQLite file.
- **Core library (`DJQCore`)** holds everything testable: models, store, intake, validation, captions, planner, engine, renderer, Doctor. The app and the CLI are thin shells over it.
- **Data model.** Videos (identity from the manifest; app-owned fields like score are never overwritten by intake), edits, text versions with carry-forward, weekly plans, and platform posts with an append-only history. A fix or repost creates a new attempt; history is never rewritten.

## Engineering highlights

- **Preview equals export.** Overlay text (including colour emoji) is rendered once with Core Text into a transparent PNG; the editor draws that exact image over the player and ffmpeg composites the same image into the final video. Measured difference between the editor preview and a frame grabbed from the rendered MP4: ~1.5/255 (codec noise). Timed texts are checked the same way at several points in the clip (the GIF above).

  ![Preview vs export](docs/media/preview-vs-export.jpg)
  *Editor preview (left), frame from the exported MP4 (middle), difference ×8 (right).*

- **Loudness.** Two-pass EBU R128 normalisation so a phone-mic clip and a clean desk-feed clip play at the same volume (−11.2 and −13.2 LUFS sources → −14.1 LUFS both, true peak ≤ −1 dBTP).
- **Never double-post.** Every planner operation (auto-schedule, swap, move, push, skip, reset, missed-day shifts) goes through one placement rule; an invariant check runs after every operation in the tests, and a reviewer fuzzed 80 × 60 random operations with zero violations.
- **Time is hard.** Slots are scheduled in America/New_York; a reviewer-found bug where every slot was an hour off on the DST change day is covered by a test.
- **Crash-safe background work.** Kernel `flock` per render plus atomic status claims, so the app and the CLI can't render the same file; ffmpeg timeouts; failed renders back off instead of starving the queue.
- **Never touch source footage.** The app writes only to its own output folders; enforced in review and checked in the final acceptance run.
- **Checked in the real app, off screen.** Every build runs click-through checks against the real app (clicks, typing, scrubbing, hovers) with its windows parked off every display, players muted and a guard that fails the run if anything reaches the screen or takes focus. The GIFs above are those runs.

## How it was built

I wrote the product spec, then directed AI coding agents (Claude Code) through a structured process I use for larger builds:

1. **Design before code** — an inventory of every screen, control and state (~110 slots), a locked visual reference per slot, and one decision page with 28 product/design questions and pictures (text styles rendered on real frames from my footage). I answered once; the answers became binding (`DECISIONS.md`).
2. **Contracts, then parallel work** — a foundation layer and an API contract (`ARCHITECTURE.md`), then four agents building in parallel on separate branches with disjoint file ownership: renderer, engine + CLI + Doctor, main UI, editor.
3. **Independent review on every branch** — a fresh reviewer agent per milestone checked spec fidelity and code quality, with probes. Real bugs caught this way: a double-post path after a missed day, an edit hash that would have re-rendered and overwritten files whenever a platform was toggled, a DST off-by-an-hour, trim handles that stuck, crop maths 1 px off the export.
4. **Integration and a final end-to-end review** against the spec's acceptance criteria on my real clips, with screenshots of every screen beside its reference, then ship.
5. **Round 2 — redesign from my own usage notes.** After scoring my first set I staged 14 changes (too "rectangly", no bulk editing, unclear controls, the app guessing names). They were turned into a new design lock (`design/DESIGN-v2.md`), a SwiftUI design system (`design/DESIGN-SYSTEM.md`), a core rework (defaults with override semantics, bulk ops with an undo journal, proxies, an agent API) and rebuilt screens — again in parallel branches with independent reviews, a lossless schema migration verified against my real data, and a final end-to-end review. Decisions are logged in `DECISIONS-R2.md` and `design/*-DECISIONS*.md`.
6. **Round 3 onward — fixes from daily use**, same process, one decision log per round (`DECISIONS-R<N>.md`): stage moves, grouped post cards, tooltips and undo everywhere, auto-update, Postiz, retries, ⌘K search, the Calendar, timed texts, and off-screen live checks. Every fix is committed, pushed and shown in this README.

The commit history shows that flow (`Co-Authored-By` lines mark agent-written commits). Design artifacts are in `design/` (`INVENTORY.md`, `DESIGN.md`, `REFS.md`, text-style mockups) and the decision page is `DECISIONS.html` (its third-party reference images aren't published).

## Run it

Requires macOS 15+, a Swift 6 toolchain (Xcode or Command Line Tools) and `ffmpeg` (`brew install ffmpeg`).

```bash
swift build && swift test                  # the full suite
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

The app reads session folders at `~/Movies/DJ Video/Sessions/<date – name>/videos.json` (written by my CapCut export scripts). To run against a scratch copy instead of real data, set `DJQ_ROOT` (the "DJ Video" folder) and `DJQ_HOME` (database and logs) and launch the binary inside the bundle directly. `scripts/live-checks.sh <dir>` renders every screen in light and dark and runs the click-through checks, all off screen; `scripts/readme-media.sh <dir>` turns that run into the README's stills and GIFs in `docs/media/`.

## Layout

```
Sources/DJQCore/        core library — models, store, intake, captions, validation
  Render/               Core Text overlay, media helpers, ffmpeg renderer
  Engine/               queue, planner, scheduling, post actions, engine loop, Doctor
Sources/djq/            CLI
Sources/DJQueueApp/     SwiftUI app — queue, calendar, library, posts, health, settings, editor, menu bar, ⌘K search
  Snapshot/             off-screen captures, click-through scripts and the screen guard behind scripts/live-checks.sh
Tests/DJQCoreTests/     Swift Testing suite
Sources/DJQueueApp/DesignSystem/  tokens + components (shadcn-style anatomy in SwiftUI)
skills/                 Claude skills: Doctor report, agent access via djq, djq-daddy build process (plan → review → ship)
scripts/                build, tests, live checks, README media, title-suggestion formatter
docs/media/             README stills and GIFs
design/                 inventory, design specs v1/v2, design system, decision logs
```

## Status

In daily use (v0.12.1). Phase 1 (manual publishing) shipped first, then the round-2 redesign and fixes from daily use: tooltips and undo everywhere, stage = readiness, auto-update on every commit to `main` (v0.6), the Postiz publisher (v0.7), own hashtag groups and caption templates (v0.8), automatic retries (v0.9), ⌘K search (v0.10), Queue as the last step with a Day / 3 Day / Week / Month Calendar (v0.11), timed texts with their own look (v0.12) and live checks that run entirely off screen (v0.12.1). Next: analytics-driven, opt-in reposting of underperforming posts and a one-way Notion sync of posts.

## License

MIT — see [LICENSE](LICENSE).
