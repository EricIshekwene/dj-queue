import Foundation
import Testing
@testable import DJQCore

/// Round 13 (A11, reverses round 4's "stage = readiness"): nothing moves a clip from Edit to the Queue except Eric's Send to
/// Queue, for one clip or many. A clip with nothing to fix waits in Edit until then.
@Suite struct R13SendToQueueTests {
  /// Nothing to fix, scored, never sent.
  func unsent(_ f: Fixture, _ id: String = "clip-0", score: Int = 50) throws {
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = "Text \(id)"
    v.captionTemplateId = "short"
    try f.store.save(v, videoId: id)
    try f.store.setScore(id, score)
    try f.store.refreshState(videoId: id)
  }

  func clip(_ f: Fixture, _ id: String = "clip-0") throws -> Video { try #require(try f.store.video(id: id)) }

  func expectInEdit(_ f: Fixture, _ id: String = "clip-0", _ c: SourceLocation = #_sourceLocation) throws {
    let v = try clip(f, id)
    #expect(v.state == .needsEdit && ClipStage.of(v) == .edit && !v.sentToQueue, sourceLocation: c)
    #expect(try !Queue(store: f.store).ordered().contains { $0.id == id }, sourceLocation: c)
  }

  func base() throws -> Fixture {
    let f = try Fixture.engine(2, ready: 0)
    try unsent(f)
    return f
  }

  // MARK: Doors that must NOT promote

  @Test func nothingToFixStaysInEditWithNoIssueAdded() throws {
    let f = try base()
    try expectInEdit(f)
    #expect(try Validation.issues(video: clip(f), store: f.store).isEmpty)  // never "1 to fix"
    #expect(try Queue(store: f.store).needsEdit().map(\.id).contains("clip-0"))
  }

  @Test func theEditorSavingDoesntPromote() throws {
    let f = try Fixture.engine(2, ready: 0)
    try f.store.setScore("clip-0", 50)
    try f.store.setTitle("clip-0", "Song")  // the last things it needed, one save at a time
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    try f.store.refreshState(videoId: "clip-0")
    #expect(try Validation.issues(video: clip(f), store: f.store).isEmpty)
    try expectInEdit(f)
  }

  @Test func bulkEditsDontPromote() throws {
    let f = try base()
    let b = BulkActions(store: f.store)
    try b.setTitle(["clip-0"], "New")
    try b.setKind(["clip-0"], .talking)
    try b.setExtraHashtags(["clip-0"], ["#a"])
    try b.applyDefaults(["clip-0"], sections: [.cover])
    try b.setPlatform(["clip-0"], .x, skipped: true)
    try b.setScore(["clip-0"], 60)
    try b.adjustScore(["clip-0"], by: 5)
    try expectInEdit(f)
  }

  @Test func scoringDoesntPromote() throws {
    let f = try Fixture.engine(2, ready: 0)
    try unsent(f)
    try f.store.setScore("clip-0", nil)
    try f.store.refreshState(videoId: "clip-0")
    #expect(try ClipStage.of(clip(f)) == .score)
    try f.store.setScore("clip-0", 70)
    try f.store.refreshState(videoId: "clip-0")
    try expectInEdit(f)
  }

  @Test func theStageCheckTheEngineAndRelinkDontPromote() throws {
    let f = try base()
    try Revalidation(store: f.store).run()
    let (e, _) = (Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()), 0)
    e.tick(reason: "t")
    try expectInEdit(f)
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    // File gone, file back.
    try FileManager.default.removeItem(at: try #require(try f.store.fileURL(for: clip(f))))
    try f.intake()
    try Revalidation(store: f.store).run()
    #expect(try clip(f).missing)
    try f.fakeFile("Clips/\(f.sessionDir.lastPathComponent) – song0 x mix0.mp4", seed: "song0 x mix0")
    try f.intake()
    try Revalidation(store: f.store).run()
    try expectInEdit(f)
  }

  @Test func raisedLimitsDontPromote() throws {
    let f = try Fixture.engine(2)
    try f.updateSettings { $0.limits[.x]?.maxDuration = 5 }
    try Revalidation(store: f.store).run()
    try expectInEdit(f)
    try f.updateSettings { $0.limits[.x]?.maxDuration = 140 }
    try Revalidation(store: f.store).run()
    try expectInEdit(f)
  }

  @Test func intakeWithCompleteDefaultsDoesntPromote() throws {
    let f = try base()
    try f.updateSettings { $0.defaults.textSource = .rawTag }
    try f.intake()
    try f.store.refreshState(videoId: "clip-0")
    try expectInEdit(f)
  }

  @Test func includingAnExcludedClipDoesntPromote() throws {
    let f = try Fixture.engine(2)
    try f.store.setExcluded("clip-0", true)
    #expect(try !clip(f).sentToQueue)
    try f.store.setExcluded("clip-0", false)
    try expectInEdit(f)
  }

  @Test func pinAndPostTodayCantBypassTheSend() throws {
    let f = try base()
    let p = Planner(store: f.store)
    #expect(throws: EngineError.self) { try p.pin(videoId: "clip-0", date: "2026-11-05") }
    #expect(throws: EngineError.self) { try p.postToday(videoId: "clip-0") }
    #expect(try f.store.planSlots().isEmpty)
    try expectInEdit(f)
  }

  // MARK: The real doors

  @Test func theStageControlSends() throws {
    let f = try base()
    let r = try BulkActions(store: f.store).forward(["clip-0"])
    #expect(r.moves?["clip-0"] == StageMove(from: .edit, to: .queue, note: StageWording.sentToQueue))
    #expect(try clip(f).state == .ready && clip(f).sentToQueue)
    #expect(try Queue(store: f.store).ordered().map(\.id) == ["clip-0"])
  }

  @Test func sendToQueueWorksForAnyEditClipNotOnlyHeldOnes() throws {
    let f = try base()
    let r = try BulkActions(store: f.store).sendToQueue(["clip-0"])
    #expect(r.changed == ["clip-0"])
    #expect(try clip(f).state == .ready)
    // Sending it again is already so.
    #expect(try BulkActions(store: f.store).sendToQueue(["clip-0"]).changed.isEmpty)
  }

  @Test func theBulkSendWithDefaultsSendsOnlyWhatsComplete() throws {
    let f = try Fixture.engine(3, ready: 0)
    try f.store.setScore("clip-0", 50)
    try f.store.setTitle("clip-0", "Song")
    try f.store.setScore("clip-1", 50)  // no title: stays
    try f.store.setTitle("clip-2", "Song Two")  // no score: stays
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    let r = try b.makeReadyWithDefaults(["clip-0", "clip-1", "clip-2"])
    #expect(r.outlook?.ready == ["clip-0"] && r.outlook?.needTitle == ["clip-1"] && r.outlook?.needScore == ["clip-2"])
    #expect(try clip(f).state == .ready)
    try expectInEdit(f, "clip-1")
    #expect(try !clip(f, "clip-2").sentToQueue)  // no score: scoring it later doesn't send it
    try f.store.setScore("clip-2", 40)
    try f.store.refreshState(videoId: "clip-2")
    try expectInEdit(f, "clip-2")
  }

  @Test func theEngineSchedulesASentClip() throws {
    let f = try base()
    try BulkActions(store: f.store).sendToQueue(["clip-0"])
    Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier()).tick(reason: "t")
    #expect(try clip(f).state == .planned && f.store.posts().count == 6)
  }

