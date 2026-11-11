import AppKit
import DJQCore
import SwiftUI

/// `DJQueueApp --snapshot <dir>`: copies the database from `Paths.standard` (DJQ_ROOT/DJQ_HOME) into a throwaway
/// folder, seeds sample data there, then renders every shot at 1440×900 in light and dark to PNG.
///
/// Shots come from one static func per leaf (`SnapshotShots.shell/pipeline/planning/browse/settings`, each in its
/// own `Shots+<Leaf>.swift` file) so parallel leaves never edit the same file. Name prefixes: shell 0x,
/// pipeline 1x, planning 2x, browse 3x, settings 4x. `DJQ_SNAPSHOT_ONLY=<substring>` limits the run.
/// `DJQ_SNAPSHOT_GALLERY=1` renders the design-system gallery instead (DSGallerySnapshot); `DJQ_SNAPSHOT_EDITOR=1`
/// renders the editor (EditorSnapshot, incl. `DJQ_EDITOR_SELFTEST`).
///
/// Rendering uses real AppKit windows (NSHostingController + window capture / `cacheDisplay`) instead of
/// `ImageRenderer`, because ImageRenderer can't draw AppKit-backed controls. Every window goes to `Backstage`, off every
/// display, and `ScreenGuard` fails the run if one shows up on a screen.
@MainActor
enum SnapshotRunner {
  static func run(outputDir: String) async -> Int32 {
    // Every run starts from the dev root: `Store` migrates what it opens, and that must never be the real database.
    guard Paths.hasDevEnvironment(ProcessInfo.processInfo.environment) else {
      FileHandle.standardError.write(Data("snapshot refused: set DJQ_HOME and DJQ_ROOT to the dev root\n".utf8))
      return 2
    }
    // Every snapshot and scripted run: a throwaway database must never make the installed app reload or tick.
    setenv("DJQ_NO_SIGNAL", "1", 1)
    if ProcessInfo.processInfo.environment["DJQ_SEARCH_PROBE"] != nil { return await SearchProbe.run(outputDir: outputDir) }
    if ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_GALLERY"] != nil { return await DSGallerySnapshot.run(outputDir: outputDir) }
    if ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_EDITOR"] != nil { return await EditorSnapshot.run(outputDir: outputDir) }
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let src = Paths.standard
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-snapshot-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: tmp) }

      // 1. Throwaway copy of the dev database (never the source DB).
      var paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      // Round 21: this run's photo posts live in its own throwaway folder, never in the shared dev footage folder.
      paths.photosOverride = tmp.appendingPathComponent("Photos")
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: src.thumbs, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
      if FileManager.default.fileExists(atPath: src.database.path) {
        let source = try Store(paths: src)
        try source.db.backup(to: paths.database.path)
      }
      let dm = DayMath(settings: AppSettings())
      let now = dm.at(dm.key(Date()), minutes: 16 * 60 + 10)
      let clock = FixedClock(now)
      let store = try Store(paths: paths, clock: clock)
      if try store.videos().isEmpty { try Intake(store: store).run() }
      try SampleData.seed(store: store, clock: clock, now: now)
      clock.set(now)
      // Round 21: photo posts in Edit, the Queue and on the Calendar at a set time (`DJQ_SAMPLE_PHOTOS=0` leaves them out).
      if ProcessInfo.processInfo.environment["DJQ_SAMPLE_PHOTOS"] != "0" {
        try SampleData.addPhotoPosts(store: store, now: now, scratch: tmp.appendingPathComponent("photo-samples"))
      }

      let model = AppModel(store: store)
      model.frozen = true
      model.now = now
      model.refreshNow()
      print("snapshot: \(model.videos.count) videos, \(model.posts.count) posts, \(model.problems.count) problems")
      let vids = model.videos
      let keys = Dictionary(uniqueKeysWithValues: vids.map { ($0.id, "\(ThumbStamps.shared.key($0.id))|g0") })
      await Task.detached { ThumbCache.shared.warm(vids, keys: keys) }.value

      // 2. Empty-state model: fresh DB over an empty root.
      let emptyRoot = tmp.appendingPathComponent("EmptyRoot")
      try FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
      let ePaths = Paths(root: emptyRoot, appSupport: tmp.appendingPathComponent("esupport"), logs: tmp.appendingPathComponent("elogs"),
                         launchAgents: tmp.appendingPathComponent("eLA"))
      let eStore = try Store(paths: ePaths, clock: FixedClock(now))
      let empty = AppModel(store: eStore)
      empty.frozen = true
      empty.now = now
      empty.refreshNow()
      // 3. Postiz model (round 6): a copy of the seeded sample with Postiz turned on for most platforms, sample
      // channels and a Postiz job behind posts in every state. No key, no Keychain, no network.
      var pPaths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("psupport"), logs: tmp.appendingPathComponent("plogs"),
                         launchAgents: tmp.appendingPathComponent("pLA"))
      pPaths.photosOverride = paths.photosOverride
      try FileManager.default.createDirectory(at: pPaths.appSupport, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: pPaths.thumbs, withDestinationURL: src.thumbs)
      try store.db.backup(to: pPaths.database.path)
      let pClock = FixedClock(now)
      let pStore = try Store(paths: pPaths, clock: pClock)
      try SampleData.seedPostiz(store: pStore, clock: pClock, now: now)
      pClock.set(now)
      let pModel = AppModel(store: pStore)
      pModel.frozen = true
      pModel.now = now
      pModel.postiz.hasKey = true
      pModel.refreshNow()

      // The covers belong to the main sample model (the empty one must not take over the shared cache).
      ThumbCache.shared.store = store
      model.refreshNow()

      if ProcessInfo.processInfo.environment["DJQ_SEND_TO_QUEUE_SCRIPT"] != nil {
        return await SendToQueueScript.run(model: model, store: store, out: out)
      }
      if ProcessInfo.processInfo.environment["DJQ_PHOTO_IMPORT_SCRIPT"] != nil {
        return await PhotoImportScript.run(model: model, store: store, out: out, scratch: tmp.appendingPathComponent("photo-picked"))
      }
      if ProcessInfo.processInfo.environment["DJQ_PHOTO_AUDIO_SCRIPT"] != nil {
        return await PhotoAudioScript.run(model: model, store: store, out: out, scratch: tmp.appendingPathComponent("photo-audio"))
      }
      if ProcessInfo.processInfo.environment["DJQ_POST_AT_SCRIPT"] != nil {
        return await PostAtScript.run(model: model, store: store, clock: clock, out: out)
      }
      let ctx = SnapshotContext(model: model, empty: empty, store: store, now: now, postiz: pModel)
      var shots = SnapshotShots.shell(ctx) + SnapshotShots.pipeline(ctx) + SnapshotShots.planning(ctx)
        + SnapshotShots.browse(ctx) + SnapshotShots.settings(ctx)
        + SnapshotShots.unqueue(ctx)
        + SnapshotShots.r3posts(ctx)
        + SnapshotShots.r4previews(ctx)
        + SnapshotShots.r6postiz(ctx)
        + SnapshotShots.r9retry(ctx)
        + SnapshotShots.r10search(ctx)
      if let only = ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_ONLY"] {
        shots = shots.filter { $0.name.contains(only) }
      }
      for shot in shots {
        try await shot.render(to: out)
        print("snapshot: \(shot.name)")
      }
      print("snapshot: wrote \(shots.count * 2) PNGs to \(out.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
      return 1
    }
  }
}

