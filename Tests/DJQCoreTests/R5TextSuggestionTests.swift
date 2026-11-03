import CryptoKit
import Foundation
import Testing
@testable import DJQCore

/// Round 5: agent suggestions for the text on the video, kept apart from title suggestions.
@Suite struct R5TextSuggestionTests {
  @Test func importReadsBothListsAndKeepsTheOldShapes() throws {
    let both = #"[{"video_id":"a","title_suggestions":[{"text":"A x B"}],"text_suggestions":[{"text":"A\nx\nB","confidence":0.8}]}]"#
    let r = try SuggestionImport.parse(Data(both.utf8))
    #expect(r.count == 1 && r[0].suggestions.map(\.text) == ["A x B"] && r[0].textSuggestions.map(\.text) == ["A\nx\nB"])
    let textOnly = #"{"text_suggestions":[{"text":"Hook"}]}"#
    let t = try SuggestionImport.parse(Data(textOnly.utf8), videoId: "z")
    #expect(t[0].videoId == "z" && t[0].suggestions.isEmpty && t[0].textSuggestions.map(\.text) == ["Hook"])
    // A bare array is still title suggestions (not an array of empty entries).
    let bare = try SuggestionImport.parse(Data(#"[{"text":"Old","confidence":0.4}]"#.utf8), videoId: "z")
    #expect(bare.count == 1 && bare[0].suggestions.map(\.text) == ["Old"] && bare[0].textSuggestions.isEmpty)
    #expect(throws: (any Error).self) { try SuggestionImport.parse(Data(#"[{"video_id":"a"}]"#.utf8)) }
    #expect(throws: (any Error).self) {
      try SuggestionImport.parse(Data(#"[{"video_id":"a","text_suggestions":[{"text":"x","confidence":2}]}]"#.utf8))
    }
    #expect(throws: (any Error).self) {
      try SuggestionImport.parse(Data(#"[{"video_id":"a","text_suggestions":[{"text":"  "}]}]"#.utf8))
    }
  }

  @Test func textSuggestionsAreStoredApartAndKeepLineBreaks() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Yayo x Johnny", confidence: 0.7)])
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Who knows this blend?", confidence: 0.3, source: "hook"),
                                                   SuggestionInput(text: "Yayo\nx\nJohnny\n", confidence: 0.8, source: "a")],
                               kind: .text)
    #expect(try f.store.titleSuggestions(videoId: "clip-0").map(\.text) == ["Yayo x Johnny"])
    #expect(try f.store.textSuggestions(videoId: "clip-0").map(\.text) == ["Yayo\nx\nJohnny", "Who knows this blend?"])
    // Same text + source updates in place; text suggestions never count as title help.
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Yayo\nx\nJohnny", confidence: 0.9, source: "a")], kind: .text)
    let t = try f.store.textSuggestions(videoId: "clip-0")
    #expect(t.count == 2 && t[0].confidence == 0.9)
    try f.store.addSuggestions(videoId: "clip-1", [SuggestionInput(text: "Poosh\nx\n5", confidence: 0.9)], kind: .text)
    #expect(try AgentPrompts.needsTitleHelp(#require(try f.store.video(id: "clip-1")), store: f.store))
    try f.store.deleteSuggestion(id: t[1].id, kind: .text)
    #expect(try f.store.textSuggestions(videoId: "clip-0").count == 1)
    #expect(try f.store.titleSuggestions(videoId: "clip-0").count == 1)
  }

  @Test func manifestTextSuggestionsSyncAndAgentOnesStay() throws {
    let f = try Fixture()
    f.entries[1]["text_suggestions"] = [["text": "Yayo\nx\nJohnny", "confidence": 0.7, "source": "tool"]]
    f.entries[2]["text_suggestions"] = "not a list"  // malformed → ignored
    try f.saveManifest()
    #expect(try f.intake().parseErrors.isEmpty)
    #expect(try f.store.textSuggestions(videoId: "clip-0").map(\.origin) == ["manifest"])
    #expect(try f.store.titleSuggestions(videoId: "clip-0").isEmpty)
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Hook", confidence: 0.2)], kind: .text)
    f.entries[1]["text_suggestions"] = [["text": "Yayo x Johnny", "confidence": 0.6]]
    try f.saveManifest()
    try f.intake()
    #expect(try f.store.textSuggestions(videoId: "clip-0").map(\.text) == ["Yayo x Johnny", "Hook"])
    let first = try f.store.textSuggestions(videoId: "clip-0").map(\.id)
    try f.intake()
    #expect(try f.store.textSuggestions(videoId: "clip-0").map(\.id) == first)  // no churn
  }

  @Test func jsonAndPromptCarryTextSuggestions() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.setTitle("clip-0", "Yayo x Johnny")
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Yayo\nx\nJohnny", confidence: 0.8, source: "a")], kind: .text)
    let d = try AgentAPI.video("clip-0", store: f.store)
    #expect(d.text_suggestions.map(\.text) == ["Yayo\nx\nJohnny"] && d.video.text_suggestion_count == 1)
    let obj = try #require(try JSONSerialization.jsonObject(with: AgentAPI.encoder.encode(d)) as? [String: Any])
    #expect(obj["text_suggestions"] != nil)
    let md = try AgentPrompts.titles(for: ["clip-0", "clip-1"], store: f.store)
    #expect(md.contains("text_suggestions") && md.contains("title_suggestions"))
    #expect(md.contains("- Text on the video now: \"Yayo x Johnny\""))
    #expect(md.contains("- Text suggestions so far:\n  - \"Yayo / x / Johnny\" (confidence 0.80, source a)"))
    // The JSON block the prompt shows round-trips through `djq suggest --file`, both lists.
    let block = try #require(md.components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
    let parsed = try SuggestionImport.parse(Data(block.utf8))
    #expect(parsed.count == 1 && !parsed[0].suggestions.isEmpty)
    #expect(parsed[0].textSuggestions.first?.text == "Song One\nx\nSong Two")
  }

