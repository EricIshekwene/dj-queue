// TEMPORARY dev harness for the editor (the parent deletes this file at merge; UI-MAIN owns the real @main).
//   DJQueueApp [--video <id>]           opens EditorView on the DJQ_ROOT/DJQ_HOME database's short-form videos
//   DJQueueApp --snapshot <dir>         renders every tab in light + dark at 1440×900 to PNGs (on a throwaway DB copy)
import AppKit
import DJQCore
import SwiftUI

@main
enum EditorHarnessMain {
  static func main() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
      MainActor.assumeIsolated { EditorSnapshots.run(out: URL(fileURLWithPath: args[i + 1])) }
      exit(0)
    }
    EditorHarnessApp.main()
  }

  static func shortVideoIds(_ store: Store) -> [String] {
    ((try? store.videos()) ?? []).filter { $0.type == .short && !$0.excluded }
      .sorted { ($0.part ?? 0, $0.start ?? 0, $0.name) < ($1.part ?? 0, $1.start ?? 0, $1.name) }
      .map(\.id)
  }
}

struct EditorHarnessApp: App {
  @NSApplicationDelegateAdaptor(HarnessDelegate.self) var delegate
  let store: Store
  let ids: [String]
  let first: String

  init() {
    store = try! Store(paths: .standard)
    Log.shared.configure(store.paths)
    ids = EditorHarnessMain.shortVideoIds(store)
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--video"), args.count > i + 1 { first = args[i + 1] } else { first = ids.first ?? "" }
  }

  var body: some Scene {
    WindowGroup("DJ Queue — Editor") {
      HarnessRoot(store: store, first: first, ids: ids)
        .frame(minWidth: 1100, minHeight: 700)
    }
    .defaultSize(width: 1440, height: 900)
  }

  final class HarnessDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
  }
}

/// Borderless windows can't become key by default; key + active app = accent-coloured controls.
final class SnapshotWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// `--tab frame|text|caption|cover` picks the start tab; `--autoplay` starts playback (live checks).
struct HarnessRoot: View {
  let store: Store
  let first: String
  let ids: [String]
  @StateObject private var model: EditorModel
  init(store: Store, first: String, ids: [String]) {
    self.store = store; self.first = first; self.ids = ids
    _model = StateObject(wrappedValue: EditorModel(store: store, videoId: first))
  }
  var body: some View {
    EditorView(model: model, videoIds: ids) { NSApp.terminate(nil) }
      .task {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), a.count > i + 1, let t = EditorTab.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1] }) {
          model.tab = t
        }
        if a.contains("--autoplay") {
          try? await Task.sleep(nanoseconds: 1_500_000_000)
          model.playback.toggle()
        }
        if a.contains("--selfcheck") { await selfCheck() }
      }
  }
}

extension HarnessRoot {
  /// Live check without screen capture: playback advances, the AVPlayerLayer is displaying and its geometry
  /// maps the crop onto the preview; then exercises crop/text/trim edits through the model and quits.
  @MainActor func selfCheck() async {
    func surfaces() -> [EditorPlayerSurface.SurfaceView] {
      func walk(_ v: NSView) -> [EditorPlayerSurface.SurfaceView] {
        (v as? EditorPlayerSurface.SurfaceView).map { [$0] } ?? v.subviews.flatMap(walk)
      }
      return NSApp.windows.compactMap(\.contentView).flatMap(walk)
    }
    func report(_ label: String) {
      for s in surfaces() {
        let k = s.bounds.width / s.visible.width
        print("[\(label)] t=\(String(format: "%.2f", model.playback.time)) playing=\(model.playback.isPlaying) rate=\(model.playback.player?.rate ?? -1) ready=\(s.playerLayer.isReadyForDisplay) bounds=\(s.bounds.size) visible=\(s.visible) layer=\(s.playerLayer.frame) crop->bounds=\(String(format: "%.1fx%.1f", s.visible.width * k, s.visible.height * k)) tab=\(model.tab.rawValue) overlay=\(model.overlay != nil)")
      }
    }
    try? await Task.sleep(nanoseconds: 2_500_000_000); report("play+2.5s")
    try? await Task.sleep(nanoseconds: 2_000_000_000); report("play+4.5s")
    model.playback.toggle(); report("paused")
    model.tab = .frame
    try? await Task.sleep(nanoseconds: 500_000_000); report("frame tab")
    var c = model.crop; c.x += 600; model.setCrop(c); model.setZoom(1.5)
    try? await Task.sleep(nanoseconds: 500_000_000); report("crop moved+zoom1.5")
    print("upscale=\(String(format: "%.2f", model.upscale)) crop=\(model.crop)")
    model.tab = .text
    model.updateVersion { $0.posY = 0.3 }
    try? await Task.sleep(nanoseconds: 700_000_000); report("text tab posY .3")
    print("textBoundsUnit=\(String(describing: model.textBoundsUnit))")
    model.flushAndWait()
    try? await Task.sleep(nanoseconds: 300_000_000)
    print("issues=\(EditorValidationStrip.liveIssues(model).map(\.message)) saved=\(model.lastSaved != nil)")
    NSApp.terminate(nil)
  }
}

