import Foundation
import Testing
@testable import DJQCore

/// Rounds 8 and 9: a failed Postiz post retries by itself through `PostActions.fixed`, never for copyright, a held clip,
/// a platform off Postiz or while anything else of the clip + platform is open or published. A retry of a test run never
/// goes public. The times, the veto table and the quiet display are in `R9PostizRetryTests`.
@Suite struct R8PostizRetryTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  static let quota = "YouTube's daily upload quota is exhausted for today, please reschedule this post for a later time."
  static let monday = "2026-11-02"
  static let noRetry = " — no automatic retry for this one, mark Fixed when it's ready"
  static let retrying = " — retrying automatically"
  static let youTubeStays = " — " + PostizService.youTubeStaysNote

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
                    "HTTP 429: Too Many Requests"])
  func clearWordingRetries(_ m: String) { #expect(PostizService.retriesByItself(m, on: .x)) }

  @Test(arguments: ["Copyright claim, try again later", "Music rights quota exceeded", "audio rate limit", "Rights holder: too many requests"])
  func copyrightAlwaysWins(_ m: String) {
    #expect(PostizService.isCopyright(m) && PostizService.isVetoed(m))
  }

  /// A veto word anywhere beats a temporary word (these are test strings, not captured Postiz errors).
  @Test(arguments: ["This video violates our Community Guidelines. Please try again later.",
                    "Your upload violates our Terms. Quota for this account has been revoked.",
                    "Your reel may infringe someone's intellectual property. Try again later.",
                    "DMCA takedown received, upload quota revoked", "Content ID match found. Service temporarily unavailable.",
                    "This sound isn't available for business accounts. Try again later.",
                    "Song not licensed for your region, try again later", "Unlicensed track detected: too many requests",
                    "Copy right strike on channel, quota",
                    "Your account is restricted for violating our policies. Try again later.",
                    "Your account is banned from posting. Please try again later.", "Account suspended. Try again later.",
                    "Channel disabled, try again later", "Unauthorized: too many requests",
                    "Your storage quota is full, upgrade your plan",
                    "You have used your plan's post quota. Upgrade to continue.",
                    "Subscription quota exceeded", "Video rejected: spam. Too many requests",
                    "Exceeds the moderate limit for video size", "Exceeds the separate limit on hashtags",
                    "Account suspension in effect, quota", "Instagram blocks your request, rate limit",
                    "Your account has a posting ban. Too many requests", "Content removal pending, quota",
                    "Post rejection: quota", "Access revoke in progress, too many requests",
                    "Soundtrack not cleared, quota", "Copy-right notice, quota",
                    "Your post goes against our Community Standards. Quota", "Your video was flagged, rate limit",
                    "Your video was taken down, too many requests", "Trademark complaint received, quota",
                    "Matched third party content, quota", "Your account has been locked, rate limit",
                    "Account deactivated, too many requests", "This content isn't allowed here, quota",
                    "Lyrics match, rate limit"])
  func aVetoWordBeatsATemporaryWord(_ m: String) { #expect(PostizService.isVetoed(m)) }

  @Test func aPolicyErrorIsAPlainFailureAndNeverRetries() throws {
    let (rig, yt) = try ytRig()
    let m = "Your account is banned from posting. Please try again later."
    try fail(rig, yt, m)
    rig.tick(3)
    let p = try #require(try rig.store.post(id: yt.id))
    #expect(p.state == .failed && p.resolution == nil && p.errorMessage == m)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
  }

  /// YouTube: only the upload quota, where no video was created. The other platforms keep every temporary wording.
  @Test func youTubeRetriesOnlyTheUploadQuota() {
    for m in [Self.quota, "defaultVideoInsertPerDayPerProject exceeded"] { #expect(PostizService.retriesByItself(m, on: .youtube)) }
    for m in ["Rate limit reached while setting the thumbnail", "Too Many Requests", "Please try again later.",
              "Service temporarily unavailable", "Quota exceeded", "Your channel is suspended: daily upload quota",
              "We have uploaded your video but could not set the thumbnail: daily upload quota",
              "Thumbnail failed, defaultVideoInsertPerDayPerProject"] {
      #expect(!PostizService.retriesByItself(m, on: .youtube), "\(m)")
    }
    #expect(PostizService.retriesByItself("Rate limit reached", on: .x))
    #expect(!PostizService.retriesByItself("Account suspended, rate limit", on: .x))
  }

  @Test func aYouTubeRateLimitStaysAPlainFailure() throws {
    let (rig, yt) = try ytRig()
    let m = "Rate limit reached while setting the thumbnail, try again later"
    try fail(rig, yt, m)
    rig.tick(3)
    let p = try #require(try rig.store.post(id: yt.id))
    #expect(p.state == .failed && p.resolution == nil && p.errorMessage == m + Self.youTubeStays)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
  }

  @Test func aRateLimitOnAnotherPlatformStillRetries() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let x = try #require(try rig.f.post(.x, day: Self.monday))
    try fail(rig, x, "Rate limit reached")
    rig.tick(3)
    #expect(try attempts(rig, x).count == 2)
  }

  // MARK: The retry

  /// No alert, no Problem, no audit: the attempt exists as soon as the failure is known, and Postiz holds it.
  @Test func aQuotaFailureRetriesWithoutEric() throws {
    let (rig, yt) = try ytRig()
    let creates = rig.fake.createCount
    try fail(rig, yt)
    let failed = try #require(try rig.store.post(id: yt.id))
    #expect(failed.state == .failed && failed.errorType == .uploadFailed && failed.resolution == "retried")
    #expect(failed.errorMessage == Self.quota + Self.retrying)
    #expect(try rig.store.history(postId: yt.id).contains { $0.note == "auto-retry → attempt 2" })
    let list = try attempts(rig, yt)
    #expect(list.count == 2)
    let retry = list[1]
    #expect(retry.kind == .retry && retry.attemptNo == 2 && retry.publisher == "postiz")
    #expect(try problems(rig).isEmpty)

    // The publish step submits the new attempt with no manual action; the failed one is never resent.
    rig.tick(2)
    #expect(try rig.job(retry)?.phase == .live)
    #expect(rig.fake.createCount == creates + 1)
    #expect(try rig.job(failed) == nil)
    #expect(try rig.invariants().isEmpty)
    #expect(try events(rig, "automatic retry 1 on") == 1)
    #expect(!rig.notifier.delivered.contains { $0.key == "problem:\(yt.id)" })
  }

  /// YouTube says so and stays with Eric: this error may come after the video exists.
  @Test func aPlainFailureOnYouTubeWaitsForEric() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt, "Upload failed at the platform")
    rig.tick(3)
    let p = try #require(try rig.store.post(id: yt.id))
    #expect(p.state == .failed && p.resolution == nil && p.errorMessage == "Upload failed at the platform" + Self.youTubeStays)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
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
    #expect(try rig.store.post(id: again.id)?.errorMessage == Self.quota + Self.noRetry)
  }

  @Test(arguments: [PostState.skipped, .removed])
  func aSkippedOrRemovedPostIsLeftAlone(_ state: PostState) throws {
    let (rig, yt) = try ytRig()
    try rig.store.setHeldInEdit(yt.videoId, true)  // so its retry is still waiting
    try fail(rig, yt)
    var p = try #require(try rig.store.post(id: yt.id))
    p.state = state
    try rig.store.save(p, note: "test")
    try rig.store.setHeldInEdit(yt.videoId, false)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1)
  }

  /// The promise can't be kept any more: it goes back to Eric, loud.
  @Test func aPlatformSkippedInTheEditorIsLeftAlone() throws {
    let (rig, yt) = try ytRig()
    try rig.store.setHeldInEdit(yt.videoId, true)
    try fail(rig, yt)
    #expect(try problems(rig).isEmpty)
    var e = try rig.store.edit(videoId: yt.videoId)
    e.skippedPlatforms = [.youtube]
    try rig.store.save(e, videoId: yt.videoId)
    try rig.store.setHeldInEdit(yt.videoId, false)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
    #expect(try rig.store.post(id: yt.id)?.errorMessage == Self.quota + Self.noRetry)
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(yt.id)" })
  }

  @Test func aSkippedPlatformGetsNoPromise() throws {
    let (rig, yt) = try ytRig()
    var e = try rig.store.edit(videoId: yt.videoId)
    e.skippedPlatforms = [.youtube]
    try rig.store.save(e, videoId: yt.videoId)
    #expect(try rig.service.retryNote(Self.quota, yt) == Self.noRetry)
  }

  @Test func aHeldClipKeepsThePromiseBecauseItOnlyWaits() throws {
    let (rig, yt) = try ytRig()
    try rig.store.setHeldInEdit(yt.videoId, true)
    #expect(try rig.service.retryNote(Self.quota, yt) == Self.retrying)
  }

  @Test func aFailureAfterResetHasItsOwnAlert() throws {
    let (rig, yt) = try ytRig()
    let m = "Upload failed at the platform"
    try fail(rig, yt, m)
    rig.tick()
    let key = "problem:\(yt.id)"
    #expect(rig.notifier.delivered.filter { $0.key == key }.count == 1)
    try PostActions(store: rig.store).reset(postId: yt.id)
    rig.tick(2)
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: "Video too long")
    rig.f.clock.advance(3600)
    rig.tick()
    #expect(try rig.store.post(id: yt.id)?.state == .failed)
    rig.tick()
    let alerts = rig.notifier.delivered.filter { $0.key == key }
    #expect(alerts.count == 2 && alerts.last?.body.contains("Video too long") == true)
  }

  @Test func aHeldClipWaitsAndAReleasedOneRetries() throws {
    let (rig, yt) = try ytRig()
    try rig.store.setHeldInEdit(yt.videoId, true)
    try fail(rig, yt)
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
    let before = try rig.store.settings()
    let j = try #require(try rig.job(yt))
    rig.fake.fail(j.postizId!, error: Self.quota)
    rig.f.setTime(rig.f.dm.key(j.remoteDate), "23:30")
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
    #expect(try rig.store.post(id: yt.id)?.state == .failed)
    #expect(try attempts(rig, yt).count == 1 && problems(rig).isEmpty)
    #expect(!rig.notifier.delivered.contains { $0.key == "problem:\(yt.id)" })
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
    try rig.store.save(j)
    return j
  }

  /// Postiz fails the post while `paused`, so its retry waits; `paused(rig, false)` lets it go.
  func paused(_ rig: Rig, _ on: Bool) throws {
    try rig.f.updateSettings { s in if on { s.pausedPlatforms.insert(.youtube) } else { s.pausedPlatforms.remove(.youtube) } }
  }

  @Test func anOpenJobOfTheClipBlocksTheRetryUntilItIsGone() throws {
    let (rig, yt) = try ytRig()
    let j = try otherJob(rig, yt)
    try fail(rig, yt)
    #expect(try rig.service.retryDecision(rig.store.post(id: yt.id)!, settings: rig.store.settings(), router: rig.service.router()) == .wait)
    rig.tick(2)
    #expect(try attempts(rig, yt).count == 1)
    try rig.store.closePostizJob(id: j.id, reason: .cancelled)
    rig.tick()
    #expect(try attempts(rig, yt).count == 2)
  }

  @Test(arguments: [PostizCloseReason.published, .inbox])
  func aPublishedJobOfTheClipBlocksTheRetryForGood(_ reason: PostizCloseReason) throws {
    let (rig, yt) = try ytRig()
    try rig.store.closePostizJob(id: try otherJob(rig, yt).id, reason: reason)
    try fail(rig, yt)
    rig.tick(3)
    #expect(try attempts(rig, yt).count == 1 && problems(rig) == [yt.id])
    #expect(try rig.store.post(id: yt.id)?.errorMessage == Self.quota + Self.noRetry)
  }

  @Test func aLiveOrPostedAttemptBlocksTheRetry() throws {
    let (rig, yt) = try ytRig()
    try paused(rig, true)
    try fail(rig, yt)
    // Eric got there first: Fixed, then that attempt is posted by hand; a reset of the failure doesn't retry it either.
    let n = try PostActions(store: rig.store).fixed(postId: yt.id)
    try paused(rig, false)
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
    try paused(rig, true)
    try fail(rig, yt)
    var n = try PostActions(store: rig.store).fixed(postId: yt.id)
    n.state = state
    try rig.store.save(n, note: "test")
    var failed = try #require(try rig.store.post(id: yt.id))
    failed.resolution = nil
    try rig.store.save(failed, note: "test")
    try paused(rig, false)
    #expect(try rig.service.retryFailures() == "none")
    #expect(try attempts(rig, yt).count == 2)
    // The failed attempt alone (the other one failed too, or was skipped) does qualify: the guard isn't always on.
    n.state = .skipped
    try rig.store.save(n, note: "test")
    #expect(try rig.service.retryFailures() == "scheduled 1")
  }

  /// A repost carries the clip's published original: `fixed` would put it on the original's lineage.
  /// Round 31 (DECISIONS-R31, narrowing R8 §9): every version posts its count on purpose, so a repost failing after the
  /// clip's first post went out retries by itself like any post; only its own version post being out stops it.
  @Test func aRepostOfAClipPostizPublishedRetriesByItself() throws {
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
    let all = try attempts(rig, yt)
    #expect(all.count == 3 && all.last?.kind == .repost && all.last?.unit == repost.unit)
    #expect(try problems(rig).isEmpty)
    #expect(try PostizJob.lineage(#require(all.last)) == PostizJob.lineage(repost))
  }

  /// Eric's Fixed on that repost is sent: its own job, and only that job's result marks it posted.
  @Test func aFixedRepostIsSentNeverRecordedWithTheOriginalsLink() throws {
    let (rig, yt) = try ytRig()
    let j = try #require(try rig.job(yt))
    rig.fake.publish(j.postizId!)
    rig.f.setTime(Self.monday, "23:30")
    rig.tick()
    let original = try #require(try rig.store.post(id: yt.id)?.url)
    var v2 = Version(number: 2)
    v2.caption = "second cut"
    try rig.store.save(v2, videoId: yt.videoId)
    let repost = try PostActions(store: rig.store).repost(videoId: yt.videoId, platform: .youtube)
    rig.f.setTime(rig.f.dm.key(repost.scheduledAt), "00:10")
    rig.tick(4)
    try fail(rig, try #require(try rig.store.post(id: repost.id)), "Upload failed at the platform")
    rig.tick()

    let n = try PostActions(store: rig.store).fixed(postId: repost.id)
    let creates = rig.fake.createCount
    rig.tick(4)
    let sent = try #require(try rig.store.post(id: n.id))
    #expect(sent.state != .posted && sent.url == nil && sent.kind == .repost)
    #expect(rig.fake.createCount == creates + 1)
    let job = try #require(try rig.job(sent))
    #expect(job.postId == n.id && job.lineage == PostizJob.lineage(repost) && job.lineage != j.lineage)

    // Only one Postiz post for the attempt, whatever the ticks.
    rig.tick(3)
    #expect(rig.fake.createCount == creates + 1)
    rig.fake.publish(job.postizId!, url: "https://youtube.com/shorts/second", releaseId: "second")
    rig.f.setTime(rig.f.dm.key(job.remoteDate), "23:30")
    rig.tick()
    let posted = try #require(try rig.store.post(id: n.id))
    #expect(posted.state == .posted && posted.url == "https://youtube.com/shorts/second" && posted.url != original)
    #expect(try rig.store.post(id: yt.id)?.url == original)
    #expect(rig.fake.createCount == creates + 1)
  }

  /// A repost attempt really sends, so Re-upload can't pick a version the platform already has.
  @Test func reuploadRefusesAVersionAlreadyPosted() throws {
    let (rig, yt) = try ytRig()
    let j = try #require(try rig.job(yt))
    rig.fake.publish(j.postizId!)
    rig.f.setTime(Self.monday, "23:30")
    rig.tick()
    var v2 = Version(number: 2)
    v2.caption = "second cut"
    try rig.store.save(v2, videoId: yt.videoId)
    let actions = PostActions(store: rig.store)
    let repost = try actions.repost(videoId: yt.videoId, platform: .youtube)
    rig.f.setTime(rig.f.dm.key(repost.scheduledAt), "00:10")
    rig.tick(4)
    try fail(rig, try #require(try rig.store.post(id: repost.id)), "Copyright claim on this video")
    #expect(throws: EngineError.self) { try actions.resolveCopyright(postId: repost.id, .reuploadAnyway(versionNo: 1)) }
    #expect(try attempts(rig, yt).count == 2)
    try actions.resolveCopyright(postId: repost.id, .reuploadAnyway(versionNo: 2))
    #expect(try attempts(rig, yt).count == 3)
  }

  @Test func reuploadRefusesAVersionStillLiveOrPublishedUnsynced() throws {
    let (rig, yt) = try ytRig()
    let actions = PostActions(store: rig.store)
    var v2 = Version(number: 2)
    v2.caption = "second cut"
    try rig.store.save(v2, videoId: yt.videoId)
    // A repost planned while the regular v1 is still in flight: its copyright block can't re-upload v1.
    var repost = yt
    repost.id = "repost-v2"
    repost.versionNo = 2
    repost.kind = .repost
    repost.attemptNo = 2
    repost.state = .copyrightBlocked
    repost.errorType = .copyrightBlocked
    repost.renderId = nil
    try rig.store.save(repost, note: "test")
    #expect(throws: EngineError.self) { try actions.resolveCopyright(postId: repost.id, .reuploadAnyway(versionNo: 1)) }
    // Postiz published v1 and the post reads Failed: the job still counts.
    let j = try #require(try rig.job(yt))
    var seen = j
    seen.remoteState = "PUBLISHED"
    try rig.store.save(seen)
    var failed = try #require(try rig.store.post(id: yt.id))
    failed.state = .failed
    try rig.store.save(failed, note: "test")
    #expect(throws: EngineError.self) { try actions.resolveCopyright(postId: repost.id, .reuploadAnyway(versionNo: 1)) }
    // Its own version is still free.
    try actions.resolveCopyright(postId: repost.id, .reuploadAnyway(versionNo: 2))
  }

  // MARK: Two processes

  @Test func twoEnginesRetryOnceAndLogOnce() throws {
    let (rig, yt) = try ytRig()
    try fail(rig, yt)
    let other = PostizService(store: rig.store, transport: rig.fake, keyStore: rig.keys)
    let engine2 = Engine(store: rig.store, renderer: rig.renderer, publisher: nil, notifier: rig.notifier, postiz: other).planFrozen
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
      try rig.store.setHeldInEdit(yt.videoId, true)
      try fail(rig, yt)
      try rig.store.setHeldInEdit(yt.videoId, false)
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("djq-race-\(UUID().uuidString).sqlite").path
      defer { try? FileManager.default.removeItem(atPath: file) }
      try rig.store.db.backup(to: file)
      let stores = try (0..<4).map { _ in try Store(paths: rig.f.paths, clock: rig.f.clock, path: file) }
      let services = stores.map { PostizService(store: $0, transport: rig.fake, keyStore: rig.keys) }
      let errors = Box()
      DispatchQueue.concurrentPerform(iterations: services.count) { i in
        do { _ = try services[i].retryFailures() } catch { errors.add("\(error)") }
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

  /// Today's real case: a quota failure Eric already fixed by hand, its alert long sent. The retry leaves it alone.
  @Test func aFailureEricAlreadyFixedIsLeftAlone() throws {
    let (rig, yt) = try ytRig()
    try paused(rig, true)
    try fail(rig, yt)
    try paused(rig, false)
    let n = try PostActions(store: rig.store).fixed(postId: yt.id)
    #expect(n.attemptNo == 2)
    #expect(try rig.service.retryFailures() == "none")
    rig.tick(3)
    rig.f.setTime(rig.f.dm.key(n.scheduledAt), "08:00")
    rig.tick(3)
    #expect(try attempts(rig, yt).map(\.id) == [yt.id, n.id])
    #expect(try rig.store.post(id: yt.id)?.resolution == "retried")
    #expect(try rig.service.autoRetries(yt).count == 0)
    #expect(try events(rig, "automatic retry") == 0)
    #expect(try rig.service.pendingAutoRetries().isEmpty)
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
    let pending = try rig.service.pendingAutoRetries()
    let retry = try #require(try attempts(rig, yt).last)
    #expect(pending.map(\.post.id) == [retry.id] && pending[0].number == 1 && pending[0].queued)
    #expect(try rig.service.status().autoRetries == [retry.id])
    let finding = try #require(DoctorPostizTests.postiz(DoctorPostizTests.doctor(rig.store, keys: rig.keys).run())["postiz.auto_retry"])
    #expect(finding.severity == .info && finding.where_ == [retry.id] && finding.detail.contains("Retrying ") && !finding.detail.contains("try 1"))
    // Once the attempt has gone out nothing is pending.
    rig.tick(2)
    rig.fake.publishDue(now: retry.scheduledAt.addingTimeInterval(60))
    rig.f.clock.set(retry.scheduledAt.addingTimeInterval(3600))
    rig.tick()
    #expect(try rig.service.pendingAutoRetries().isEmpty)
  }

  @Test func aTickWithNoFailureDoesNothing() throws {
    let (rig, _) = try ytRig()
    #expect(rig.tick().steps["retry"] == "none")
    #expect(TickReport.order.firstIndex(of: "retry")! < TickReport.order.firstIndex(of: "publish")!)
  }
}
