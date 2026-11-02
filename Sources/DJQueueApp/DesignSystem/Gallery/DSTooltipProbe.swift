import AppKit
import DJQCore
import SwiftUI

/// Evidence run for DSTooltip in the REAL main window (design/TOOLTIPS-DECISIONS.md):
/// `DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1 DJQueueApp --snapshot <dir>`.
///
/// Builds the real AppModel on a throwaway copy of the dev DB (same seeding as SnapshotRunner), opens the real main
/// window without activating the app (it never steals focus or moves the user's cursor), then drives the tooltip
/// through synthetic mouse-moved events posted to the app's own queue — the same hover path a real pointer takes.
/// For each case it captures the window server's composite of the main window + the tooltip panel and records
/// the frames (`probe.json`). Cases: toolbar at the window's top edge (must flip below), sidebar status near the
/// bottom edge, the delay group hand-off, Escape, dark mode, and the window pushed into the screen's top-right
/// corner (must flip + shift and stay on screen).
@MainActor
enum DSTooltipProbe {
  struct Record: Encodable {
    var name: String
    var label: String
    var side: String
    var anchor: [Double]
    var bubble: [Double]?
    var window: [Double]
    var insideWindow: Bool
    var insideScreen: Bool
    var openedAfterMs: Int?
    var note: String
  }

  static func run(outputDir: String) async -> Int32 {
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let model = try makeModel()
      let w = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
      w.isReleasedWhenClosed = false
      w.appearance = NSAppearance(named: .aqua)
      let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      w.setFrameOrigin(NSPoint(x: screen.midX - 720, y: screen.midY - 450))
      w.orderBack(nil)
      let c = DSTooltipController.shared
      c.requireActiveApp = false
      var records: [Record] = []

      func settle(_ ms: Int = 1200) async throws { try await Task.sleep(for: .milliseconds(ms)); w.displayIfNeeded() }

      /// Moves the synthetic pointer to `a`'s centre and waits for the tooltip (or `timeout`).
      func hover(_ a: DSTooltipAnchorView, timeout: Int = 1500) async throws -> Int? {
        guard let r = a.visibleScreenRect else { return nil }
        let start = Date()
        await post(.mouseMoved, at: CGPoint(x: r.midX, y: r.midY), in: w)
        while Date().timeIntervalSince(start) * 1000 < Double(timeout) {
          try await Task.sleep(for: .milliseconds(20))
          if c.debugShown === a, c.debugPanelFrame != nil { return Int(Date().timeIntervalSince(start) * 1000) }
        }
        return nil
      }

      func record(_ name: String, _ a: DSTooltipAnchorView, opened: Int?, note: String) async throws {
        try await Task.sleep(for: .milliseconds(250))  // let the 120 ms fade/slide finish
        let rect = a.visibleScreenRect ?? .zero
        let b = c.debugPanelFrame
        let vis = (w.screen ?? NSScreen.main)?.frame ?? screen
        records.append(Record(name: name, label: a.content.label ?? a.content.disabledReason ?? "", side: c.debugSide?.rawValue ?? "-",
                              anchor: arr(rect), bubble: b.map(arr), window: arr(w.frame),
                              insideWindow: b.map { w.frame.contains($0) } ?? false, insideScreen: b.map { vis.contains($0) } ?? false,
                              openedAfterMs: opened, note: note))
        try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent("\(name).png"))
        print("tooltip-probe: \(name) · \(a.content.label ?? "") · side \(c.debugSide?.rawValue ?? "-") · opened \(opened.map { "\($0) ms" } ?? "no")")
      }

      func park() async throws {
        await post(.mouseMoved, at: CGPoint(x: w.frame.midX, y: w.frame.minY + 2), in: w)  // empty strip, no trigger
        c.hide(resetGroup: true)
        try await Task.sleep(for: .milliseconds(450))
      }

