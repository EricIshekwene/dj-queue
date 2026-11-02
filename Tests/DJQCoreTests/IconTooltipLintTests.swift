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

  /// Review r4 L2: the lint catches the easy defeats (empty-title image buttons, empty tooltips with extra arguments,
  /// `.help (`, badges with no explanation) and still allows hidden shortcut buttons and disabled-reason-only tooltips.
  @Test func lintCatchesDefeats() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-lint-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("Sources/DJQueueApp")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let bad = """
      struct Bad: View {
        var body: some View {
          Button("", systemImage: "trash") { }
          Button("") { go() }
          Text("a").dsTooltip("", side: .bottom)
          Text("b").dsTooltip(nil, shortcut: "⌘B")
          Text("c").help ("x")
          DSBadge("3")
        }
      }
      """
    let good = """
      struct Good: View {
        var body: some View {
          Button("") { go() }.keyboardShortcut("k", modifiers: .command)
          Text("d").dsTooltip(nil, disabledReason: reason)
          DSBadge("3", help: "3 platforms")
          DSBadge("4")
            .dsTooltip("4 posts")
        }
      }
      """
    try bad.write(to: src.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
    try good.write(to: src.appendingPathComponent("Good.swift"), atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [repo.appendingPathComponent("scripts/check-icon-tooltips.py").path, tmp.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(p.terminationStatus == 1)
    #expect(!text.contains("Good.swift"), "\(text)")
    for line in [3, 4, 5, 6, 7, 8] { #expect(text.contains("Bad.swift:\(line):"), "line \(line) not flagged:\n\(text)") }
  }
}
