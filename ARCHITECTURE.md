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

## Round 21 additions: post at a set time

Eric picks an exact day and time for an item; every platform it posts to goes out at that minute. Decisions: `DECISIONS-R21.md` (D12–D14). Core only here; it works for any short-form item (clip or photo post). Code: `Engine/ExactTime.swift`, `BulkActions+PostAt.swift`, `djq/PostAtCommand.swift`; tests `R21ExactTime*Tests.swift`.

**Model.** A set time is a `PlanSlot` with `exactAt` set (`isExact`), no new table:

- `pinned` is always true, `date` is the local day of `exactAt`, `position` is the first free one from `PlanSlot.exactBase` (100) up on that day, so two set-time items can share a day. On the same minute both keep it on Manual; through Postiz one of the two goes a minute later on each channel (`PostizService.remoteDate`: two open jobs on a channel never share a minute) and the preview says so.
- Its week is marked approved the way `autoSchedule` does it, and it holds one regular `PlatformPost` per usable platform with `scheduledAt = exactAt`. A YouTube time inside the quiet window goes through `YouTubeWindow.clear` (7 pm–midnight Pacific → 00:30 Pacific, round 22) like every other YouTube time.
- Always the slot's own clip on every platform: no `PlatformPicker`, even with a per-platform sort.
- A shared day is refused (`refuseSharedCard`, `StageWording.sharedCard`). When a platform has its own order, a scheduled item's card can carry another clip's post and its own post can sit on another clip's card; `postAt` on it throws "TikTok has its own order, so this day is shared with another clip. Send it back to Edit, then set the time." and the preview shows it as the blocker. Nothing is detached, deleted or guessed, and no regular post is ever left without a card. An item in the Queue has no card, and a set-time slot only holds its own clip's posts, so setting from the Queue, changing a set time and clearing one are unaffected.
- A platform that is off for the item or marked already posted gets no post. One that failed keeps its lineage (`Planner.carryRetries`): a retry on its way moves to the set time as the same post; a failure whose retry is still to come has it made for the set time by the engine; a failure waiting for Eric, or a skipped post, gets nothing and the preview says which.
- A change is refused while Postiz holds a copy that goes out within `Planner.exactLead` (`refuseTooLate`: "Facebook goes out in 3 minutes — too late to change"), in `postAt`, `clearExact` and a move: Postiz would keep that copy and send it at the old time. The undo of a "post-at" or "post-at-clear" batch is refused by the same test (`Planner.tooLate`, `BulkActions.tooLateToUndo`: "… too late to undo"), force or not.
- `exactAt` is on the whole minute (`Planner.exactMinute`), at least `Planner.exactLead` (10 min) ahead when it is set, and a clock time that exists that day (`Planner.exactDate` refuses the hour the clocks skip, typed or on a move).

**Invariants** (a test per line in `R21ExactTimePathsTests`):

- It is outside the cadence. `openPositions`, `fill` and `isOpen` see only regular slots: a day keeps all its `0..<postsPerDay` positions beside any number of set times, and regular filling never lands on 100 or up.
- It takes no `Placer` key and its plan day is its slot's date (`Store.planDay(of:)`); `position × offset` is never used for it.
- Nothing re-times it: `setSlot` (kept, "it has a set time"), `pushPlan` and Post today (its retry stays at the set time too), the relay (`movableSlots`), `reflow`, `movablePosts` and missed-day shifts all leave it out. A set-time post the Mac slept through goes overdue by the usual rule and stays at its time; Post now and Skip work, Shift plan is refused (`StageWording.setTimeNoShift`) and the missed notice doesn't offer it.
- `swap`, `skipNext` and `postToday` on a set-time item are refused with `StageWording.hasSetTime`; on other clips they pass over it.
- `move(slotId:to:)` and `pin(videoId:date:)` (what a Calendar drag calls) keep its clock time on the new day (new `exactAt`, checked against the lead), never swap and never displace. A regular slot moved onto a day ignores the set times there, both for a free position and for a swap partner.
- Posts regenerated or topped up for it (`createPosts`, `regenerateMany`, `approveWeek`) come back at `exactAt`, never a slot time, and never in the past. `rebuildWeek`, `proposeWeek`, `adoptDraftSlots` and `dropStalePastDraftSlots` leave it as it is.
- Back to Edit, `unplan` and `remove(slotId:)` take it off like any other day; `UnplanItem.setTime` carries the time for the words.
- `Queue.runway()` doesn't count it: `approvedDays` and `scheduledThrough` are about the cadence.
- Undo: `PlanSnap` holds whole `PlanSlot`s, so `exactAt` round-trips; the batches below journal the plan.

