import Foundation
import Testing
@testable import DJQCore

/// Round 6, milestone 2: the Postiz publisher in the engine — submit ahead, replace, cancel on every plan path, sync
/// mapping, fallbacks, budget, analytics and a randomized planner fuzz. Everything runs against `FakePostiz`.
@Suite struct R6PostizLifecycleTests {
  final class Rig {
    let f: Fixture
    let fake = FakePostiz()
    let keys = MemoryPostizKeyStore(key: "test-key-123")
    let notifier = LogNotifier()
    let renderer: FakeRenderer
    let service: PostizService
    let engine: Engine

    init(_ n: Int = 3, platforms: [Platform] = Platform.allCases, budget: Int = 1000, approve: Bool = true,
         change: ((inout Settings) -> Void)? = nil) throws {
      f = try Fixture.engine(n)
      renderer = FakeRenderer(store: f.store)
      service = PostizService(store: f.store, transport: fake, keyStore: keys)
      engine = Engine(store: f.store, renderer: renderer, publisher: nil, notifier: notifier, postiz: service)
      try f.updateSettings { s in
        for p in platforms {
          s.publishing.publishers[p] = .postiz
          s.publishing.channels[p] = "ch-\(p.rawValue)"
        }
        s.publishing.hourlyBudget = budget
        change?(&s)
      }
      if approve { try Planner(store: f.store).approveWeek(f.week) }
    }

    var store: Store { f.store }

    @discardableResult
    func tick(_ times: Int = 1) -> TickReport {
      var r = engine.tick(reason: "t")
      for _ in 1..<max(1, times) { r = engine.tick(reason: "t") }
      return r
    }

    /// Ticks until every approved post in the horizon has its render (one render per tick).
    func settle() { tick(12) }

    func job(_ p: PlatformPost) throws -> PostizJob? { try store.livePostizJob(postId: p.id) }

