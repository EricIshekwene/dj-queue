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