**API the UI calls** (all public):

| Call | What it does |
|---|---|
| `BulkActions.postAt(_ ids: [String], at: Date, dryRun: Bool = false) -> BulkResult` | Sets the time for each item, one batch, one undo (`action` "post-at"). An Edit item goes through Send to Queue first (D13); one with something to fix stays untouched and `skipped[id]` says what, in Send to Queue's words. `moves[id].note` is the toast, "Set for Sat 14 Nov 3:15 PM". Throws when the time has passed or is under 10 minutes away, unless every item already has it (unchanged). |
| `BulkActions.clearExact(_ ids: [String], dryRun: Bool = false) -> BulkResult` | "Use the regular schedule": the set time goes, the item is back in the Queue and the next scheduling pass gives it the next open day. One batch, one undo (`action` "post-at-clear"). Refused once something posted. `moves[id].note` is the toast, and names a retry that keeps its own time: "Back on the regular schedule · TikTok's retry still goes out Fri 6 Nov 10:00 AM" (the dry run reads the same). |
| `BulkActions.postAtPreview(_ id: String, at: Date) -> Planner.ExactPreview` | Read-only, for the confirm sheet, wherever the item is (Edit, Queue, Scheduled): `platforms[{platform, at, moved, retry}]`, `skipped[{platform, reason, why}]` (reason: off, posted, retrying, failed, skipped, history), `replaces` (the day or set time it leaves), `notes` ("YouTube moves to 3:30 AM (00:30 Pacific)", "TikTok goes out at 7:01 PM: another post has 7:00 PM"), `unchanged`, `blocker`, `summary`. It runs the real thing and rolls it back, so it can't disagree. |
| `Planner.exactSlot(videoId:) -> PlanSlot?` | The item's set-time slot, nil on the regular schedule. `PlanSlot.exactAt` / `isExact` mark it in any slot list. |
| `Planner.exactTimeProblem(_ at: Date) -> String?` | Why a time can't be picked (passed, or inside the lead), for live validation in a picker. |
| `Planner.exactLead`, `Planner.exactMinute(_:)`, `Planner.parseExact(_:settings:)`, `Planner.exactDate(day:minutes:settings:)` | The 10-minute lead, a date on its whole minute, "YYYY-MM-DD HH:MM" in the Settings time zone, and a day plus minutes after midnight as a date (both throw for a time the clocks skip). |
| `Planner.postAt(videoId:at:) -> PlanSlot`, `Planner.clearExact(videoId:)`, `Planner.postAtPreview(videoId:at:)` | The engine level under the batches: no journal, and the item must already be in the Queue or scheduled. The app uses the `BulkActions` calls. |
| `Planner.move(slotId:to:)`, `Planner.pin(videoId:date:)` | Unchanged signatures; on a set-time slot they keep the clock time on the new day. |
| `StageWording.setFor(_:settings:)`, `dayTime(_:settings:)`, `setTimeMark(_:settings:)`, `useRegularSchedule`, `regularSchedule`, `hasSetTime`, `setTimeNoShift`, `setTimePassed`, `setTimeTooSoon`, `noSetTime`, `tooLateToChange(_:seconds:to:)`, `sharedCard(_:)`, `retryStays(_:at:settings:)`, `noSuchTime(minutes:day:settings:)`, `sameMinute(_:goesAt:taken:settings:)`, `noSetTimePost(_:_:)`, `youtubeMoves(to:setFor:settings:)` | The words, shared by the app and `djq`. |

**CLI.** `djq post-at <video> "<YYYY-MM-DD HH:MM>" [--dry-run] [--json]` and `djq post-at <video> --clear`. `djq week` marks the slot "set time 3:15 PM", `djq today` / `djq posts` mark its posts "[set time]", `djq status` adds "N at a set time"; `djq video --json` carries `plan[].exactAt`. Agents never run it unless Eric says so.

