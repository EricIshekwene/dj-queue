import Foundation
import Testing
@testable import DJQCore

/// Round 7, C2: a content-only edit (caption, title, hashtags, template, Postiz settings) reaches Postiz once it has
/// stayed the same for `PostizService.settleDelay` (one delete + create per edit burst, not one per edit); cancels,
/// moves and new renders stay immediate; the safety-window hold is unchanged; a delete retry is logged once per job
/// and kind of failure, not every tick. Everything runs against `FakePostiz` with the fixture's fixed clock.
@Suite struct R7PostizSettleTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  /// One X post (2026-11-02 17:00) scheduled in Postiz, the clock at 12:20 that day.
  func xRig(budget: Int = 1000) throws -> (Rig, PlatformPost, PostizJob) {
    let rig = try Rig(1, platforms: [.x], budget: budget)
    rig.settle()
    rig.f.setTime("2026-11-02", "12:20")
    let x = try #require(try rig.f.post(.x, day: "2026-11-02"))
    let j = try #require(try rig.job(x))
    #expect(j.phase == .live && rig.fake.deleteCount == 0)
    return (rig, x, j)
  }

  func reply(_ rig: Rig, _ w: XWhoCanReply) throws {
    try rig.f.updateSettings { $0.publishing.x.whoCanReply = w }
  }

  func events(_ rig: Rig, _ text: String) throws -> Int {
    try rig.store.events(limit: 5000).filter { $0.message.contains(text) }.count
  }

  // MARK: C2a debounce

  @Test func editBurstReplacesOnceTwoMinutesAfterTheLastEdit() throws {
    let (rig, x, old) = try xRig()
    let creates = rig.fake.createCount
    // Three edits 60 s apart: nothing is deleted or created while they keep coming.
    for w in [XWhoCanReply.following, .mentionedUsers, .subscribers] {
      try reply(rig, w)
      rig.tick()
      #expect(rig.fake.deleteCount == 0 && rig.fake.createCount == creates)
      #expect(try rig.job(x)?.id == old.id)
      rig.f.clock.advance(60)
    }
    // 60 s after the last edit (and again at 119 s): still waiting.
    rig.tick()
    rig.f.clock.advance(59)
    rig.tick()
    #expect(rig.fake.deleteCount == 0 && rig.fake.createCount == creates)
    #expect(rig.fake.post(old.postizId!)?.deleted == false)
    // 120 s stable: exactly one replace, delete first, with the last version.
    rig.f.clock.advance(1)
    rig.tick()
    #expect(rig.fake.deleteCount == 1 && rig.fake.createCount == creates + 1)
    let order = rig.fake.log.filter { $0.hasPrefix("DELETE") || $0 == "POST posts" }
    #expect(order.suffix(2) == ["DELETE posts/\(old.postizId!)", "POST posts"])
    let new = try #require(try rig.job(x))
    #expect(try new.id != old.id && rig.store.postizJob(id: old.id)?.closeReason == .replaced)
    #expect(rig.fake.post(new.postizId!)?.settings["who_can_reply_post"] as? String == "subscribers")
    // Settled: further ticks change nothing; one quiet "waiting" event for the whole burst.
    rig.f.clock.advance(600)
    rig.tick(3)
    #expect(rig.fake.deleteCount == 1 && rig.fake.createCount == creates + 1)
    #expect(try events(rig, "waiting for edits to settle") == 1)
    #expect(try rig.invariants().isEmpty)
    // The finished job's pending-change record is swept.
    #expect(try rig.store.kv(PostizService.settleKey(old.id), as: PostizService.Settling.self) == nil)
  }

  @Test func everyPostOfTheClipWaitsAndIsReplacedOnce() throws {
    let rig = try Rig(1, platforms: Platform.allCases)
    rig.settle()
    rig.f.setTime("2026-11-02", "07:00")  // before every slot of the day
    let before = try rig.store.openPostizJobs()
    let creates = rig.fake.createCount
    // Like editing a clip's hashtags: every edit changes the content of the same posts (X, YouTube, TikTok).
    let edits: [(inout Settings) -> Void] = [
      { $0.publishing.x.whoCanReply = .following; $0.publishing.youtube.madeForKids = true; $0.publishing.tiktok.duet = false },
      { $0.publishing.x.whoCanReply = .mentionedUsers; $0.publishing.youtube.visibility = .unlisted; $0.publishing.tiktok.stitch = false },
      { $0.publishing.x.whoCanReply = .verified; $0.publishing.youtube.madeForKids = false; $0.publishing.tiktok.comment = false },
    ]
    for e in edits {
      try rig.f.updateSettings(e)
      rig.tick()
      #expect(rig.fake.deleteCount == 0 && rig.fake.createCount == creates)
      rig.f.clock.advance(60)
    }
    rig.f.clock.advance(59)  // 119 s after the last edit
    rig.tick()
    #expect(rig.fake.deleteCount == 0 && rig.fake.createCount == creates)
    rig.f.clock.advance(1)
    rig.tick()
    let changed: Set<Platform> = [.x, .youtube, .tiktok]
    #expect(rig.fake.deleteCount == changed.count && rig.fake.createCount == creates + changed.count)
    for j in before {
      let closed = try #require(try rig.store.postizJob(id: j.id))
      #expect(changed.contains(j.platform) ? closed.closeReason == .replaced : closed.isOpen)
    }
    rig.tick(2)
    #expect(rig.fake.deleteCount == changed.count)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func revertingForgetsThePendingChange() throws {
    let (rig, x, old) = try xRig()
    try reply(rig, .following)
    rig.tick()
    rig.f.clock.advance(30)
    try reply(rig, .everyone)  // back to what Postiz has
    rig.tick()
    rig.f.clock.advance(70)
    try reply(rig, .following)  // same edit again, 100 s after the first: a fresh clock
    rig.tick()
    rig.f.clock.advance(100)
    rig.tick()
    #expect(try rig.fake.deleteCount == 0 && rig.job(x)?.id == old.id)
    rig.f.clock.advance(20)
    rig.tick()
    #expect(try rig.fake.deleteCount == 1 && rig.job(x)?.id != old.id)
    #expect(try rig.invariants().isEmpty)
  }

  // MARK: Immediate paths

  @Test func cancelsStayImmediateWhileAnEditSettles() throws {
    // Skipped while an edit is pending: removed this tick.
    do {
      let (rig, x, old) = try xRig()
      try reply(rig, .following)
      rig.tick()
      try PostActions(store: rig.store).skip(postId: x.id)
      rig.tick()
      #expect(try rig.store.postizJob(id: old.id)?.closeReason == .cancelled)
      #expect(rig.fake.post(old.postizId!)?.deleted == true)
      #expect(try rig.invariants().isEmpty)
    }
    // Switched to Manual while an edit is pending: removed this tick, nothing re-created.
    do {
      let (rig, _, old) = try xRig()
      let creates = rig.fake.createCount
      try reply(rig, .following)
      rig.tick()
      try rig.f.updateSettings { $0.publishing.publishers[.x] = .manual }
      rig.tick()
      #expect(try rig.store.postizJob(id: old.id)?.closeReason == .cancelled)
      #expect(rig.fake.createCount == creates && rig.fake.livePosts.isEmpty)
    }
    // Posting paused while an edit is pending: removed this tick.
    do {
      let (rig, _, old) = try xRig()
      try reply(rig, .following)
      rig.tick()
      try rig.f.updateSettings { $0.paused = true }
      rig.tick()
      #expect(try rig.store.postizJob(id: old.id)?.closeReason == .cancelled)
    }
  }

  @Test func newRenderAndMoveStayImmediate() throws {
    // A version change re-renders (FakeRenderer): replaced in the same tick, no waiting.
    do {
      let (rig, x, old) = try xRig()
      var v = try #require(try rig.store.versions(videoId: "clip-0").first)
      v.caption = "New caption"
      try rig.store.save(v, videoId: "clip-0")
      rig.tick()
      #expect(try rig.store.postizJob(id: old.id)?.closeReason == .replaced)
      #expect(try rig.job(x)?.id != old.id)
      #expect(try events(rig, "waiting for edits to settle") == 0)
    }
    // A settings edit pending, then the slot moves: replaced (or cancelled for a new post id) at once.
    do {
      let rig = try Rig(4, platforms: [.x])
      rig.settle()
      rig.f.setTime("2026-11-02", "12:20")
      let s = try #require(try rig.store.planSlots(where: "date='2026-11-03'").first)
      let xp = try #require(try rig.f.post(.x, day: "2026-11-03"))
      let old = try #require(try rig.job(xp))
      try reply(rig, .following)
      rig.tick()
      try Planner(store: rig.store).move(slotId: s.id, to: "2026-11-07")
      rig.tick()
      #expect(try rig.store.postizJob(id: old.id)?.isOpen == false)
      #expect(rig.fake.post(old.postizId!)?.deleted == true)
      #expect(try rig.invariants().isEmpty)
    }
  }

  // MARK: Safety window

  @Test func safetyWindowHoldIsUnchanged() throws {
    let (rig, x, old) = try xRig()
    // An edit 10 min before the slot starts the clock…
    rig.f.setTime("2026-11-02", "16:50")
    try reply(rig, .following)
    rig.tick()
    // …and the next look is inside the 5-min window: held, never replaced, even though it's long settled.
    rig.f.setTime("2026-11-02", "16:56")
    rig.tick(3)
    #expect(try rig.fake.deleteCount == 0 && rig.job(x)?.id == old.id)
    #expect(try events(rig, "within 5 min of its slot — Postiz keeps the version it has") == 1)
    // An edit made inside the window is held at once (no settle event).
    try reply(rig, .verified)
    rig.tick()
    #expect(rig.fake.deleteCount == 0 && rig.fake.post(old.postizId!)?.deleted == false)
    #expect(try events(rig, "waiting for edits to settle") == 1)  // only the 16:50 one
    #expect(try rig.invariants().isEmpty)
  }

  // MARK: C2b retry notice once

  @Test func deleteRetryIsLoggedOncePerJobAndKindOfFailure() throws {
    let (rig, x, old) = try xRig()
    let line = "Couldn't remove the X post from Postiz"
    // Budget used up: the delete retries every tick, one event.
    try rig.store.pausePostiz()
    try PostActions(store: rig.store).skip(postId: x.id)
    for _ in 0..<12 {
      rig.tick()
      rig.f.clock.advance(10)
    }
    var j = try #require(try rig.store.postizJob(id: old.id))
    #expect(j.phase == .deleting && j.attempts == 12)
    #expect(try events(rig, line) == 1)
    #expect(try events(rig, "budget used up") == 1)
    // A different failure is a new state: logged once more, then quiet again.
    rig.f.clock.advance(PostizBudget.pauseAfter429)
    rig.fake.failNext["DELETE posts"] = [500, 500, 500]
    rig.tick(3)
    #expect(try events(rig, line) == 2)
    // Then it goes through.
    rig.tick()
    j = try #require(try rig.store.postizJob(id: old.id))
    #expect(j.closeReason == .cancelled && rig.fake.post(old.postizId!)?.deleted == true)
    #expect(try events(rig, line) == 2)
    #expect(try rig.invariants().isEmpty)
  }
}