@MainActor
enum EditorSnapshots {
  static func run(out: URL) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    app.activate(ignoringOtherApps: true)
    settle(0.5)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let base = Paths.standard
    for dark in [false, true] {
      // Throwaway copy of the dev database so snapshot edits never touch it.
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-editor-snap-\(UUID().uuidString)")
      let support = tmp.appendingPathComponent("support")
      try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      for f in ["queue.sqlite", "queue.sqlite-wal", "queue.sqlite-shm", "prefill-rules.json"] {
        try? FileManager.default.copyItem(at: base.appSupport.appendingPathComponent(f), to: support.appendingPathComponent(f))
      }
      let paths = Paths(root: base.root, appSupport: support, logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("la"))
      guard let store = try? Store(paths: paths) else { print("no store"); return }
      let ids = EditorHarnessMain.shortVideoIds(store)
      let videos = (try? store.videos()) ?? []
      let main = videos.first { $0.tag == "yayo x johnny" }?.id ?? ids.first ?? ""
      let long = videos.filter { $0.type == .short }.max { $0.duration < $1.duration }?.id ?? main
      let theme = dark ? "dark" : "light"

      let m = EditorModel(store: store, videoId: main, snapshotMode: true)
      m.tab = .frame
      shoot(m, ids: ids, dark: dark, to: out.appendingPathComponent("E-frame-\(theme).png"))

      m.confirmCrop()
      m.updateVersion { $0.text = m.prefill }
      m.flushAndWait(); settle()
      m.tab = .text
      shoot(m, ids: ids, dark: dark, to: out.appendingPathComponent("E-text-\(theme).png"))

      m.updateVersion { $0.captionTemplateId = m.settings.defaultCaptionTemplateId }
      m.flushAndWait(); settle()
      m.tab = .caption
      shoot(m, ids: ids, dark: dark, to: out.appendingPathComponent("E-caption-\(theme).png"))

      m.tab = .cover
      shoot(m, ids: ids, dark: dark, to: out.appendingPathComponent("E-cover-\(theme).png"))

      // v2: everything carries forward from v1 ("from v1"), then the version list.
      m.newVersion(copying: nil)
      m.updateVersion { $0.style = .outline }
      m.flushAndWait(); settle()
      m.tab = .text
      shoot(m, ids: ids, dark: dark, to: out.appendingPathComponent("E-text-v2-\(theme).png"))
      shootView(EditorVersionList(model: m), size: NSSize(width: 300, height: 220), dark: dark,
                to: out.appendingPathComponent("E-versions-\(theme).png"))

      // Missing file (E.states Er).
      if let other = ids.first(where: { $0 != main && $0 != long }) {
        try? store.db.run("UPDATE videos SET file='Clips/__missing__.mp4' WHERE id=?", [other])
        let x = EditorModel(store: store, videoId: other, snapshotMode: true)
        shoot(x, ids: ids, dark: dark, to: out.appendingPathComponent("E-missing-\(theme).png"))
      }

      // A clip too long for some platforms, with a per-platform trim lane open.
      let l = EditorModel(store: store, videoId: long, snapshotMode: true)
      l.tab = .frame
      if let p = Validation.platformIssues(video: l.video!, edit: l.edit, settings: l.settings).first?.platform {
        l.addPlatformTrim(p)
      }
      l.flushAndWait(); settle()
      shoot(l, ids: ids, dark: dark, to: out.appendingPathComponent("E-frame-platformtrim-\(theme).png"))
      try? FileManager.default.removeItem(at: tmp)
    }
  }

  private static func settle(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

  private static func shoot(_ m: EditorModel, ids: [String], dark: Bool, to url: URL) {
    shootView(EditorView(model: m, videoIds: ids, onDone: {}), size: NSSize(width: 1440, height: 900), dark: dark, to: url)
  }

  private static func shootView<V: View>(_ root: V, size: NSSize, dark: Bool, to url: URL) {
    let view = NSHostingView(rootView: root.frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor)))
    let w = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                     backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.contentView = view
    w.orderFrontRegardless()
    w.makeKeyAndOrderFront(nil)
    w.makeMain()
    settle(1.2)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
    w.orderOut(nil)
  }
}
