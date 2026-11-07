import CoreGraphics
import Foundation
import Testing

@testable import DJQCore

/// Verification runs must never show on a display or take focus: `ScreenGuard` watches a run, and the lint stops a new
/// script from pulling a window forward by itself.
@Suite struct BackgroundWindowTests {
  let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

  @Test func backstageWindowsPass() {
    let w = ScreenGuardLogic.Seen(bounds: CGRect(x: -24_000, y: -24_000, width: 1440, height: 900), alpha: 1)
    #expect(ScreenGuardLogic.onScreen([w], displays: [display]).isEmpty)
  }

  @Test func anyPartOnADisplayFails() {
    let corner = ScreenGuardLogic.Seen(bounds: CGRect(x: 1511, y: 981, width: 400, height: 300), alpha: 1)
    let tiny = ScreenGuardLogic.Seen(bounds: CGRect(x: 0, y: 0, width: 2, height: 2), alpha: 0.01)
    #expect(ScreenGuardLogic.onScreen([corner, tiny], displays: [display]) == [corner, tiny])
  }

  @Test func theSecondDisplayCounts() {
    let w = ScreenGuardLogic.Seen(bounds: CGRect(x: 1600, y: 10, width: 100, height: 100), alpha: 1)
    #expect(ScreenGuardLogic.onScreen([w], displays: [display]).isEmpty)
    #expect(ScreenGuardLogic.onScreen([w], displays: [display, CGRect(x: 1512, y: 0, width: 1920, height: 1080)]) == [w])
  }

  @Test func fullyClearWindowsDontCount() {
    let w = ScreenGuardLogic.Seen(bounds: CGRect(x: 10, y: 10, width: 100, height: 100), alpha: 0)
    #expect(ScreenGuardLogic.onScreen([w], displays: [display]).isEmpty)
  }

  @Test func devBuildsNeedBothDevVariables() {
    let dev = "/x/worktree/.build/debug/djq"
    #expect(Paths.devRunRefusal(executable: dev, environment: [:]) != nil)
    #expect(Paths.devRunRefusal(executable: dev, environment: ["DJQ_HOME": "/s"]) != nil)
    #expect(Paths.devRunRefusal(executable: dev, environment: ["DJQ_HOME": "", "DJQ_ROOT": "/r"]) != nil)
    #expect(Paths.devRunRefusal(executable: dev, environment: ["DJQ_HOME": "/s", "DJQ_ROOT": "/r"]) == nil)
  }

  @Test func theInstalledAppIsNeverRefused() {
    #expect(Paths.devRunRefusal(executable: "/Users/x/Applications/DJ Queue.app/Contents/MacOS/DJQueue", environment: [:]) == nil)
    #expect(Paths.devRunRefusal(executable: "/Users/x/Applications/DJ Queue.app/Contents/MacOS/djq", environment: [:]) == nil)
  }

  /// Only the real app's window code and `Backstage` may bring a window forward or activate the app.
  @Test func onlyBackstageBringsWindowsForward() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources/DJQueueApp")
    let allowed = ["DJQueueApp.swift", "Snapshot/Backstage.swift", "Snapshot/ScreenGuard.swift", "DesignSystem/DSTooltip.swift"]
    let banned = ["orderFrontRegardless", "makeKeyAndOrderFront", "orderBack(", ".orderFront(", "setIsVisible(true)", "NSApp.activate",
                  "NSApplication.shared.activate", "NSRunningApplication.current.activate", "setActivationPolicy(.regular)",
                  "NSWindow(contentRect", "NSMenu.popUpContextMenu"]
    var offenders: [String] = []
    let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    while let url = walker?.nextObject() as? URL {
      guard url.pathExtension == "swift", !allowed.contains(where: { url.path.hasSuffix("/" + $0) }) else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      for (i, line) in text.components(separatedBy: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
        if banned.contains(where: line.contains) { offenders.append("\(url.lastPathComponent):\(i + 1): \(line)") }
      }
    }
    #expect(offenders.isEmpty, "use Backstage.show(window): \(offenders)")
  }
}
