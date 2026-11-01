import AppKit
import DJQCore
import SwiftUI

/// `DJQueueApp --snapshot <dir>`: copies the database from `Paths.standard` (DJQ_ROOT/DJQ_HOME) into a throwaway
/// folder, seeds sample data there, then renders every screen at 1440×900 in light and dark to PNG.
///
/// Rendering uses real AppKit windows (NSHostingController + `cacheDisplay`) instead of `ImageRenderer`, because
/// ImageRenderer can't draw AppKit-backed controls (lists, tables, toggles, pickers, text fields).
@MainActor
enum SnapshotRunner {
  static func run(outputDir: String) async -> Int32 {
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let src = Paths.standard
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-snapshot-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: tmp) }

      // 1. Throwaway copy of the dev database (never the source DB).
      let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: src.thumbs, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
      if FileManager.default.fileExists(atPath: src.database.path) {
        let source = try Store(paths: src)
        try source.db.backup(to: paths.database.path)
      }
      var settings = AppSettings()
      let dm = DayMath(settings: settings)
      let now = dm.at(dm.key(Date()), minutes: 16 * 60 + 10)
      let clock = FixedClock(now)
      let store = try Store(paths: paths, clock: clock)
      if try store.videos().isEmpty { try Intake(store: store).run() }
      try SampleData.seed(store: store, clock: clock, now: now)
      clock.set(now)
      settings = try store.settings()

      let model = AppModel(store: store)
      model.frozen = true
      model.now = now
      model.refreshNow()
      model.weekStart = model.planner.weekStart(for: now)
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

      var shots: [Shot] = []
      func main(_ name: String, _ m: AppModel = model, _ setup: @escaping (AppModel) -> Void) {
        shots.append(Shot(name: name, kind: .main(m, setup)))
      }
      let firstPlanned = model.upcomingSlots.first?.videoId
      main("01-queue") { m in m.screen = .queue; m.queueTab = .ready; m.queueSelection = Set(firstPlanned.map { [$0] } ?? []) }
      main("02-queue-to-score") { m in m.queueTab = .toScore; m.queueSelection = Set([m.toScore.first?.id].compactMap { $0 }) }
      main("03-queue-bulk") { m in m.queueTab = .ready; m.queueSelection = Set(m.ordered.suffix(3).map(\.id)) }
      main("04-score-mode") { m in m.queueSelection = []; m.scoreMode = true }
      main("05-week") { m in m.scoreMode = false; m.screen = .week; m.weekStart = m.planner.weekStart(for: m.now) }
      main("06-week-next-draft") { m in m.weekStart = m.dm.addDays(m.planner.weekStart(for: m.now), 7); m.weekBacklogExpanded = true }
      main("07-today") { m in m.weekBacklogExpanded = false; m.screen = .today }
      main("08-library") { m in m.screen = .library; m.librarySelection = Set([m.videos.first { $0.type == .long }?.id].compactMap { $0 }) }
      main("09-library-grid") { m in m.libraryGrid = true; m.librarySelection = [] }
      main("10-posts") { m in
        m.libraryGrid = false; m.screen = .posts; m.postsFilter = .all
        m.postsSelection = m.problems.first { $0.state.isCopyright }?.id ?? m.problems.first?.id
      }
      main("11-health") { m in m.screen = .health; m.doctorReport = Doctor(store: m.store).run() }
      main("12-command-palette") { m in m.screen = .queue; m.queueSelection = Set(firstPlanned.map { [$0] } ?? []); m.showPalette = true }
      main("13-banners-paused") { m in
        m.showPalette = false
        m.update { $0.paused = true }
        m.screen = .today
      }
      let editId = model.ordered.first?.id ?? model.videos.first { $0.type == .short }?.id
      main("14-editor") { m in
        m.update { $0.paused = false }
        if let editId { m.openEditor(editId, in: m.ordered.map(\.id)) }
      }
      main("15-queue-after-editor") { m in m.editor = nil; m.screen = .queue }
      main("20-empty-queue", empty) { m in m.screen = .queue }
      main("21-empty-week", empty) { m in m.screen = .week }
      main("22-empty-today", empty) { m in m.screen = .today }
      main("23-empty-posts", empty) { m in m.screen = .posts }
      main("24-empty-library", empty) { m in m.screen = .library }
      for s in SettingsSection.allCases {
        shots.append(Shot(name: "30-settings-\(s.rawValue)", kind: .settings(model, s)))
      }
      shots.append(Shot(name: "40-menubar", kind: .view(CGSize(width: 320, height: 0)) {
        model.update { $0.paused = false }
        return AnyView(MenuBarView(model: model).background(.background))
      }))
      shots.append(Shot(name: "41-menubar-engine-off", kind: .view(CGSize(width: 320, height: 0)) {
        AnyView(MenuBarView(model: empty).background(.background))
      }))
      let due = model.dueToday.first { $0.state == .due }
      if let due {
        shots.append(Shot(name: "42-sheet-mark-posted", kind: .view(CGSize(width: 480, height: 0)) {
          AnyView(MarkPostedSheet(model: model, post: due).background(.background))
        }))
        shots.append(Shot(name: "43-sheet-report-problem", kind: .view(CGSize(width: 520, height: 0)) {
          AnyView(ReportProblemSheet(model: model, post: due).background(.background))
        }))
      }
      shots.append(Shot(name: "44-sheet-shortcuts", kind: .view(CGSize(width: 680, height: 0)) {
        AnyView(ShortcutSheet(model: model).background(.background))
      }))
      shots.append(Shot(name: "45-menubar-icons", kind: .view(CGSize(width: 360, height: 0)) {
        AnyView(MenuBarIconSheet().background(.background))
      }))
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

