import CryptoKit
import Foundation

/// Reads every `Sessions/*/videos.json` and keeps the database in step (spec §4).
/// Never writes to session folders.
public struct IntakeReport: Sendable, Codable {
  public var sessionsSeen = 0
  public var newVideos: [String] = []
  public var updated = 0
  public var relinked: [String] = []  // "name: old → new"
  public var missing: [String] = []
  public var removedFromManifest: [String] = []
  public var parseErrors: [String] = []  // "path: error"
  public var duplicateIds: [String] = []
  public var untracked: [String] = []  // .mp4 in Clips/ not in any videos.json
  public init() {}
}

public final class Intake: @unchecked Sendable {
  let store: Store
  var paths: Paths { store.paths }
  let fm = FileManager.default

  public init(store: Store) { self.store = store }

  struct Manifest: Decodable {
    var session: String?
    var videos: [Entry]
  }

  struct Entry: Decodable {
    var id: String?
    var name: String
    var tags: [String]?
    var type: String?
    var contentType: String?
    var file: String
    var session: String?
    var part: Int?
    var markedStart: Double?
    var markedEnd: Double?
    var start: Double?
    var end: Double?
    var duration: Double?
    var grace: Double?
    var audio: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
      case id, name, tags, type, file, session, part, start, end, duration, grace, audio, status
      case contentType = "content-type"
      case markedStart = "marked_start"
      case markedEnd = "marked_end"
    }
  }

  @discardableResult
  public func run() throws -> IntakeReport {
    var report = IntakeReport()
    let dirs = (try? fm.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: [.isDirectoryKey]))?
      .filter { !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".") }
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

    let existingVideos = Dictionary(uniqueKeysWithValues: try store.videos().map { ($0.id, $0) })
    var existingSessions = try store.sessions()
    var seenIds = Set<String>()
    var seenSessionIds = Set<String>()
    var manifestFiles = Set<String>()

    for dir in dirs {
      let mURL = dir.appendingPathComponent("videos.json")
      guard fm.fileExists(atPath: mURL.path) else { continue }
      report.sessionsSeen += 1
      let manifest: Manifest
      do {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: mURL))
      } catch {
        report.parseErrors.append("\(mURL.path): \(error)")
        // Keep this session's videos as they are; don't mark them missing because of a parse error.
        for v in existingVideos.values where existingSessions.first(where: { $0.id == v.sessionId })?.folder == dir.path {
          seenIds.insert(v.id)
        }
        if let s = existingSessions.first(where: { $0.folder == dir.path }) { seenSessionIds.insert(s.id) }
        continue
      }

      // Session: match by folder, else by any known video id (folder was renamed), else new.
      let ids = manifest.videos.compactMap(\.id)
      var session = existingSessions.first { $0.folder == dir.path }
        ?? ids.lazy.compactMap { existingVideos[$0]?.sessionId }.first.flatMap { sid in existingSessions.first { $0.id == sid } }
      let name = dir.lastPathComponent
      if session == nil {
        session = Session(id: newId(), folder: dir.path, name: name, date: Self.date(from: name),
                          discoveredAt: store.now, missing: false)
        try store.logEvent("intake", "New session \(name)")
      } else if session!.folder != dir.path {
        try store.logEvent("intake", "Session renamed \(URL(fileURLWithPath: session!.folder).lastPathComponent) → \(name)")
      }
      session!.folder = dir.path
      session!.name = name
      session!.date = Self.date(from: name)
      session!.missing = false
      try store.save(session!)
      existingSessions.removeAll { $0.id == session!.id }
      existingSessions.append(session!)
      seenSessionIds.insert(session!.id)

      for e in manifest.videos {
        manifestFiles.insert(dir.appendingPathComponent(e.file).standardizedFileURL.path)
        guard let id = e.id, !id.isEmpty else {
          report.parseErrors.append("\(mURL.path): video \"\(e.name)\" has no id")
          continue
        }
        if !seenIds.insert(id).inserted {
          report.duplicateIds.append("\(id) (\(e.name))")
          continue
        }
        try upsert(e, id: id, session: session!, old: existingVideos[id], report: &report)
      }
    }

    // Videos whose manifest no longer lists them: keep the record, mark missing, ask (spec §4).
    for v in existingVideos.values where !seenIds.contains(v.id) && v.inManifest {
      var v = v
      v.inManifest = false
      v.missing = true
      v.updatedAt = store.now
      try store.save(v)
      try store.refreshState(videoId: v.id)
      report.removedFromManifest.append(v.name)
      try store.logEvent("intake", "Removed from videos.json: \(v.name)", videoId: v.id)
    }
    for var s in try store.sessions() where !seenSessionIds.contains(s.id) && !s.missing {
      s.missing = true
      try store.save(s)
      try store.logEvent("intake", "Session folder missing: \(s.name)")
    }

    // Untracked clips (Doctor finding).
    let tracked = try relinkedPaths()
    for dir in dirs {
      let clips = dir.appendingPathComponent("Clips")
      for f in (try? fm.contentsOfDirectory(atPath: clips.path)) ?? [] where f.lowercased().hasSuffix(".mp4") {
        let p = clips.appendingPathComponent(f).standardizedFileURL.path
        if !manifestFiles.contains(p) && !tracked.contains(p) { report.untracked.append(p) }
      }
    }
    try store.setKV("lastIntake", report)
    try store.setKV("lastIntakeAt", store.now)
    return report
  }

  private func relinkedPaths() throws -> Set<String> {
    Set(try store.videos().compactMap { v in try store.fileURL(for: v)?.standardizedFileURL.path })
  }

  private func upsert(_ e: Entry, id: String, session: Session, old: Video?, report: inout IntakeReport) throws {
    let now = store.now
    let type: VideoType = e.type == VideoType.long.rawValue ? .long : .short
    var v = old ?? Video(
      id: id, sessionId: session.id, name: e.name, tags: e.tags ?? [], type: type,
      contentType: e.contentType ?? "dj vid", kind: .djVid, file: e.file, fingerprint: nil, fileSize: nil,
      duration: e.duration ?? 0, markedStart: e.markedStart, markedEnd: e.markedEnd, start: e.start, end: e.end,
      grace: e.grace, audio: e.audio, part: e.part, score: nil, state: .needsEdit, excluded: false, missing: false,
      inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil, createdAt: now, updatedAt: now)
    // Identity/metadata fields come from videos.json; app-owned fields (score, kind, notes, excluded…) are kept.
    v.sessionId = session.id
    v.name = e.name
    v.tags = e.tags ?? v.tags
    v.type = type
    v.contentType = e.contentType ?? v.contentType
    v.duration = e.duration ?? v.duration
    v.markedStart = e.markedStart
    v.markedEnd = e.markedEnd
    v.start = e.start
    v.end = e.end
    v.grace = e.grace
    v.audio = e.audio
    v.part = e.part
    v.inManifest = true
    if old != nil, old!.file != e.file, !fileExists(session, old!.file) || fileExists(session, e.file) {
      v.file = e.file  // manifest moved the file
    } else if old == nil {
      v.file = e.file
    }

    let base = URL(fileURLWithPath: session.folder)
    let url = base.appendingPathComponent(v.file)
    if fm.fileExists(atPath: url.path) {
      let size = Self.size(url)
      if v.fingerprint == nil || v.fileSize != size {
        v.fileSize = size
        v.fingerprint = Self.fingerprint(url, duration: v.duration)
      }
      v.missing = false
    } else if let found = try relink(v, session: session) {
      let rel = Self.relative(found, to: base) ?? found.path
      report.relinked.append("\(v.name): \(v.file) → \(rel)")
      try store.logEvent("relink", "Relinked \(v.name): \(v.file) → \(rel)", videoId: v.id)
      v.file = rel
      v.missing = false
    } else {
      if !v.missing {
        report.missing.append(v.name)
        try store.logEvent("missing", "File missing: \(v.name) (\(v.file))", videoId: v.id)
      }
      v.missing = true
    }

    if old == nil {
      report.newVideos.append(v.name)
      try store.logEvent("intake", "New \(type == .long ? "long-form" : "short-form"): \(v.name)", videoId: v.id)
    } else if old != v {
      report.updated += 1
    }
    if old != v {
      v.updatedAt = now
      try store.save(v)
    }
    try store.refreshState(videoId: v.id)
  }

  private func fileExists(_ s: Session, _ rel: String) -> Bool {
    fm.fileExists(atPath: URL(fileURLWithPath: s.folder).appendingPathComponent(rel).path)
  }

  /// Same fingerprint in this session, then in all sessions (spec §4).
  private func relink(_ v: Video, session: Session) throws -> URL? {
    guard let fp = v.fingerprint, let size = v.fileSize else { return nil }
    let ownDir = URL(fileURLWithPath: session.folder)
    let others = try store.sessions().map { URL(fileURLWithPath: $0.folder) }.filter { $0 != ownDir }
    for dir in [ownDir] + others {
      guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
      for case let f as URL in en {
        if ["Video", "Audio", "Other"].contains(f.lastPathComponent) { en.skipDescendants(); continue }
        guard f.pathExtension.lowercased() == "mp4", Self.size(f) == size else { continue }
        if Self.fingerprint(f, duration: v.duration) == fp { return f }
      }
    }
    return nil
  }

  // MARK: Helpers

  public static func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
  }

  /// size + duration + sha256 of the first 4 MB (spec §3).
  public static func fingerprint(_ url: URL, duration: Double) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let data = h.readData(ofLength: 4 * 1024 * 1024)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "\(size(url))-\(String(format: "%.2f", duration))-\(digest)"
  }

  static func relative(_ url: URL, to base: URL) -> String? {
    let p = url.standardizedFileURL.path, b = base.standardizedFileURL.path + "/"
    return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : nil
  }

  static func date(from name: String) -> String? {
    guard let r = name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
    return String(name[r])
  }
}