    /// The invariants: one open job per post, every QUEUE/DRAFT post in Postiz is held by exactly one open job (no
    /// orphan = no double post), never a delete of a published post, and per post a new job only after the previous
    /// one closed with its Postiz copy gone (or published/failed).
    func invariants() throws -> [String] {
      var bad = fake.violations
      let open = try store.openPostizJobs()
      let byPost = Dictionary(grouping: open, by: \.postId)
      for (pid, js) in byPost where js.count > 1 { bad.append("two open jobs for \(pid)") }
      let held = Dictionary(grouping: open.compactMap(\.postizId), by: { $0 })
      for r in fake.livePosts where r.state == "QUEUE" || r.state == "DRAFT" {
        if held[r.id]?.count != 1 { bad.append("orphan in Postiz: \(r.id)") }
      }
      for (pid, js) in Dictionary(grouping: try store.postizJobs(where: "kind='post'"), by: \.postId) {
        let sorted = js.sorted { $0.createdAt < $1.createdAt || ($0.createdAt == $1.createdAt && $0.closedAt != nil && $1.closedAt == nil) }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
          guard let closed = a.closedAt else { bad.append("job after an open job for \(pid)"); continue }
          if b.createdAt < closed { bad.append("create before the previous job closed for \(pid)") }
          if let id = a.postizId, let r = fake.post(id), !r.deleted, r.state == "QUEUE" || r.state == "DRAFT" {
            bad.append("new job while the old Postiz post \(id) still lives for \(pid)")
          }
        }
      }
      return bad
    }
  }

  // MARK: Submit ahead

  @Test func approvedRenderedPostsAreScheduledAheadOncePerRender() throws {
    let rig = try Rig(3)
    rig.settle()
    let posts = try rig.store.posts()
    let rendered = posts.filter { $0.renderId != nil }
    #expect(rendered.count == posts.count && posts.count == 18)
    for p in posts {
      let j = try #require(try rig.job(p))
      #expect(j.phase == .live && j.remoteDate == p.scheduledAt && j.remoteState == "QUEUE")
      #expect(try rig.store.post(id: p.id)?.publisher == "postiz")
      let remote = try #require(rig.fake.post(j.postizId!))
      #expect(remote.date == p.scheduledAt && remote.integrationId == "ch-\(p.platform.rawValue)")
    }
    #expect(rig.fake.createCount == 18)
    #expect(rig.fake.uploadCount == 3 + 3)  // one video per render + one YouTube cover per render
    #expect(try rig.invariants().isEmpty)
    // Ticking again changes nothing.
    rig.tick(3)
    #expect(rig.fake.createCount == 18 && rig.fake.deleteCount == 0)
  }

  @Test func noManualDueNotificationAndNeverOverdueWhilePostizHoldsIt() throws {
    let rig = try Rig(1)
    rig.settle()
    rig.f.setTime("2026-11-02", "19:05")
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    #expect(tt.state == .due)
    #expect(rig.notifier.delivered.filter { $0.key.hasPrefix("due:") }.isEmpty)
    // A day later, still unpublished in Postiz: not overdue, nothing shifted (Postiz posts with the Mac off).
    rig.f.setTime("2026-11-03", "09:00")
    rig.tick()
    #expect(try rig.store.post(id: tt.id)?.state == .due)
    #expect(rig.notifier.delivered.filter { $0.key.hasPrefix("overdue:") }.isEmpty)
    // …and it says so: stuck notification once.
    #expect(rig.notifier.delivered.contains { $0.key.hasPrefix("postiz.stuck:") })
  }

  /// P3: a post whose render lands after its slot still gets submitted (now + 3 min), and the TODO path is gone.
  @Test func renderAfterDueStillGetsSubmitted() throws {
    let rig = try Rig(1, platforms: [.tiktok])
    rig.f.setTime("2026-11-02", "20:00")  // TikTok 19:00 already passed, nothing rendered yet
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    let j = try #require(try rig.job(tt))
    #expect(j.remoteDate == rig.f.clock.now.addingTimeInterval(180))
    #expect(rig.notifier.delivered.filter { $0.key.hasPrefix("due:\(tt.id)") }.isEmpty)
    // Manual platforms behave exactly as before.
    let ig = try #require(try rig.f.post(.instagram, day: "2026-11-02"))
    #expect(try rig.job(ig) == nil && rig.notifier.delivered.contains { $0.key.hasPrefix("due:\(ig.id)") })
  }

  // MARK: Replace

  @Test func editedCaptionReplacesDeleteFirst() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let old = try #require(try rig.job(x))
    var v = try #require(try rig.store.versions(videoId: "clip-0").first)
    v.caption = "New caption"
    try rig.store.save(v, videoId: "clip-0")
    rig.tick()
    let new = try #require(try rig.job(x))
    #expect(new.id != old.id && rig.fake.post(new.postizId!)?.content.hasPrefix("New caption") == true)
    #expect(rig.fake.post(old.postizId!)?.deleted == true)
    #expect(try rig.store.postizJob(id: old.id)?.closeReason == .replaced)
    let order = rig.fake.log.filter { $0.hasPrefix("DELETE") || $0 == "POST posts" }
    #expect(order.suffix(2) == ["DELETE posts/\(old.postizId!)", "POST posts"])
    #expect(rig.fake.uploadCount == 2)  // FakeRenderer re-renders on any version change; the real hash ignores captions
    #expect(try rig.invariants().isEmpty)
  }

  @Test func failedDeleteNeverCreates() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let old = try #require(try rig.job(x))
    rig.fake.failNext["DELETE posts"] = [500, 502]
    var v = try #require(try rig.store.versions(videoId: "clip-0").first)
    v.caption = "Changed"
    try rig.store.save(v, videoId: "clip-0")
    let creates = rig.fake.createCount
    rig.tick()
    rig.tick()
    #expect(rig.fake.createCount == creates)
    let j = try #require(try rig.job(x))
    #expect(j.id == old.id && j.phase == .deleting && j.attempts == 2)
    #expect(try rig.invariants().isEmpty)
    rig.tick()
    #expect(rig.fake.createCount == creates + 1 && rig.fake.post(old.postizId!)?.deleted == true)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func deleteOf404CountsAsDone() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let old = try #require(try rig.job(x))
    rig.fake.failNext["DELETE posts"] = [404]
    try PostActions(store: rig.store).skip(postId: x.id)
    rig.tick()
    #expect(try rig.store.postizJob(id: old.id)?.closeReason == .cancelled)
  }

  // MARK: Cancel on every path

  /// Runs `change` after everything is scheduled and checks the affected posts' Postiz copies are gone (or replaced)
  /// and the invariants hold.
  func cancels(_ change: (Rig) throws -> Void, expect: (Rig, [String: PostizJob]) throws -> Void,
               n: Int = 4, platforms: [Platform] = [.tiktok, .x]) throws {
    let rig = try Rig(n, platforms: platforms)
    rig.settle()
    let before = Dictionary(uniqueKeysWithValues: try rig.store.openPostizJobs().map { ($0.postId, $0) })
    try change(rig)
    rig.tick(4)
    try expect(rig, before)
    #expect(try rig.invariants().isEmpty)
    // Every open job matches its post's current slot.
    for j in try rig.store.openPostizJobs() {
      let p = try #require(try rig.store.post(id: j.postId))
      #expect(p.scheduledAt == j.scheduledAt && !p.state.isTerminal)
    }
  }

  func gone(_ rig: Rig, _ j: PostizJob?) -> Bool {
    guard let j, let id = j.postizId else { return false }
    return rig.fake.post(id)?.deleted == true
  }

  @Test func plannerRemoveCancels() throws {
    var slot = ""
    try cancels({ rig in
      let s = try #require(try rig.store.planSlots(where: "date='2026-11-03'").first)
      slot = s.id
      try Planner(store: rig.store).remove(slotId: s.id)
    }, expect: { rig, before in
      let removed = before.values.filter { rig.f.dm.key($0.scheduledAt) == "2026-11-03" }
      #expect(!removed.isEmpty && removed.allSatisfy { gone(rig, $0) })
      let reasons = try removed.map { try rig.store.postizJob(id: $0.id)?.closeReason }
      #expect(reasons.allSatisfy { $0 == .cancelled })
      _ = slot
    })
  }

  @Test func unqueueCancels() throws {
    try cancels({ rig in
      _ = try BulkActions(store: rig.store).removeFromQueue(["clip-1"])
    }, expect: { rig, before in
      let mine = before.values.filter { $0.videoId == "clip-1" }
      #expect(!mine.isEmpty && mine.allSatisfy { gone(rig, $0) })
    })
  }

  @Test func moveReplacesAtTheNewTime() throws {
    try cancels({ rig in
      let s = try #require(try rig.store.planSlots(where: "date='2026-11-03'").first)
      try Planner(store: rig.store).move(slotId: s.id, to: "2026-11-07")
    }, expect: { rig, before in
      let moved = before.values.filter { $0.videoId == "clip-1" }
      #expect(moved.allSatisfy { gone(rig, $0) })
      for p in try rig.store.posts(where: "video_id='clip-1' AND platform IN ('tiktok','x')") where rig.f.dm.key(p.scheduledAt) == "2026-11-07" {
        #expect(try rig.job(p)?.remoteDate == p.scheduledAt)  // re-created at the new slot
      }
    })
  }

  @Test func swapReplacesBoth() throws {
    try cancels({ rig in
      let a = try #require(try rig.store.planSlots(where: "date='2026-11-03'").first)
      let b = try #require(try rig.store.planSlots(where: "date='2026-11-04'").first)
      try Planner(store: rig.store).swap(a.id, b.id)
    }, expect: { rig, before in
      #expect(before.values.filter { ["clip-1", "clip-2"].contains($0.videoId ?? "") }.allSatisfy { gone(rig, $0) })
      for p in try rig.store.posts(where: "video_id IN ('clip-1','clip-2') AND platform IN ('tiktok','x')") { #expect(try rig.job(p)?.remoteDate == p.scheduledAt) }
    })
  }

  @Test func pushPlanReplaces() throws {
    try cancels({ rig in try Planner(store: rig.store).pushPlan(from: "2026-11-04", days: 1) }, expect: { rig, _ in
      for p in try rig.store.posts(where: "platform IN ('tiktok','x')") where !p.state.isTerminal { #expect(try rig.job(p)?.remoteDate == p.scheduledAt) }
    })
  }

  @Test func rebuildWeekCancelsWhatLeft() throws {
    try cancels({ rig in try Planner(store: rig.store).rebuildWeek(rig.f.week) }, expect: { rig, before in
      // Rebuilt week is a draft again: every post from today on is gone, and so are their Postiz copies.
      let left = before.values.filter { (try? rig.store.post(id: $0.postId)) == nil }
      #expect(!left.isEmpty && left.allSatisfy { gone(rig, $0) })
    })
  }

  @Test func skipNextReplaces() throws {
    try cancels({ rig in try Planner(store: rig.store).skipNext(videoId: "clip-1") }, expect: { rig, _ in
      for p in try rig.store.posts(where: "platform IN ('tiktok','x')") where !p.state.isTerminal { #expect(try rig.job(p)?.remoteDate == p.scheduledAt) }
    })
  }

  @Test func skipAndMarkPostedByHandCancel() throws {
    try cancels({ rig in
      let a = PostActions(store: rig.store)
      try a.skip(postId: try #require(try rig.f.post(.x, day: "2026-11-03")).id)
      try a.markPosted(postId: try #require(try rig.f.post(.tiktok, day: "2026-11-02")).id, url: Fixture.postURLs[.tiktok]!)
    }, expect: { rig, before in
      let x = try #require(try rig.f.post(.x, day: "2026-11-03")), tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
      #expect(gone(rig, before[x.id]) && gone(rig, before[tt.id]))
      #expect(try rig.store.post(id: tt.id)?.state == .posted)
    })
  }

  @Test func settingsChangesCancel() throws {
    try cancels({ rig in
      try rig.f.updateSettings {
        $0.pausedPlatforms = [.x]
        $0.publishing.publishers[.tiktok] = .manual
      }
    }, expect: { rig, before in
      #expect(before.values.allSatisfy { gone(rig, $0) })
      let open = try rig.store.openPostizJobs()
      let posts = try rig.store.posts()
      #expect(open.isEmpty)
      #expect(posts.allSatisfy { $0.publisher == "manual" || $0.state.isTerminal })
    })
    try cancels({ rig in try rig.f.updateSettings { $0.enabledPlatforms.remove(.x); $0.paused = true } }, expect: { rig, before in
      #expect(before.values.allSatisfy { gone(rig, $0) })
    })
  }

  @Test func unpausingResubmits() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    #expect(try rig.store.openPostizJobs().isEmpty)
    try rig.f.updateSettings { $0.paused = false }
    rig.tick()
    #expect(try rig.store.openPostizJobs().count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func resetFixedAndRepostGoThroughPostizAgain() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Upload failed at the platform")
    rig.f.setTime("2026-11-02", "17:30")
    rig.tick()
    #expect(try rig.store.post(id: x.id)?.state == .failed)
    #expect(try rig.store.postizJob(id: j.id)?.closeReason == .error)
    // fixed → new attempt tomorrow → submitted again.
    let retry = try PostActions(store: rig.store).fixed(postId: x.id)
    rig.tick(2)
    #expect(try rig.job(retry)?.phase == .live)
    let failedJob = try rig.store.livePostizJob(postId: x.id)
    #expect(failedJob == nil)  // the failed one is never resent
    #expect(try rig.invariants().isEmpty)
  }

  @Test func resetReleasesAFailedPost() throws {
    let rig = try Rig(2, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-03"))
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: nil)
    rig.f.setTime("2026-11-03", "18:00")
    rig.tick()
    let failed = try #require(try rig.store.post(id: x.id))
    #expect(failed.state == .failed && failed.errorMessage == "Postiz reported an error (no details)")
    try PostActions(store: rig.store).reset(postId: x.id)
    rig.tick()
    #expect(try rig.job(failed) != nil)
  }

  @Test func undoOfUnqueueBringsTheJobsBack() throws {
    let rig = try Rig(3, platforms: [.x])
    rig.settle()
    let b = BulkActions(store: rig.store)
    let r = try b.removeFromQueue(["clip-1"])
    rig.tick()
    #expect(try rig.store.posts(where: "video_id='clip-1' AND platform='x'").allSatisfy { try rig.job($0) == nil })
    _ = try b.undo(try #require(r.batchId))
    rig.tick(3)
    let back = try rig.store.posts(where: "video_id='clip-1' AND platform='x'")
    let backJobs = try back.map { try rig.job($0) }
    #expect(!back.isEmpty && backJobs.allSatisfy { $0 != nil })
    #expect(try rig.invariants().isEmpty)
  }

  @Test func revalidationAndEditsReplaceThroughTheRender() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let old = try #require(try rig.job(x))
    var e = try rig.store.edit(videoId: "clip-0")
    e.crop = CropRect(x: 10, y: 0, w: 1215, h: 2160)  // new crop → new render → replace
    try rig.store.save(e, videoId: "clip-0")
    rig.tick(3)
    let new = try #require(try rig.job(x))
    #expect(new.renderId != old.renderId && gone(rig, old))
    #expect(try rig.invariants().isEmpty)
  }

  @Test func missedManualPostReflowReplacesTheShiftedPostizPosts() throws {
    // TikTok via Postiz but its Monday post has no render (render fails) → manual fallback → goes overdue → the
    // remaining TikTok plan shifts a day; the shifted Postiz posts are replaced at their new times.
    let rig = try Rig(3, platforms: [.tiktok])
    rig.renderer.failVideos = ["clip-0"]
    rig.settle()
    let mon = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    #expect(try rig.job(mon) == nil)
    rig.f.setTime("2026-11-03", "02:00")
    rig.tick(2)
    #expect(try rig.store.post(id: mon.id)?.state == .overdue)
    for p in try rig.store.posts(where: "platform='tiktok' AND state IN ('rendered','due','planned')") {
      if let j = try rig.job(p) { #expect(j.scheduledAt == p.scheduledAt) }
    }
    #expect(try rig.invariants().isEmpty)
  }

  // MARK: Sync mapping

  @Test func publishedRecordsTheLinkThroughPostActions() throws {
    let rig = try Rig(1, platforms: [.tiktok, .youtube])
    rig.settle()
    rig.f.setTime("2026-11-02", "19:30")
    rig.fake.publishDue(now: rig.f.clock.now)
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    rig.fake.publish(try #require(try rig.job(yt)).postizId!, url: "", releaseId: "missing")
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    let j = try #require(try rig.store.postizJobs(postId: tt.id).last)
    #expect(tt.state == .posted && tt.url?.contains("tiktok.com") == true && tt.externalId == "rel-\(j.postizId!)")
    #expect(tt.postedAt == j.remoteDate && j.closeReason == .published)
    #expect(try rig.store.history(postId: tt.id).last?.note == "published by Postiz")
    let ytp = try #require(try rig.store.post(id: yt.id))
    #expect(ytp.state == .posted && ytp.url == nil)
    #expect(try rig.service.linkMissingPosts().map(\.id) == [yt.id])
    // A published job is never deleted, even if the slot is removed afterwards.
    rig.tick(2)
    #expect(rig.fake.violations.isEmpty && rig.fake.deleteCount == 0)
    // djq postiz link fixes the missing link.
    try rig.service.link(postId: yt.id, releaseId: "777", url: "https://youtube.com/shorts/777")
    #expect(try rig.store.post(id: yt.id)?.url == "https://youtube.com/shorts/777")
  }

  @Test func errorsAndCopyrightAreLoudAndNeverRetried() throws {
    let rig = try Rig(1, platforms: [.instagram, .x])
    rig.settle()
    let ig = try #require(try rig.f.post(.instagram, day: "2026-11-02"))
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    rig.fake.fail(try #require(try rig.job(ig)).postizId!, error: "This audio is unavailable due to a copyright claim")
    rig.fake.fail(try #require(try rig.job(x)).postizId!, error: "Video too long")
    rig.f.setTime("2026-11-02", "19:00")
    rig.tick()
    let igp = try #require(try rig.store.post(id: ig.id)), xp = try #require(try rig.store.post(id: x.id))
    #expect(igp.state == .copyrightBlocked && igp.errorMessage?.contains("copyright") == true)
    #expect(xp.state == .failed && xp.errorType == .uploadFailed && xp.errorMessage == "Video too long")
    let creates = rig.fake.createCount
    rig.f.clock.advance(3 * 86400)
    rig.tick(3)
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(ig.id)" && $0.critical })
    #expect(try rig.store.posts(where: "platform='instagram' AND video_id='clip-0'").count == 1)  // no auto-retry
    #expect(rig.fake.createCount >= creates)
    #expect(try rig.store.livePostizJob(postId: ig.id) == nil && rig.store.livePostizJob(postId: x.id) == nil)
  }

  @Test func vanishedFallsBackToTodayLoudly() throws {
    let rig = try Rig(1, platforms: [.threads])
    rig.settle()
    let th = try #require(try rig.f.post(.threads, day: "2026-11-02"))
    rig.fake.vanish(try #require(try rig.job(th)).postizId!)
    rig.f.clock.advance(600)
    rig.tick()
    let p = try #require(try rig.store.post(id: th.id))
    let pj = try rig.job(p)
    #expect(p.publisher == "manual" && pj == nil)
    #expect(rig.notifier.delivered.contains { $0.key.hasPrefix("postiz.vanished:") && $0.critical })
    rig.tick(2)
    #expect(try rig.job(p) == nil)  // never sent again by itself
    // It's a manual post now: due notification at its slot.
    rig.f.setTime("2026-11-02", "13:35")
    rig.tick()
    #expect(rig.notifier.delivered.contains { $0.key.hasPrefix("due:\(th.id)") })
  }

  @Test func testModeDraftsInboxAndUnlisted() throws {
    let rig = try Rig(1, platforms: [.tiktok, .youtube, .x]) { $0.publishing.testMode = true }
    rig.settle()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let ttj = try #require(try rig.job(tt))
    let ytj = try #require(try rig.job(yt))
    let ttr = try #require(rig.fake.post(ttj.postizId!))
    #expect(ttr.settings["content_posting_method"] as? String == "UPLOAD" && ttr.state == "QUEUE")
    #expect(rig.fake.post(ytj.postizId!)?.settings["type"] as? String == "unlisted")
    let xj = try #require(try rig.job(x))
    #expect(xj.remoteState == "DRAFT" && rig.fake.post(xj.postizId!)?.state == "DRAFT")
    // TikTok "PUBLISHED" = in the inbox: stays a manual Mark posted step.
    rig.f.setTime("2026-11-02", "19:10")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick()
    let ttp = try #require(try rig.store.post(id: tt.id))
    #expect(ttp.state != .posted && ttp.publisher == "manual")
    #expect(try rig.store.postizJobs(postId: tt.id).last?.closeReason == .inbox)
    #expect(rig.notifier.delivered.contains { $0.title == "TikTok · in your inbox" })
    #expect(try rig.store.post(id: yt.id)?.state == .posted)  // unlisted YouTube is recorded
    #expect(try rig.store.post(id: x.id)?.state == .due)  // a draft never publishes by itself
    try rig.service.releaseDraft(postId: x.id)
    #expect(rig.fake.post(xj.postizId!)?.state == "QUEUE")
  }

  // MARK: Fallbacks, key, budget

  @Test func noKeyMeansManualAndNoCalls() throws {
    let rig = try Rig(1, platforms: [.x])
    try rig.keys.delete()
    rig.settle()
    let open = try rig.store.openPostizJobs()
    #expect(rig.fake.log.isEmpty && open.isEmpty)
    rig.f.setTime("2026-11-02", "17:05")
    rig.tick()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    #expect(rig.notifier.delivered.contains { $0.key.hasPrefix("due:\(x.id)") })
    #expect(try rig.service.router().route(.x) == .fallback(.noKey))
    #expect(try rig.store.postizBudget().calls.isEmpty)  // no budget spent either
  }

  @Test func refusedCreateFallsBackToTodayOnce() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.fake.failNext["POST posts"] = [400]
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let p = try #require(try rig.store.post(id: x.id))
    let pj = try rig.job(p)
    #expect(p.publisher == "manual" && pj == nil)
    #expect(try rig.store.finalPostizJob(postId: x.id)?.closeReason == .rejected)
    #expect(rig.notifier.delivered.contains { $0.key.hasPrefix("postiz.rejected:") })
    #expect(try rig.store.events(videoId: "clip-0").contains { $0.message.contains("Postiz refused this post: injected 400") })
    let creates = rig.fake.createCount
    rig.tick(3)
    #expect(rig.fake.createCount == creates)  // never resubmitted by itself
  }

  @Test func refusedKeyStopsCallsUntilSavedAgain() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.fake.key = "rotated"
    rig.tick()
    #expect(try rig.store.postizKeyInvalid() != nil)
    #expect(rig.notifier.delivered.filter { $0.title == "Postiz refused the API key" }.count == 1)
    let calls = rig.fake.log.count
    rig.tick(5)
    #expect(rig.fake.log.count == calls)  // no call per tick; the hourly probe waits
    #expect(try rig.service.router().route(.x) == .fallback(.keyInvalid))
    try rig.service.saveKey("rotated")
    #expect(try rig.store.postizKeyInvalid() == nil)
    rig.tick(2)
    #expect(try rig.store.openPostizJobs().count == 1)
  }

  @Test func rateLimitPausesFifteenMinutes() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.fake.failNext["POST upload"] = [429]
    rig.tick()
    #expect(try rig.store.postizBudget().isPaused(now: rig.f.clock.now))
    let calls = rig.fake.log.count
    rig.tick()
    #expect(rig.fake.log.count == calls)
    rig.f.clock.advance(16 * 60)
    rig.tick(2)
    #expect(try rig.store.openPostizJobs().count == 1)
  }

  @Test func budgetSpreadsAWeekAndKeepsDeletesFirst() throws {
    let rig = try Rig(7, budget: 25)
    rig.settle()
    #expect(try rig.store.postizBudget().used(now: rig.f.clock.now) <= 25)
    let first = try rig.store.openPostizJobs().count
    #expect(first > 0 && first < 42)
    // Soonest slots first.
    let latest = try rig.store.openPostizJobs().map(\.scheduledAt).max()!
    let missing = try rig.store.posts().filter { try rig.job($0) == nil }
    #expect(missing.allSatisfy { $0.scheduledAt >= latest })
    for _ in 0..<4 {
      rig.f.clock.advance(3600)
      rig.tick(2)
    }
    let pending = try rig.store.posts().filter { !$0.state.isTerminal && $0.scheduledAt > rig.f.clock.now }
    #expect(try pending.allSatisfy { try rig.job($0) != nil })
    #expect(try rig.invariants().isEmpty)
  }

  @Test func analyticsPullsMetricsDaily() throws {
    let rig = try Rig(1, platforms: [.tiktok])
    rig.settle()
    rig.f.setTime("2026-11-02", "19:30")
    rig.fake.publishDue(now: rig.f.clock.now)
    rig.tick()
    rig.f.clock.advance(86400)
    rig.tick()
    let tt = try #require(try rig.f.post(.tiktok, day: "2026-11-02"))
    #expect(tt.metrics?.views == 25 && tt.metrics?.likes == 3)
    #expect(PostizAnalytics.parse(Data("{\"missing\":true}".utf8)) == nil)
    #expect(!PostizAnalytics.isUnknownShape(Data("{\"missing\":true}".utf8)))
    #expect(PostizAnalytics.parse(Data("[{\"label\":\"Views\",\"data\":[{\"total\":3},{\"total\":1}]}]".utf8))?.views == 4)
  }

  @Test func interruptedCreateIsAdoptedOrReleased() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.fake.failNext["POST posts"] = [503]
    rig.tick(12)
    // The 503 came after the create was sent: the claim stays until the sync step looks.
    let stuck = try rig.store.openPostizJobs().filter { $0.phase == .creating }
    #expect(stuck.count == 1)
    rig.f.clock.advance(PostizService.staleCreate + 1)
    rig.tick(2)
    #expect(try rig.store.openPostizJobs().allSatisfy { $0.phase == .live })
    #expect(try rig.store.openPostizJobs().count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func secondProcessCantClaimTheSamePost() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.tick(2)
    let other = PostizService(store: rig.store, transport: rig.fake, keyStore: rig.keys)
    let before = rig.fake.createCount
    _ = try other.publish()
    #expect(rig.fake.createCount == before)
    #expect(try rig.invariants().isEmpty)
  }

  // MARK: CLI helpers, Doctor, publisher

  @Test func testPostDryRunAndDrafts() throws {
    let rig = try Rig(1, platforms: [.tiktok, .youtube], approve: false)
    #expect(throws: EngineError.self) { try rig.service.testPost(videoId: "clip-0", draft: false) }
    _ = try rig.renderer.ensureRender(videoId: "clip-0", versionNo: 1, platform: nil)
    let dry = try rig.service.testPost(videoId: "clip-0", draft: false)
    #expect(dry.platforms.count == 6 && rig.fake.log.isEmpty)
    #expect(dry.platforms.first { $0.platform == .x }?.skipped == "no Postiz channel picked")
    #expect(dry.platforms.allSatisfy { !$0.body.contains("test-key") } && dry.headers["Authorization"] == "<redacted>")
    #expect(dry.platforms.first { $0.platform == .youtube }?.body.contains("\"__type\" : \"youtube\"") == true)
    let run = try rig.service.testPost(videoId: "clip-0", draft: true)
    #expect(run.platforms.filter { $0.postizId != nil }.count == 2)
    #expect(rig.fake.livePosts.allSatisfy { $0.type == "draft" && $0.state == "DRAFT" })
    #expect(try rig.store.openPostizJobs().isEmpty)  // test drafts are records, never reconciled
    rig.tick()
    #expect(rig.fake.deleteCount == 0)
  }

  @Test func statusChannelsAndDoctor() throws {
    let rig = try Rig(1, platforms: [.tiktok, .x])
    #expect(try PostizDoctor.findings(store: rig.store, keyStore: rig.keys).findings.isEmpty)
    let ch = try rig.service.channels()
    #expect(ch.count == 6 && ch.first { $0.platform == .instagram }?.identifier == "instagram-standalone")
    var st = try rig.service.status(check: true)
    #expect(st.hasKey && st.connected == true && st.platforms.first { $0.platform == .x }?.route == "postiz")
    #expect(st.platforms.first { $0.platform == .instagram }?.route == "manual")
    let json = String(decoding: try JSONEncoder().encode(st), as: UTF8.self)
    #expect(!json.contains("test-key-123"))
    try rig.f.updateSettings { $0.publishing.channels[.x] = nil }
    try rig.keys.delete()
    let d = try PostizDoctor.findings(store: rig.store, keyStore: rig.keys)
    #expect(Set(d.findings.map(\.id)) == ["postiz.not_connected", "postiz.mapping_missing"])
    #expect(d.passed.contains("postiz.stuck"))
    st = try rig.service.status()
    #expect(!st.hasKey && st.platforms.first { $0.platform == .tiktok }?.fallbackCode == "no_key")
    // Manual everywhere: Doctor is quiet and nothing reads the Keychain.
    let quiet = try Fixture.engine(1)
    #expect(try PostizDoctor.findings(store: quiet.store, keyStore: rig.keys).passed == PostizDoctor.checkIds)
  }

  @Test func publisherInterface() throws {
    let rig = try Rig(1, platforms: [.youtube])
    rig.tick(2)
    let pub = PostizPublisher(service: rig.service)
    let yt = try #require(try rig.f.post(.youtube, day: "2026-11-02"))
    let prepared = try pub.prepare(postId: yt.id)
    #expect(pub.name == "postiz" && prepared.title?.hasSuffix("| DJ Lovd") == true && prepared.coverURL != nil)
    guard case .scheduled(let id) = try pub.status(postId: yt.id) else { Issue.record("not scheduled"); return }
    #expect(id == (try rig.job(yt))?.postizId)
    #expect(try pub.submit(prepared) == .scheduled(externalId: id))  // no second create
  }

  @Test func defaultEngineMakesNoCallsWhileEverythingIsManual() throws {
    let f = try Fixture.engine(2)
    try Planner(store: f.store).approveWeek(f.week)
    let e = Engine(store: f.store, renderer: FakeRenderer(store: f.store), publisher: nil, notifier: LogNotifier())
    let r = e.tick(reason: "t")
    #expect(r.steps["publish"] == "off" && r.steps["sync"] == "off")
    #expect(TickReport.order.firstIndex(of: "publish")! == TickReport.order.firstIndex(of: "render")! + 1)
    #expect(TickReport.order.firstIndex(of: "sync")! == TickReport.order.firstIndex(of: "publish")! + 1)
  }

  // MARK: Fuzz

  @Test(arguments: Array(1...12) as [UInt64])
  func randomPlannerOpsKeepTheInvariants(seed: UInt64) throws {
    var rng = SeededRNG(seed: seed)
    let rig = try Rig(8, platforms: [.tiktok, .x, .youtube], budget: 60)
    rig.fake.deleteFailRate = 0.3
    rig.fake.createFailRate = 0.1
    rig.fake.rng = SeededRNG(seed: seed &+ 99)
    let planner = Planner(store: rig.store), actions = PostActions(store: rig.store), bulk = BulkActions(store: rig.store)
    var trace: [String] = []
    for step in 0..<100 {
      let op = Int.random(in: 0..<14, using: &rng)
      let slots = try rig.store.planSlots(where: "date>=?", [rig.f.dm.key(rig.f.clock.now)])
      let live = try rig.store.posts().filter { !$0.state.isTerminal }
      func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[Int.random(in: 0..<a.count, using: &rng)] }
      do {
        switch op {
        case 0: if let s = pick(slots) { try planner.remove(slotId: s.id) }
        case 1: if let s = pick(slots) { try planner.move(slotId: s.id, to: rig.f.dm.addDays(s.date, Int.random(in: 1...4, using: &rng))) }
        case 2: if let a = pick(slots), let b = pick(slots), a.id != b.id { try planner.swap(a.id, b.id) }
        case 3: if let s = pick(slots) { try planner.pushPlan(from: s.date, days: 1) }
        case 4: if let p = pick(live) { try actions.skip(postId: p.id) }
        case 5: if let p = pick(live) { try actions.markPosted(postId: p.id, url: Fixture.postURLs[p.platform]!) }
        case 6:
          let id = "clip-\(Int.random(in: 0..<8, using: &rng))"
          var v = try #require(try rig.store.versions(videoId: id).first)
          v.caption = "caption \(step)"
          try rig.store.save(v, videoId: id)
        case 7: try rig.f.updateSettings { $0.pausedPlatforms.formSymmetricDifference([.x]) }
        case 8:
          try rig.f.updateSettings {
            $0.publishing.publishers[.tiktok] = $0.publishing.publisher(for: .tiktok) == .postiz ? .manual : .postiz
          }
        case 9: try rig.f.updateSettings { $0.paused.toggle() }
        case 10: _ = try bulk.removeFromQueue(["clip-\(Int.random(in: 0..<8, using: &rng))"])
        case 11:
          let w = rig.f.dm.addDays(rig.f.dm.weekStart(of: rig.f.clock.now), 7)
          if try rig.store.week(w)?.state != .approved { try planner.approveWeek(w) }
        case 12:
          if let j = pick(try rig.store.openPostizJobs().filter { $0.postizId != nil }) {
            if Bool.random(using: &rng) { rig.fake.vanish(j.postizId!) } else { rig.fake.fail(j.postizId!, error: "boom") }
          }
        default:
          rig.f.clock.advance(Double(Int.random(in: 1...10, using: &rng)) * 3600)
          rig.fake.publishDue(now: rig.f.clock.now)
        }
        trace.append("\(step):\(op)")
      } catch is EngineError {
        trace.append("\(step):\(op)!")
      }
      rig.tick()
      let bad = try rig.invariants()
      #expect(bad.isEmpty, "seed \(seed) after \(trace.suffix(5)): \(bad)")
      if !bad.isEmpty { return }
    }
    // Quiet down: no failures, time moves on; everything converges.
    rig.fake.deleteFailRate = 0
    rig.fake.createFailRate = 0
    try rig.f.updateSettings { $0.paused = false; $0.pausedPlatforms = [] }
    rig.f.clock.advance(1800)
    rig.tick(4)
    #expect(try rig.invariants().isEmpty)
    #expect(try rig.store.openPostizJobs().allSatisfy { $0.phase == .live })
    #expect(try rig.f.doublePosts().isEmpty)
    for j in try rig.store.openPostizJobs() {
      let p = try #require(try rig.store.post(id: j.postId), "seed \(seed): open job for a removed post")
      #expect(!p.state.isTerminal && p.scheduledAt == j.scheduledAt, "seed \(seed): stale job \(j.id)")
    }
    // The run really exercised replaces and failed deletes.
    #expect(rig.fake.deleteCount > 5 && rig.fake.createCount > 20, "seed \(seed): \(rig.fake.deleteCount) deletes")
  }
}
