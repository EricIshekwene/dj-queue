import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import DJQCore

/// "Remove from queue" (sent back to Edit), "Send to queue", and the stage moves built on them.
@Suite struct UnqueueTests {
  func bulk(_ f: Fixture) -> BulkActions {
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    return b
  }

  /// Everything undo must put back, minus the bookkeeping timestamp `save` refreshes.
  func planState(_ f: Fixture) throws -> (slots: [PlanSlot], weeks: [String], posts: [String]) {
    let posts = try f.store.posts(order: "id").map { p in
      "\(p.id)|\(p.videoId)|\(p.platform.rawValue)|\(p.state.rawValue)|\(p.scheduledAt.timeIntervalSince1970)|\(p.planSlotId ?? "-")|\(p.attemptNo)|\(p.kind.rawValue)|\(p.renderId ?? "-")"
    }
    let weeks = try f.store.db.query("SELECT week_start, state FROM weeks ORDER BY week_start").map { "\($0.string("week_start")!)|\($0.string("state")!)" }
    return (try f.store.planSlots().sorted { $0.id < $1.id }, weeks, posts)
  }

  func slot(_ f: Fixture, _ day: String) throws -> PlanSlot { try #require(try f.store.planSlots(where: "date=?", [day]).first) }

  @Test func flagForcesNeedsEditWithAClearIssue() throws {
    let f = try Fixture.engine(2)
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
    try f.store.setHeldInEdit("clip-0", true)
    let v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.heldInEdit && v.state == .needsEdit)
    let issues = try Validation.issues(video: v, store: f.store)
    #expect(issues.map(\.kind) == [.heldInEdit] && issues[0].message.hasPrefix("Sent back from Queue"))
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-1"])
    #expect(try Queue(store: f.store).needsEdit().map(\.id) == ["clip-0"])
    #expect(ClipStage.of(v) == .edit)
    // The planner never picks or pins a held clip.
    #expect(throws: EngineError.self) { try Planner(store: f.store).pin(videoId: "clip-0", date: "2026-11-05") }
    try Planner(store: f.store).proposeWeek(f.week)
    #expect(try f.store.planSlots(where: "video_id='clip-0'").isEmpty)
    #expect(try f.store.events(videoId: "clip-0").contains { $0.message == "Sent back to Edit from Queue" })
  }

  @Test func removeDeletesFutureUnpostedOnlyAndUndoRestoresExactly() throws {
    let f = try Fixture.engine(6)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)  // Mon 2 … Sat 7 Nov, one clip a day, 6 platforms each
    #expect(try f.store.planSlots().count == 6 && f.store.posts().count == 36)
    let mon = try slot(f, "2026-11-02"), tue = try slot(f, "2026-11-03"), thu = try slot(f, "2026-11-05")
    // Monday fully posted; Tuesday posted on TikTok only.
    try f.postAll(on: "2026-11-02")
    let tueTikTok = try #require(try f.store.slotPosts(tue.id).first { $0.platform == .tiktok })
    f.setTime("2026-11-03", "20:00")
    try PostActions(store: f.store).markPosted(postId: tueTikTok.id, url: Fixture.postURLs[.tiktok]!)
    f.setTime("2026-11-03", "21:00")
    let before = try planState(f)
    let b = bulk(f)

    // Dry run: what would go, nothing changes.
    let dry = try b.removeFromQueue([thu.videoId], dryRun: true)
    #expect(dry.changed == [thu.videoId] && dry.batchId == nil)
    #expect(dry.unplanned?[thu.videoId]?.map(\.date) == ["2026-11-05"])
    #expect(dry.unplanned?[thu.videoId]?.first?.platforms.count == 6)
    #expect(try planState(f) == before)

