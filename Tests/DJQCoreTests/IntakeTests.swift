import Foundation
import Testing
@testable import DJQCore

@Suite struct IntakeTests {
  @Test func importsAllVideosWithMetadata() throws {
    let f = try Fixture()
    let r = try f.intake()
    #expect(r.sessionsSeen == 1)
    #expect(r.newVideos.count == 5)
    let vids = try f.store.videos()
    #expect(vids.count == 5)
    let long = try #require(vids.first { $0.type == .long })
    #expect(long.state == .ready)
    let yayo = try #require(try f.store.video(id: "clip-0"))
    #expect(yayo.tag == "yayo x johnny")
    #expect(yayo.kind == .djVid)
    #expect(yayo.state == .needsEdit)
    #expect(yayo.score == nil)
    #expect(yayo.markerIn == 3)
    #expect(yayo.fingerprint != nil)
    #expect(r.untracked.isEmpty)
  }

  @Test func secondRunKeepsAppOwnedFields() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.setScore("clip-0", 72)
    try f.store.setKind("clip-0", .talking)
    let r = try f.intake()
    #expect(r.newVideos.isEmpty)
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.score == 72)
    #expect(v.kind == .talking)
  }

  @Test func renamedFileIsRelinked() throws {
    let f = try Fixture()
    try f.intake()
    let old = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – bone shaker.mp4")
    let new = f.sessionDir.appendingPathComponent("Clips/bone shaker RENAMED.mp4")
    try FileManager.default.moveItem(at: old, to: new)
    let r = try f.intake()
    #expect(r.relinked.count == 1)
    let v = try #require(try f.store.video(id: "clip-2"))
    #expect(v.file == "Clips/bone shaker RENAMED.mp4")
    #expect(!v.missing)
    #expect(r.untracked.isEmpty)
  }

  @Test func deletedFileIsMarkedMissingNotDeleted() throws {
    let f = try Fixture()
    try f.intake()
    try FileManager.default.removeItem(at: f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – poosh 5.mp4"))
    let r = try f.intake()
    #expect(r.missing == ["2026-10-23 – Afroween Jazz Piano – poosh 5"])
    let v = try #require(try f.store.video(id: "clip-1"))
    #expect(v.missing)
    #expect(v.state == .missingFile)
    #expect(try f.store.videos().count == 5)
  }

  @Test func renamedSessionFolderMatchesByIds() throws {
    let f = try Fixture()
    try f.intake()
    let sid = try #require(try f.store.sessions().first?.id)
    let newDir = f.paths.sessions.appendingPathComponent("2026-10-23 – Afroween (renamed)")
    try FileManager.default.moveItem(at: f.sessionDir, to: newDir)
    try f.intake()
    let sessions = try f.store.sessions()
    #expect(sessions.count == 1)
    #expect(sessions[0].id == sid)
    #expect(URL(fileURLWithPath: sessions[0].folder).resolvingSymlinksInPath() == newDir.resolvingSymlinksInPath())
    #expect(try f.store.videos().allSatisfy { !$0.missing })
  }

  @Test func removedFromManifestIsKeptAndFlagged() throws {
    let f = try Fixture()
    try f.intake()
    f.entries.removeLast()
    try f.saveManifest()
    let r = try f.intake()
    #expect(r.removedFromManifest.count == 1)
    let v = try #require(try f.store.video(id: "clip-3"))
    #expect(!v.inManifest)
    #expect(v.missing)
  }

  @Test func parseErrorKeepsExistingVideos() throws {
    let f = try Fixture()
    try f.intake()
    try Data("{ broken".utf8).write(to: f.sessionDir.appendingPathComponent("videos.json"))
    let r = try f.intake()
    #expect(r.parseErrors.count == 1)
    #expect(try f.store.videos().allSatisfy { !$0.missing })
  }

  @Test func untrackedClipIsReported() throws {
    let f = try Fixture()
    try f.fakeFile("Clips/stray.mp4", seed: "stray-file")
    let r = try f.intake()
    #expect(r.untracked.count == 1)
  }

  @Test func duplicateIdsAreReported() throws {
    let f = try Fixture()
    var dup = f.entries[1]
    dup["name"] = "dup"
    f.entries.append(dup)
    try f.saveManifest()
    let r = try f.intake()
    #expect(r.duplicateIds.count == 1)
  }
}
