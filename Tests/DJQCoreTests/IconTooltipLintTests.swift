import Foundation
import Testing

/// Round 3 F5 (Eric's acceptance rule): every icon-only button or menu trigger in the app has a tooltip.
/// Runs `scripts/check-icon-tooltips.py` over Sources/DJQueueApp and fails with the offenders it lists.
@Suite struct IconTooltipLintTests {
  @Test func everyIconOnlyButtonHasATooltip() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/check-icon-tooltips.py").path
    guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script, root.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(p.terminationStatus == 0, "\(text)")
  }
}