/// Namespace for the per-leaf shot lists (one `static func <leaf>(_ c: SnapshotContext) -> [Shot]` per file).
@MainActor
enum SnapshotShots {}

/// What every shot list gets: the seeded sample model, an empty-state model, the frozen `now`, and helpers.
///
/// Main-window shots share `model`; before each one the UI state is reset (`resetUI`), so shots don't depend on
/// order. DATA changes a setup makes (scores, pause, …) persist in the throwaway DB — undo them in your own
/// shots if later shots of yours care.
@MainActor
struct SnapshotContext {
  let model: AppModel
  let empty: AppModel
  let store: Store
  let now: Date
  /// Round 6: the sample with Postiz on (see `SampleData.seedPostiz`).
  let postiz: AppModel

  /// The first clip in the upcoming plan (Queue/Week shots).
  var firstPlannedId: String? { model.upcomingSlots.first?.videoId }

  /// The main window (1440×900) on `m` (default: the sample model) after `setup` ran on a reset UI state.
  /// Setup may open overlays: `m.showSettings = true`, `m.showPalette = true`, `m.requestBulk(…)` (confirmation
  /// sheet), `m.show(DSToastModel(…))` (toast), `m.previewVideo = v`, `m.openEditor(id)`.
  func main(_ name: String, _ m: AppModel? = nil, size: CGSize = Shot.standard, setup: @escaping (AppModel) -> Void) -> Shot {
    Shot(name: name, kind: .main(m ?? model, setup), size: size)
  }

  /// A standalone view `width` wide; `height` nil = fitting height. Drawn on `DS.color.background`.
  func view(_ name: String, width: CGFloat, height: CGFloat? = nil, _ make: @escaping () -> AnyView) -> Shot {
    Shot(name: name, kind: .view(CGSize(width: width, height: height ?? 0), make))
  }