@MainActor
struct Shot {
  enum Kind {
    case main(AppModel, (AppModel) -> Void)
    case settings(AppModel, SettingsSection)
    case view(CGSize, () -> AnyView)
  }

  let name: String
  let kind: Kind

  func render(to dir: URL) async throws {
    let window: NSWindow
    switch kind {
    case .main(let m, let setup):
      setup(m)
      m.toast = nil
      window = WindowManager.makeMainWindow(model: m, make: SnapshotWindow.make)
      window.setContentSize(NSSize(width: 1440, height: 900))
    case .settings(let m, let s):
      window = WindowManager.makeSettingsWindow(model: m, section: s, make: SnapshotWindow.make)
      window.setContentSize(NSSize(width: 900, height: 640))
    case .view(let size, let make):
      let hv = NSHostingView(rootView: make().frame(width: size.width).modifier(SnapshotActive(on: true)))
      let fit = hv.fittingSize
      hv.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: max(fit.height, 40)))
      window = SnapshotWindow.make(hv.frame, [.borderless])
      window.contentView = hv
    }
    window.isReleasedWhenClosed = false
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      window.orderBack(nil)
      try await Task.sleep(for: .milliseconds(suffix == "light" ? 1600 : 800))
      window.displayIfNeeded()
      let png = WindowCapture.png(window) ?? cachedDisplay(window, dark: appearance == .darkAqua)
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

  static func png(_ w: NSWindow) -> Data? {
    let includingWindow: UInt32 = 1 << 3
    let ignoreFraming: UInt32 = 1 << 0, nominal: UInt32 = 1 << 4
    guard let fn, let img = fn(.null, includingWindow, UInt32(w.windowNumber), ignoreFraming | nominal)?.takeRetainedValue(),
          img.width > 10 else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
  }
}

/// MB.ICON states side by side (the real status item lives in the system menu bar).
struct MenuBarIconSheet: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Menu-bar icon states")
      row("Normal", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: false))
      row("Errors", MenuBarIcon.image(days: 5, errors: 2, engineOn: true, paused: false))
      row("Paused", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: true))
      row("Engine stopped", MenuBarIcon.image(days: 1, errors: 0, engineOn: false, paused: false))
    }
    .padding(16)
  }

  private func row(_ t: String, _ img: NSImage) -> some View {
    HStack {
      Text(t).font(DS.Font.body).frame(width: 120, alignment: .leading)
      Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original).foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
  }
}
