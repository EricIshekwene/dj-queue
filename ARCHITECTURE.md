# DJ Queue — Architecture and build contract (north star for every agent)

**Goal (Eric's words):** a local Mac app that controls what DJ Lovd short-form videos get posted, when and how — "the app is kind of complex, I need to understand everything" — clean, modern, low cognitive load, every control present but presented simply.

**Binding sources, in order:** `DECISIONS.md` (Eric's answers) → `~/Movies/DJ Video/_spec/DJ Queue – App Spec.md` → `design/DESIGN.md` + `refs/` (presentation) → this file (code layout and contracts). Refer to Eric as they/them.

## Hard rules

- Never modify, move or delete anything under a session's `Video/`, `Audio/`, `Other/`, `Clips/`, or CapCut projects. The app writes only to `Ready to Post/Shortform/`, `Posted/Shortform/`, moves long-form between the Longform folders on "Mark posted", and its own folders (`~/Library/Application Support/DJ Queue`, `~/Library/Logs/DJ Queue`, `~/Movies/DJ Video/_app/`).
- Tests use a temp `Fixture` (see `Tests/DJQCoreTests/Fixtures.swift`) or `DJQ_ROOT`/`DJQ_HOME` env vars — never the real database. Reading real clips under `~/Movies/DJ Video/Sessions/` for render proofs is fine; write proof outputs to the scratch/evidence dir you are given, not into session folders.
- Never use ffmpeg `drawtext` (colour emoji breaks). Overlay text is a Core Text PNG (`TextOverlay`), used by the editor preview and by the export.
- No network calls, no paid services, no posting to any platform.
- Build: `swift build`. Tests: `scripts/test.sh`. **Until Eric accepts the Xcode license, prefix every swift/python3/xcrun command with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`** (or `export` it once per shell) (Swift Testing; works with Command Line Tools). Swift 5 language mode. macOS 15+ APIs.
- Don't commit unless told to; your parent merges. Don't edit files you don't own — if you need a change in a shared file, write it in your final report.

## Layout

```
Package.swift                   (parent owns)
Sources/DJQCore/                core library (no UI)
  Models.swift Store.swift SQLite.swift Paths.swift Log.swift      (parent owns — foundation)
  Intake.swift Prefill.swift Captions.swift Validation.swift Defaults.swift Contracts.swift (parent owns)
  Render/                       RENDER agent: TextOverlay, Renderer (RenderService), Media (probe, thumbnails, frames)
  Engine/                       ENGINE agent: Queue, Planner, PostActions, ManualPublisher, Engine, Doctor, Backup, LaunchAgent
Sources/djq/                    ENGINE agent: CLI
Sources/DJQueueApp/             UI agents: SwiftUI app (main window + MenuBarExtra + engine host)
Tests/DJQCoreTests/             each agent adds its own test files (prefix with its area)
scripts/                        build-app.sh (UI agent), test.sh, install helpers
```

## Process model

One app bundle, `~/Applications/DJ Queue.app` (bundle id `com.djlovd.queue`), launched at login by the LaunchAgent `~/Library/LaunchAgents/com.djlovd.queue.engine.plist` (RunAtLoad + KeepAlive, runs the app with `--agent`). The process hosts the **engine loop**, the **menu-bar item** and, on demand, the **main window** (activation policy switches to `.regular` while a window is open). Closing the window never stops the engine. Notifications need an app bundle, which is why the engine lives in the app process (deviation from the spec's "headless engine", recorded in DESIGN.md). The `djq` CLI opens the same SQLite file (WAL) and posts `ChangeSignal` after writes.

**Auto-update (v0.6.0, `Sources/DJQCore/AutoUpdate/`, DECISIONS-R4-AUTOUPDATE.md).** A second LaunchAgent, `com.djlovd.queue.autoupdate`, runs `djq autoupdate run --trigger watch` from the installed bundle whenever `refs/heads/main` (or `packed-refs`, `refs/tags`) of the source checkout changes, or the app writes `request.json` / `window.json` under `<app support>/autoupdate/`. One run at a time (`run.lock`): gate (`scripts/test.sh` + `scripts/build-app.sh` in a scratch clone with scratch `DJQ_HOME`/`DJQ_ROOT`) → wait for no render → DB backup → install (old bundle kept in `autoupdate/previous/`) → `launchctl kickstart -k` the engine → verify (fresh engine heartbeat, ids/scores/titles/count via `djq videos --json`, no new Doctor errors) → notice. The runner is the only writer of `state.json`; the app reads it for the banner, menu-bar dot and Settings, and delivers its notices. Bundles carry `DJQGitCommit` and `DJQSchemaVersion` in Info.plist.

**Title and Text suggestions (round 5, schema v4, DECISIONS-R5-TEXT.md).** Two separate tables of the same shape: `title_suggestions` (the clip's one-line Title) and `text_suggestions` (the overlay text on the video, line breaks kept). `Store.suggestions(_ kind: SuggestionKind, videoId:)`, `addSuggestions(…, kind:)`; intake syncs both from `videos.json`; `djq suggest` and `djq video --json` carry both; the editor's Title and Text sections each show their own chips.

## Contracts (exact public API — other agents compile against these names)

Foundation (exists): `Store` (all persistence, `refreshState`, `resolvedVersion`, `logEvent`, `heartbeat`, `markNotified`, kv), `Intake(store:).run() -> IntakeReport`, `Prefill.text(tag:kind:rules:)`, `PrefillRules.load(paths)`, `Captions.caption(for:version:video:sessionName:sets:templates:settings:)`, `Captions.youtubeTitle`, `Captions.hashtags`, `Validation.issues(video:store:)`, `Validation.platformIssues`, `VersionResolver`, `DayMath`, `Contracts.swift` protocols/types.

### RENDER agent provides (`Sources/DJQCore/Render/`)

```swift
public enum TextOverlay {
  public static func image(for v: ResolvedVersion, aspect: Aspect) -> CGImage?          // nil when !v.hasText
  public static func png(for v: ResolvedVersion, aspect: Aspect) -> Data?
  @discardableResult public static func write(for v: ResolvedVersion, aspect: Aspect, to url: URL) throws -> Bool
  public static func textBounds(for v: ResolvedVersion, aspect: Aspect) -> CGRect?       // in output pixels, top-left origin (for drag hit-testing)
  // Round 16: the same four for one `TextLayer` (image, png, write, textBounds), and `image(for: [TextLayer], aspect:)` stacked.
}
public struct ProbeInfo: Sendable, Hashable, Codable { duration: Double; width: Int; height: Int; fps: Double; hasAudio: Bool; size: Int64; videoCodec: String; audioCodec: String? }
public enum Media {
  public static func probe(_ url: URL) throws -> ProbeInfo
  public static func thumbnail(store: Store, video: Video, at seconds: Double? = nil, maxHeight: Int = 320) -> URL?  // cached JPG in paths.thumbs; uses edit crop when set
  public static func frame(_ url: URL, at seconds: Double, maxSize: CGSize) -> CGImage?   // AVAssetImageGenerator, exact time
}
public final class Renderer: RenderService {
  public init(store: Store)
  public static func outputName(video: Video, versionNo: Int, platform: Platform?) -> String   // "<video name> – v<n>[ – <Platform>].mp4"
  public func measureLoudness(_ url: URL) throws -> LoudnessInfo
  public var onProgress: (@Sendable (String, Double) -> Void)?   // (renderId, 0…1)
  // + RenderService
}
```

### ENGINE agent provides (`Sources/DJQCore/Engine/`, `Sources/djq/`)

```swift
public final class Queue {
  public init(store: Store)
  public func ordered(platform: Platform? = nil) throws -> [Video]   // ready + unplanned backlog in posting order (sort + tie-break)
  public func toScore() throws -> [Video]        // short-form, not excluded/missing, score == nil
  public func needsEdit() throws -> [Video]      // scored, state needs_edit
  public func runway() throws -> Runway
}
public final class Planner {
  public init(store: Store)
  public func weekStart(for date: Date) -> String
  public func slots(week: String) throws -> [PlanSlot]
  public func autoSchedule(now:dryRun:revalidate:) throws -> AutoScheduleReport   // keeps every Queue clip on the calendar (round 13)
  public func proposeWeek(_ week: String) throws -> [PlanSlot]   // internal seam: fills open days of a draft week
  public func approveWeek(_ week: String) throws                // internal seam: creates PlatformPosts for every slot × active platform
  public func rebuildWeek(_ week: String) throws                // internal seam: drops unpinned, un-posted slots, back to draft
  public func pushPlan(from date: String, days: Int) throws
  public func pin(videoId: String, date: String) throws
  public func remove(slotId: String) throws
  public func swap(_ a: String, _ b: String) throws
  public func move(slotId: String, to date: String) throws
  public func postToday(videoId: String) throws
  public func skipNext(videoId: String) throws
}
public final class PostActions {
  public init(store: Store)
  public func markPosted(postId: String, url: String, at: Date? = nil) throws     // validates host against Platform.urlHosts
  public func reportProblem(postId: String, type: ErrorType, message: String, raw: String? = nil) throws
  public func resolveCopyright(postId: String, _ r: CopyrightResolution) throws
  public func fixed(postId: String) throws                                        // failure cause fixed → re-queue next day, ≥3 h stagger
  public func reset(postId: String) throws
  public func skip(postId: String) throws
  public func repost(videoId: String, platform: Platform) throws                  // next version, cooldown, staggered
  public func setMetrics(postId: String, _ m: PostMetrics) throws
  public func markLongformPosted(videoId: String, url: String) throws             // moves file Ready to Post/Longform → Posted/Longform
  public func dueToday(now: Date) throws -> [PlatformPost]                        // the Calendar's rows for today
  public func problems() throws -> [PlatformPost]                                 // failed / copyright / overdue, unresolved, no retry coming
}
public final class ManualPublisher: Publisher { public init(store: Store, renderer: RenderService) }
public struct TickReport: Sendable { public var started: Date; public var steps: [String: String]; public var errors: [String] }
public final class Engine {
  public init(store: Store, renderer: RenderService?, publisher: Publisher?, notifier: Notifier)
  public func tick(reason: String) -> TickReport     // intake → plan → render-ahead → due → missed/overdue → alerts → move/cleanup → heartbeat → backup
  public func start()                                // 60 s timer + wake/sleep observers + ChangeSignal observer (app process)
  public func stop()
  public private(set) var lastTick: TickReport?
  public var isRendering: Bool { get }
}
public final class Doctor {
  public init(store: Store)
  public func run() -> DoctorReport
  public static func markdown(_ r: DoctorReport) -> String
}
public enum Health {
  public static func awakePeriods(store: Store, since: Date) throws -> [DateInterval]   // from heartbeats; gaps > 3 min = asleep/off
  public static func missedSlots(store: Store, since: Date) throws -> [PlatformPost]    // posts that went overdue (for the timeline)
}
public enum Backup { public static func runIfDue(store: Store) throws -> URL? }       // daily, keep 14
public enum LaunchAgent { public static func install(appPath: String, paths: Paths) throws; public static func isLoaded() -> Bool; public static func uninstall(paths: Paths) throws }
```

CLI `djq`: `doctor [--json]`, `intake`, `status`, `queue`, `week [YYYY-MM-DD]`, `schedule [--dry-run]`, `today`, `prefill "<tag>" [--kind talking]`, `render <video-id> [--version N] [--platform P]`, `tick`, `posted <post-id> <url>`, `problem <post-id> <type> <message>`, `fixed <post-id>`, `reset <post-id>`, `agent install|uninstall|status`.

### UI agents (`Sources/DJQueueApp/`)

SwiftUI app per `design/DESIGN.md`. Talks only to the APIs above and `Store`. Runs `Engine` in-process (background queue). Implements `Notifier` with `UNUserNotificationCenter` (actions Post now / Shift plan / Skip / Mark posted). `scripts/build-app.sh` builds release, assembles `DJ Queue.app` (Info.plist: `LSUIElement` true, bundle id `com.djlovd.queue`, min macOS 15), ad-hoc signs, installs to `~/Applications`.

## Round 16 additions: timed texts and the text look

- **One text is still the Version fields.** `Version.moreText: [TextLayer]?` holds every text after the first and carries forward as a whole list (nil inherits, [] = none); `Version.textLook: TextLook?` is the first text's look (an empty look = back to default). Both are optional JSON keys, so nothing is rewritten, Title-follow keeps working and `hasText` still means the first text. `ResolvedVersion` adds `moreText`, `textLook` (written only when used), `firstLayer`, `allLayers` (every text, numbered), `layers` (what draws) and `hasDrawnText` (what Health's "No text" asks).
- **`TextLayers`** (`DJQCore/TextLayers.swift`) holds the pure edits, shared by the editor and `djq overlay`: `new`, `layer(ref)`, `adding`, `updating`, `removing`, `promotingNext`, `copyAdvanced`, and the cap (`maxCount`, 12 with the first text).
- **`TextOverlay`** draws a `TextLayer`. `Layout` takes the look through the same Core Text path (colour, accent by style, font with system fallback, kerning, opacity as one transparency layer); a nil look doesn't touch the path, so the PNG is byte-identical.
- **`PreviewKeys`** has the shared rules: `layerWindows` (first text as ever; an extra starting past the trim or inverted isn't drawn), `coverLayers` (what shows at the cover frame, else the first text), `layerKey` and `coverKey` for caches. `textKey` is unchanged for one plain text.
- **Renderer**: one PNG input per text, chained `overlay` filters each with its own `between(t,…)` (`Renderer.overlayGraph`). `HashInput` adds `text.look` and `moreText`, nil and absent when unused, so existing edit hashes hold and `pipelineVersion` stays.
- **`TextTimeline`** (`DJQCore/TextTimeline.swift`) is the timeline's arithmetic, pure and tested: `span`, `lanes` (first fit in list order, 4 at most), `newWindow`, `duplicateWindow`, `moved`, `snappedStart`, `clampedStart/End`, `parse`.
- **Editor:** `EditorModel.selectedText` is the one selection; `updateText` edits any text; the first text keeps its version fields. `textImages` holds one `EditorTextImage` per drawn text from a cost-capped cache keyed by `layerKey`. `textBars` is the timeline's list. `EditorDisclosures.shared` holds the open rows for the app run, and `scrollTarget` opens what it lands on.
- **Lists:** `ClipPreview.overlays` is a `[DSTimedOverlay]`, each image with its window. `DSPlayerNSView` keeps one `CALayer` per text, toggled in one time observer, with no SwiftUI redraw per frame. `AppModel.overlayCache` is keyed by `layerKey`.
- **Design system:** `DSDisclosure` (the collapsible row of Frame, Cover, Size and position, Advanced) and `DSColorSwatches` (preset swatches plus a custom well).
- **Scripted checks:** `EditorDragSurface` takes the mouse in AppKit for text bars, grips and text on the canvas, so `TextLayersScript` (`DJQ_TEXT_LAYERS_SCRIPT=<dir>`) can drive them with window events, then export and compare.

## Round 4 additions (v0.5.0)

- **Stages are readiness** (reversed in round 13: only Send to Queue moves a clip Edit → Queue) (`DJQCore/StageWording.swift`): one source for stage names, the stage control's neighbour labels ("Back to Edit", "Send to Queue"), blockers and the Edit reason chips (`ValidationIssue.chipText` / `chipOrder` / `isBlock`). Stored states (`needs_edit`, `ready`, …) are unchanged; only display names changed.
- **Revalidation** (`DJQCore/Engine/Revalidation.swift`): re-derives every short, included clip in Edit / Queue / missing-file state. Runs as the tick step `stages`, after every djq write (`Revalidation.afterWrite`), inside Settings batches (states only) and after New clip defaults saves. An invalid Queue clip lands in Edit with a "Moved to Edit: <reasons>" event; Scheduled and pinned clips stay put and show the problem. Unpinned draft-week days whose clip left the Queue are refilled; `approveWeek` re-checks first, in one transaction.
- **Edited previews** (`DJQCore/Render/PreviewStamp.swift`, `App/AppModel+Previews.swift`): one preview stamp per clip (+ version) from edits, versions, the defaults generation and the clip-row fields. `previewChanged(_:)` is the single invalidation entry (editor exit, refresh, undo). Lists play the 540-px proxy (crop/aspect/trim) with the `TextOverlay` image drawn as a layer during `PreviewKeys.textWindow`; covers composite the text via `Media.coverComposite` (shared with the renderer). Overlays live in a 64 MB cost-capped LRU (`CostCappedCache`). A proxy request for a running encode queues a follow-up job, so a stale crop never lands.
- **List header** (`DesignSystem/DSListHeader.swift`, `Shared/ClipListFilters.swift`, `Shared/ListPrefs.swift`): one header on Score, Edit, Queue, Library and Posts, with page chips, one Filters popover, applied chips + Clear all and sort, persisted per page in UserDefaults (`djq.list.<page>`). ⌘F focuses the page's search.

## Round 6 additions (v0.7.0, schema v5) — Postiz publisher

- **Contract:** `docs/postiz.md` (endpoints, payload per provider, lifecycle, test run, auth). Decisions: `DECISIONS-R6.md`.
- **Core (`DJQCore/Postiz/`):** `PostizClient` over an injectable `PostizTransport` (URLSession in the app, fakes in tests; multipart streamed from a temp file), `PostizKeyStore` (Keychain service "DJ Queue Postiz", read through `/usr/bin/security`, key on stdin only), `PostizRouter` (Manual | Postiz | fallback reason per platform), `PostizService` (publish, sync, analytics, status, channels, test payloads, link/resolve/release), `PostizPublisher: Publisher`, a shared 25-per-hour request budget in kv.
- **Schema v5:** `postiz_jobs` (one row per Postiz post DJ Queue made; survives planner deletes so it can be cancelled) and `postiz_media` (render → uploaded media). Additive; the migration backs up the DB first.
- **Engine:** tick order `… alerts, retry, render, publish, sync, proxies …`. `retry` picks up a failed post whose automatic retry waited; `sync` makes the attempt as soon as it reads the failure (`PostizRetry.swift`, DECISIONS-R9.md). `publish` reconciles every open job (cancel/replace, delete confirmed before any create) and submits Postiz-routed approved posts once their render exists (closes the old `Engine.due()` gap). `sync` maps Postiz states back onto the post state machine. Never double-post is enforced per clip + platform inside the claim transaction; a create with an unknown outcome is never resent (Doctor `postiz.create_unknown`). Posts with a live job are never overdue/shifted; posts Postiz can't take fall back to the Calendar.
- **Settings:** `Settings.publishing` (per-platform publisher, channel ids — local only —, Test run, per-provider options). Scratch `DJQ_HOME`/`DJQ_ROOT` runs never touch the Keychain or the network unless `DJQ_POSTIZ_LIVE=1`.
- **CLI/Doctor:** `djq postiz status|channels|map|publisher|test-mode|test|link|release|resolve|sync`; Doctor `postiz.*` checks (offline unless `--live`).
- **App:** Settings → Platforms → Publishing (key, connection, channels, Manual | Postiz, Test run), confirms before anything can go public, Postiz state and live links on the Calendar, Posts and the menu bar, editor cover meaning per platform, YouTube/TikTok title limits, Trim/Skip for platforms a clip is too long for.

## Round 7 additions (v0.8.0, schema v6) — caption section

- **Hashtag groups are Eric's own** (`Defaults.hashtagSets` is empty, `defaults.hashtagSetIds` = []). Schema 6
  (`DJQCore/HashtagGroupsMigration.swift`) freezes the six built-in groups' tags into `extraHashtags` for every clip with
  a post in flight or posted (captions byte-identical, proven per platform inside the migration), drops them elsewhere,
  deletes them, and is one journaled batch (`djq bulk undo`); `BulkActions.Snapshot.hashtagSets` journals the group table.
- **A written caption is literal** (WYSIWYG): `Captions.build` appends nothing; `{hashtags}` still fills (the migration gave
  every written caption without it `Captions.legacySuffix`, so its output is unchanged). `Captions.sharedCaption` is what
  the editor's field shows; `replaceHashtags` / `retag` swap the hashtags in a written caption when groups or extra tags
  change (editor and `djq bulk hashtags`).
- **YouTube title templates:** `Settings.youtubeTitleTemplates` + `defaults.youtubeTitleTemplateId` + `Version.youtubeTitleTemplateId`
  (resolved into `ResolvedVersion.youtubeTitleTemplate`, which `Captions.youtubeTitle` prefers); a typed title wins.
  `defaults.youtubeTitleTemplate` is kept in step on every save for older builds.
- **Issue → section** is core's exhaustive `ValidationIssue.Kind.editorSection` (held / missing file / unreadable → none).
- **Editor caption field** owns its text while typing (`EditorCaptionText`, `EditorModel.typeCaption` applied after
  250 ms; `fieldRevision` re-syncs it after any other change). `DSTextArea` grows to `maxHeight`, then scrolls.
  `DJQ_EDITOR_CAPTION_SCRIPT=<dir>` drives the real caption NSTextView (typing cost, mid-text edits, chips in place).
- **djq:** `hashtag-groups`, `title-templates`, `youtube-title`, `bulk youtube-title-template`.

## v0.8.3 additions (schema v7) — captions you control

Decisions: `DECISIONS-R7.md`, "v0.8.3".

- **`CaptionHold` is the one guarantee:** anything that changes what a caption is built from (default template, New clip defaults, a template's
  text, the link line, a hashtag cap, a group move) lists the clips with scheduled or posted posts that would change, then proves captions, YouTube tags and
  titles identical inside one journaled batch. It pins, freezes or writes a platform's own caption as needed, and rolls back rather than let one move.
- **`CaptionTemplates`** is the write path for templates, the default, New clip defaults, the link line and caps; the editor and Settings both call it.
  `batchActions` lists what writes clips on its own, so an open editor session moves past it and undo checks for conflicts.
- **`CaptionParts`** is pure text (`toggled`, `isOn`); `BulkActions.togglePart` applies it by clip id.
- **Bulk crop (v0.11.2):** `CropChange` (one offset from the frame's centre, per-clip overrides) is one `crop-offset` batch through `BulkActions.setCropOffset`, from the Crop dialog (`BulkCropDialog`) and `djq bulk crop-offset`. `previewCrop` plans the same crops without writing. `cropLock` stops a clip once any platform could post it, and undo obeys it. See `DECISIONS-R15.md`.
- **Bulk captions (v0.10.2):** `CaptionChange` (template, groups added, groups removed) is one `caption` batch through `BulkActions.setCaption`, from the Caption dialog (`BulkCaptionDialog`) and `djq bulk caption`. `previewCaption` runs the same `apply` and `retag` without writing. Clips with scheduled or posted posts are skipped. `djq caption-templates` manages templates through `CaptionTemplates`. See `DECISIONS-R12.md`.
- **`Captions.caption(for:)`** now also writes each tag once where a clip's tags are filled in and applies the platform's cap, so the preview,
  validation and Postiz all read one result. `sharedCaption`, the editor's field, stays uncapped.
- **Schema 7 (`CaptionRulesMigration`)** holds clips with posts against those rules at install, journaled. Undoing it needs `--force`.
- **Editor merge:** `HashtagGroups.keepingFreeze(memory:saved:base:)` brings a hold in under unsaved work.

## Round 13 additions (schema v8) — the Queue is the last step

Eric's pipeline is Score → Edit → Queue → Posted. Decisions: `DECISIONS-R13.md`.

- **Send to Queue is the only way in.** `videos.sent_to_queue` (`Video.sentToQueue`): a short clip that isn't sent is `needs_edit` even with nothing to fix. `BulkActions.send` is the one door (the stage control, `sendToQueue`/`requeue`, `makeReadyWithDefaults`, which Edit's bulk button labels Send to Queue). `Store.refreshState` clears the flag whenever a sent clip lands in Edit, so a later fix never promotes it. This reverses round 4's "stage = readiness".
- **A clip in the Queue is approved.** `Planner.autoSchedule` (`DJQCore/Engine/AutoSchedule.swift`) runs in the tick's plan step, one `BEGIN IMMEDIATE` transaction: adopt draft-week slots, relay when due, fill open (day, position) slots from today to today + 30 in Queue order, creating real posts at once. `weeks`, `plan_slots` and every Placer/Postiz/lineage guard stay: it marks the week approved itself, so `isApproved`, `regenerateMany`, the runway and undo snapshots work unchanged. "Approved" survives only as an internal word. `Engine.autoSchedules` is a test seam.
- **Lead time:** a position is open only when its earliest platform time is 30 min away or more; no post is ever created in the past or inside the lead. A swap that would put another clip inside it is refused.
- **Plan days:** `Placer`, `reflow`, `push` and `makeRoom` key a post by its plan day (`Sched.planDay`), not the local posting day: with 3 a day and a 180-minute offset, position 2 posts after midnight.
- **Relay:** only when posts/day or the Queue sort changes (kv `plan.layoutSig`), once; the first run just records it. Pinned, posted, sooner than 60 min, handed-to-the-Calendar and Postiz-published slots stay. Everything else about a gap is filled from the backlog; other clips keep their days.
- **Undo survives the scheduler:** `BulkActions.planConflict` treats unpinned new slots, untouched new regular posts and weeks that only flipped to approved as derived; `restorePlan` drops them and the next tick derives them again.
- **Stages:** `.scheduled` stays as a case and a status word; back from it is "Back to Edit" (held). The Queue has no forward move.
- **Runway:** `approvedDays` keeps its name and means days with slots; `scheduledThrough` and `Runway.isLow` feed the words `StageWording.scheduledThrough` and "Queue running low". `djq schedule [--dry-run]` runs the pass once; it is the only safe way to exercise scheduling on a DB copy.

## Round 10 additions — whole-app search
- `Sources/DJQCore/Search/`: `AppSearch.swift` (pure engine: `SearchIndex`, `SearchQuery`, tiers, snippets, no SwiftUI, no database), `SearchCorpus.swift` (clips, posts, weeks, sessions, settings and Health as `SearchItem`s; `Store.searchClipText`, one query for the latest version's text) and `SettingsSearchRegistry.swift` (every Settings row and header; `SettingsRegistryTests` scans the Settings views and fails on a missing label).
- `AppModel.load` builds `searchIndex` off the main actor on every refresh, so a keystroke only scans folded bytes and never touches the database. Nothing is written and there is no schema change.
- `Shell/SearchSources.swift` turns hits into palette rows, only for what's on screen, and holds the open paths (`openPost`, `openWeek`, `openSession`, `openSettings`, `leaveForScreen`). Actions and Go to follow the selection, so the palette indexes those itself. A search id rebuilds its row later, which is how Recents work; a stale id gives nil.
- Settings deep links: `.settingsAnchor` marks a row, `SettingsUIState.scrollTarget` asks for it and `landOnTarget` scrolls and flashes.
- Real-window proof: `DJQ_SEARCH_PROBE=1 DJQueueApp --snapshot <dir>` with the dev-root env (`Snapshot/SearchProbe.swift`). It drives real key events through the window in light and dark and exits 1 on a failed step. `DJQ_SEARCH_PROBE=sabotage` shows it can fail.

## Background verification

`scripts/live-checks.sh <dir>` runs every live click-through check without showing anything. `Snapshot/Backstage.swift` puts each window on a fake stage far off every display; the window server keeps drawing it there, live player and materials included, and each window is captured on its own (a region capture of that area comes back empty). Clicks, keys and hovers are events sent to that window. `Snapshot/ScreenGuard.swift` samples the window server every 0.1 s during a `--snapshot` run and exits 3 if a window of the run lands on a display or the app activates; `DJQ_SCREEN_GUARD_SELFTEST=1` proves it can fail. Anything under `.build` refuses to start without `DJQ_HOME` and `DJQ_ROOT`, because `Store` migrates what it opens, and an unknown `--` flag no longer opens the real window. Players stay at volume 0 and animations are off in these runs, and the script runs on scratch copies of the newest backup, or a fresh database where a check expects one. New scripts call `Backstage.show`; `BackgroundWindowTests` fails on anything else that brings a window forward. Real menus and real `.sheet`s are the exception, since macOS pulls them onto a display: the hover probe sends AppKit's menu notifications instead, and the tooltip pass shows the pin sheet's view in its own window. Both are labelled as stand-ins.
