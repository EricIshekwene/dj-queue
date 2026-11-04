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
  public func proposeWeek(_ week: String) throws -> [PlanSlot]   // fills open days of a draft week from Queue.ordered()
  public func approveWeek(_ week: String) throws                // creates PlatformPosts for every slot × active platform
  public func rebuildWeek(_ week: String) throws                // drops unpinned, un-posted slots and re-proposes (back to draft)
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
  public func dueToday(now: Date) throws -> [PlatformPost]                        // Today screen rows
  public func problems() throws -> [PlatformPost]                                 // failed / copyright / overdue, unresolved
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

CLI `djq`: `doctor [--json]`, `intake`, `status`, `queue`, `week [--propose|--approve] [YYYY-MM-DD]`, `today`, `prefill "<tag>" [--kind talking]`, `render <video-id> [--version N] [--platform P]`, `tick`, `posted <post-id> <url>`, `problem <post-id> <type> <message>`, `fixed <post-id>`, `reset <post-id>`, `agent install|uninstall|status`.

### UI agents (`Sources/DJQueueApp/`)

SwiftUI app per `design/DESIGN.md`. Talks only to the APIs above and `Store`. Runs `Engine` in-process (background queue). Implements `Notifier` with `UNUserNotificationCenter` (actions Post now / Shift plan / Skip / Mark posted). `scripts/build-app.sh` builds release, assembles `DJ Queue.app` (Info.plist: `LSUIElement` true, bundle id `com.djlovd.queue`, min macOS 15), ad-hoc signs, installs to `~/Applications`.

## Round 4 additions (v0.5.0)

- **Stages are readiness** (`DJQCore/StageWording.swift`): one source for stage names, the stage control's neighbour labels ("Back to Edit", "Send to Queue", "Back to Queue"), blockers and the Edit reason chips (`ValidationIssue.chipText` / `chipOrder` / `isBlock`). Stored states (`needs_edit`, `ready`, …) are unchanged; only display names changed.
- **Revalidation** (`DJQCore/Engine/Revalidation.swift`): re-derives every short, included clip in Edit / Queue / missing-file state. Runs as the tick step `stages`, after every djq write (`Revalidation.afterWrite`), inside Settings batches (states only) and after New clip defaults saves. An invalid Queue clip lands in Edit with a "Moved to Edit: <reasons>" event; Scheduled and pinned clips stay put and show the problem. Unpinned draft-week days whose clip left the Queue are refilled; `approveWeek` re-checks first, in one transaction.
- **Edited previews** (`DJQCore/Render/PreviewStamp.swift`, `App/AppModel+Previews.swift`): one preview stamp per clip (+ version) from edits, versions, the defaults generation and the clip-row fields. `previewChanged(_:)` is the single invalidation entry (editor exit, refresh, undo). Lists play the 540-px proxy (crop/aspect/trim) with the `TextOverlay` image drawn as a layer during `PreviewKeys.textWindow`; covers composite the text via `Media.coverComposite` (shared with the renderer). Overlays live in a 64 MB cost-capped LRU (`CostCappedCache`). A proxy request for a running encode queues a follow-up job, so a stale crop never lands.
- **List header** (`DesignSystem/DSListHeader.swift`, `Shared/ClipListFilters.swift`, `Shared/ListPrefs.swift`): one header on Score, Edit, Queue, Library, Posts and Week's Next up drawer, with page chips, one Filters popover, applied chips + Clear all and sort, persisted per page in UserDefaults (`djq.list.<page>`). ⌘F focuses the page's search.

## Round 6 additions (v0.7.0, schema v5) — Postiz publisher

- **Contract:** `docs/postiz.md` (endpoints, payload per provider, lifecycle, test run, auth). Decisions: `DECISIONS-R6.md`.
- **Core (`DJQCore/Postiz/`):** `PostizClient` over an injectable `PostizTransport` (URLSession in the app, fakes in tests; multipart streamed from a temp file), `PostizKeyStore` (Keychain service "DJ Queue Postiz", read through `/usr/bin/security`, key on stdin only), `PostizRouter` (Manual | Postiz | fallback reason per platform), `PostizService` (publish, sync, analytics, status, channels, test payloads, link/resolve/release), `PostizPublisher: Publisher`, a shared 25-per-hour request budget in kv.
- **Schema v5:** `postiz_jobs` (one row per Postiz post DJ Queue made; survives planner deletes so it can be cancelled) and `postiz_media` (render → uploaded media). Additive; the migration backs up the DB first.
- **Engine:** tick order `… alerts, retry, render, publish, sync, proxies …`. `retry` re-queues temporary Postiz failures by itself (`PostizRetry.swift`, DECISIONS-R8.md). `publish` reconciles every open job (cancel/replace, delete confirmed before any create) and submits Postiz-routed approved posts once their render exists (closes the old `Engine.due()` gap). `sync` maps Postiz states back onto the post state machine. Never double-post is enforced per clip + platform inside the claim transaction; a create with an unknown outcome is never resent (Doctor `postiz.create_unknown`). Posts with a live job are never overdue/shifted; posts Postiz can't take fall back to Today.
- **Settings:** `Settings.publishing` (per-platform publisher, channel ids — local only —, Test run, per-provider options). Scratch `DJQ_HOME`/`DJQ_ROOT` runs never touch the Keychain or the network unless `DJQ_POSTIZ_LIVE=1`.
- **CLI/Doctor:** `djq postiz status|channels|map|publisher|test-mode|test|link|release|resolve|sync`; Doctor `postiz.*` checks (offline unless `--live`).
- **App:** Settings → Platforms → Publishing (key, connection, channels, Manual | Postiz, Test run), confirms before anything can go public, Postiz state and live links on Today, Posts, Week and the menu bar, editor cover meaning per platform, YouTube/TikTok title limits, Trim/Skip for platforms a clip is too long for.

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