    let monPosts = try f.store.slotPosts(mon.id), tuePosts = try f.store.slotPosts(tue.id)
    let r = try b.removeFromQueue([thu.videoId, mon.videoId, tue.videoId])
    #expect(r.changed == [thu.videoId])
    // Thursday: slot + its 6 posts gone; the other days keep their clips and dates (no reshuffle).
    #expect(try f.store.planSlot(id: thu.id) == nil)
    #expect(try f.store.posts(where: "video_id=?", [thu.videoId]).isEmpty)
    #expect(try f.store.planSlots().map(\.date) == ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-06", "2026-11-07"])
    for s in before.slots where s.id != thu.id { #expect(try f.store.planSlot(id: s.id) == s) }
    // Monday (fully posted) and Tuesday (posted on TikTok, 5 in flight) are refused: nothing deleted, not held.
    #expect(r.skipped[mon.videoId]?.hasPrefix("Already posted on") == true)
    #expect(r.skipped[tue.videoId] == "Already posted on TikTok — it can't leave the plan; skip or reset its posts in Posts")
    #expect(try f.store.slotPosts(mon.id) == monPosts && f.store.slotPosts(tue.id) == tuePosts)
    for id in [mon.videoId, tue.videoId] {
      let v = try #require(try f.store.video(id: id))
      #expect(!v.heldInEdit && v.state != .needsEdit)
    }
    #expect(try f.store.video(id: mon.videoId)?.state == .posted && f.store.video(id: tue.videoId)?.state == .posting)
    let held = try #require(try f.store.video(id: thu.videoId))
    #expect(held.heldInEdit && held.state == .needsEdit)
    #expect(try f.store.events(videoId: thu.videoId).contains { $0.kind == "bulk" && $0.message.hasPrefix("unqueue") })
    #expect(try f.doublePosts().isEmpty)
    // Send to queue has nothing to do on the refused clips (they were never held).
    let s = try b.sendToQueue([mon.videoId, tue.videoId])
    #expect(s.changed.isEmpty && s.batchId == nil)
    // Stage back gives the same reason.
    #expect(try b.blocker(try #require(try f.store.video(id: tue.videoId)), .back) == r.skipped[tue.videoId])

    // One undo puts the flag, slots, weeks and posts back exactly.
    try b.undo(try #require(r.batchId))
    #expect(try planState(f) == before)
    #expect(try f.store.video(id: thu.videoId)?.heldInEdit == false)
    #expect(try f.store.video(id: thu.videoId)?.state == .planned)
    #expect(try f.doublePosts().isEmpty)
  }

  /// A clip held before this rule (or via the raw flag) that has a posted post keeps its real posted state.
  @Test func heldFlagNeverMasksPostedState() throws {
    let f = try Fixture.engine(2)
    try Planner(store: f.store).approveWeek(f.week)
    let mon = try slot(f, "2026-11-02")
    let tiktok = try #require(try f.store.slotPosts(mon.id).first { $0.platform == .tiktok })
    f.setTime("2026-11-02", "20:00")
    try PostActions(store: f.store).markPosted(postId: tiktok.id, url: Fixture.postURLs[.tiktok]!)
    try f.store.setHeldInEdit(mon.videoId, true)
    let v = try #require(try f.store.video(id: mon.videoId))
    #expect(v.state == .posting)
    #expect(try !Validation.issues(video: v, store: f.store).contains { $0.kind == .heldInEdit })
  }

  @Test func removingAPinnedClipRemovesItsPin() throws {
    let f = try Fixture.engine(8)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)  // 7 days, clip-7 (best) left in the backlog with worst-first
    let backlog = try #require(try Queue(store: f.store).ordered().first)
    try planner.pin(videoId: backlog.id, date: "2026-11-06")
    let pinned = try #require(try f.store.planSlots(where: "video_id=?", [backlog.id]).first)
    #expect(pinned.pinned && pinned.date == "2026-11-06")
    let before = try planState(f)
    let r = try bulk(f).removeFromQueue([backlog.id])
    #expect(r.unplanned?[backlog.id]?.first?.pinned == true)
    #expect(try f.store.planSlots(where: "video_id=?", [backlog.id]).isEmpty)
    #expect(try f.store.planSlots(where: "date='2026-11-06'").isEmpty)  // no backfill
    #expect(try f.store.planSlots(where: "pinned=1").isEmpty)
    try bulk(f).undo(try #require(r.batchId))
    #expect(try planState(f) == before)
  }

  @Test func sendToQueueReturnsValidClipsAndKeepsRealIssues() throws {
    let f = try Fixture.engine(4, ready: 2)
    try f.store.setScore("clip-2", 55)  // scored, no crop/text → needs edit
    let b = bulk(f)
    let r = try b.removeFromQueue(["clip-0", "clip-2", "clip-3", "long-0001"])
    #expect(Set(r.changed) == ["clip-0", "clip-2"])
    #expect(r.skipped["clip-3"]?.hasPrefix("not scored") == true && r.skipped["long-0001"]?.hasPrefix("long-form") == true)
    #expect(r.unplanned?.isEmpty == true)
    let again = try b.removeFromQueue(["clip-0"])
    #expect(again.changed.isEmpty && again.batchId == nil)  // already so
    let s = try b.sendToQueue(["clip-0", "clip-2", "clip-1"])
    #expect(Set(s.changed) == ["clip-0", "clip-2"])
    #expect(try f.store.video(id: "clip-0")?.state == .ready)
    #expect(try Queue(store: f.store).ordered().map(\.id).contains("clip-0"))
    let v2 = try #require(try f.store.video(id: "clip-2"))
    #expect(v2.state == .needsEdit && !v2.heldInEdit)
    #expect(s.remainingIssues["clip-2"]?.contains { $0.kind == .noCrop } == true)
    #expect(s.remainingIssues["clip-2"]?.contains { $0.kind == .heldInEdit } == false)
    try b.undo(try #require(s.batchId))
    #expect(try f.store.video(id: "clip-0")?.heldInEdit == true)
  }

  @Test func inFlightExtrasOfAHeldClipAreRemovedToo() throws {
    let f = try Fixture.engine(3)
    let planner = Planner(store: f.store)
    try planner.approveWeek(f.week)
    let mon = try slot(f, "2026-11-02")
    // Monday's X post failed, then was fixed → a retry is queued for a later day.
    let x = try #require(try f.store.slotPosts(mon.id).first { $0.platform == .x })
    let actions = PostActions(store: f.store)
    try actions.reportProblem(postId: x.id, type: .uploadFailed, message: "network")
    let retry = try actions.fixed(postId: x.id)
    #expect(retry.kind == .retry && !retry.state.isTerminal)
    try bulk(f).removeFromQueue([mon.videoId])
    #expect(try f.store.post(id: retry.id) == nil)  // nothing of a held clip posts
    #expect(try f.store.post(id: x.id)?.state == .failed)  // terminal history stays
    #expect(try f.store.posts(where: "video_id=?", [mon.videoId]).allSatisfy { $0.state.isTerminal })
  }

  // MARK: Stage moves

  @Test func stagesAndBlockers() throws {
    let f = try Fixture.engine(4, ready: 3)
    try Planner(store: f.store).approveWeek(f.week)
    let b = bulk(f)
    #expect(try b.stage(of: "clip-3") == .score)
    #expect(try b.stage(of: "clip-0") == .scheduled)
    #expect(try b.stage(of: "long-0001") == nil)
    let v3 = try #require(try f.store.video(id: "clip-3"))
    #expect(try b.blocker(v3, .back) == "Score is the first stage")
    #expect(try b.blocker(v3, .forward) != nil)
    let v0 = try #require(try f.store.video(id: "clip-0"))
    #expect(try b.blocker(v0, .back) == nil)
    #expect(try b.blocker(v0, .forward)?.contains("Today") == true)
    try f.postAll(on: "2026-11-02")
    let posted = try #require(try f.store.video(id: try slot(f, "2026-11-02").videoId))
    #expect(ClipStage.of(posted) == .posted)
    #expect(try b.blocker(posted, .back)?.contains("Repost") == true)
    let r = try b.back([posted.id])
    #expect(r.changed.isEmpty && r.skipped[posted.id]?.contains("Repost") == true)
  }

  @Test func backMovesEachStageAndUndoes() throws {
    let f = try Fixture.engine(5, ready: 4)
    try f.store.setScore("clip-4", 42)  // Edit stage
    try Planner(store: f.store).approveWeek(f.week)  // clip-0…3 scheduled Mon…Thu
    let thu = try slot(f, "2026-11-05")
    let b = bulk(f)
    let before = try planState(f)

    // Edit → Score clears the score.
    let e = try b.back(["clip-4"])
    #expect(e.moves?["clip-4"] == StageMove(from: .edit, to: .score, note: "Score 42 cleared — back to Score"))
    #expect(try f.store.video(id: "clip-4")?.score == nil && b.stage(of: "clip-4") == .score)
    try b.undo(try #require(e.batchId))
    #expect(try f.store.video(id: "clip-4")?.score == 42)

    // Scheduled → Queue: unposted days leave the plan, the clip stays ready (not held), others keep their days.
    let s = try b.back([thu.videoId])
    #expect(s.moves?[thu.videoId]?.to == .queue && s.moves?[thu.videoId]?.note.contains("Thu 5 Nov · 6 platforms") == true)
    let v = try #require(try f.store.video(id: thu.videoId))
    #expect(v.state == .ready && !v.heldInEdit)
    #expect(try f.store.planSlots().map(\.date) == ["2026-11-02", "2026-11-03", "2026-11-04"])
    try b.undo(try #require(s.batchId))
    #expect(try planState(f) == before)

    // Queue → Edit is "Remove from queue" (held).
    try b.back([thu.videoId])  // scheduled → queue
    let q = try b.back([thu.videoId])  // queue → edit
    #expect(q.moves?[thu.videoId]?.to == .edit)
    #expect(try f.store.video(id: thu.videoId)?.heldInEdit == true)
  }

  @Test func forwardMovesReportWhatHappened() throws {
    let f = try Fixture.engine(4, ready: 2)
    let b = bulk(f)
    // Edit → Queue: clears "sent back", confirms the crop; a clip still missing text says so and stays in Edit.
    try f.store.setScore("clip-2", 50)
    try f.store.setHeldInEdit("clip-2", true)
    try f.store.setScore("clip-3", 60)
    let r = try b.forward(["clip-2", "clip-3"])
    #expect(Set(r.changed) == ["clip-2", "clip-3"])
    let m2 = try #require(r.moves?["clip-2"])
    #expect(m2.from == .edit && m2.to == .edit && m2.note.hasPrefix("Still in Edit: Add text"))
    #expect(try f.store.video(id: "clip-2")?.heldInEdit == false && f.store.edit(videoId: "clip-2").crop != nil)
    // Nothing left to do but still invalid → skipped with the reason (never silent).
    let again = try b.forward(["clip-3"])
    #expect(again.changed.isEmpty && again.skipped["clip-3"]?.hasPrefix("Still in Edit: Add text") == true)
    try f.store.setTitle("clip-3", "Song Three")
    #expect(try f.store.video(id: "clip-3")?.state == .ready)
    try b.undo(try #require(r.batchId))
    #expect(try f.store.video(id: "clip-2")?.heldInEdit == true && f.store.edit(videoId: "clip-2").crop == nil)

    // Queue → Scheduled: next open day; a draft week says it needs approval; an approved week schedules it.
    let q = try b.forward(["clip-0"])
    let m0 = try #require(q.moves?["clip-0"])
    #expect(m0.to == .queue && m0.note.contains("Mon 2 Nov") && m0.note.contains("draft"))
    #expect(try f.store.planSlots(where: "video_id='clip-0'").first?.pinned == true)
    let dup = try b.forward(["clip-0"])
    #expect(dup.skipped["clip-0"]?.contains("proposed week") == true)
    try Planner(store: f.store).approveWeek(f.week)
    let s1 = try b.forward(["clip-1"])
    let m1 = try #require(s1.moves?["clip-1"])
    #expect(m1.from == .queue && m1.to == .scheduled && m1.note.hasPrefix("Scheduled for "))
    let slot1 = try #require(try f.store.planSlots(where: "video_id='clip-1'").first)
    #expect(slot1.pinned && slot1.date >= "2026-11-02" && slot1.date <= "2026-11-08")
    #expect(try f.store.week(slot1.weekStart)?.state == .approved)
    let posts1 = try f.store.posts(where: "video_id='clip-1' AND kind='regular'")
    #expect(posts1.count == 6 && Set(posts1.map(\.platform)).count == 6 && posts1.allSatisfy { $0.planSlotId == slot1.id })
    #expect(try f.store.video(id: "clip-1")?.state == .planned)
    #expect(try f.doublePosts().isEmpty)
    // Scheduled → Posted only via Today.
    #expect(try b.forward(["clip-0"]).skipped["clip-0"]?.contains("Today") == true)
  }

  // MARK: Migration v3

  func tempPaths() -> (Paths, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-v3-\(UUID().uuidString)")
    let p = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                  logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    return (p, dir)
  }

  @Test func syntheticV2GainsTheFlagLosslessly() throws {
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    var rows: [String] = []
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      for (i, id) in ["a", "b"].enumerated() {
        try s.save(Video(id: id, sessionId: "s", name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid,
                         file: "\(id).mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27,
                         start: 0, end: 30, grace: 3, audio: nil, part: 1, score: 40 + i, state: i == 0 ? .ready : .needsEdit,
                         excluded: false, missing: false, inManifest: true, notes: "n\(i)", alreadyPostedOn: [], longformURL: nil,
                         createdAt: Date(), updatedAt: Date(), title: "T\(i)"))
      }
      // Back to a v2 database: no held_in_edit column.
      try s.db.exec("ALTER TABLE videos DROP COLUMN held_in_edit; PRAGMA user_version = 2")
      rows = try s.db.query("SELECT * FROM videos ORDER BY id").map { r in
        ["id", "score", "state", "notes", "title"].map { r.string($0) ?? r.int($0).map(String.init) ?? "-" }.joined(separator: "|")
      }
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(try s.db.query("SELECT * FROM videos ORDER BY id").map { r in
      ["id", "score", "state", "notes", "title"].map { r.string($0) ?? r.int($0).map(String.init) ?? "-" }.joined(separator: "|")
    } == rows)
    #expect(try s.videos().allSatisfy { !$0.heldInEdit })
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-schema3-") })
  }

  /// `DJQ_MIGRATION_BACKUP_V3=<copy of a real queue.sqlite>`: migrates a further copy of it (the given file is
  /// checksummed before and after) and checks every clip keeps its data and stored state and starts not held.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP_V3"] != nil))
  func realBackupCopyGainsTheFlag() throws {
    let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_MIGRATION_BACKUP_V3"]!)
    let (paths, dir) = tempPaths()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sum = { (u: URL) in SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined() }
    let before = try sum(src)
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let copy = paths.appSupport.appendingPathComponent("queue.sqlite")
    try FileManager.default.copyItem(at: src, to: copy)
    let raw = try SQLite(path: copy.path)
    let cols = "id, score, kind, excluded, notes, state"
    let old = try raw.query("SELECT \(cols) FROM videos ORDER BY id").map { r in
      ["id", "score", "kind", "excluded", "notes", "state"].map { r.string($0) ?? r.int($0).map(String.init) ?? "-" }.joined(separator: "|")
    }
    let store = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)
    #expect(try store.db.one("PRAGMA user_version")?.int("user_version") == 3)
    #expect(try store.db.query("SELECT \(cols) FROM videos ORDER BY id").map { r in
      ["id", "score", "kind", "excluded", "notes", "state"].map { r.string($0) ?? r.int($0).map(String.init) ?? "-" }.joined(separator: "|")
    } == old)
    let vids = try store.videos()
    #expect(!vids.isEmpty && vids.allSatisfy { !$0.heldInEdit })
    #expect(try sum(src) == before)
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: copy.path)  // re-open is a no-op
  }
}