      // 1. Queue: toolbar triggers sit 10 pt under the window's top edge → preferred top must flip below.
      SnapshotContext.resetUI(model)
      model.screen = .queue
      try await settle(1800)
      let all = anchors(in: w)
      try JSONEncoder.pretty.encode(all.map { [$0.content.label ?? "", $0.content.shortcut ?? "", $0.content.disabledReason ?? "",
                                               "\(Int($0.visibleScreenRect?.minX ?? 0) - Int(w.frame.minX)),\(Int(w.frame.maxY - ($0.visibleScreenRect?.maxY ?? 0)))"] })
        .write(to: out.appendingPathComponent("anchors-queue.json"))
      let toolbar = all.filter { ($0.visibleScreenRect?.maxY ?? 0) > w.frame.maxY - 60 }.sorted { ($0.visibleScreenRect?.minX ?? 0) < ($1.visibleScreenRect?.minX ?? 0) }
      guard let tA = toolbar.dropLast().last, let tB = toolbar.last else { throw ProbeError.noAnchors("toolbar") }
      var opened = try await hover(tA)
      try await record("01-queue-toolbar-top-edge-flips-below", tA, opened: opened, note: "first hover: full delay; window top edge above")
      // 2. Delay group: straight to the neighbour → opens at once.
      opened = try await hover(tB)
      try await record("02-queue-toolbar-delay-group-instant", tB, opened: opened, note: "moved from the previous trigger: delay group")
      // 3. Escape closes and keeps it closed while the pointer stays.
      postKey(53, in: w)
      try await Task.sleep(for: .milliseconds(700))
      records.append(Record(name: "03-escape-closes", label: tB.content.label ?? "", side: "-", anchor: arr(tB.visibleScreenRect ?? .zero),
                            bubble: c.debugPanelFrame.map(arr), window: arr(w.frame), insideWindow: false, insideScreen: false,
                            openedAfterMs: nil, note: c.debugPanelFrame == nil ? "closed after Esc, stayed closed 700 ms" : "STILL OPEN"))
      try await park()

      // 4. Sidebar engine status near the window's bottom-left edge.
      if let s = all.filter({ ($0.visibleScreenRect?.minX ?? .infinity) < w.frame.minX + 260 })
        .min(by: { ($0.visibleScreenRect?.minY ?? 0) < ($1.visibleScreenRect?.minY ?? 0) }) {
        opened = try await hover(s)
        try await record("04-sidebar-bottom-left", s, opened: opened, note: "bottom-left of the window")
        try await park()
      }

      // 5. Collapsed sidebar: icon rows explain themselves (label + ⌘ shortcut).
      model.sidebarCollapsed = true
      try await settle()
      let rail = anchors(in: w).filter { ($0.visibleScreenRect?.maxX ?? .infinity) < w.frame.minX + 90 && $0.content.shortcut != nil }
      if let r = rail.dropFirst(2).first {
        opened = try await hover(r)
        try await record("05-collapsed-sidebar-row-shortcut", r, opened: opened, note: "compact sidebar row, keycaps")
        try await park()
      }
      model.sidebarCollapsed = false

      // 6. Dark mode, Week screen, a content trigger.
      w.appearance = NSAppearance(named: .darkAqua)
      model.screen = .week
      try await settle(1600)
      let week = anchors(in: w).filter { ($0.visibleScreenRect?.minX ?? 0) > w.frame.minX + 300 && ($0.visibleScreenRect?.maxY ?? 0) < w.frame.maxY - 80 }
      if let d = week.first {
        opened = try await hover(d)
        try await record("06-dark-week-content", d, opened: opened, note: "dark: light bubble, no shadow")
        try await park()
      }

      // 7. Window pushed into the screen's top-right corner: toolbar's last trigger must flip below and shift left.
      w.appearance = NSAppearance(named: .aqua)
      model.screen = .queue
      w.setFrameTopLeftPoint(NSPoint(x: screen.maxX - w.frame.width, y: screen.maxY))
      try await settle(1600)
      if let last = anchors(in: w).filter({ ($0.visibleScreenRect?.maxY ?? 0) > w.frame.maxY - 60 })
        .max(by: { ($0.visibleScreenRect?.maxX ?? 0) < ($1.visibleScreenRect?.maxX ?? 0) }) {
        opened = try await hover(last)
        try await record("07-window-at-screen-top-right-corner", last, opened: opened, note: "window flush with screen top + right edges")
        try await park()
      }

