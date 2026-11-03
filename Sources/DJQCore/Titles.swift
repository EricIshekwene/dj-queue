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

/// What a suggestion is for. `title`: the clip's one-line Title (display name, search, `{text}` fallback).
/// `text`: the on-video overlay text — line breaks, hooks — for the current version. Stored in separate tables.
public enum SuggestionKind: String, Codable, Sendable, CaseIterable {
  case title, text
  /// Also the videos.json / `djq suggest` key.
  var table: String { self == .title ? "title_suggestions" : "text_suggestions" }
}

/// A stored suggestion (title or overlay text, see `SuggestionKind`). `origin` is "manifest" (synced from
/// videos.json on every intake) or "agent" (added with `djq suggest`, kept until replaced by the same text+source).
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

/// Parses `djq suggest --file` input. Each entry carries `title_suggestions`, `text_suggestions` or both.
/// Accepted shapes:
/// - `[{video_id, title_suggestions: [...], text_suggestions: [...]}, ...]` (many clips — what `AgentPrompts`
///   asks agents to return)
/// - `{video_id, title_suggestions: [...]}` (one clip)
/// - `{title_suggestions: [...]}` or `[{text, ...}, ...]` (one clip; the video id comes from the command line;
///   a bare array is title suggestions)
public enum SuggestionImport {
  public struct Entry: Codable, Sendable, Hashable {
    public var videoId: String?
    public var titleSuggestions: [SuggestionInput]
    public var textSuggestions: [SuggestionInput]
    enum CodingKeys: String, CodingKey {
      case videoId = "video_id", titleSuggestions = "title_suggestions", textSuggestions = "text_suggestions"
    }
    init(videoId: String?, titleSuggestions: [SuggestionInput], textSuggestions: [SuggestionInput] = []) {
      self.videoId = videoId; self.titleSuggestions = titleSuggestions; self.textSuggestions = textSuggestions
    }
    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      // An entry needs at least one list; otherwise a bare `[{text, ...}]` would read as empty entries.
      guard c.contains(.titleSuggestions) || c.contains(.textSuggestions) else {
        throw DecodingError.keyNotFound(CodingKeys.titleSuggestions,
                                        .init(codingPath: c.codingPath, debugDescription: "no title_suggestions or text_suggestions"))
      }
      videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
      titleSuggestions = try c.decodeIfPresent([SuggestionInput].self, forKey: .titleSuggestions) ?? []
      textSuggestions = try c.decodeIfPresent([SuggestionInput].self, forKey: .textSuggestions) ?? []
    }
  }

  public struct ImportError: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = s }
  }

  /// `suggestions` are title suggestions; `textSuggestions` are overlay-text suggestions.
  public static func parse(_ data: Data, videoId: String? = nil) throws
    -> [(videoId: String, suggestions: [SuggestionInput], textSuggestions: [SuggestionInput])] {
    let dec = JSONDecoder()
    var entries: [Entry] = []
    if let many = try? dec.decode([Entry].self, from: data) {
      entries = many
    } else if let one = try? dec.decode(Entry.self, from: data) {
      entries = [one]
    } else if let bare = try? dec.decode([SuggestionInput].self, from: data) {
      entries = [Entry(videoId: nil, titleSuggestions: bare)]
    } else {
      throw ImportError("unreadable suggestions JSON — expected [{\"video_id\": …, \"title_suggestions\": [{\"text\": …}], \"text_suggestions\": [{\"text\": …}]}]")
    }
    return try entries.map { e in
      guard let id = e.videoId ?? videoId, !id.isEmpty else {
        throw ImportError("a suggestion entry has no video_id (pass <video> on the command line or add video_id)")
      }
      let all = e.titleSuggestions + e.textSuggestions
      for s in all where s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ImportError("a suggestion for \(id) has empty text")
      }
      if let bad = all.compactMap(\.confidence).first(where: { !(0...1).contains($0) }) {
        throw ImportError("confidence must be 0…1 (got \(bad)) for \(id)")
      }
      return (id, e.titleSuggestions, e.textSuggestions)
    }
  }
}

extension Store {
  // MARK: Titles

  /// `title_source` of a title Eric (or an agent) cleared: intake's manifest `title` never re-seeds it.
  public static let clearedTitleSource = "cleared"