  // MARK: Send with issues, fix later

  @Test func aSendThatStaysInEditDoesntStick() throws {
    let f = try Fixture.engine(2, ready: 0)
    try f.store.setScore("clip-0", 50)  // no title, so no text
    let b = BulkActions(store: f.store)
    b.sourceSize = { _, _ in CGSize(width: 3840, height: 2160) }
    let r = try b.forward(["clip-0"])
    #expect(r.moves?["clip-0"]?.to == .edit && r.moves?["clip-0"]?.note.hasPrefix("Still in Edit") == true)
    try expectInEdit(f)
    try f.store.setTitle("clip-0", "Song")
    try expectInEdit(f)  // the fix doesn't send it
    #expect(try b.forward(["clip-0"]).changed == ["clip-0"])
    #expect(try clip(f).state == .ready)
  }

  @Test func sendToQueueSaysWhatsStillMissing() throws {
    let f = try Fixture.engine(2, ready: 0)
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
    try f.store.save(e, videoId: "clip-0")
    try f.store.setScore("clip-0", 50)
    let r = try BulkActions(store: f.store).sendToQueue(["clip-0", "clip-1"])
    #expect(r.changed.isEmpty && r.skipped["clip-0"]?.hasPrefix("Still in Edit") == true)
    #expect(r.skipped["clip-1"]?.contains("not scored") == true)
  }

