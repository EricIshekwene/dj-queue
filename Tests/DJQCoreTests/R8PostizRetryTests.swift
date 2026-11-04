import Foundation
import Testing
@testable import DJQCore

/// Round 8: a temporary Postiz failure (quota, rate limit) stays Failed and loud, then re-queues by itself through
/// `PostActions.fixed`, at most twice per clip + platform, never for copyright, a held clip, a platform off Postiz or
/// while anything else of the clip + platform is open or published. A retry of a test run never goes public.
@Suite struct R8PostizRetryTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  static let quota = "YouTube's daily upload quota is exhausted for today, please reschedule this post for a later time."
  static let monday = "2026-11-02"

  /// One YouTube post scheduled in Postiz on Monday.
  func ytRig(_ change: ((inout Settings) -> Void)? = nil) throws -> (Rig, PlatformPost) {
    let rig = try Rig(1, platforms: [.youtube], change: change)
    rig.settle()
    return (rig, try #require(try rig.f.post(.youtube, day: Self.monday)))
  }

  /// Postiz reports `error` for the post's job; one tick after its slot's day reads it back. The next tick alerts.
  @discardableResult
  func fail(_ rig: Rig, _ p: PlatformPost, _ error: String? = quota) throws -> PostizJob {
    let j = try #require(try rig.job(p))
    rig.fake.fail(j.postizId!, error: error)
    rig.f.setTime(rig.f.dm.key(j.remoteDate), "23:30")
    rig.tick()
    return j
  }

  func attempts(_ rig: Rig, _ p: PlatformPost) throws -> [PlatformPost] {
    try rig.store.posts(where: "video_id=? AND platform=?", [p.videoId, p.platform.rawValue]).sorted { $0.attemptNo < $1.attemptNo }
  }

  /// Open problems, without the Manual platforms' missed posts.
  func problems(_ rig: Rig) throws -> [String] { try PostActions(store: rig.store).problems().filter { $0.state != .overdue }.map(\.id) }

  func events(_ rig: Rig, _ text: String) throws -> Int {
    try rig.store.events(limit: 5000).filter { $0.message.contains(text) }.count
  }

  // MARK: Classification

  @Test(arguments: [quota, "Quota exceeded", "exceeded your quotas", "Rate limit reached", "rate-limited by the platform",
                    "HTTP 429: Too Many Requests", "Please try again later.", "Service temporarily unavailable"])
  func clearWordingIsTemporary(_ m: String) { #expect(PostizService.isTemporary(m)) }

  @Test(arguments: ["Upload failed at the platform", "Postiz reported an error (no details)", "Account suspended", "Invalid token",
                    "Invalid quotation mark in title", "try again", "unavailable", "limit", "video too long", ""])
  func anythingElseIsNormal(_ m: String) { #expect(!PostizService.isTemporary(m)) }

  @Test(arguments: ["Copyright claim, try again later", "Music rights quota exceeded", "audio rate limit", "Rights holder: too many requests"])
  func copyrightAlwaysWins(_ m: String) {
    #expect(PostizService.isCopyright(m) && !PostizService.isTemporary(m))
  }

  // MARK: The retry

  @Test func quotaFailureStaysFailedAndLoudThenRetriesTheNextDay() throws {
    let (rig, yt) = try ytRig()
    let creates = rig.fake.createCount
    try fail(rig, yt)
    // Failed, with the message and the promise, on every screen; nothing moved yet.
    var failed = try #require(try rig.store.post(id: yt.id))
    #expect(failed.state == .failed && failed.errorType == .uploadFailed && failed.resolution == nil)
    #expect(failed.errorMessage == Self.quota + " — retries tomorrow automatically")
    #expect(try rig.service.displayState(for: failed) == .failed(failed.errorMessage!))
    #expect(try attempts(rig, yt).count == 1)

    rig.tick()  // alert, then re-queue, then publish
    let alert = try #require(rig.notifier.delivered.first { $0.key == "problem:\(yt.id)" })
    #expect(alert.title == "Failed on \(Platform.youtube.displayName)" && alert.body.contains(Self.quota) && alert.body.contains("retries tomorrow automatically"))
    failed = try #require(try rig.store.post(id: yt.id))
    #expect(failed.state == .failed && failed.resolution == "retried")
    #expect(try rig.store.history(postId: yt.id).contains { $0.note == "auto-retry → attempt 2" })
    let list = try attempts(rig, yt)
    #expect(list.count == 2)
    let retry = list[1]
    #expect(retry.kind == .retry && retry.attemptNo == 2 && retry.publisher == "postiz")
    #expect(rig.f.dm.key(retry.scheduledAt) == "2026-11-03")
    #expect(try problems(rig).isEmpty)

    // The publish step submits the new attempt with no manual action; the failed one is never resent.
    rig.tick(2)
    #expect(try rig.job(retry)?.phase == .live)
    #expect(rig.fake.createCount == creates + 1)
    #expect(try rig.job(failed) == nil)
    #expect(try rig.invariants().isEmpty)
    #expect(try events(rig, "automatic retry 1 of 2") == 1)
    #expect(rig.notifier.delivered.filter { $0.key == "problem:\(yt.id)" }.count == 1)
  }

  @Test func theAlertAlwaysGoesOutBeforeTheRetry() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    // Another process's retry step, before any alert step: nothing happens, so `problems()` still has it for the alert.
    #expect(try rig.service.retryTemporary() == "none")
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
    rig.tick()
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(yt.id)" })
    #expect(try attempts(rig, yt).count == 2)
  }

  @Test func aNormalFailureWaitsForEric() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt, "Upload failed at the platform")
    rig.tick(3)
    let p = try #require(try rig.store.post(id: yt.id))
    #expect(p.state == .failed && p.resolution == nil && p.errorMessage == "Upload failed at the platform")
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
  }

  @Test func twoRetriesThenItStaysFailedForEric() throws {
    let (rig, yt) = try ytRig()
    var post = yt
    for n in 1...2 {
      try fail(rig, post)
      rig.tick(3)
      let list = try attempts(rig, yt)
      #expect(list.count == n + 1)
      post = list[n]
      #expect(try events(rig, "automatic retry \(n) of 2") == 1)
    }
    let third = try fail(rig, post)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 3)
    let last = try #require(try rig.store.post(id: third.postId))
    #expect(last.state == .failed && last.resolution == nil)
    #expect(try problems(rig) == [last.id])
    #expect(last.errorMessage == Self.quota + " — automatic retries used up, mark Fixed when it's ready")
    #expect(!last.errorMessage!.contains("retries tomorrow"))
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(last.id)" })
    #expect(try rig.service.pendingAutoRetries().isEmpty)
    // Eric's Fixed still works.
    #expect(try PostActions(store: rig.store).fixed(postId: last.id).attemptNo == 4)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func copyrightIsNeverRetried() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt, "Copyright claim: please reschedule this post for a later time")
    rig.tick(3)
    let p = try #require(try rig.store.post(id: yt.id))
    #expect(p.state == .copyrightBlocked && p.resolution == nil && !(p.errorMessage ?? "").contains("automatically"))
    #expect(try attempts(rig, yt).count == 1)
    #expect(try rig.store.finalPostizJob(postId: yt.id)?.closeReason == .copyright)
  }

  @Test func aCopyrightProblemOnTheClipBlocksLaterRetries() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt, "Copyright claim on this video")
    rig.tick()
    try PostActions(store: rig.store).resolveCopyright(postId: yt.id, .reuploadAnyway(versionNo: nil))
    rig.tick(3)
    let again = try #require(try attempts(rig, yt).last)
    #expect(again.attemptNo == 2)
    try fail(rig, again)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 2)
    #expect(try problems(rig) == [again.id])
  }

  @Test(arguments: [PostState.skipped, .removed])
  func aSkippedOrRemovedPostIsLeftAlone(_ state: PostState) throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    var p = try #require(try rig.store.post(id: yt.id))
    p.state = state
    try rig.store.save(p, note: "test")
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1)
  }

  @Test func aPlatformSkippedInTheEditorIsLeftAlone() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    var e = try rig.store.edit(videoId: yt.videoId)
    e.skippedPlatforms = [.youtube]
    try rig.store.save(e, videoId: yt.videoId)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1)
  }

  @Test func aHeldClipWaitsAndAReleasedOneRetries() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    try rig.store.setHeldInEdit(yt.videoId, true)
    let r = rig.tick(3)
    #expect(try attempts(rig, yt).count == 1)
    #expect(r.errors.isEmpty)  // not a refused `fixed` on every tick
    try rig.store.setHeldInEdit(yt.videoId, false)
    rig.tick()
    #expect(try attempts(rig, yt).count == 2)
  }

  @Test(arguments: ["manual", "paused", "pausedAll", "off", "noChannel"])
  func aPlatformNoLongerOnPostizWaits(_ how: String) throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    let before = try rig.store.settings()
    try rig.f.updateSettings { s in
      switch how {
      case "manual": s.publishing.publishers[.youtube] = .manual
      case "paused": s.pausedPlatforms.insert(.youtube)
      case "pausedAll": s.paused = true
      case "off": s.enabledPlatforms.remove(.youtube)
      default: s.publishing.channels[.youtube] = nil
      }
    }
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
    try rig.f.updateSettings { $0 = before }
    rig.tick()
    #expect(try attempts(rig, yt).count == 2)
  }

  // MARK: Never double-post

  /// A hand-made unconfirmed job of the same clip + platform under another post id: it stays open until closed here.
  func otherJob(_ rig: Rig, _ p: PlatformPost) throws -> PostizJob {
    var j = PostizJob(postId: "other", videoId: p.videoId, platform: p.platform, integrationId: "ch-\(p.platform.rawValue)",
                      phase: .creating, renderId: p.renderId, contentHash: "h", scheduledAt: p.scheduledAt,
                      remoteDate: p.scheduledAt, testMode: false, postType: "schedule", remoteState: PostizJob.unconfirmed,
                      submittedAt: rig.f.clock.now, createdAt: rig.f.clock.now, updatedAt: rig.f.clock.now)
    j.lineage = PostizJob.lineage(p)
    #expect(try rig.store.claimPostizJob(j))
    return j
  }

  @Test func anOpenJobOfTheClipBlocksTheRetryUntilItIsGone() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    let j = try otherJob(rig, yt)
    #expect(try rig.service.retryableJob(rig.store.post(id: yt.id)!, settings: rig.store.settings(), router: rig.service.router()) == nil)
    rig.tick(2)
    #expect(try attempts(rig, yt).count == 1)
    try rig.store.closePostizJob(id: j.id, reason: .cancelled)
    rig.tick()
    #expect(try attempts(rig, yt).count == 2)
  }

  @Test(arguments: [PostizCloseReason.published, .inbox])
  func aPublishedJobOfTheClipBlocksTheRetryForGood(_ reason: PostizCloseReason) throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    try rig.store.closePostizJob(id: try otherJob(rig, yt).id, reason: reason)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
  }

  @Test func aLiveOrPostedAttemptBlocksTheRetry() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    // Eric got there first: Fixed, then that attempt is posted by hand; a reset of the failure doesn't retry it either.
    let n = try PostActions(store: rig.store).fixed(postId: yt.id)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 2)
    #expect(try rig.job(n) != nil)
    #expect(try rig.invariants().isEmpty)
    var failed = try #require(try rig.store.post(id: yt.id))
    failed.resolution = nil
    try rig.store.save(failed, note: "test")
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 2)  // the attempt is live
  }

  /// No job in the way, only another post of the clip + platform: not submitted yet, posted by hand, or a copyright problem.
  @Test(arguments: [PostState.planned, .posted, .copyrightBlocked])
  func anotherPostOfTheClipBlocksTheRetry(_ state: PostState) throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    #expect(try rig.store.markNotified(PostActions.problemKey(yt.id)))
    var n = try PostActions(store: rig.store).fixed(postId: yt.id)
    n.state = state
    try rig.store.save(n, note: "test")
    var failed = try #require(try rig.store.post(id: yt.id))
    failed.resolution = nil
    try rig.store.save(failed, note: "test")
    #expect(try rig.service.retryTemporary() == "none")
    #expect(try attempts(rig, yt).count == 2)
    // The failed attempt alone (the other one failed too, or was skipped) does qualify: the guard isn't always on.
    n.state = .skipped
    try rig.store.save(n, note: "test")
    #expect(try rig.service.retryTemporary() == "re-queued 1")
  }

  /// A repost carries the clip's published original: `fixed` would put it on the original's lineage.
  @Test func aRepostOfAClipPostizPublishedStaysFailed() throws {
    let (rig, yt) = try ytRig()
    let j = try #require(try rig.job(yt))
    rig.fake.publish(j.postizId!)
    rig.f.setTime(Self.monday, "23:30")
    rig.tick()
    #expect(try rig.store.post(id: yt.id)?.state == .posted)
    var v2 = Version(number: 2)
    v2.caption = "second cut"
    try rig.store.save(v2, videoId: yt.videoId)
    let repost = try PostActions(store: rig.store).repost(videoId: yt.videoId, platform: .youtube)
    rig.f.setTime(rig.f.dm.key(repost.scheduledAt), "00:10")
    rig.tick(4)
    let current = try #require(try rig.store.post(id: repost.id))
    #expect(try rig.job(current) != nil)
    try fail(rig, current)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 2)
    #expect(try problems(rig) == [repost.id])
  }

  // MARK: Two processes

  @Test func twoEnginesRetryOnceAndLogOnce() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    let other = PostizService(store: rig.store, transport: rig.fake, keyStore: rig.keys)
    let engine2 = Engine(store: rig.store, renderer: rig.renderer, publisher: nil, notifier: rig.notifier, postiz: other)
    rig.tick()
    engine2.tick(reason: "b")
    rig.tick()
    engine2.tick(reason: "b")
    #expect(try attempts(rig, yt).count == 2)
    #expect(try events(rig, "automatic retry") == 1)
    #expect(try rig.service.autoRetries(yt).count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  /// Real connections on one database file, at the same moment.
  @Test func twoConnectionsRacingRetryOnce() throws {
    for _ in 0..<6 {
      let (rig, yt) = try ytRig()
      try fail(rig, yt)
      #expect(try rig.store.markNotified(PostActions.problemKey(yt.id)))
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("djq-race-\(UUID().uuidString).sqlite").path
      defer { try? FileManager.default.removeItem(atPath: file) }
      try rig.store.db.backup(to: file)
      let stores = try (0..<4).map { _ in try Store(paths: rig.f.paths, clock: rig.f.clock, path: file) }
      let services = stores.map { PostizService(store: $0, transport: rig.fake, keyStore: rig.keys) }
      let errors = Box()
      DispatchQueue.concurrentPerform(iterations: services.count) { i in
        do { _ = try services[i].retryTemporary() } catch { errors.add("\(error)") }
      }
      #expect(errors.list.isEmpty)
      let s = stores[0]
      #expect(try s.posts(where: "video_id=? AND platform='youtube'", [yt.videoId]).count == 2)
      #expect(try s.events(limit: 5000).filter { $0.message.contains("automatic retry") }.count == 1)
      #expect(try services[0].autoRetries(yt).count == 1)
    }
  }

  final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var list: [String] { lock.withLock { items } }
  }

  @Test func ericsFixedAndTheRetryMakeOneAttempt() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    try PostActions(store: rig.store).fixed(postId: yt.id)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 2)
    #expect(try rig.service.autoRetries(yt).count == 0)
  }

  // MARK: Test run

  @Test func aRetryOfATestRunStaysATestRunWhenTestRunIsTurnedOff() throws {
    let (rig, yt) = try ytRig { $0.publishing.testMode = true }
    let j = try #require(try rig.job(yt))
    #expect(j.testMode && rig.fake.post(j.postizId!)?.settings["type"] as? String == "unlisted")
    try rig.f.updateSettings { $0.publishing.testMode = false }
    try fail(rig, yt)
    rig.tick(3)
    let retry = try #require(try attempts(rig, yt).last)
    #expect(retry.attemptNo == 2)
    var job = try #require(try rig.job(retry))
    #expect(job.testMode && job.id != j.id)
    #expect(rig.fake.post(job.postizId!)?.settings["type"] as? String == "unlisted")
    #expect(try events(rig, "stays a test run") == 1)

    // A move replaces it in Postiz: still a test run.
    var moved = retry
    moved.scheduledAt = retry.scheduledAt.addingTimeInterval(3600)
    try rig.store.save(moved, note: "test move")
    rig.tick(2)
    let replaced = try #require(try rig.job(retry))
    #expect(replaced.id != job.id && replaced.testMode)
    #expect(rig.fake.post(replaced.postizId!)?.settings["type"] as? String == "unlisted")

    // And the second retry too.
    job = replaced
    try fail(rig, retry)
    rig.tick(3)
    let second = try #require(try attempts(rig, yt).last)
    #expect(second.attemptNo == 3)
    let last = try #require(try rig.job(second))
    #expect(last.testMode && rig.fake.post(last.postizId!)?.settings["type"] as? String == "unlisted")
    #expect(rig.fake.everCreated.allSatisfy { $0.settings["type"] as? String == "unlisted" })
  }

  @Test func aDraftPlatformsRetryStaysADraft() throws {
    let rig = try Rig(1, platforms: [.x]) { $0.publishing.testMode = true }
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: Self.monday))
    try rig.f.updateSettings { $0.publishing.testMode = false }
    try fail(rig, x)
    rig.tick(3)
    let retry = try #require(try attempts(rig, x).last)
    let job = try #require(try rig.job(retry))
    #expect(job.testMode && job.postType == "draft" && rig.fake.post(job.postizId!)?.type == "draft")
  }

  @Test func aRetryOfARealPostFollowsTheTestRunSwitch() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    try rig.f.updateSettings { $0.publishing.testMode = true }
    rig.tick(3)
    let a = try #require(try attempts(rig, yt).last)
    #expect(try rig.job(a)?.testMode == true)

    let (rig2, yt2) = try ytRig()
    try fail(rig2, yt2)
    rig2.tick(3)
    let b = try #require(try attempts(rig2, yt2).last)
    let job = try #require(try rig2.job(b))
    #expect(!job.testMode && rig2.fake.post(job.postizId!)?.settings["type"] as? String != "unlisted")
  }

  // MARK: Status

  @Test func doctorAndStatusShowPendingRetries() throws {
    let (rig, yt) = try ytRig()
    #expect(try rig.service.pendingAutoRetries().isEmpty)
    try fail(rig, yt)
    var pending = try rig.service.pendingAutoRetries()
    #expect(pending.map(\.post.id) == [yt.id] && pending[0].number == 1 && !pending[0].queued)
    rig.tick(3)
    pending = try rig.service.pendingAutoRetries()
    let retry = try #require(try attempts(rig, yt).last)
    #expect(pending.map(\.post.id) == [retry.id] && pending[0].number == 1 && pending[0].queued)
    #expect(try rig.service.status().autoRetries == [retry.id])
    let finding = try #require(DoctorPostizTests.postiz(DoctorPostizTests.doctor(rig.store, keys: rig.keys).run())["postiz.auto_retry"])
    #expect(finding.severity == .info && finding.where_ == [retry.id] && finding.detail.contains("retry 1 of 2"))
    // Once the attempt has gone out nothing is pending.
    rig.fake.publishDue(now: retry.scheduledAt.addingTimeInterval(60))
    rig.f.clock.set(retry.scheduledAt.addingTimeInterval(3600))
    rig.tick()
    #expect(try rig.service.pendingAutoRetries().isEmpty)
  }

  @Test func aTickWithNoFailureDoesNothing() throws {
    let (rig, _) = try ytRig()
    #expect(rig.tick().steps["retry"] == "none")
    #expect(TickReport.order.firstIndex(of: "retry")! == TickReport.order.firstIndex(of: "alerts")! + 1)
    #expect(TickReport.order.firstIndex(of: "retry")! < TickReport.order.firstIndex(of: "publish")!)
  }
}