  /// UI state every main shot starts from: Score screen, nothing selected or open, loaded, this week.
  static func resetUI(_ m: AppModel) {
    m.editor = nil
    m.showPalette = false
    m.showSettings = false
    m.showShortcuts = false
    m.pendingBulk = nil
    m.captionDialogIds = nil
    m.cropDialogIds = nil
    m.pendingConfirm = nil
    m.previewVideo = nil
    m.postAtRequest = nil
    m.photoImportRequest = nil
    PhotoImportUI.shared.dropTargeted = false
    m.toast = nil
    m.selection = [:]
    m.selectionAnchor = [:]
    m.sidebarCollapsed = false
    m.loaded = true
    m.screen = .score
    m.calendarMode = .week
    m.calendarAnchor = ""
    m.calendarPlatform = nil
    m.calendarPinTarget = nil
    ListPrefs.shared.reset()
  }
}

@MainActor
struct Shot {
  enum Kind {
    /// Main window 1440×900; the closure sets up the UI (after `SnapshotContext.resetUI`).
    case main(AppModel, (AppModel) -> Void)
    /// Standalone view of this size (height 0 = fitting height).
    case view(CGSize, () -> AnyView)
  }

  let name: String
  let kind: Kind
  /// Main-window shots: the default size, or the narrowest the window goes.
  var size = Shot.standard

  nonisolated static let standard = CGSize(width: 1440, height: 900)
  nonisolated static let narrow = CGSize(width: 1100, height: 700)
  /// The tightest Calendar toolbar: the sidebar is still open at this width.
  nonisolated static let tight = CGSize(width: 1200, height: 700)

  func render(to dir: URL) async throws {
    let window: NSWindow
    switch kind {
    case .main(let m, let setup):
      SnapshotContext.resetUI(m)
      setup(m)
      window = WindowManager.makeMainWindow(model: m, make: SnapshotWindow.make)
      window.setContentSize(size)
    case .view(let size, let make):
      let root = make().frame(width: size.width, height: size.height > 0 ? size.height : nil)
        .background(DS.color.background).modifier(SnapshotActive(on: true))
      let hv = NSHostingView(rootView: root)
      let fit = hv.fittingSize
      hv.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height > 0 ? size.height : max(fit.height, 40)))
      window = SnapshotWindow.make(hv.frame, [.borderless])
      window.contentView = hv
    }
    window.isReleasedWhenClosed = false
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      Backstage.show(window)
      try await Task.sleep(for: .milliseconds(suffix == "light" ? 1600 : 800))
      window.displayIfNeeded()
      // Default: AppKit draws the view tree (deterministic, works with the display asleep; no AVPlayer frames).
      // DJQ_SNAPSHOT_WINDOW=1 uses the window-server capture instead (playing video; needs an awake display).
      let useWindow = ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_WINDOW"] != nil
      let png = (useWindow ? WindowCapture.png(window) : nil) ?? cachedDisplay(window, dark: appearance == .darkAqua)
      try png?.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
    }
    window.orderOut(nil)
    window.close()
  }

  /// Fallback when the window server can't capture: AppKit draws the view tree (no vibrancy / glass).
  private func cachedDisplay(_ window: NSWindow, dark: Bool) -> Data? {
    let view = window.contentView?.superview ?? window.contentView!
    view.layoutSubtreeIfNeeded()
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}

/// Snapshot windows report key/main so AppKit draws them as the front window, without activating the app.
final class SnapshotWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
  override var canBecomeKey: Bool { true }
  /// AppKit pulls titled windows back onto a display; these stay on `Backstage.stage`.
  override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }

  static func make(_ r: NSRect, _ style: NSWindow.StyleMask) -> NSWindow {
    SnapshotWindow(contentRect: r, styleMask: style, backing: .buffered, defer: false)
  }
}

/// Window-server capture of one of our own windows at 1x (CGWindowListCreateImage is unavailable to Swift in the
/// macOS 15+ SDK but still exported; capturing your own windows needs no Screen Recording permission).
enum WindowCapture {
  private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
  private static let fn: Fn? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: Fn.self)
  }()

  static func image(_ w: NSWindow) -> CGImage? {
    let includingWindow: UInt32 = 1 << 3
    let ignoreFraming: UInt32 = 1 << 0, nominal: UInt32 = 1 << 4
    guard let fn, let img = fn(.null, includingWindow, UInt32(w.windowNumber), ignoreFraming | nominal)?.takeRetainedValue() else { return nil }
    return img
  }

  static func png(_ w: NSWindow) -> Data? {
    guard let img = image(w), img.width > 10 else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
  }
}