  @Test func aQueueClipThatGoesInvalidThenGetsFixedStaysInEditUntilSent() throws {
    let f = try Fixture.engine(2)
    let good = try f.store.edit(videoId: "clip-0")
    var e = good
    e.crop = nil
    try f.store.save(e, videoId: "clip-0")
    try Revalidation(store: f.store).run()
    try expectInEdit(f)
    try f.store.save(good, videoId: "clip-0")
    try Revalidation(store: f.store).run()
    try f.store.refreshState(videoId: "clip-0")
    try expectInEdit(f)
    try BulkActions(store: f.store).sendToQueue(["clip-0"])
    #expect(try clip(f).state == .ready)
  }

  @Test func backToEditThenAnEditDoesntPromote() throws {
    let f = try Fixture.engine(2)
    let b = BulkActions(store: f.store)
    try b.back(["clip-0"])
    #expect(try clip(f).heldInEdit && !clip(f).sentToQueue)
    try f.store.setHeldInEdit("clip-0", false)  // even without the hold
    try f.store.setTitle("clip-0", "Changed")
    try expectInEdit(f)
  }

  @Test func clearingAScoreUnsends() throws {
    let f = try Fixture.engine(2)
    try BulkActions(store: f.store).back(["clip-0"])  // Queue → Edit
    try BulkActions(store: f.store).back(["clip-0"])  // Edit → Score
    #expect(try clip(f).score == nil && !clip(f).sentToQueue)
    try f.store.setScore("clip-1", nil)
    #expect(try !clip(f, "clip-1").sentToQueue)
    try f.store.setScore("clip-1", 30)
    try f.store.refreshState(videoId: "clip-1")
    try expectInEdit(f, "clip-1")
  }

  // MARK: Undo