  // MARK: Migration v4

  func tempPaths() -> (Paths, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-v4-\(UUID().uuidString)")
    let p = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                  logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    return (p, dir)
  }

  @Test func syntheticV3GainsTheTableLosslessly() throws {
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    var before: [String] = []
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      try s.save(Video(id: "a", sessionId: "s", name: "a", tags: ["a"], type: .short, contentType: "dj vid", kind: .djVid,
                       file: "a.mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27,
                       start: 0, end: 30, grace: 3, audio: nil, part: 1, score: 40, state: .ready,
                       excluded: false, missing: false, inManifest: true, notes: "n", alreadyPostedOn: [], longformURL: nil,
                       createdAt: Date(), updatedAt: Date(), title: "T"))
      try s.addSuggestions(videoId: "a", [SuggestionInput(text: "Sug", confidence: 0.5)])
      // Back to a v3 database: no text_suggestions table.
      try s.db.exec("DROP TABLE text_suggestions; PRAGMA user_version = 3")
      before = try dump(s.db)
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(try dump(s.db) == before)
    #expect(try s.textSuggestions(videoId: "a").isEmpty && s.titleSuggestions(videoId: "a").map(\.text) == ["Sug"])
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema4-") })
  }

  /// `DJQ_MIGRATION_BACKUP_V4=<copy of a real queue.sqlite>`: migrates a further copy of it (the given file is
  /// checksummed before and after) and checks every existing table's rows are unchanged.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP_V4"] != nil))
  func realBackupCopyGainsTheTable() throws {
    let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP_V4"]!)
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sum = { (u: URL) in SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }
    let srcSum = try sum(src)
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let copy = paths.appSupport.appendingPathComponent("queue.sqlite")
    try FileManager.default.copyItem(at: src, to: copy)
    let old = try dump(SQLite(path: copy.path))
    let store = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)
    #expect(try store.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(try dump(store.db) == old)
    #expect(try store.db.one("SELECT COUNT(*) AS n FROM text_suggestions")?.int("n") == 0)
    #expect(try sum(src) == srcSum)
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)  // re-open is a no-op
  }

  /// Every row of the tables that existed before v4 (videos, edits, versions, title suggestions, posts), as text.
  func dump(_ db: SQLite) throws -> [String] {
    try ["videos", "edits", "versions", "title_suggestions", "platform_posts", "plan_slots"].flatMap { t in
      try db.query("SELECT * FROM \(t) ORDER BY rowid").map { r in
        "\(t): " + r.values.keys.sorted().map { "\($0)=\(r.string($0) ?? "null")" }.joined(separator: "|")
      }
    }
  }
}
