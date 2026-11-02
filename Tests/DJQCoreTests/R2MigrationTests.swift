import CryptoKit
import Foundation
import Testing
@testable import DJQCore

/// Schema v2 migration must be lossless (north star). With `DJQ_MIGRATION_BACKUP=<round-1 queue.sqlite>` it migrates a
/// COPY of that database (the original is checksummed before and after); the synthetic v1 test runs everywhere.
@Suite struct R2MigrationTests {
  static let backup = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP"] ?? "/nonexistent")

  func tempPaths() -> (Paths, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-mig-\(UUID().uuidString)")
    let p = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                  logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    return (p, dir)
  }

  func sha(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }

  @Test(.enabled(if: FileManager.default.fileExists(atPath: R2MigrationTests.backup.path)))
  func realBackupCopyMigratesLosslessly() throws {
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = try sha(Self.backup)
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let copy = paths.appSupport.appendingPathComponent("queue.sqlite")
    try FileManager.default.copyItem(at: Self.backup, to: copy)
    // Read the round-1 values straight from the copy before migrating.
    let raw = try SQLite(path: copy.path)
    let scores = try raw.query("SELECT id, score, kind, excluded, notes FROM videos ORDER BY id").map {
      "\($0.string("id")!)|\($0.int("score").map(String.init) ?? "-")|\($0.string("kind")!)|\($0.bool("excluded"))|\($0.string("notes") ?? "")"
    }
    let oldEdits = try raw.query("SELECT video_id, json FROM edits").map { ($0.string("video_id")!, $0.string("json")!) }
    let oldVersions = try raw.query("SELECT video_id, number, json FROM versions ORDER BY video_id, number").map { $0.string("json")! }
    let oldSettings = try raw.one("SELECT json FROM kv WHERE key='settings'")?.string("json")
    #expect(try raw.one("PRAGMA user_version")?.int("user_version") == 1)

    let store = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)
    #expect(try store.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(try store.db.query("SELECT id, score, kind, excluded, notes FROM videos ORDER BY id").map {
      "\($0.string("id")!)|\($0.int("score").map(String.init) ?? "-")|\($0.string("kind")!)|\($0.bool("excluded"))|\($0.string("notes") ?? "")"
    } == scores)
    #expect(try store.db.query("SELECT json FROM versions ORDER BY video_id, number").map { $0.string("json")! } == oldVersions)
    #expect(try store.videos().allSatisfy { $0.title == nil })
    let settings = try store.settings()
    for (id, json) in oldEdits {
      // Round-1 meaning of the stored JSON (non-optional aspect / cover text, nil trim = whole file, nil cover = trim start).
      let o = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      let r = try store.resolvedEdit(videoId: id, settings: settings)
      #expect(r.aspect.rawValue == (o["aspect"] as? String ?? "9:16"))
      #expect(r.coverIncludesText == (o["coverIncludesText"] as? Bool ?? true))
      let c = o["crop"] as? [String: Double]
      #expect(r.crop == c.map { CropRect(x: $0["x"]!, y: $0["y"]!, w: $0["w"]!, h: $0["h"]!) } && r.cropConfirmed == (c != nil))
      if let t = o["trimIn"] as? Double { #expect(r.trimIn == t && !r.isDefault(.trimIn)) }
      if let t = o["trimOut"] as? Double { #expect(r.trimOut == t && !r.isDefault(.trimOut)) }
      if let t = o["coverTime"] as? Double { #expect(r.coverTime == t) }
    }
    // Settings: every round-1 value survives; the text/caption defaults moved into `defaults`.
    if let old = oldSettings, let o = try JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Any] {
      #expect(settings.postsPerDay == o["postsPerDay"] as? Int)
      #expect(settings.paused == o["paused"] as? Bool)
      #expect(settings.defaults.captionTemplateId == o["defaultCaptionTemplateId"] as? String ?? "set-link")
      #expect(settings.defaults.hashtagSetIds == o["defaultHashtagSetIds"] as? [String] ?? ["amapiano", "dj"])
      #expect(settings.defaults.textSize == o["defaultTextSize"] as? Double ?? 64)
    }
    // A copy was taken before migrating, and the original backup was never touched.
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema2-") })
    #expect(try sha(Self.backup) == before)
    // Re-opening is a no-op.
    let again = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)
    #expect(try again.db.query("SELECT json FROM edits").map { $0.string("json")! }
      == (try store.db.query("SELECT json FROM edits").map { $0.string("json")! }))
  }

  @Test func syntheticV1EditsBecomeOverrides() throws {
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("q.sqlite")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      for id in ["a", "b", "c"] {
        try s.save(Video(id: id, sessionId: "s", name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid,
                         file: "\(id).mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27,
                         start: 0, end: 30, grace: 3, audio: nil, part: 1, score: 50, state: .needsEdit, excluded: false,
                         missing: false, inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil,
                         createdAt: Date(), updatedAt: Date()))
      }
      let rows = [
        ("a", #"{"aspect":"9:16","coverIncludesText":true,"crop":{"h":2160,"w":1216,"x":10,"y":0},"platformTrims":[],"skippedPlatforms":["x"]}"#),
        ("b", #"{"aspect":"4:5","coverIncludesText":false,"platformTrims":[],"skippedPlatforms":[],"trimIn":1,"trimOut":9}"#),
        ("c", #"{ broken"#),
      ]
      for (id, j) in rows { try s.db.run("INSERT INTO edits(video_id,json,updated_at) VALUES(?,?,0)", [id, j]) }
      try s.db.exec("PRAGMA user_version = 1")
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    let a = try s.edit(videoId: "a"), b = try s.edit(videoId: "b")
    #expect(a.aspectOverride == nil && a.coverIncludesTextOverride == nil && a.crop?.x == 10 && a.skippedPlatforms == [.x])
    #expect(b.aspectOverride == .r4x5 && b.coverIncludesTextOverride == false && b.trimIn == 1 && b.trimOut == 9)
    #expect(try s.db.one("SELECT json FROM edits WHERE video_id='c'")?.string("json") == "{ broken")  // untouched
    let ra = try s.resolvedEdit(videoId: "a")
    #expect(ra.aspect == .r9x16 && ra.coverIncludesText && ra.isDefault(.aspect))
  }
}
