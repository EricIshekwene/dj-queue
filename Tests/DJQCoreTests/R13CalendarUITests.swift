import Foundation
import Testing

/// Round 13: the words Eric sees and the way the Calendar loads, read from the app's source (the app target can't be
/// imported into tests). Queue is the last step, so no approval step may survive in a string, and `body` never reaches
/// for the database.
@Suite struct R13CalendarUITests {
  private static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/DJQueueApp")

  private func sources(under folder: String = "") throws -> [(path: String, text: String)] {
    let root = Self.app.appendingPathComponent(folder)
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
    return try files.filter { $0.pathExtension == "swift" }.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
  }

  /// String literals on code lines, without comments or interpolated code (`\\(s.approvedRunwayAlertDays)` is a field,
  /// not a word Eric sees).
  private func literals(_ text: String) -> [String] {
    text.split(separator: "\n").flatMap { line -> [String] in
      let code = line.trimmingCharacters(in: .whitespaces)
      guard !code.hasPrefix("//") else { return [] }
      return code.split(separator: "\"", omittingEmptySubsequences: false).enumerated().compactMap { i, s in
        i % 2 == 1 ? String(s).replacing(/\\\([^)]*\)/, with: "") : nil
      }
    }
  }

  @Test func noApprovalWordsInTheApp() throws {
    let banned = ["approve", "approved", "approval", "draft week", "propose", "rebuild week", "add to week", "push plan", "open week", "open today"]
    var hits: [String] = []
    for (path, text) in try sources() where !path.contains("/Snapshot/") {
      for s in literals(text) where banned.contains(where: { s.lowercased().contains($0) }) && !s.hasPrefix("alert.") {
        hits.append("\(URL(fileURLWithPath: path).lastPathComponent): \(s)")
      }
    }
    #expect(hits.isEmpty, "\(hits)")
  }

  @Test func theStagesAreGone() throws {
    let screen = try String(contentsOf: Self.app.appendingPathComponent("App/Screen.swift"), encoding: .utf8)
    #expect(screen.contains("case score, edit, queue, calendar, library, posts, health"))
    for (path, text) in try sources() {
      #expect(!text.contains("screen = .today"), "\(path)")
      #expect(!text.contains("screen = .week"), "\(path)")
      #expect(!text.contains("showMain(screen: .today)"), "\(path)")
    }
  }

  @Test func noDatabaseWorkInCalendarViews() throws {
    for (path, text) in try sources(under: "Calendar") where !path.hasSuffix("CalendarModel.swift") && !path.contains("/AppModel+") {
      #expect(!text.contains("store."), "\(path)")
    }
  }

  @Test func theRemovedPlanActionsStayRemoved() throws {
    let all = try sources().filter { !$0.path.contains("/Snapshot/") }.map(\.text).joined()
    for call in ["approveWeek(", "proposeWeek(", "rebuildWeek(", "pushPlan(", "addToWeek("] { #expect(!all.contains(call), "\(call)") }
  }

  @Test func onlySendToQueueMovesAClipOutOfEdit() throws {
    let edit = try String(contentsOf: Self.app.appendingPathComponent("EditScreen/EditView.swift"), encoding: .utf8)
    #expect(edit.contains("Nothing missing. Press Send to Queue when it's ready to post."))
    for (_, text) in try sources() { #expect(!text.contains("movedToQueue")) }
  }
}
