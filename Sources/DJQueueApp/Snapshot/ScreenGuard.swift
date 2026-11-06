import AppKit
import DJQCore

/// Watches a `--snapshot` run for the two things it must never do: show a window on a display, or activate the app.
/// It reads the window server's list of this process's windows, so tooltips, popovers and menus count too. Each break
/// prints `screen-guard: FAIL …`, and the run exits 3 even if everything else passed.
@MainActor
enum ScreenGuard {
  private static var timer: Timer?
  private static var breaks = Set<String>()
  private static var samples = 0

  static func start() {
    let t = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    if ProcessInfo.processInfo.environment["DJQ_SCREEN_GUARD_SELFTEST"] != nil { selfTest() }
    sample()
  }

  /// The run's exit code once the guard has had its say.
  static func finish(_ code: Int32) -> Int32 {
    sample()
    timer?.invalidate()
    print(breaks.isEmpty ? "screen-guard: clean, \(samples) samples" : "screen-guard: FAIL \(breaks.count) break(s)")
    fflush(stdout)
    return breaks.isEmpty ? code : (code == 0 ? 3 : code)
  }

  private static func sample() {
    samples += 1
    if NSApp.isActive { report("the app became active") }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine: [ScreenGuardLogic.Seen] = info.compactMap { w in
      guard (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) == getpid() }) == true,
            let d = w[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: d as CFDictionary) else { return nil }
      return .init(bounds: bounds, alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
    }
    // Window-server rects run down from the primary display's top; NSScreen's run up from its bottom.
    let top = NSScreen.screens.first?.frame.height ?? 0
    let displays = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    for w in ScreenGuardLogic.onScreen(mine, displays: displays) {
      report("a window on a display at \(Int(w.bounds.minX)),\(Int(w.bounds.minY)) \(Int(w.bounds.width))×\(Int(w.bounds.height))")
    }
  }

  private static func report(_ what: String) {
    guard breaks.insert(what).inserted else { return }
    print("screen-guard: FAIL \(what)")
    fflush(stdout)
  }

  /// `DJQ_SCREEN_GUARD_SELFTEST=1`: proves the guard can fail, with a 2 pt, nearly clear, click-through window.
  private static func selfTest() {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.alphaValue = 0.01
    w.ignoresMouseEvents = true
    Backstage.front(w)
    w.setFrameOrigin(NSPoint(x: NSScreen.screens.first?.frame.minX ?? 0, y: NSScreen.screens.first?.frame.minY ?? 0))
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { w.orderOut(nil) }
  }
}
