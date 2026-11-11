import CryptoKit
import Foundation
import Testing
@testable import DJQCore

/// Round 21 foundation: schema 9 (photo posts and set-time slots) is additive and lossless, and the new fields round-trip.
@Suite struct R21FoundationTests {
  func tempPaths() -> (Paths, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r21-\(UUID().uuidString)")
    return (Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                  logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents")), dir)
  }

  func video(_ id: String, score: Int?) -> Video {
    Video(id: id, sessionId: "s", name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid,
          file: "\(id).mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27,
          start: 0, end: 30, grace: 3, audio: nil, part: 1, score: score, state: .needsEdit,
          excluded: false, missing: false, inManifest: true, notes: "n-\(id)", alreadyPostedOn: [], longformURL: nil,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "T-\(id)")
  }

  /// Every table's rows as text, for a before/after comparison (`columns` leaves the new ones out).
  func dump(_ db: SQLite, _ table: String, _ columns: [String], order: String) throws -> [String] {
    try db.query("SELECT \(columns.map { "\"\($0)\"" }.joined(separator: ",")) FROM \(table) ORDER BY \(order)").map { r in
      columns.map { r.string($0) ?? r.double($0).map { String($0) } ?? "-" }.joined(separator: "|")
    }
  }

  @Test func schema8DatabaseGainsTheColumnsAndKeepsEveryRow() throws {
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    let vcols = ["id", "score", "state", "notes", "title", "file", "duration", "sent_to_queue"]
    let scols = ["id", "date", "position", "video_id", "pinned", "week_start"]
    let rcols = ["id", "video_id", "edit_hash", "output_path", "status"]
    var before: [[String]] = []
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      try s.save(video("a", score: 40))
      try s.save(video("b", score: nil))
      try s.save(PlanSlot(id: "slot", date: "2026-11-05", position: 0, videoId: "a", pinned: true, weekStart: "2026-11-02"))
      try s.save(Render(id: "r", videoId: "a", versionNo: 1, editHash: "h", scope: "all", outputPath: "/tmp/a.mp4", coverPath: nil,
                        loudness: nil, duration: 24, size: 10, status: .done, error: nil, createdAt: Date(), deletedAt: nil))
      // Back to a schema 8 database: none of the round 21 columns.
      try s.db.exec("""
        ALTER TABLE videos DROP COLUMN photos; ALTER TABLE plan_slots DROP COLUMN exact_at;
        ALTER TABLE renders DROP COLUMN more_paths; PRAGMA user_version = 8;
        """)
      before = [try dump(s.db, "videos", vcols, order: "id"), try dump(s.db, "plan_slots", scols, order: "id"),
                try dump(s.db, "renders", rcols, order: "id")]
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(Store.schemaVersion == 9)
    #expect(try dump(s.db, "videos", vcols, order: "id") == before[0])
    #expect(try dump(s.db, "plan_slots", scols, order: "id") == before[1])
    #expect(try dump(s.db, "renders", rcols, order: "id") == before[2])
    #expect(try s.videos().allSatisfy { $0.photos == nil && !$0.isPhoto })
    #expect(try s.planSlots().allSatisfy { $0.exactAt == nil && !$0.isExact })
    #expect(try s.renders().allSatisfy { $0.morePaths == nil && $0.allPaths == ["/tmp/a.mp4"] })
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema9-") })
    // Opening it again changes nothing and takes no second backup.
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    let again = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(again.filter { $0.hasPrefix("queue-before-schema9-") }.count == 1)
  }

  @Test func newFieldsRoundTrip() throws {
    let f = try Fixture()
    try f.store.save(Session(id: Session.photosId, folder: f.paths.photos.path, name: "Photos", date: nil, discoveredAt: f.clock.now,
                             missing: false))
    var v = video("photo-1", score: nil)
    v.sessionId = Session.photosId
    v.photos = [PhotoItem(id: "p1", file: "Originals/photo-1/01-p1.jpg", width: 4000, height: 3000),
                PhotoItem(id: "p2", file: "Originals/photo-1/02-p2.jpg", width: 3000, height: 4000)]
    v.inManifest = false
    try f.store.save(v)
    let back = try #require(try f.store.video(id: "photo-1"))
    #expect(back.isPhoto && back.photos == v.photos)

    let at = f.clock.now.addingTimeInterval(86400)
    try f.store.save(PlanSlot(id: "x", date: "2026-11-03", position: PlanSlot.exactBase, videoId: "photo-1", pinned: true,
                              weekStart: "2026-11-02", exactAt: at))
    let slot = try #require(try f.store.planSlots(where: "id='x'").first)
    #expect(slot.isExact && slot.exactAt == at && slot.position == 100)

    var r = Render(id: "r", videoId: "photo-1", versionNo: 1, editHash: "h", scope: "all", outputPath: "/tmp/01.jpg", coverPath: nil,
                   loudness: nil, duration: nil, size: 10, status: .done, error: nil, createdAt: f.clock.now, deletedAt: nil)
    r.morePaths = ["/tmp/02.jpg"]
    try f.store.save(r)
    #expect(try f.store.render(id: "r")?.allPaths == ["/tmp/01.jpg", "/tmp/02.jpg"])
    try f.store.setRenderMorePaths(id: "r", ["/tmp/b.jpg"])
    #expect(try f.store.render(id: "r")?.morePaths == ["/tmp/b.jpg"])
    try f.store.setRenderMorePaths(id: "r", nil)
    #expect(try f.store.render(id: "r")?.morePaths == nil)
  }

  /// A video's stored edit JSON is byte-identical to before (render hashes read it); photo crops appear only when set.
  @Test func editJSONIsUnchangedWithoutPhotoCrops() throws {
    var e = Edit()
    e.crop = CropRect(x: 1, y: 2, w: 3, h: 4)
    let plain = JSONCoding.string(e)
    #expect(!plain.contains("photoCrops"))
    e.photoCrops = ["p1": CropRect(x: 0, y: 0, w: 10, h: 10)]
    let withCrops = JSONCoding.string(e)
    #expect(withCrops.contains("photoCrops"))
    #expect(try JSONCoding.decoder.decode(Edit.self, from: Data(withCrops.utf8)) == e)
    #expect(try JSONCoding.decoder.decode(Edit.self, from: Data(plain.utf8)).photoCrops.isEmpty)
  }

  @Test func platformPhotoLimits() {
    #expect(!Platform.youtube.supportsPhotos && Platform.youtube.maxPhotos == 0)
    #expect(Platform.x.maxPhotos == 4 && Platform.instagram.maxPhotos == 10 && Platform.tiktok.maxPhotos == 35)
    #expect(Platform.allCases.filter(\.supportsPhotos).count == 5)
  }
}
