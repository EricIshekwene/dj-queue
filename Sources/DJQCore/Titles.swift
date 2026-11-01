import Foundation

/// One track behind a title suggestion (upstream metadata; see docs/metadata.md).
public struct Track: Codable, Sendable, Hashable {
  public var title: String
  public var artist: String?
  public init(title: String, artist: String? = nil) { self.title = title; self.artist = artist }
}

/// A title suggestion as written by upstream agents/tools — in videos.json (`title_suggestions`) or through
/// `djq suggest --file`. The app never generates these.
public struct SuggestionInput: Codable, Sendable, Hashable {
  public var text: String
  public var tracks: [Track]
  public var confidence: Double?
  public var source: String?
  public init(text: String, tracks: [Track] = [], confidence: Double? = nil, source: String? = nil) {
    self.text = text; self.tracks = tracks; self.confidence = confidence; self.source = source
  }
  enum CodingKeys: String, CodingKey { case text, tracks, confidence, source }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    text = try c.decode(String.self, forKey: .text)
    tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
    source = try c.decodeIfPresent(String.self, forKey: .source)
  }
}

/// A stored suggestion. `origin` is "manifest" (synced from videos.json on every intake) or "agent"
/// (added with `djq suggest`, kept until replaced by the same text+source).
public struct TitleSuggestion: Codable, Sendable, Hashable, Identifiable {
  public var id: Int64
  public var videoId: String
  public var text: String
  public var tracks: [Track]
  public var confidence: Double?
  public var source: String
  public var origin: String
  public var createdAt: Date
}

/// Parses `djq suggest --file` input. Accepted shapes:
/// - `[{video_id, title_suggestions: [...]}, ...]` (many clips — what `AgentPrompts` asks agents to return)
/// - `{video_id, title_suggestions: [...]}` (one clip)
/// - `{title_suggestions: [...]}` or `[{text, ...}, ...]` (one clip; the video id comes from the command line)
public enum SuggestionImport {
  public struct Entry: Codable, Sendable, Hashable {
    public var videoId: String?
    public var titleSuggestions: [SuggestionInput]
    enum CodingKeys: String, CodingKey { case videoId = "video_id", titleSuggestions = "title_suggestions" }
  }

  public struct ImportError: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = s }
  }

  public static func parse(_ data: Data, videoId: String? = nil) throws -> [(videoId: String, suggestions: [SuggestionInput])] {
    let dec = JSONDecoder()
    var entries: [Entry] = []
    if let many = try? dec.decode([Entry].self, from: data) {
      entries = many
    } else if let one = try? dec.decode(Entry.self, from: data) {
      entries = [one]
    } else if let bare = try? dec.decode([SuggestionInput].self, from: data) {
      entries = [Entry(videoId: nil, titleSuggestions: bare)]
    } else {
      throw ImportError("unreadable suggestions JSON — expected [{\"video_id\": …, \"title_suggestions\": [{\"text\": …}]}]")
    }
    return try entries.map { e in
      guard let id = e.videoId ?? videoId, !id.isEmpty else {
        throw ImportError("a suggestion entry has no video_id (pass <video> on the command line or add video_id)")
      }
      for s in e.titleSuggestions where s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ImportError("a suggestion for \(id) has empty text")
      }
      if let bad = e.titleSuggestions.compactMap(\.confidence).first(where: { !(0...1).contains($0) }) {
        throw ImportError("confidence must be 0…1 (got \(bad)) for \(id)")
      }
      return (id, e.titleSuggestions)
    }
  }
}

extension Store {
  // MARK: Titles

  /// Sets (or clears with nil/empty) Eric's title. `source`: "app" (default), "agent", "suggestion".
  public func setTitle(_ videoId: String, _ title: String?, tracks: [Track]? = nil, source: String = "app") throws {
    let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (t?.isEmpty ?? true) ? nil : t
    try db.run("UPDATE videos SET title=?, title_tracks=?, title_source=?, updated_at=? WHERE id=?",
               [value, value == nil ? nil : tracks.map { JSONCoding.string($0) }, value == nil ? nil : source, now, videoId])
    try logEvent("title", value.map { "Title \"\($0)\" (\(source))" } ?? "Title cleared", videoId: videoId)
    try refreshState(videoId: videoId)
  }

  /// Suggestions for a clip, best first (confidence desc, then manifest order / newest agent).
  public func titleSuggestions(videoId: String) throws -> [TitleSuggestion] {
    try db.query("SELECT * FROM title_suggestions WHERE video_id=? ORDER BY COALESCE(confidence,-1) DESC, sort, id", [videoId])
      .map(Self.suggestion)
  }

  /// Adds/updates suggestions (same text + source replaces the old one). Returns how many were stored.
  @discardableResult
  public func addSuggestions(videoId: String, _ list: [SuggestionInput], origin: String = "agent") throws -> Int {
    guard try video(id: videoId) != nil else { throw StoreError.corruptRow("videos", "\(videoId) (no such video)") }
    return try db.transaction {
      var n = 0
      for (i, s) in list.enumerated() {
        let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        try db.run("""
          INSERT INTO title_suggestions(video_id,text,tracks,confidence,source,origin,sort,created_at) VALUES(?,?,?,?,?,?,?,?)
          ON CONFLICT(video_id,origin,text,source) DO UPDATE SET tracks=excluded.tracks, confidence=excluded.confidence,
            sort=excluded.sort, created_at=excluded.created_at
          """, [videoId, text, JSONCoding.string(s.tracks), s.confidence, s.source ?? "", origin, i, now])
        n += 1
      }
      if origin != "manifest", n > 0 { try logEvent("title", "\(n) title suggestion\(n == 1 ? "" : "s") added", videoId: videoId) }
      return n
    }
  }

  /// Replaces the manifest-origin suggestions of a clip with videos.json's current list (agent ones stay).
  func syncManifestSuggestions(videoId: String, _ list: [SuggestionInput]) throws {
    let current = try titleSuggestions(videoId: videoId).filter { $0.origin == "manifest" }
    let same = current.count == list.count && Set(current.map { "\($0.text)|\($0.source)" })
      == Set(list.map { "\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))|\($0.source ?? "")" })
      && zip(current.sorted { $0.text < $1.text }, list.sorted { $0.text < $1.text })
      .allSatisfy { $0.confidence == $1.confidence && $0.tracks == $1.tracks }
    if same { return }
    try db.run("DELETE FROM title_suggestions WHERE video_id=? AND origin='manifest'", [videoId])
    try addSuggestions(videoId: videoId, list, origin: "manifest")
  }

  public func deleteSuggestion(id: Int64) throws { try db.run("DELETE FROM title_suggestions WHERE id=?", [id]) }

  static func suggestion(_ r: Row) -> TitleSuggestion {
    TitleSuggestion(id: r.int64("id")!, videoId: r.string("video_id")!, text: r.string("text")!,
                    tracks: r.json("tracks") ?? [], confidence: r.double("confidence"), source: r.string("source") ?? "",
                    origin: r.string("origin") ?? "agent", createdAt: r.date("created_at")!)
  }
}