  /// Sets Eric's title, or clears it with nil/empty. `source`: "app" (default), "agent", "suggestion".
  /// Clearing leaves a tombstone (`title_source = "cleared"`) so a videos.json `title` doesn't bring it back;
  /// a manifest title then only appears as a suggestion.
  public func setTitle(_ videoId: String, _ title: String?, tracks: [Track]? = nil, source: String = "app") throws {
    let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (t?.isEmpty ?? true) ? nil : t
    try db.run("UPDATE videos SET title=?, title_tracks=?, title_source=?, updated_at=? WHERE id=?",
               [value, value == nil ? nil : tracks.map { JSONCoding.string($0) },
                value == nil ? Self.clearedTitleSource : source, now, videoId])
    try logEvent("title", value.map { "Title \"\($0)\" (\(source))" } ?? "Title cleared", videoId: videoId)
    try refreshState(videoId: videoId)
  }

  /// Title suggestions for a clip, best first (confidence desc, then manifest order / newest agent).
  public func titleSuggestions(videoId: String) throws -> [TitleSuggestion] { try suggestions(.title, videoId: videoId) }

  /// Overlay-text suggestions for a clip, best first.
  public func textSuggestions(videoId: String) throws -> [TitleSuggestion] { try suggestions(.text, videoId: videoId) }

  public func suggestionCount(_ kind: SuggestionKind, videoId: String) throws -> Int {
    try db.one("SELECT COUNT(*) AS n FROM \(kind.table) WHERE video_id=?", [videoId])?.int("n") ?? 0
  }

  public func suggestions(_ kind: SuggestionKind, videoId: String) throws -> [TitleSuggestion] {
    try db.query("SELECT * FROM \(kind.table) WHERE video_id=? ORDER BY COALESCE(confidence,-1) DESC, sort, id", [videoId])
      .map(Self.suggestion)
  }

  /// Adds/updates suggestions (same text + source replaces the old one). Returns how many were stored.
  @discardableResult
  public func addSuggestions(videoId: String, _ list: [SuggestionInput], origin: String = "agent",
                             kind: SuggestionKind = .title) throws -> Int {
    guard try video(id: videoId) != nil else { throw StoreError.corruptRow("videos", "\(videoId) (no such video)") }
    return try db.transaction {
      var n = 0
      for (i, s) in list.enumerated() {
        let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        try db.run("""
          INSERT INTO \(kind.table)(video_id,text,tracks,confidence,source,origin,sort,created_at) VALUES(?,?,?,?,?,?,?,?)
          ON CONFLICT(video_id,origin,text,source) DO UPDATE SET tracks=excluded.tracks, confidence=excluded.confidence,
            sort=excluded.sort, created_at=excluded.created_at
          """, [videoId, text, JSONCoding.string(s.tracks), s.confidence, s.source ?? "", origin, i, now])
        n += 1
      }
      if origin != "manifest", n > 0 {
        try logEvent("title", "\(n) \(kind.rawValue) suggestion\(n == 1 ? "" : "s") added", videoId: videoId)
      }
      return n
    }
  }

  /// Replaces the manifest-origin suggestions of a clip with videos.json's current list (agent ones stay).
  func syncManifestSuggestions(videoId: String, _ raw: [SuggestionInput], kind: SuggestionKind = .title) throws {
    // Compare against what would actually be stored (non-empty text, one per text+source, last wins like the upsert).
    var seen = Set<String>()
    let list = raw.reversed().compactMap { s -> SuggestionInput? in
      var s = s
      s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
      s.source = s.source ?? ""
      guard !s.text.isEmpty, seen.insert("\(s.text)|\(s.source!)").inserted else { return nil }
      return s
    }.reversed().map { $0 }
    let current = try suggestions(kind, videoId: videoId).filter { $0.origin == "manifest" }
    func key(_ text: String, _ source: String, _ c: Double?, _ t: [Track]) -> String {
      "\(text)|\(source)|\(c.map { String($0) } ?? "-")|\(JSONCoding.string(t))"
    }
    let same = current.count == list.count
      && Set(current.map { key($0.text, $0.source, $0.confidence, $0.tracks) })
      == Set(list.map { key($0.text, $0.source ?? "", $0.confidence, $0.tracks) })
    if same { return }
    try db.run("DELETE FROM \(kind.table) WHERE video_id=? AND origin='manifest'", [videoId])
    try addSuggestions(videoId: videoId, list, origin: "manifest", kind: kind)
  }

  public func deleteSuggestion(id: Int64, kind: SuggestionKind = .title) throws {
    try db.run("DELETE FROM \(kind.table) WHERE id=?", [id])
  }

  static func suggestion(_ r: Row) -> TitleSuggestion {
    TitleSuggestion(id: r.int64("id")!, videoId: r.string("video_id")!, text: r.string("text")!,
                    tracks: r.json("tracks") ?? [], confidence: r.double("confidence"), source: r.string("source") ?? "",
                    origin: r.string("origin") ?? "agent", createdAt: r.date("created_at")!)
  }
}