## Round 10 additions — whole-app search
- `Sources/DJQCore/Search/`: `AppSearch.swift` (pure engine: `SearchIndex`, `SearchQuery`, tiers, snippets, no SwiftUI, no database), `SearchCorpus.swift` (clips, posts, weeks, sessions, settings and Health as `SearchItem`s; `Store.searchClipText`, one query for the latest version's text) and `SettingsSearchRegistry.swift` (every Settings row and header; `SettingsRegistryTests` scans the Settings views and fails on a missing label).
- `AppModel.load` builds `searchIndex` off the main actor on every refresh, so a keystroke only scans folded bytes and never touches the database. Nothing is written and there is no schema change.
- `Shell/SearchSources.swift` turns hits into palette rows, only for what's on screen, and holds the open paths (`openPost`, `openWeek`, `openSession`, `openSettings`, `leaveForScreen`). Actions and Go to follow the selection, so the palette indexes those itself. A search id rebuilds its row later, which is how Recents work; a stale id gives nil.
- Settings deep links: `.settingsAnchor` marks a row, `SettingsUIState.scrollTarget` asks for it and `landOnTarget` scrolls and flashes.
- Real-window proof: `DJQ_SEARCH_PROBE=1 DJQueueApp --snapshot <dir>` with the dev-root env (`Snapshot/SearchProbe.swift`). It drives real key events through the window in light and dark and exits 1 on a failed step. `DJQ_SEARCH_PROBE=sabotage` shows it can fail.

## Background verification

`scripts/live-checks.sh <dir>` runs every live click-through check without showing anything. `Snapshot/Backstage.swift` puts each window on a fake stage far off every display; the window server keeps drawing it there, live player and materials included, and each window is captured on its own (a region capture of that area comes back empty). Clicks, keys and hovers are events sent to that window. `Snapshot/ScreenGuard.swift` samples the window server every 0.1 s during a `--snapshot` run and exits 3 if a window of the run lands on a display or the app activates; `DJQ_SCREEN_GUARD_SELFTEST=1` proves it can fail. Anything under `.build` refuses to start without `DJQ_HOME` and `DJQ_ROOT`, because `Store` migrates what it opens, and an unknown `--` flag no longer opens the real window. Players stay at volume 0 and animations are off in these runs, and the script runs on a scratch copy of the newest backup with every stored path rewritten to the dev root, or a fresh database where a check expects one. New scripts call `Backstage.show`; `BackgroundWindowTests` fails on the known ways to bring a window forward. Real menus and real `.sheet`s are the exception, since macOS pulls them onto a display: the hover probe sends AppKit's menu notifications instead, and the tooltip pass shows the pin sheet's view in its own window. Both are labelled as stand-ins.

## Round 20 additions — ready to repost, bulk edits on versions
- `Version.repostReady` (per version, never carried forward) and `Version.captionsOwn` are optional JSON keys: no schema change. `Sources/DJQCore/RepostReady.swift`: `Store.setRepostReady` writes only the flag (no `updated_at`, no `refreshState`; a v1 written just for the mark is stamped 0, which `PreviewStampTable` skips), `repostReadyVersions()` (one query, for `AppModel.repostReady`, filters and search), and the repost round's read-only inputs `nextRepostReadyVersion(videoId:platform:)` / `RepostReady.candidates`. `VersionMerge.keepingOutsideChanges` keeps the mark and a bulk pin when an open editor saves.
- `VersionResolver`: caption fields resolve through `captionChain`, cut at the latest version with `captionsOwn`, so a pinned version never inherits captions from earlier ones. `BulkActions.keepLaterCaptions` pins every later version a caption-family change on v1 would reach (and those that follow a pinned one); `applyDefaults(.text)` resets the look on every version. Bulk undo ignores and keeps `repostReady`.
- UI: `EditorRepostReadyRow` (inspector), a switch per `EditorVersionList` row, the picker's check; `EditorModel.setRepostReady` writes through the store directly. `ListFilterKey.repost` on Edit, Queue and Library. `BulkVersionScope` (DJQCore) + `BulkRequest.versionScope` + `BulkVersionNote` say which versions a bulk change reaches. Live check `repost-ready` (`Editor/RepostReadyScript.swift`).

## Round 21 additions: photo posts
Decisions: `DECISIONS-R21.md` (D1–D11, D15–D19 and "Decisions made while building (core photos)"). Core, CLI and tests only; no screen
knows about photos yet. The UI starts from the API list at the end of this section.

**Model.** A photo post is a `Video` with `photos: [PhotoItem]` (`isPhoto`): `type .short`, `duration 0`, `sessionId = Session.photosId`,
`inManifest false`, `contentType "photo"`, `score nil`, `file` = its first photo. `name` is the first file's base name, made unique among
photo posts as a file name would be ("IMG_1234", "IMG_1234 2"; "Flyer" and "flyer", or "a:b" and "a-b", count as one name:
`PhotoImport.fileNameKey`); `tags` = [that base name]. `PhotoItem` is `id` (stable across
reorders, the key of `Edit.photoCrops`), `file` (relative to the Photos folder), upright `width`/`height`, and `fingerprint` (size + SHA-256
of the copy). `Video.fingerprint` hashes the photos' fingerprints in order and `fileSize` is their total, so a reorder changes the preview
stamp. `Video.photoCount`, `isCarousel`, `photoLabel` ("Photo" / "Carousel · 5") and `kindLabel` are the words for cards.

**Files.** `Paths.photos` = `<DJ Video>/Photos`. Copies live in `Originals/<post id>/NN-<photo id>.<ext>` (NN counts up and is never reused
in a post; a removed photo's copy stays so undo can bring it back). Renders go to
`Ready to Post/Shortform/<name> – v1 – <post id, 8 characters> – NN.jpg` (the id keeps two posts from ever sharing a file) and move to
`Posted/Shortform/`. The file Eric picked is only read, and a symlink is imported as a copy of the file it points at. Every photo path is
resolved from `Paths.photos` (`Store.photoURL`, `fileURL(for:)`, the render folder), never from the session row's folder, and intake puts
that row's folder back to `Paths.photos` when it differs. Intake's manifest pass never sees the Photos session or its posts;
`PhotoImport.checkFiles` (end of `Intake.run`) marks a post `missing` while one of its photo files is gone or can't be read as a picture. Doctor: `photos.missing`. A scripted run keeps the Photos folder in its own scratch (`Paths.photosOverride`, `DJQ_PHOTOS`; `Paths.owns` counts it).

**Stages (D4).** `ClipStage.of`: an unscored photo post is in Edit, never Score. `Queue.toScore` leaves photos out; `needsEdit`, `candidates`,
`ordered` and `Store.wasInQueue` take them unscored. Queue order: unscored photos first, oldest `createdAt` first, then the existing rules
(a scored photo sorts like a clip). `BulkActions.send` needs no score for a photo and `confirmDefaultCrop` writes the centred crop of every
photo that has none into `photoCrops`. Back from Edit is blocked (`PhotoRules.noScoreStage`); clearing a photo's score doesn't unsend it.

**Edit rules.** `EditResolver.resolve` on a photo post: aspect = `aspectOverride ?? defaults.photoAspect` (4:5), `crop` = the first photo's,
`cropConfirmed` = every photo has its own crop, trim = 0…photo count (one unit per photo), cover 0, and every platform with
`maxPhotos == 0` skipped. **YouTube is off three ways** (D8): `Store.edit(videoId:)` adds the skip on every read, `Store.save(_:videoId:)`
stores it, and the resolver adds it; `BulkActions.setPlatform` refuses to turn it on with `PhotoRules.youtubeReason`. So `Planner.createPosts`,
`Planner.usable` and `Queue.ordered(platform:)` never give a photo a YouTube post, through code that doesn't know about photos.
`PhotoRules.crop(for:edit:aspect:)` is a photo's crop: its own in `photoCrops` when it still fits the aspect, else centred (a crop made for
another aspect is ignored, never stretched). `VersionResolver`: text nothing sets is "No text" on a photo post (extra texts still draw),
and default text timing is no window, whatever `defaults.textTiming` says (its seconds would read as photos).

**Validation.** For a photo post: `missingFile`, `heldInEdit`, `corrupt`, `noPhotos` (new kind; section `IssueSection.photos`), `photoShape`
(new kind, D20; per platform, section Frame: Instagram takes photos from 4:5 to 1.91:1, so 9:16 with Instagram on is an issue;
`PhotoRules.shapeProblem`), `noCaption`, `captionTooLong`. Never `noCrop`, `noText`, `tooLong` or anything about YouTube. Captions: `{set}` and `{tag}` are empty and `{text}` falls
back to the Title only (`Captions.setValue`, `tagValue`, `textValue`). Bulk crop skips photos (`PhotoRules.bulkCropReason`).

**Text on photos (D7).** Same `Version` fields and `TextLayer`s. A window is in photo units: photo *i* (0-based) is [*i*, *i*+1) and a text
shows on it when `PreviewKeys.layerWindows(version, trimDuration: count)` overlaps that (`PhotoRules.shows`, `layers(_:onPhoto:of:)`).
"Photos 2–4" is `start 1, end 4` (`PhotoRules.window(fromPhoto:toPhoto:)`); no window = every photo. A window names positions, not photos:
after a reorder or a removal the text stays on photos 2–4, whichever photos those now are.

**Render (D6).** `PhotoRenderer` (`Render/PhotoRenderer.swift`): `load` reads a photo upright through ImageIO, `compose` cuts the crop with
`Media.pixelCrop`, scales into the size with high interpolation on an opaque sRGB canvas and draws `TextOverlay.image(for: layers, aspect:)`.
The final files, `preview` and `Media.thumbnail` all call `compose`, so the editor is WYSIWYG. `Renderer` branches on `isPhoto` in `scope`
(always "all"), `editHash`, `currentRender` and `ensureRender` (same row, claim and lock as a video). Output: JPEG 0.9, 1080 wide, no
metadata. `Render.outputPath` is the first file, `morePaths` the rest (`[]` for one photo), `coverPath` nil, `duration` 0, `size` the total,
written in one statement (`Store.finishPhotoRender`); a row with fewer files than the post has photos is never the current render.
`more_paths` is stored with plain slashes (`JSONCoding.pathList`) so a dev copy's path rewrite (`scripts/seed-paths.sh`) reaches it.
The hash covers `PhotoRenderer.pipelineVersion` ("photo-1"), the photos' fingerprints in order, the aspect, each resolved crop, the drawn
texts with look and window and, when there is text, `TextOverlay.drawingVersion` (bump it when text drawing changes pixels); video hashes
and `Renderer.pipelineVersion` are untouched. A render that replaces another deletes the files it didn't overwrite; a failure while moving
files into place retires the rows whose files were overwritten, so no finished row points at a mix. **Nothing outside the store's root is
moved or deleted** (`Paths.owns`, used by `Renderer.isAppOutput`, `Engine.moveToPosted` and the cleanup): a path a copied database names
elsewhere stays put. A path counts as inside the root as it is written or after resolving symlinks, so a `Ready to Post` folder that is a
link to another drive is managed as before. Engine: `renderAhead` works unchanged; `moveAndCleanup` moves every file of a render, then writes all its paths together
(`Store.setRenderFiles`); a file that couldn't move is a tick error (as it was for clips) after the rest of the step has run, and is
tried again on the next tick; cleanup and `deleteRenders` handle every path, the proxies step
and `ProxyService` skip photos, and nothing probes one (`Media.sourceSize` answers from the row).

**Publishing (D8–D11, D19).** `PreparedPost.moreFileURLs` / `allFileURLs`; `ManualPublisher` and `PostizPublisher` fill them with the first
`platform.maxPhotos` files. `PostizPayload.photoSpec` builds a photo post's spec (`photoPaths`, no thumbnail time, no cover) and throws for
YouTube; `PostizPostSpec.body(date:media:cover:)` puts one `image` entry per photo. Settings per platform are in `docs/postiz.md`.
`PostizService.submit` and `testPost` upload each photo once per render (`postiz_media` kinds `photo1`…) and put the first photo on the
job. A photo post's uploads happen before the job is claimed, as many as the hourly budget allows; the create waits until every photo is
cached (`SubmitOutcome.waiting`, which doesn't stop the posts behind it), so a carousel larger than an hour's budget goes out an hour or
two later instead of never. One process at a time uploads a render's photos (`flock` on `work/postiz-upload-<render>.lock`; another
waits for its next tick). An upload that fails is reported as a video's is (a closed `interrupted` job with the error, "failed" in the
publish step) plus one event per kind of failure, and the render's other platform posts wait for the next tick. Nothing is created from a
render that was replaced while its photos went up. The pure `PostizPayload.spec(post:…)` now throws (YouTube for a photo post). A video's payload and content hash are byte-identical to before.

