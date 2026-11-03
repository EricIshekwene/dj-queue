import Foundation
import Testing
@testable import DJQCore

/// Round 2 agent access: "Ask an agent" prompts and the JSON contract behind `djq … --json`.
@Suite struct R2AgentTests {
  @Test func needsTitleHelpPredicate() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(try AgentPrompts.needsTitleHelp(v, store: f.store))
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Maybe", confidence: 0.5)])
    #expect(try AgentPrompts.needsTitleHelp(v, store: f.store))
    try f.store.addSuggestions(videoId: "clip-0", [SuggestionInput(text: "Yayo x Johnny", confidence: 0.6)])
    #expect(try !AgentPrompts.needsTitleHelp(v, store: f.store))
    try f.store.setTitle("clip-1", "Poosh 5")
    #expect(try AgentPrompts.clipsNeedingTitleHelp(store: f.store) == ["clip-2", "clip-3"])
  }

  @Test func titlePromptHasEveryClipAndTheExactCommand() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.addSuggestions(videoId: "clip-1", [SuggestionInput(text: "Push 5", tracks: [Track(title: "Push 5", artist: "X")], confidence: 0.3, source: "guess")])
    let ids = ["clip-0", "clip-1", "clip-3"]
    let md = try AgentPrompts.titles(for: ids, store: f.store)
    for id in ids {
      let v = try #require(try f.store.video(id: id))
      #expect(md.contains("### \(id)") && md.contains("`\(v.tag)`"))
    }
    #expect(md.contains("djq suggest --file suggestions.json"))
    #expect(md.contains("\"Push 5\" (confidence 0.30, source guess, tracks: Push 5 — X)"))
    #expect(md.contains("Session: Afroween Jazz Piano · 2026-10-23"))
    #expect(md.contains("Marked: 1:43 → 4:15 on the part timeline"))  // clip-1: 100 + 3 … 100 + 158 − 3
    #expect(md.contains("Audio source: rekordbox") && md.contains("Part: 1"))
    #expect(md.contains("Never modify") && md.contains("Suggestions only"))
    #expect(try AgentPrompts.titles(for: ["clip-0"], store: f.store) == AgentPrompts.titles(for: ["clip-0"], store: f.store))  // deterministic
    // Round trip: the JSON block the prompt asks for is exactly what `djq suggest --file` accepts.
    let block = try #require(md.components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
    let parsed = try SuggestionImport.parse(Data(block.utf8))
    #expect(parsed.count == 1 && parsed[0].videoId == "clip-0" && parsed[0].suggestions[0].tracks.count == 2)
    var answer = parsed
    answer.append((videoId: "clip-3", suggestions: [SuggestionInput(text: "Asabone x Forgiveness", confidence: 0.8, source: "rekordbox history")], textSuggestions: []))
    for e in answer { try f.store.addSuggestions(videoId: e.videoId, e.suggestions) }
    #expect(try f.store.titleSuggestions(videoId: "clip-3").first?.text == "Asabone x Forgiveness")
    #expect(throws: EngineError.self) { try AgentPrompts.titles(for: ["nope"], store: f.store) }
  }

  @Test func jsonReadsUseTheDocumentedKeys() throws {
    let f = try Fixture.engine(3)
    try f.store.setTitle("clip-0", "Song x Mix")
    try f.store.addSuggestions(videoId: "clip-1", [SuggestionInput(text: "S1", confidence: 0.4, source: "a")])
    try Planner(store: f.store).approveWeek(f.week)
    func obj(_ v: some Encodable) throws -> Any { try JSONSerialization.jsonObject(with: AgentAPI.encoder.encode(v)) }

    let list = try #require(try obj(AgentAPI.videos(store: f.store, filter: "all")) as? [[String: Any]])
    #expect(list.count == 3)
    let first = list[0]
    for k in ["id", "display_name", "raw_tag", "state", "score", "kind", "suggestion_count", "needs_title_help", "issues", "file"] {
      #expect(first[k] != nil, "missing \(k)")
    }
    #expect(first["display_name"] as? String == "Song x Mix" && first["title"] as? String == "Song x Mix")
    #expect(try AgentAPI.videos(store: f.store, filter: "planned").count == 3)

    let d = try #require(try obj(AgentAPI.video("clip-1", store: f.store)) as? [String: Any])
    for k in ["video", "title_suggestions", "edit", "resolved_edit", "versions", "resolved_v1", "captions", "youtube_title", "issues", "plan", "posts"] {
      #expect(d[k] != nil, "missing \(k)")
    }
    #expect((d["title_suggestions"] as? [[String: Any]])?.first?["text"] as? String == "S1")
    #expect((d["captions"] as? [String: String])?["x"] != nil)
    #expect((d["resolved_edit"] as? [String: Any])?["defaulted"] is [String])

    let w = try #require(try obj(AgentAPI.week(f.week, store: f.store)) as? [String: Any])
    #expect(w["state"] as? String == "approved" && (w["days"] as? [Any])?.count == 7)
    let posts = try #require(try obj(AgentAPI.posts(store: f.store)) as? [[String: Any]])
    #expect(!posts.isEmpty && posts[0]["platform"] != nil && posts[0]["scheduled_at"] is String)
  }

  @Test func defaultsRoundTripAsJSON() throws {
    var d = NewClipDefaults()
    d.platformCaptionTemplates = [.x: "short"]
    d.cropAnchor = .rightThird
    let back = try JSONCoding.decoder.decode(NewClipDefaults.self, from: JSONCoding.encoder.encode(d))
    #expect(back == d)
  }
}
