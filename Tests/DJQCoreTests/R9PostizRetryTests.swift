import Foundation
import Testing
@testable import DJQCore

/// Round 9: a failed post retries by itself, on a stored time from when it failed, with its attempt in Postiz ahead of
/// that time. Eric never audits it. See DECISIONS-R9.md.
@Suite struct R9PostizRetryTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  static let quota = R8PostizRetryTests.quota
  static let monday = R8PostizRetryTests.monday
  /// The R8 suite's helpers (one rig per test; the struct itself holds nothing).
  let r8 = R8PostizRetryTests()

  func xRig(_ platforms: [Platform] = [.x], change: ((inout Settings) -> Void)? = nil) throws -> (Rig, PlatformPost) {
    let rig = try Rig(1, platforms: platforms, change: change)
    rig.settle()
    return (rig, try #require(try rig.f.post(platforms[0], day: Self.monday)))
  }

  func attempts(_ rig: Rig, _ p: PlatformPost) throws -> [PlatformPost] { try r8.attempts(rig, p) }

  /// A New York time as a date.
  func ny(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    let p = day.split(separator: "-").compactMap { Int($0) }
    return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute))!
  }

  /// Postiz errors the post's job at its time; the Mac sees it `after` seconds later.
  @discardableResult
  func fail(_ rig: Rig, _ p: PlatformPost, _ error: String? = "Something went wrong", seenAfter after: TimeInterval = 60) throws -> PostizJob {
    let j = try #require(try rig.job(p))
    rig.fake.fail(j.postizId!, error: error)
    rig.f.clock.set(j.remoteDate.addingTimeInterval(after))
    rig.tick()
    return j
  }

  // MARK: R1 veto or retry

  /// Real wording from the platforms and Postiz's own curated errors.
  @Test(arguments: [
    (Platform.x, "Unknown error"), (.x, "Postiz reported an error (no details)"), (.x, ""), (.instagram, "An unknown error occurred"),
    (.tiktok, "TikTok API rate limit exceeded, please try again later"), (.tiktok, "Daily post limit reached, please try again tomorrow"),
    (.tiktok, "Failed to pull video from URL"), (.instagram, "The media is not ready for publishing, please wait"),
    (.instagram, "Application request limit reached"), (.facebook, "An unexpected error has occurred. Please retry your request later."),
    (.facebook, "Video upload failed"), (.threads, "Service temporarily unavailable"), (.x, "503 Service Unavailable"),
    (.x, "Rate limit exceeded"), (.x, "Rate-limited"), (.x, "Quota exceeded"), (.instagram, "Upload failed, please retry"), (.threads, "Could not publish"), (.x, "This request exceeds your quota for today"),
    (.x, "502 Bad Gateway"), (.threads, "socket hang up"), (.instagram, "Request timed out"), (.youtube, Self.quota),
    (.youtube, "defaultVideoInsertPerDayPerProject exceeded"), (.tiktok, "Internal server error"),
  ] as [(Platform, String)])
  func retries(_ platform: Platform, _ message: String) {
    #expect(PostizService.retriesByItself(message, on: platform), "\(message)")
  }

  @Test(arguments: [
    // copyright and policy
    (Platform.instagram, "This audio isn't available: the song is restricted by its rights holder"), (.tiktok, "Copyright claim on this video"),
    (.facebook, "Your video violates our Community Standards"), (.instagram, "Your account is restricted"),
    (.tiktok, "spam_risk_user_banned_from_posting"), (.tiktok, "spam_risk_too_many_posts"), (.x, "Your account is suspended"),
    (.x, "You are not allowed to create a Tweet with duplicate content."), (.threads, "This post was already published"),
    // too long, too large
    (.x, "Video longer than 2:20"), (.tiktok, "duration_check_failed"), (.instagram, "Caption too long, max 2200 characters"),
    (.facebook, "The video file you tried to upload is too large."), (.tiktok, "picture_size_check_failed"), (.x, "Text must be 280 characters or less"),
    // format, validation
    (.tiktok, "file_format_check_failed"), (.instagram, "Unsupported video format"), (.instagram, "The aspect ratio is not supported"),
    (.instagram, "Too many hashtags"), (.facebook, "(#100) Invalid parameter"), (.x, "Bad request"), (.threads, "Missing required field: media"),
    (.tiktok, "frame_rate_check_failed"), (.instagram, "Video codec H265 isn't supported: not supported"),
    // auth: round 22 made these sign-in waits (R22SelfHealingTests), not failures that stay
    // the platform has it, in any wording
    (.instagram, "This media has already been posted"), (.threads, "This post has already been published"),
    (.tiktok, "This video has been posted before"), (.x, "Whoops! You already said that."),
    // policy
    (.facebook, "(#368) The action attempted has been deemed abusive or is otherwise disallowed"), (.instagram, "This content is prohibited"),
    (.x, "You are not permitted to perform this action."), (.instagram, "Nudity or sexual activity"), (.facebook, "Hate speech"),
    (.threads, "Sensitive content detected"),
    // it says it landed, or may have
    (.instagram, "Media published but permalink lookup failed"), (.threads, "Post created but could not fetch its URL"),
    (.x, "The post is live, but the follow-up failed"), (.tiktok, "Could not be posted"), (.facebook, "Published with errors"),
    (.instagram, "Unable to fetch the permalink"),
    // the rest of the round 2 list
    (.x, "File exceeded the limit"), (.x, "Video exceeded the allowed limit"), (.tiktok, "file-too-large"),
    (.x, "Tweet needs to be a bit shorter."), (.facebook, "Content not eligible"), (.x, "Insufficient credits"),
    (.threads, "Verify your account"), (.instagram, "Not available in your country"),
    // a 403 alone isn't a sign-in (round 22 waits on the rest of the old sign-in list)
    (.x, "Request failed with status code 403"),
    // size
    (.facebook, "Video exceeds the maximum allowed"), (.x, "Video exceeds 5 minutes"), (.x, "Your video is over the limit of 512MB"),
    (.threads, "The video is 200 seconds; maximum is 180"), (.facebook, "HTTP 413"), (.tiktok, "FileSizeExceeded"), (.tiktok, "UnsupportedMedia"),
    // TikTok codes
    (.tiktok, "unaudited_client_can_only_post_to_private_accounts"), (.tiktok, "privacy_level_option_mismatch"),
    (.tiktok, "url_ownership_unverified"), (.instagram, "Instagram account is private"), (.tiktok, "reached_active_user_cap"),
    // YouTube: the video may exist
    (.youtube, "Unknown error"), (.youtube, "Rate limit reached while setting the thumbnail"), (.youtube, "Internal server error"), (.youtube, ""),
    (.youtube, "Postiz reported an error (no details)"),
  ] as [(Platform, String)])
  func staysWithEric(_ platform: Platform, _ message: String) {
    #expect(!PostizService.retriesByItself(message, on: platform), "\(message)")
  }

  @Test func anUnknownErrorRetriesAndNothingShows() throws {
    let (rig, x) = try xRig()
    try fail(rig, x, nil)  // Postiz gave no message
    #expect(try attempts(rig, x).count == 2)
    #expect(try r8.problems(rig).isEmpty)
  }

  @Test func aVetoedFailureStaysLoud() throws {
    let (rig, x) = try xRig()
    try fail(rig, x, "Video longer than 2:20")
    rig.tick()
    #expect(try attempts(rig, x).count == 1 && r8.problems(rig) == [x.id])
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(x.id)" })
  }

  /// A v0.8 row has none of the new fields.
  @Test func aRowFromTheOlderBuildStillReads() throws {
    let (rig, x) = try xRig()
    try rig.store.db.run("INSERT OR REPLACE INTO kv(key, json) VALUES(?, ?)", [PostizService.autoRetryKey(x), #"{"count":1,"testRunPosts":[]}"#])
    #expect(try rig.service.autoRetries(x).count == 1)
  }

  // MARK: R2 times

  /// X's slot is 8:00 here, so "the next slot" reads like the old "next morning".
  func next(_ failedAt: Date, _ n: Int, _ platform: Platform = .x, _ zone: String = "America/New_York") -> Date {
    var s = Settings()
    s.timeZone = zone
    s.slotMinutes[.x] = 8 * 60
    return PostizRetrySchedule.next(after: failedAt, retry: n, platform: platform, settings: s)
  }

  /// Round 22: +1 h, +6 h, then the platform's next slot at least an hour after the failure, with no end.
  @Test func theBackoff() {
    let t = ny("2026-11-04", 15, 30)
    #expect(next(t, 1) == t.addingTimeInterval(3600))
    #expect(next(t, 2) == t.addingTimeInterval(6 * 3600))
    #expect(next(t, 3) == ny("2026-11-05", 8))
    #expect(next(t, 4) == ny("2026-11-05", 8))
    #expect(next(t, 20) == ny("2026-11-05", 8))
    // Before 7 am the slot is that same day, but never less than an hour after the failure.
    #expect(next(ny("2026-11-04", 2), 3) == ny("2026-11-04", 8))
    #expect(next(ny("2026-11-04", 7, 30), 3) == ny("2026-11-05", 8))
  }

  /// US clocks go back on 1 Nov 2026 and forward on 14 Mar 2027.
  @Test func theBackoffOnADSTDay() {
    let before = ny("2026-10-31", 18)
    #expect(next(before, 4) == ny("2026-11-01", 8))  // the slot's clock time on the day the clocks went back
    #expect(next(before, 4).timeIntervalSince(before) == 15 * 3600)
    #expect(next(ny("2026-11-01", 0, 30), 1) == ny("2026-11-01", 0).addingTimeInterval(1.5 * 3600))  // hours stay hours
    #expect(next(ny("2026-11-01", 0, 30), 2).timeIntervalSince(ny("2026-11-01", 0, 30)) == 6 * 3600)
    #expect(next(ny("2026-10-31", 22), 3) == ny("2026-11-01", 8))
    let spring = ny("2027-03-13", 18)
    #expect(next(spring, 4) == ny("2027-03-14", 8))
    #expect(next(spring, 4).timeIntervalSince(spring) == 13 * 3600)
    #expect(next(ny("2027-03-13", 22), 3) == ny("2027-03-14", 8))
  }

  /// Round 22: YouTube's slot (15:00 by default) on the first day after the Pacific reset, every try.
  @Test func theYouTubeQuotaGoesToTheNextSlotAfterMidnightPacific() {
    #expect(next(ny("2026-11-04", 15), 1, .youtube) == ny("2026-11-05", 15))
    #expect(next(ny("2026-11-04", 23, 30), 1, .youtube) == ny("2026-11-05", 15))
    #expect(next(ny("2026-11-05", 2, 59), 1, .youtube) == ny("2026-11-05", 15))  // 11:59 pm Pacific: the reset is a minute away
    #expect(next(ny("2026-11-05", 3), 1, .youtube) == ny("2026-11-06", 15))  // midnight Pacific: that day's quota is the one that ran out
    // Every try waits for it, never +1 h.
    #expect(next(ny("2026-11-04", 15), 3, .youtube) == ny("2026-11-05", 15))
    // The slot is in Settings' time zone; the reset is always Pacific.
    #expect(next(ny("2026-11-04", 15), 1, .youtube, "Europe/London") == ny("2026-11-05", 10))
    // Both DST nights.
    #expect(next(ny("2026-10-31", 20), 1, .youtube) == ny("2026-11-01", 15))
    #expect(next(ny("2027-03-13", 20), 1, .youtube) == ny("2027-03-14", 15))
  }

  @Test func theTimeIsStoredAndCountsFromTheFailureNotFromWhenTheMacSawIt() throws {
    let (rig, x) = try xRig()
    let j = try fail(rig, x, seenAfter: 30 * 60)
    let r = try rig.service.autoRetries(x)
    #expect(r.failedAt == j.remoteDate && r.nextRetryAt == j.remoteDate.addingTimeInterval(3600))
    let a = try #require(try attempts(rig, x).last)
    #expect(a.scheduledAt == j.remoteDate.addingTimeInterval(3600))
  }

  @Test func quotaGoesToTheNextSlotAfterTheReset() throws {
    let (rig, yt) = try xRig([.youtube])
    try fail(rig, yt, Self.quota)
    let a = try #require(try attempts(rig, yt).last)
    #expect(a.scheduledAt == ny("2026-11-03", 15))
    rig.tick(2)
    #expect(try rig.job(a)?.remoteDate == ny("2026-11-03", 15))
  }

  // MARK: R2 stagger

  /// A second post on the platform, at `time`.
  func another(_ rig: Rig, _ x: PlatformPost, at time: Date, state: PostState = .rendered) throws {
    var o = x
    o.id = newId()
    o.scheduledAt = time
    o.state = state
    o.planSlotId = nil
    o.kind = .repost
    o.versionNo = 9
    o.renderId = nil
    try rig.store.save(o, note: "test")
  }

  @Test func aRetryKeepsTheGapFromAnotherPost() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    try another(rig, x, at: j.remoteDate.addingTimeInterval(2 * 3600))
    #expect(try Sched.retrySlot(store: rig.store, platform: .x, target: j.remoteDate.addingTimeInterval(3600),
                                settings: rig.store.settings(), excluding: [x.id]) == j.remoteDate.addingTimeInterval(5 * 3600))
  }

  /// +1 h is inside the 3 h gap from its own failure: that post went nowhere, so it doesn't count.
  @Test func aRetryIgnoresItsOwnFailureAndOtherPostsThatWentNowhere() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    try another(rig, x, at: j.remoteDate.addingTimeInterval(2 * 3600), state: .failed)
    try fail(rig, x)
    #expect(try attempts(rig, x).last?.scheduledAt == j.remoteDate.addingTimeInterval(3600))
  }

  @Test func twoQuotaRetriesKeepTheGapAndNeitherGoesLate() throws {
    let (rig, yt) = try xRig([.youtube])
    let at8 = ny("2026-11-03", 8)
    try another(rig, yt, at: at8)
    let t = try Sched.retrySlot(store: rig.store, platform: .youtube, target: at8, earliest: ny("2026-11-03", 3),
                                settings: rig.store.settings(), excluding: [yt.id])
    #expect(t == ny("2026-11-03", 5))  // earlier: still after the reset, and the day's quota goes fast
    let late = try Sched.retrySlot(store: rig.store, platform: .youtube, target: at8, earliest: ny("2026-11-03", 7),
                                   settings: rig.store.settings(), excluding: [yt.id])
    #expect(late == ny("2026-11-03", 11))  // no room before it
  }

  // MARK: R3 ahead of time, and the Mac asleep

  @Test func theAttemptIsInPostizAheadOfItsTime() throws {
    let (rig, x) = try xRig()
    let j = try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    #expect(a.scheduledAt > rig.f.clock.now)
    rig.tick(2)  // nothing else happens: the Mac can sleep from here
    let job = try #require(try rig.job(a))
    #expect(job.phase == .live && job.remoteDate == j.remoteDate.addingTimeInterval(3600))
    #expect(rig.fake.post(job.postizId!)?.state == "QUEUE")
  }

  /// The exact case: failure at T, the Mac asleep, the next tick at T + 9 h.
  @Test func theMacSleptThroughTheRetry() throws {
    let (rig, x) = try xRig()
    let creates = rig.fake.createCount
    let j = try fail(rig, x, seenAfter: 9 * 3600)
    let t = rig.f.clock.now
    #expect(try rig.service.autoRetries(x).nextRetryAt == j.remoteDate.addingTimeInterval(3600))
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    #expect(a.attemptNo == 2)
    let job = try #require(try rig.job(a))
    // Right away: now + 3 min on a whole minute, not the next day and not by hand.
    #expect(job.remoteDate.timeIntervalSince(t) >= PostizService.leadTime && job.remoteDate.timeIntervalSince(t) < PostizService.leadTime + 60)
    #expect(rig.fake.createCount == creates + 1)
    #expect(try r8.problems(rig).isEmpty)
    #expect(!rig.notifier.delivered.contains { $0.postId == a.id })
    #expect(try rig.store.post(id: a.id)?.state != .overdue)
    #expect(try !rig.service.handedToToday(a))
    #expect(try rig.invariants().isEmpty)
  }

  /// Sleep across midnight with the attempt not yet in Postiz: `missed` would hand it to Eric as overdue.
  @Test func anAttemptNotSentBeforeTheMacSleptIsNeverOverdue() throws {
    let (rig, x) = try xRig()
    try fail(rig, x, "Something went wrong")
    let a = try #require(try attempts(rig, x).last)
    #expect(try rig.job(a) == nil)  // made by the sync step, after this tick's publish
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(3 * 86400))
    rig.tick(2)
    let now = rig.f.clock.now
    let cur = try #require(try rig.store.post(id: a.id))
    #expect(cur.state != .overdue && cur.scheduledAt >= now)
    #expect(try rig.job(cur)?.phase == .live)
    #expect(!rig.notifier.delivered.contains { $0.postId == a.id })
  }

  /// A quota failure the Mac sees two days late goes out at once, not on another 07:30 UTC.
  @Test func aQuotaFailureSeenLateGoesRightAway() throws {
    let (rig, yt) = try xRig([.youtube])
    try fail(rig, yt, Self.quota, seenAfter: 2 * 86400)
    rig.tick(2)
    let a = try #require(try attempts(rig, yt).last)
    #expect(try rig.job(a)!.remoteDate.timeIntervalSince(rig.f.clock.now) < PostizService.leadTime + 60)
  }

  // MARK: R4 no audit

  @Test func aRetryComingIsNoProblemOnAnyList() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(3)
    #expect(try PostActions(store: rig.store).problems().isEmpty)
    #expect(try AgentAPI.posts(store: rig.store, problems: true).isEmpty)
    #expect(!rig.notifier.delivered.contains { $0.key.hasPrefix("problem:") })
    let doctor = DoctorPostizTests.doctor(rig.store, keys: rig.keys).run()
    #expect(!doctor.findings.contains { $0.id == "posts.failed" })
  }

  @Test func everyScreenReadsTheSameLine() throws {
    let (rig, x) = try xRig()
    let j = try fail(rig, x)
    let failed = try #require(try rig.store.post(id: x.id))
    let a = try #require(try attempts(rig, x).last)
    let when = Sched.retryDay(j.remoteDate.addingTimeInterval(3600), try rig.store.settings())
    let line = PostizDisplayState.retrying("Retrying \(when)")
    #expect(try rig.service.displayState(for: a) == line)
    #expect(try rig.service.displayState(for: failed) == line)  // Today's row is still the failed one
    rig.tick(2)
    #expect(try rig.service.displayState(for: rig.store.post(id: a.id)!) == line)  // with its job in Postiz
    #expect(line.isHeld)
  }

  /// The chip is the time alone: no try count, no error text (round 22).
  @Test func theLineSaysTheWeekdayAndTimeAndNothingElse() throws {
    let (rig, yt) = try xRig([.youtube])
    try fail(rig, yt, Self.quota)
    let a = try #require(try attempts(rig, yt).last)
    #expect(try rig.service.displayState(for: a) == .retrying("Retrying Tue 3:00 pm"))
  }

  /// Round 22: no cap. Every failure re-queues, the 6th and the 20th too, quietly: no Problem, no alert.
  @Test func noCapRetriesKeepGoing() throws {
    let (rig, x) = try xRig()
    var post = x
    for n in 1...20 {
      rig.tick(2)
      try fail(rig, post)
      let list = try attempts(rig, x)
      #expect(list.count == n + 1, "retry \(n)")
      post = list[n]
      #expect(post.kind == .retry && !post.state.isTerminal, "retry \(n)")
      #expect(try rig.service.autoRetries(x).count == n)
      #expect(try r8.events(rig, "automatic retry \(n) on") == 1, "retry \(n)")
      if n == 6 || n == 20 {
        #expect(try r8.problems(rig).isEmpty)
        #expect(!rig.notifier.delivered.contains { $0.key.hasPrefix("problem:") })
        #expect(try rig.service.pendingAutoRetries().map(\.post.id) == [post.id])
        #expect(try rig.service.displayState(for: post).map { if case .retrying(let s, _) = $0 { !s.contains(" of ") && !s.contains("(") } else { false } } == true)
      }
    }
    #expect(try rig.invariants().isEmpty)
  }

  @Test func theBackoffRunsThroughTheTries() throws {
    let (rig, x) = try xRig()
    var post = x
    var failedAt: [Date] = []
    var times: [Date] = []
    for n in 1...3 {
      rig.tick(2)
      failedAt.append(try fail(rig, post).remoteDate)
      post = try #require(try attempts(rig, x).last)
      times.append(post.scheduledAt)
      #expect(post.attemptNo == n + 1)
    }
    #expect(times[0] == failedAt[0].addingTimeInterval(3600))
    #expect(times[1] == failedAt[1].addingTimeInterval(6 * 3600))
    let dm = rig.f.dm
    #expect(dm.key(times[2]) > dm.key(failedAt[2]) || times[2] > failedAt[2])
    #expect(Sched.clock(times[2], try rig.store.settings()) == "17:00")  // X's slot
  }

  // MARK: R5 pause, held, Fixed

  /// `how` while the attempt waits in Postiz: it's taken out, its time passes, and on resume it goes once.
  @Test(arguments: ["pausedAll", "paused", "manual"])
  func aPauseAfterTheAttemptWaitsAndResumesOnce(_ how: String) throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    #expect(try rig.job(a) != nil)
    let before = try rig.store.settings()
    let creates = rig.fake.createCount
    try rig.f.updateSettings { s in
      switch how {
      case "pausedAll": s.paused = true
      case "paused": s.pausedPlatforms.insert(.x)
      default: s.publishing.publishers[.x] = .manual
      }
    }
    rig.tick()
    #expect(try rig.job(a) == nil)
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(2 * 86400))
    rig.tick(3)
    #expect(rig.fake.createCount == creates)
    var cur = try #require(try rig.store.post(id: a.id))
    #expect(cur.state != .overdue && cur.state != .due)
    if case .retrying(let s, let line?)? = try rig.service.displayState(for: cur) {
      #expect(s == "Retry waits" && line.hasPrefix("Retrying when"))
    } else { Issue.record("not retrying") }
    #expect(!rig.notifier.delivered.contains { $0.postId == a.id && !$0.key.hasPrefix("postiz.retryWaits:") })
    try rig.f.updateSettings { $0 = before }
    rig.tick(3)
    cur = try #require(try rig.store.post(id: a.id))
    #expect(rig.fake.createCount == creates + 1)
    #expect(try rig.job(cur)?.phase == .live && cur.state != .overdue)
    #expect(try rig.job(cur)!.remoteDate.timeIntervalSince(rig.f.clock.now) < PostizService.leadTime + 60)
    #expect(try attempts(rig, x).count == 2)
    #expect(try rig.service.autoRetries(x).count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  /// Its time comes while the platform is on Manual, the same day: not a task for Eric, and not stuck on Today after.
  @Test func aRetryWaitingOnManualIsNeverDueByHand() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    try rig.f.updateSettings { $0.publishing.publishers[.x] = .manual }
    rig.tick()
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(120))
    rig.tick(2)
    #expect(!rig.notifier.delivered.contains { $0.postId == a.id })
    #expect(try rig.store.post(id: a.id)?.state != .due)
    try rig.f.updateSettings { $0.publishing.publishers[.x] = .postiz }
    rig.tick(2)
    #expect(try rig.job(a)?.phase == .live)
    #expect(try attempts(rig, x).count == 2)
  }

  /// On resume the time has passed, but another post went out meanwhile: the gap still holds.
  @Test func aRetryResumedKeepsTheGap() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    try rig.f.updateSettings { $0.pausedPlatforms.insert(.x) }
    rig.tick()
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(86400))
    try another(rig, x, at: rig.f.clock.now.addingTimeInterval(3600), state: .posted)
    try rig.f.updateSettings { $0.pausedPlatforms.remove(.x) }
    rig.tick(2)
    let job = try #require(try rig.job(a))
    #expect(job.remoteDate == rig.f.clock.now.addingTimeInterval(4 * 3600))
    #expect(try rig.store.post(id: a.id)?.scheduledAt == job.remoteDate)
  }

  @Test func aFailureReadDuringAPauseWaitsThenRunsOnce() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(60))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick(3)
    #expect(try attempts(rig, x).count == 1 && r8.problems(rig).isEmpty)
    let f = try #require(try rig.store.post(id: x.id))
    #expect(try rig.service.displayState(for: f) == .retrying("Retry waits", line: "Retrying when posting resumes"))
    rig.f.clock.advance(86400)
    rig.tick()
    try rig.f.updateSettings { $0.paused = false }
    rig.tick(3)
    #expect(try attempts(rig, x).count == 2)
    #expect(try rig.service.autoRetries(x).count == 1)
    #expect(try rig.job(attempts(rig, x)[1])?.phase == .live)
  }

  /// The real path: Remove from queue deletes the waiting attempt, Send to queue brings it back once, without using a try.
  @Test func aClipSentBackToEditWaitsAndRunsOnceOnReturn() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    let job = try #require(try rig.job(a))
    let bulk = BulkActions(store: rig.store)
    let r = try bulk.removeFromQueue([x.videoId])
    #expect(r.changed == [x.videoId])
    rig.tick(3)
    #expect(try rig.store.post(id: a.id) == nil)
    #expect(rig.fake.post(job.postizId!)?.deleted == true)
    #expect(try attempts(rig, x).count == 1)
    #expect(try r8.problems(rig).isEmpty)
    let f = try #require(try rig.store.post(id: x.id))
    #expect(f.resolution == nil)
    #expect(try rig.service.displayState(for: f) == .retrying("Retry waits", line: "Retrying when it's back in the Queue"))

    rig.f.clock.advance(2 * 86400)
    rig.tick()
    _ = try bulk.sendToQueue([x.videoId])
    rig.tick(4)
    let list = try attempts(rig, x)
    #expect(list.count == 2 && list[1].id != a.id)
    #expect(try rig.job(list[1])?.phase == .live)
    #expect(try rig.service.autoRetries(x).count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func undoingRemoveFromQueueRestoresTheAttemptAndMakesNoOther() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    let bulk = BulkActions(store: rig.store)
    let r = try bulk.removeFromQueue([x.videoId])
    _ = try bulk.undo(try #require(r.batchId), force: true)
    rig.tick(4)
    #expect(try attempts(rig, x).map(\.id) == [x.id, a.id])
    #expect(try rig.store.post(id: x.id)?.resolution == "retried")
    #expect(try rig.invariants().isEmpty)
  }

  @Test func fixedWhileARetryWaitsMakesOneAttempt() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(60))
    try rig.f.updateSettings { $0.pausedPlatforms.insert(.x) }
    rig.tick()
    let n = try PostActions(store: rig.store).fixed(postId: x.id)
    #expect(n.attemptNo == 2)
    try rig.f.updateSettings { $0.pausedPlatforms.remove(.x) }
    rig.tick(3)
    #expect(try attempts(rig, x).map(\.id) == [x.id, n.id])
    #expect(try rig.service.autoRetries(x).count == 0)
    #expect(try r8.events(rig, "automatic retry") == 0)
    #expect(try rig.service.pendingAutoRetries().isEmpty)
  }

  @Test func fixedAfterTheRetryIsRefusedAndMakesNoSecondAttempt() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    #expect(throws: EngineError.self) { try PostActions(store: rig.store).fixed(postId: x.id) }
    #expect(try attempts(rig, x).count == 2)
  }

  /// Fixed and the retry step on real connections, at the same moment: one attempt, whoever wins.
  @Test func fixedRacingTheRetry() throws {
    for _ in 0..<6 {
      let (rig, x) = try xRig()
      try rig.store.setHeldInEdit(x.videoId, true)
      try fail(rig, x)
      try rig.store.setHeldInEdit(x.videoId, false)
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r9-\(UUID().uuidString).sqlite").path
      defer { try? FileManager.default.removeItem(atPath: file) }
      try rig.store.db.backup(to: file)
      let stores = try (0..<2).map { _ in try Store(paths: rig.f.paths, clock: rig.f.clock, path: file) }
      let service = PostizService(store: stores[0], transport: rig.fake, keyStore: rig.keys)
      let actions = PostActions(store: stores[1])
      DispatchQueue.concurrentPerform(iterations: 2) { i in
        if i == 0 { _ = try? service.retryFailures() } else { _ = try? actions.fixed(postId: x.id) }
      }
      #expect(try stores[0].posts(where: "video_id=? AND platform='x'", [x.videoId]).count == 2)
    }
  }

  @Test func twoEnginesReadingTheSameFailureActOnce() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    let other = PostizService(store: rig.store, transport: rig.fake, keyStore: rig.keys)
    let engine2 = Engine(store: rig.store, renderer: rig.renderer, publisher: nil, notifier: rig.notifier, postiz: other)
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(60))
    rig.tick()
    engine2.tick(reason: "b")
    let stale = PostizRemotePost(id: j.postizId!, state: "ERROR", error: "Something went wrong")
    try other.errored(j, stale)  // the other process read it before the first closed the job
    rig.tick()
    #expect(try attempts(rig, x).count == 2)
    #expect(try rig.service.autoRetries(x).count == 1)
    #expect(try r8.events(rig, "automatic retry") == 1)
    #expect(try r8.events(rig, "failed in Postiz") == 1)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func aRetryOfATestRunStaysATestRunThroughEveryTry() throws {
    let (rig, x) = try xRig { $0.publishing.testMode = true }
    try rig.f.updateSettings { $0.publishing.testMode = false }
    var post = x
    for _ in 0..<3 {
      try fail(rig, post)
      rig.tick(2)
      post = try #require(try attempts(rig, x).last)
      let job = try #require(try rig.job(post))
      #expect(job.testMode && job.postType == "draft")
    }
  }

  @Test func aManualPlatformIsUnchanged() throws {
    let rig = try Rig(1, platforms: [.x])
    rig.settle()
    let tt = try #require(try rig.f.post(.tiktok, day: Self.monday))
    try PostActions(store: rig.store).reportProblem(postId: tt.id, type: .uploadFailed, message: "Upload failed by hand")
    rig.tick(3)
    #expect(try attempts(rig, tt).count == 1)
    #expect(try PostActions(store: rig.store).problems().contains { $0.id == tt.id })
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(tt.id)" })
  }

  /// A 400 on create goes to Today as always, with a retry too: it never waits for nothing.
  @Test func aRetryPostizRefusesGoesToToday() throws {
    let (rig, x) = try xRig()
    rig.fake.failNext["POST posts"] = [400]
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    let cur = try #require(try rig.store.post(id: a.id))
    #expect(cur.publisher == "manual")
    #expect(try !rig.service.isRetryAttempt(cur))
    guard case .fellBack? = try rig.service.displayState(for: cur) else { Issue.record("expected fellBack"); return }
  }

  // MARK: Review fixes

  /// The platform took the post and a later step failed: Postiz says ERROR, with the release. Never a second post.
  @Test(arguments: [Platform.x, .instagram, .threads, .facebook, .tiktok, .youtube])
  func anErrorWithAReleaseCountsAsPublished(_ platform: Platform) throws {
    let (rig, p) = try xRig([platform])
    let j = try #require(try rig.job(p))
    let creates = rig.fake.createCount
    rig.fake.publish(j.postizId!)
    try fail(rig, p, "Something went wrong")
    rig.tick(3)
    let cur = try #require(try rig.store.post(id: p.id))
    #expect(cur.state == .posted && cur.url != nil)
    #expect(try attempts(rig, p).count == 1 && r8.problems(rig).isEmpty)
    #expect(rig.fake.createCount == creates)
    #expect(try rig.store.postizJob(id: j.id)?.closeReason == .published)
    #expect(try rig.invariants().isEmpty)
  }

  @Test func aReleaseIdAloneCountsAndSoDoesMissing() {
    #expect(PostizRemotePost(id: "a", state: "ERROR", releaseId: "123").hasRelease)
    #expect(PostizRemotePost(id: "a", state: "ERROR", releaseURL: "https://x.com/1").hasRelease)
    #expect(PostizRemotePost(id: "a", state: "ERROR", releaseId: "missing").hasRelease)
    #expect(!PostizRemotePost(id: "a", state: "ERROR", releaseURL: "", releaseId: "").hasRelease)
    #expect(!PostizRemotePost(id: "a", state: "ERROR").hasRelease)
  }

  /// `missing` is a post that went out with no id: posted, no link, and Doctor's link_missing takes it from there.
  @Test(arguments: [Platform.tiktok, .instagram, .x])
  func anErrorWithAMissingReleaseCountsAsPublished(_ platform: Platform) throws {
    let (rig, p) = try xRig([platform])
    let j = try #require(try rig.job(p))
    let creates = rig.fake.createCount
    rig.fake.publish(j.postizId!, url: "", releaseId: "missing")
    try fail(rig, p, "Something went wrong")
    rig.tick(3)
    let cur = try #require(try rig.store.post(id: p.id))
    #expect(cur.state == .posted && cur.url == nil)
    #expect(try attempts(rig, p).count == 1 && rig.fake.createCount == creates)
    #expect(try rig.service.linkMissingPosts().map(\.id) == [p.id])
  }

  /// Wording that says it landed is the likeliest shape of a failure after a live post. It doesn't retry.
  @Test func wordingThatSaysItLandedStaysWithEricThroughTheWholePath() throws {
    let (rig, x) = try xRig()
    try fail(rig, x, "Media published but permalink lookup failed")
    rig.tick(2)
    #expect(try attempts(rig, x).count == 1 && r8.problems(rig) == [x.id])
  }

  /// D1: no release, unknown wording: it retries, an accepted risk off YouTube. YouTube stays with Eric.
  @Test func anUnknownErrorWithNoReleaseRetriesExceptOnYouTube() throws {
    let (rig, x) = try xRig()
    try fail(rig, x, nil)
    #expect(try attempts(rig, x).count == 2)
    let (rig2, yt) = try xRig([.youtube])
    try fail(rig2, yt, nil)
    #expect(try attempts(rig2, yt).count == 1 && r8.problems(rig2) == [yt.id])
  }

  /// The stale copy from the publish loop's list must not undo what Eric did meanwhile.
  @Test(arguments: ["posted", "skipped", "removed"])
  func aStaleRetimeNeverOverwritesEric(_ what: String) throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    let settings = try rig.store.settings()
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(600))
    let stale = try #require(try rig.store.post(id: a.id))  // what the loop read
    let actions = PostActions(store: rig.store)
    switch what {
    case "posted": try actions.markPosted(postId: a.id, url: "https://x.com/lovd/status/1")
    case "skipped": try actions.skip(postId: a.id)
    default: try rig.store.deletePost(a.id)
    }
    #expect(try rig.service.retimeRetry(stale, settings: settings) == nil)
    let cur = try rig.store.post(id: a.id)
    if what == "posted" { #expect(cur?.state == .posted && cur?.url != nil) }
    if what == "skipped" { #expect(cur?.state == .skipped) }
    if what == "removed" { #expect(cur == nil) }
  }

  /// A retry waited, Eric reset the post, and it failed for a reason a retry can't fix: loud, whatever the kv row says.
  @Test func aResetFailureThatFailsVetoedIsLoud() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.pausedPlatforms.insert(.x) }
    rig.tick()
    #expect(try r8.problems(rig).isEmpty)
    try PostActions(store: rig.store).reset(postId: x.id)
    #expect(try rig.service.autoRetries(x).failedPostId == nil)
    try rig.f.updateSettings { $0.pausedPlatforms.remove(.x) }
    rig.tick(2)
    let job = try #require(try rig.job(x))
    rig.fake.fail(job.postizId!, error: "Video longer than 2:20")
    rig.f.clock.advance(3600)
    rig.tick(2)
    #expect(try r8.problems(rig) == [x.id])
    #expect(rig.notifier.delivered.contains { $0.key == "problem:\(x.id)" })
  }

  /// A row left by anything at all doesn't hide a failure: the failure itself has to be the kind that retries.
  @Test func aLeftoverPromiseCantHideAFailure() throws {
    let (rig, x) = try xRig()
    var r = PostizAutoRetries()
    r.failedPostId = x.id
    try rig.store.setKV(PostizService.autoRetryKey(x), r)
    try PostActions(store: rig.store).reportProblem(postId: x.id, type: .uploadFailed, message: "Failed by hand")
    #expect(try r8.problems(rig) == [x.id])

    // And a row beside a vetoed failure from Postiz.
    let (rig2, y) = try xRig()
    try fail(rig2, y, "Video longer than 2:20")
    try rig2.store.setKV(PostizService.autoRetryKey(y), r2(y))
    #expect(try r8.problems(rig2) == [y.id])
  }

  func r2(_ p: PlatformPost) -> PostizAutoRetries {
    var r = PostizAutoRetries()
    r.failedPostId = p.id
    return r
  }

  /// Excluded after its attempt exists: it can't render, so it can't go. A day late it comes back to Eric with a reason.
  @Test func anAttemptThatCantBeSentGoesBackToEric() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    #expect(try rig.job(a) == nil)
    var v = try #require(try rig.store.video(id: x.videoId))
    v.excluded = true
    try rig.store.save(v)
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(PostizService.stuckAfter + 3600))
    rig.tick(3)
    #expect(try rig.service.isRetryAttempt(a))  // not after a few ticks: a Mac that just woke looks the same
    var r = try rig.service.autoRetries(a)
    r.unsentTicks = PostizService.maxUnsentTicks - 1
    try rig.store.setKV(PostizService.autoRetryKey(a), r)
    rig.tick(2)
    let cur = try #require(try rig.store.post(id: a.id))
    #expect(try !rig.service.isRetryAttempt(cur))
    #expect(cur.state == .overdue && cur.errorMessage?.contains("couldn't reach Postiz for a day") == true)
    #expect(try PostActions(store: rig.store).problems().contains { $0.id == a.id })
    if case .retrying? = try rig.service.displayState(for: cur) { Issue.record("still says retrying") }
  }

  /// Nothing sits silently: a retry stuck on a setting or a pause alerts once, a day past its time, and keeps waiting.
  @Test(arguments: ["manual", "paused", "pausedAll"])
  func aRetryStuckForADayAlertsOnce(_ how: String) throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    try rig.f.updateSettings { s in
      switch how {
      case "manual": s.publishing.publishers[.x] = .manual
      case "paused": s.pausedPlatforms.insert(.x)
      default: s.paused = true
      }
    }
    rig.tick()
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(PostizService.stuckAfter - 600))
    rig.tick(2)
    let key = "postiz.retryWaits:\(a.id)"
    #expect(!rig.notifier.delivered.contains { $0.key == key })
    rig.f.clock.set(a.scheduledAt.addingTimeInterval(PostizService.stuckAfter + 600))
    rig.tick(3)
    #expect(rig.notifier.delivered.filter { $0.key == key }.count == 1)
    #expect(try rig.service.isRetryAttempt(a))
  }

  @Test func aFailureWaitingOnAPauseAlertsToo() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    rig.f.clock.advance(2 * 86400)
    rig.tick()
    #expect(rig.notifier.delivered.contains { $0.key == "postiz.retryWaits:\(x.id)" })
  }

  /// Eric took the clip out of the plan while a retry waited: it doesn't fire on resume.
  @Test func anUnscheduledClipDoesntRetry() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    let r = try BulkActions(store: rig.store).back([x.videoId])
    #expect(r.changed == [x.videoId])
    try rig.f.updateSettings { $0.paused = false }
    rig.tick(3)
    #expect(try attempts(rig, x).count == 1)
    #expect(try rig.store.post(id: x.id)?.resolution == "unscheduled")
    #expect(try rig.service.pendingAutoRetries().isEmpty)
  }

  /// `djq posted` on the failed row: the attempt waiting in Postiz must not go out too.
  @Test func markingTheFailedRowPostedClosesItsAttempt() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    let job = try #require(try rig.job(a))
    try PostActions(store: rig.store).markPosted(postId: x.id, url: "https://x.com/lovd/status/1")
    rig.tick(3)
    #expect(try rig.store.post(id: a.id)?.state == .skipped)
    #expect(rig.fake.post(job.postizId!)?.deleted == true)
    #expect(try rig.service.pendingAutoRetries().isEmpty)
    #expect(try rig.invariants().isEmpty)
  }

  /// `djq problem` on a waiting failure: a report by hand ends the promise, so it's a Problem, not a retry that never fires.
  @Test func aHandReportOnAWaitingFailureIsLoud() throws {
    let (rig, x) = try xRig()
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    #expect(try r8.problems(rig).isEmpty)
    try PostActions(store: rig.store).reportProblem(postId: x.id, type: .uploadFailed, message: "Eric says it's broken")
    #expect(try r8.problems(rig) == [x.id])
  }

  /// Removing the day takes its retry too: Eric took it out, and a post of that day doesn't go out after that.
  @Test func removingTheDayTakesTheRetry() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    rig.tick(2)
    let a = try #require(try attempts(rig, x).last)
    let job = try #require(try rig.job(a))
    try Planner(store: rig.store).remove(slotId: try #require(x.planSlotId))
    rig.tick(3)
    #expect(try rig.store.post(id: a.id) == nil)
    #expect(rig.fake.post(job.postizId!)?.deleted == true)
    #expect(try attempts(rig, x).count == 1 && rig.service.pendingAutoRetries().isEmpty)
  }

  /// A promise given up refreshes the clip: it counted that post as still going.
  @Test func aRetryGivenUpLeavesTheClipFinished() throws {
    let (rig, x) = try xRig()
    try rig.f.updateSettings { $0.enabledPlatforms = [.x] }
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    #expect(try rig.store.video(id: x.videoId)?.state == .planned)
    var e = try rig.store.edit(videoId: x.videoId)
    e.skippedPlatforms = [.x]
    try rig.store.save(e, videoId: x.videoId)
    try rig.f.updateSettings { $0.paused = false }
    rig.tick()
    #expect(try r8.problems(rig) == [x.id])
    #expect(try rig.store.video(id: x.videoId)?.state != .planned)
  }

  @Test func waitingBehindAnotherPostSaysSo() throws {
    let (rig, x) = try xRig()
    try another(rig, x, at: rig.f.clock.now.addingTimeInterval(30 * 86400))
    var other = try #require(try rig.store.posts(where: "video_id=? AND version_no=9", [x.videoId]).first)
    other.versionNo = 1
    try rig.store.save(other, note: "test")
    try fail(rig, x)
    let f = try #require(try rig.store.post(id: x.id))
    #expect(try rig.service.displayState(for: f) == .retrying("Retry waits", line: "Retrying when its other post is done"))
  }

  @Test func aSecondFailureWhileWaitingIsListedOnce() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    rig.tick(2)
    let job = try #require(try rig.job(a))
    rig.fake.fail(job.postizId!, error: "Something went wrong")
    rig.f.clock.set(job.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.pausedPlatforms.insert(.x) }
    rig.tick()
    #expect(try rig.service.pendingAutoRetries().count == 1)
  }

  /// A clip whose only platform has a retry coming isn't finished.
  @Test func aWaitingFailureLeavesTheClipScheduledAndTheCardSaysRetrying() throws {
    let (rig, x) = try xRig()
    try rig.f.updateSettings { $0.enabledPlatforms = [.x] }
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(700))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick()
    #expect(try rig.store.video(id: x.videoId)?.state == .planned)
    let f = try #require(try rig.store.post(id: x.id))
    #expect(PostGrouping.summary([f], retrying: [f.id]) == "1 platform · retrying")
    #expect(PostGrouping.summary([f]) == "1 platform · failed")
  }

  // MARK: The inbox guard stays

  /// Post 4ab3180d: closed as `inbox` and sent outside DJ Queue. A closed test-run inbox job still blocks everything.
  @Test func aClosedInboxJobStillBlocksARetry() throws {
    let (rig, tt) = try xRig([.tiktok]) { $0.publishing.testMode = true }
    let j = try #require(try rig.job(tt))
    rig.fake.publish(j.postizId!)
    rig.f.clock.set(j.remoteDate.addingTimeInterval(60))
    rig.tick()
    #expect(try rig.store.finalPostizJob(postId: tt.id)?.closeReason == .inbox)
    let creates = rig.fake.createCount
    rig.tick(3)
    rig.f.clock.advance(3 * 86400)
    rig.tick(3)
    #expect(rig.fake.createCount == creates)
    #expect(try rig.service.retryRuledOut(tt))
    #expect(try rig.store.publishedPostizJob(lineage: PostizJob.lineage(tt)) != nil)
  }

  // MARK: Status

  @Test func statusAndDoctorSayWhenAndWhatItWaitsFor() throws {
    let (rig, x) = try xRig()
    try fail(rig, x)
    let a = try #require(try attempts(rig, x).last)
    var st = try rig.service.status()
    #expect(st.retries.first?.post == a.id && st.retries.first?.at == a.scheduledAt && st.retries.first?.text.hasPrefix("Retrying ") == true
            && st.retries.first?.text.contains(" of ") == false)
    try rig.f.updateSettings { $0.publishing.publishers[.x] = .manual }
    rig.tick()
    st = try rig.service.status()
    #expect(st.retries.first?.waiting?.hasSuffix("is back on Postiz") == true)
    let finding = try #require(DoctorPostizTests.postiz(DoctorPostizTests.doctor(rig.store, keys: rig.keys).run())["postiz.auto_retry"])
    #expect(finding.severity == .warning)  // this one needs Eric's setting back, or a hand post
  }

  // MARK: Fuzz

  /// Whatever happens to it, a clip + platform never has two live jobs or two live posts, and Postiz never holds or
  /// publishes two copies. The total at the end proves the runs really went through retries.
  @Test func fuzz() throws {
    var retries = 0, waited = 0, published = 0
    for seed in UInt64(1)...24 {
      var rng = Seeded(seed)
      let (rig, x) = try xRig()
      let bulk = BulkActions(store: rig.store)
      let actions = PostActions(store: rig.store)
      let errors = ["Something went wrong", "Rate limit reached", nil, "503 Service Unavailable", "Video longer than 2:20"]
      for step in 0..<80 {
        let held = try rig.store.video(id: x.videoId)?.heldInEdit == true
        let list = try attempts(rig, x)
        switch rng.next() % 14 {
        case 0...4:
          // A post Postiz published can fail too, in a later step: the fake keeps its release, and that must never resend.
          if let j = try rig.store.postizJobs(where: "video_id=? AND platform='x' AND closed_at IS NULL AND phase='live' AND kind='post'", [x.videoId]).first {
            rig.fake.fail(j.postizId!, error: errors[Int(rng.next() % UInt64(errors.count))])
            rig.f.clock.set(max(rig.f.clock.now, j.remoteDate).addingTimeInterval(Double(rng.next() % 3) * 3600 + 700))
          }
        case 5: rig.f.clock.advance(Double(rng.next() % 12) * 3600 + 700)
        case 6: rig.f.clock.advance(Double(rng.next() % 3) * 86400 + 700)
        case 7: try rig.f.updateSettings { $0.paused.toggle() }
        case 8: try rig.f.updateSettings { s in
          if s.pausedPlatforms.contains(.x) { s.pausedPlatforms.remove(.x) } else { s.pausedPlatforms.insert(.x) }
        }
        case 9: try rig.f.updateSettings { s in s.publishing.publishers[.x] = s.publishing.publisher(for: .x) == .postiz ? .manual : .postiz }
        case 10:
          if held { _ = try bulk.sendToQueue([x.videoId]) }
          // Once a failure exists: before that it only takes the clip out of the plan, and the run ends there.
          else if list.count > 1 || list.first?.state == .failed { _ = try bulk.removeFromQueue([x.videoId]) }
        case 11:
          if let f = list.last(where: { $0.state == .failed && $0.resolution == nil }) { _ = try? actions.fixed(postId: f.id) }
        case 12:
          // Not at once: it ends the retries, and the guards after a publish are what's left to prove.
          if step > 15, let j = try rig.store.postizJobs(where: "video_id=? AND platform='x' AND closed_at IS NULL AND phase='live' AND kind='post'", [x.videoId]).first {
            rig.f.clock.set(max(rig.f.clock.now, j.remoteDate.addingTimeInterval(60)))
            rig.fake.publishDue(now: rig.f.clock.now)
          }
        default: try rig.f.updateSettings { s in s.paused = false; s.pausedPlatforms = []; s.publishing.publishers[.x] = .postiz }
        }
        let before = try rig.store.posts(where: "video_id=? AND state='failed' AND resolution IS NULL", [x.videoId]).count
        rig.tick(1 + Int(rng.next() % 2))
        if try before > 0 && rig.service.pendingAutoRetries().contains(where: { $0.waiting != nil }) { waited += 1 }
        let bad = try rig.invariants()
        #expect(bad.isEmpty, "seed \(seed) step \(step): \(bad)")
        let live = try attempts(rig, x).filter { !$0.state.isTerminal }
        #expect(live.count <= 1, "seed \(seed) step \(step): live \(live.map(\.id))")
        let open = try rig.store.postizJobs(where: "video_id=? AND platform='x' AND closed_at IS NULL AND kind='post'", [x.videoId])
        #expect(open.filter { $0.phase != .deleting }.count <= 1, "seed \(seed) step \(step): open \(open.map(\.id))")
        #expect(try rig.service.autoRetries(x).count >= 0)
      }
      retries += try rig.service.autoRetries(x).count
      if !rig.fake.everPublished.isEmpty { published += 1 }
    }
    #expect(retries >= 24 && waited >= 24 && published >= 2, "retries \(retries), waited \(waited), published \(published)")
  }

  struct Seeded {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
      s ^= s << 13
      s ^= s >> 7
      s ^= s << 17
      return s
    }
  }
}