**CLI and JSON.** `djq photo add <file>… [--separate] [--title T] [--json]`, `djq photo list [--json]` (`Sources/djq/PhotoCommand.swift`).
`AgentAPI.VideoSummary` gains `media` ("photo" | "video") and `photos[{id, file, width, height}]`.

**What the UI calls** (all in DJQCore):
- `PhotoImport(store:).add(files:mode:title:titleSource:) -> Result{posts, skipped[{file, reason}]}`: import (`.carousel` | `.separate`). It copies and hashes files, so call it off the main thread, and post `ChangeSignal` yourself.
- `PhotoImport.refusal(_ url:) -> String?`: why a dropped file can't be a photo, before importing. `PhotoRules.extensions`: for the file picker.
- `PhotoImport.append(files:to:journal:)`, `remove(photoId:from:journal:)`, `reorder(videoId:ids:journal:) -> Change{video, skipped, batchId}`: one journal entry each (`photo-add`, `photo-remove`, `photo-reorder`) for ⌘Z; pass `journal: false` inside an open editor entry (`BulkActions.begin`), whose `commit` records photo changes with the rest (`ClipSnap.photos`). Removing the last photo throws.
- `Store.photoURL(_:of:)`, `photoURLs(_:)`: where a photo's file is.
- `PhotoRenderer.preview(store:video:index:size:withText:version:) -> CGImage?`: one photo of a saved post as it posts (size nil = output size).
- `PhotoRenderer.image(_:photo:index:count:edit:version:defaults:size:) -> CGImage?`: the same from the editor's unsaved edit and resolved version (version nil = no text); pair it with `PhotoRenderer.load(_:maxPixel:)`.
- `PhotoRenderer.compose(_:sourceSize:crop:aspect:size:layers:)`: the one drawing function, when you hold the crop and layers yourself.
- `Media.thumbnail(store:video:maxHeight:version:photo:) -> URL?`: cached JPG of photo `photo` (0 = the cover) as it posts.
- `PhotoRules.aspect(_:defaults:)`, `aspects`, `crop(for:edit:aspect:)`, `centredCrop(_:aspect:)`, `hasOwnCrop(_:edit:aspect:)`: frame and crop per photo; write a crop to `Edit.photoCrops[photo.id]` (upright source pixels) and save the edit as for a clip.
- `PhotoRules.layers(_:onPhoto:of:)`, `photoRange(of:in:count:)`, `rangeLabel(_:count:)`, `window(fromPhoto:toPhoto:)`: which photos a text shows on, and the stored window for a range.
- `PhotoRules.sent(count:platform:) -> (sent, dropped)`, `notice(count:platform:)` ("X gets the first 4 of 7 photos"), `platformNote(count:aspect:platform:)` (what a platform row says: `youtubeReason`, else the shape problem, else the notice), `maxPerPost` (35).
- `PhotoRules.aspectNote(_:posting:)` ("Instagram doesn't take 9:16 photos") for the aspect picker; `takes(_:platform:)`, `refusing(_:posting:)`, `shapeProblem(_:platform:)` (the `photoShape` issue's message).
- The YouTube row of a photo post: show it off and disabled with `PhotoRules.youtubeReason`. An edit held in memory can still be changed, but every save and every read puts the skip back.
- `Video.isPhoto`, `photoCount`, `isCarousel`, `photoLabel`, `kindLabel`; `Settings.defaults.photoAspect`; `StageWording.backTitle/backHelp/blocker` already say "Photos have no Score stage".
- `Render.allPaths`, `PreparedPost.allFileURLs`: every file of a photo post, for Reveal, drag-out and the Calendar's post sheet.
- `ValidationIssue.Kind.noPhotos` → `IssueSection.photos` → `EditorSection.photos`: the editor scrolls to the photos strip and flashes it.
- `PhotoTextRanges` (pure): what happens to each text's range when a photo is removed. A range after the removed photo moves down one place, a range that held it gets one shorter, a text whose only photo went moves to the nearest one left (`moved`, for the toast). `PhotoImport.remove` applies it to the stored versions when it journals (`djq`, lists); an open editor passes `journal: false` and applies the same rule to the versions it holds.
- `PhotoImport.setPhotos(_:videoId:)`: makes a list the post had before the list again (same ids and files), for the editor's undo and redo of a list change. Refuses an empty list and a file that isn't on disk.

## Round 21 additions: the screens

- **Import** (`App/AppModel+Photos.swift`, `Shared/PhotoImportSheet.swift`): Add photos on Edit, ⌘K, and a drop on the Edit page all end in `AppModel.importPhotos`, which runs `PhotoImport.add` off the main thread. Several files open the in-window sheet (`model.photoImportRequest`). Nothing is sent to the Queue.
- **Lists and previews**: a photo post draws through `DSPhotoPreview` (first photo as it posts, "Photo" / "Carousel · N", ‹ › in large previews) and never gets a player, a proxy or hover playback (`AppModel+Previews`, `requestProxies`).
- **Photo editor** (`Editor/EditorModel+Photos.swift` and the `isPhoto` branches of the editor): the canvas is `PhotoRenderer`'s own picture of the unsaved edit, the timeline is the photos strip with text bars in photo units, each photo has its own crop, and ←/→ step photos. The clip editor's code paths are unchanged.
- **Post at a set time** (`App/AppModel+PostAt.swift`, `Shared/PostAtDialog.swift`): `askPostAt` from the stage control's clock, the ⋯ menus, the bulk bars, ⌘K and the Calendar. The dialog previews through `BulkActions.postAtPreview` and keeps its button off until the preview for the current day and time has landed.
- **Calendar**: set-time slots show their own time with a clock mark, sort by time, never count as one of the day's regular places, and keep their clock time when dragged to another day.
- **Live checks**: `photo-import`, `photo-editor`, `post-at` (each with `-dark`), on sample photo posts cut from the dev clips (`SampleData.addPhotoPosts`).

## Round 23 additions: photo with audio
Decisions: `DECISIONS-R23.md` (D1–D11 and "Decisions made while building"). Code: `DJQCore/StillVideo.swift`, `djq/PhotoCommand.swift`,
`App/AppModel+PhotoAudio.swift`, `Editor/EditorAudioRow.swift`; tests `R23*.swift`; live check `photo-audio` (`Snapshot/PhotoAudioScript.swift`).

**Model (schema 10).** One nullable column, `videos.still` (JSON `StillSource {photo, audio, audioName, audioDuration}`). A made video is a
`Video` with `still` set (`isStill`) and `photos` nil: `file` = `Stills/<id>/video.mp4`, `duration` = the audio's length, `start` 0, `end` =
duration, fingerprint and size from the made file, source size = the video's pixels. It stays in the Photos session (`Session.photosId`,
`inManifest` false), so `Store.fileURL(for:)`, renders and `Paths.owns` resolve under `Paths.photos`. `migrateToV10` follows `migrateToV9`.