  @Test func undoRestoresTheFlagBothWays() throws {
    let f = try base()
    let b = BulkActions(store: f.store)
    let sent = try b.sendToQueue(["clip-0"])
    try b.undo(try #require(sent.batchId))
    try expectInEdit(f)
    let again = try b.forward(["clip-0"])
    let back = try b.back(["clip-0"])
    #expect(try !clip(f).sentToQueue)
    try b.undo(try #require(back.batchId))
    #expect(try clip(f).state == .ready && clip(f).sentToQueue && !clip(f).heldInEdit)
    try b.undo(try #require(again.batchId))
    try expectInEdit(f)
  }

  @Test func undoingAnExcludeOrAClearedScoreBringsTheClipBack() throws {
    let f = try Fixture.engine(2)
    let b = BulkActions(store: f.store)
    let x = try b.setExcluded(["clip-0"], true)
    try b.undo(try #require(x.batchId))
    #expect(try clip(f).state == .ready)
    let s = try b.setScore(["clip-0"], nil)
    try b.undo(try #require(s.batchId))
    #expect(try clip(f).state == .ready && clip(f).sentToQueue)
  }

  @Test func undoingABatchThatInvalidatedAClipBringsItBack() throws {
    let f = try Fixture.engine(2)
    let b = BulkActions(store: f.store)
    let r = try b.applyDefaults(["clip-0"], sections: [.text, .caption])  // no title: nothing left for its text
    try Revalidation(store: f.store).run()
    try expectInEdit(f)
    let u = try b.undo(try #require(r.batchId))
    #expect(u.skipped.isEmpty)
    #expect(try clip(f).state == .ready)
  }

  @Test func aJournalFromBeforeTheFlagStillUndoesAndLeavesTheFlagAlone() throws {
    let f = try Fixture.engine(2)
    let b = BulkActions(store: f.store)
    let r = try b.setTitle(["clip-0"], "New")
    let id = try #require(r.batchId)
    for col in ["before", "after"] {
      let raw = try #require(try f.store.db.one("SELECT \(col) AS j FROM batches WHERE id=?", [id])?.string("j"))
      var o = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      var clips = try #require(o["clips"] as? [[String: Any]])
      for i in clips.indices { clips[i].removeValue(forKey: "sent") }
      o["clips"] = clips
      let old = String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
      try f.store.db.run("UPDATE batches SET \(col)=? WHERE id=?", [old, id])
    }
    let u = try b.undo(id)
    #expect(u.skipped.isEmpty && u.changed == ["clip-0"])
    #expect(try clip(f).state == .ready && clip(f).sentToQueue)
  }

  @Test func undoDoesntOverwriteASendMadeAfterTheBatch() throws {
    let f = try base()
    let b = BulkActions(store: f.store)
    let r = try b.setTitle(["clip-0"], "New")
    try b.sendToQueue(["clip-0"])
    let u = try b.undo(try #require(r.batchId))
    #expect(u.skipped["clip-0"]?.contains("changed again") == true)
    #expect(try clip(f).state == .ready)
  }

  // MARK: Agents

  @Test func agentsSeeTheFlag() throws {
    let f = try base()
    #expect(try AgentAPI.summary(clip(f), store: f.store).sent_to_queue == false)
    try BulkActions(store: f.store).sendToQueue(["clip-0"])
    #expect(try AgentAPI.summary(clip(f), store: f.store).sent_to_queue == true)
  }

  // MARK: Migration

  /// A schema 6 database: the column gone, the version back. Only a `ready` clip with a send on record counts as sent.
  func downgrade(_ file: String) throws {
    let db = try SQLite(path: file)
    try db.exec("ALTER TABLE videos DROP COLUMN sent_to_queue; PRAGMA user_version = 6;")
  }

  func rows(_ db: SQLite) throws -> [String] {
    try db.query("SELECT id, score, title, state, kind, excluded, missing, held_in_edit FROM videos ORDER BY id").map { r in
      ["id", "title", "state", "kind"].map { r.string($0) ?? "" }.joined(separator: "|")
        + "|\(r.int("score") ?? -1)|\(r.int("excluded") ?? 0)|\(r.int("missing") ?? 0)|\(r.int("held_in_edit") ?? 0)"
    }
  }

  @Test func migrationMarksClipsPastEditAsSentAndChangesNoState() throws {
    let f = try Fixture.engine(6, ready: 5)
    let dir = f.dir.appendingPathComponent("v6")
    let paths = Paths(root: f.paths.root, appSupport: dir, logs: f.paths.logs, launchAgents: f.paths.launchAgents)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("queue.sqlite").path
    try f.store.db.backup(to: file)
    do {
      let db = try SQLite(path: file)
      try db.run("INSERT INTO events(at,kind,message,video_id) VALUES(1,'queue','Sent to Queue','clip-0')")
      for (id, state) in [("clip-0", "ready"), ("clip-1", "planned"), ("clip-2", "posting"), ("clip-3", "posted"), ("clip-4", "partial")] {
        try db.run("UPDATE videos SET state=? WHERE id=?", [state, id])
      }
      try db.run("UPDATE videos SET sent_to_queue=0")
      try db.run("UPDATE videos SET state='ready', score=NULL WHERE id='clip-5'")  // complete, unscored: it's in Score
    }
    try downgrade(file)
    let before = try rows(try SQLite(path: file))
    let s = try Store(paths: paths, clock: f.clock, path: file)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == Store.schemaVersion)
    #expect(try rows(s.db) == before)
    let sent = try s.videos().filter(\.sentToQueue).map(\.id).sorted()
    #expect(sent == ["clip-0", "clip-1", "clip-2", "clip-3", "clip-4"])
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
    #expect(backups.contains { $0.hasPrefix("queue-before-sent-to-queue-") })
    // Opening again changes nothing.
    _ = try Store(paths: paths, clock: f.clock, path: file)
    #expect(try rows(try SQLite(path: file)) == before)
  }

  /// A copy of the newest real backup, when `DJQ_TEST_BACKUP` names one (the round's evidence run sets it).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_TEST_BACKUP"] != nil))
  func migrationOnACopyOfARealBackupKeepsEveryStateCountScoreAndTitle() throws {
    let f = try Fixture.engine(1)
    let dir = f.dir.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("queue.sqlite")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_TEST_BACKUP"]!), to: file)
    let before = try rows(try SQLite(path: file.path))
    let paths = Paths(root: f.paths.root, appSupport: dir, logs: f.paths.logs, launchAgents: f.paths.launchAgents)
    let s = try Store(paths: paths, clock: f.clock, path: file.path)
    #expect(try rows(s.db) == before)
    #expect(!before.isEmpty)
    for v in try s.videos(where: "type='short-form'") {
      if v.state == .ready {  // only with proof of a send
        let queue = try s.events(limit: 500, videoId: v.id).filter { $0.kind == "queue" }  // newest first
        #expect(v.sentToQueue == (queue.first?.message == "Sent to Queue" && v.score != nil), "\(v.id)")
      } else {
        #expect(v.sentToQueue == [.planned, .posting, .posted, .partial].contains(v.state), "\(v.id)")
      }
    }
  }
}