      try JSONEncoder.pretty.encode(records).write(to: out.appendingPathComponent("probe.json"))
      print("tooltip-probe: \(records.count) cases → \(out.path) (SwiftUI hover-ins: \(c.debugHoverEvents), forwarded moves: \(forwarded))")
      w.orderOut(nil)
      w.close()
      return 0
    } catch {
      FileHandle.standardError.write(Data("tooltip-probe failed: \(error)\n".utf8))
      return 1
    }
  }

  enum ProbeError: Error { case noAnchors(String) }

  // MARK: Helpers

  /// The real model on a throwaway copy of the dev DB (never the source DB), seeded like SnapshotRunner.
  static func makeModel() throws -> AppModel {
    let src = Paths.standard
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-tooltip-probe-\(UUID().uuidString)")
    let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                      launchAgents: tmp.appendingPathComponent("LaunchAgents"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src.thumbs, withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
    if FileManager.default.fileExists(atPath: src.database.path) { try Store(paths: src).db.backup(to: paths.database.path) }
    let dm = DayMath(settings: AppSettings())
    let now = dm.at(dm.key(Date()), minutes: 16 * 60 + 10)
    let clock = FixedClock(now)
    let store = try Store(paths: paths, clock: clock)
    if try store.videos().isEmpty { try Intake(store: store).run() }
    try SampleData.seed(store: store, clock: clock, now: now)
    clock.set(now)
    let model = AppModel(store: store)
    model.frozen = true
    model.now = now
    model.refreshNow()
    model.weekStart = model.planner.weekStart(for: now)
    model.loaded = true
    return model
  }

  static func anchors(in w: NSWindow) -> [DSTooltipAnchorView] {
    var found: [DSTooltipAnchorView] = []
    func walk(_ v: NSView) {
      if let a = v as? DSTooltipAnchorView, !a.content.isEmpty, a.visibleScreenRect != nil { found.append(a) }
      v.subviews.forEach(walk)
    }
    if let root = w.contentView?.superview ?? w.contentView { walk(root) }
    return found
  }

  /// Posts a real mouse-moved event to our own queue (never the user's cursor). AppKit derives tracking-area
  /// enter/exit from the window server's pointer, not from posted events; if no enter arrives within 80 ms the
  /// probe forwards the move to the tracking logic exactly as an enter/exit pair would (counted in probe.json).
  private static func post(_ type: NSEvent.EventType, at screenPoint: CGPoint, in w: NSWindow) async {
    let c = DSTooltipController.shared
    c.simulatedPointer = screenPoint
    let before = c.debugHoverEvents
    let p = w.convertPoint(fromScreen: screenPoint)
    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
      NSApp.postEvent(e, atStart: false)
    }
    try? await Task.sleep(for: .milliseconds(80))
    if c.debugHoverEvents == before {
      forwarded += 1
      c.debugPointerMoved(to: screenPoint, in: w)
    }
  }

  static var forwarded = 0

  private static func postKey(_ code: UInt16, in w: NSWindow) {
    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: code) {
      DSTooltipController.shared.debugHandle(e)
    }
  }

  private static func arr(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

  /// Window-server composite of the main window plus the tooltip panel (own windows: no permission needed).
  private typealias FromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
  private static let fromArray: FromArray? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let sym = dlsym(h, "CGWindowListCreateImageFromArray") else { return nil }
    return unsafeBitCast(sym, to: FromArray.self)
  }()

  private static func capture(_ w: NSWindow, panel: NSWindow?) -> Data? {
    guard let img = captureImage(w, panel: panel) else { return WindowCapture.png(w) }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
  }

  /// The window server's image of `w` (plus `panel` when visible), framed by the window: own windows need no
  /// Screen Recording permission.
  static func captureImage(_ w: NSWindow, panel: NSWindow?) -> CGImage? {
    let wins = [panel?.isVisible == true ? panel : nil, w].compactMap { $0 }
    var ids: [UnsafeRawPointer?] = wins.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
    guard let fromArray, let arr = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let r = w.frame
    let cg = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    guard let img = fromArray(cg, arr, 1 << 4)?.takeRetainedValue(), img.width > 10 else { return nil }
    return img
  }

}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
  }
}