**Files.** `Photos/Stills/<video id>/video.mp4` and DJ Queue's copy of the audio, `audio.<ext>`. A later Change audio writes `video-2.mp4` /
`audio-2.<ext>` beside them and nothing is ever written over or deleted, so the undo of any audio change only points the row back at files
that are still there (the same idea as a removed photo's copy staying in Originals). The picked files are only read.

**Making it (`StillVideo.make`).** Three ffmpeg steps, each with a timeout: the audio's first stream to AAC 256 kbps 48 kHz stereo in the work
folder (its measured length is the video's length, since a header's can be an estimate); the photo, upright through ImageIO, at its own
shape inside 3840×2160 (2160×3840 for a tall or square photo, never enlarged, even pixels), as ONE keyframe interval of 30 fps H.264
(5 s: a keyframe at quantiser 18 and 149 frames that code nothing), sRGB values through the BT.709 matrix, limited range, tagged BT.709;
then that interval repeated under the audio with `-stream_loop` and `-c copy`, cut at the audio's end. Nothing is encoded twice, so 3
minutes take about 3 s and 20 minutes 13 s (most of it reading the audio); a 3-minute 4K video is about 25 MB with its audio (20 minutes: about 170 MB). It is probed (codec, size,
30 fps, audio, length within 0.05 s) before both files move into place; a failure leaves nothing. Refusals read as sentences: not there,
a folder, not a format taken, unreadable, no sound, over 20 minutes, under a second, no ffmpeg.

**The predicate.** `Video.needsNoScore` (`isPhoto || isStill`, SQL `Store.noScoreSQL`) is the one test for "skips Score". It replaced
`isPhoto` in `ClipStage.of`, `Queue.toScore/needsEdit/candidates/sort`, `Store.wasInQueue`, `Store.setScore`, `BulkActions.send`,
`removeFromQueue`, `sendToQueue`, `ids(filter:)`, the outlook's `hasScore`, and `StageWording.backTitle/backHelp/blocker`. Three more
places ask `isPhoto || isStill` because they are about a file name, not a score: `VersionResolver` (no text unless a version sets it; no
default text window), `Captions.tagValue/setValue`, `AgentPrompts.needsTitleHelp`. Every other `isPhoto` is untouched, so a made video
renders through the video `Renderer`, gets proxies, thumbnails and probes, has length checks and per-platform trims, takes the video
Postiz payload and posts to YouTube. `photoLabel` still means "a photo post"; `markLabel` / `kindLabel` say "Photo + audio".

**The other differences.** `Validation`: a made video posting to YouTube with no Title, no text on it and no typed YouTube title has the
existing `noTitle` issue (platform YouTube, section Title). The default crop is centred whatever the anchor (`NewClipDefaults.defaultCrop(for:)`,
used by the resolver, Send to Queue, Apply defaults and thumbnails) and never becomes "last crop". Bulk crop skips it. `Queue.overlaps`
never pairs two made videos. `Media.ensureProxy` makes its proxy from one frame and the audio copied (`StillVideo.proxy`: under a second
for any length, where decoding 20 minutes of 4K took 104 s), and falls back to the clip's path if that fails. `PhotoImport.checkFiles`
(end of intake) calls `StillVideo.checkFiles`: missing while its video file is gone. Doctor lists it under `photos.missing`.

**Add, change, remove.** Each makes its file outside any transaction, then writes the row, edit and versions in one journal entry
(`photo-audio-add`, `-change`, `-remove`), re-checking the row first. `ClipSnap.still` (a `StillSnap`: the source and the row's media
fields) is set only for a made video, so every other journal compares and restores as before; `restoreStill` turns the row back either
way. `StillVideo.blocker` is D3 and D9 in one place (one photo; in Edit, no plan slot, no post); the undo of an audio batch is refused
under a day or a post, force or not.

**API the UI calls.**
- `StillVideo(store:).addAudio(to:audio:journal:progress:) -> Change{video, batchId}`: a one-photo post becomes a video in place (D2).
- `changeAudio(videoId:audio:journal:progress:)`, `removeAudio(videoId:journal:)`: D5/D9. `blocker(_ v:) -> String?`: why not, for a control's off state.
- `add(photos:audio:title:titleSource:progress:) -> AddResult{videos, skipped}`: the import sheet and `djq photo add --audio`; the audio is read once.
- `StillVideo.audioSeconds(_:)` (throws the refusal), `refusal(audio:)`, `audioExtensions`, `label`, `addHint`, `carouselReason`, `lockedReason`.
- `Video.isStill`, `still`, `needsNoScore`, `markLabel`; `AgentAPI.VideoSummary.still {audio_name, audio_seconds, photo}` (`media` stays "video").

**Screens.** `AppModel+PhotoAudio.swift`: `askAddAudio` / `askChangeAudio` / `askImportAudio` open the system picker and end in `addAudio(to:audio:)`,
`changeAudio(videoId:audio:)`, `removeAudio(videoId:)` or `importPhotos(urls:audio:title:)`, which run Core off the main thread, count up in a
toast (`PhotoAudioUI`), journal into the app's undo history and reload an editor open on the item (`reloadOpenEditor`: it carries on as
the clip editor, or the photo editor after Remove). `EditorAudioRow` sits under Kind in the Title section of both editors; `EditorMakingVideo`
covers the editor while its item's video is made. Cards say "Photo + audio · 0:12" where a clip names its night. Menus: `AudioMenuItems`.

