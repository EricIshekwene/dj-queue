import Foundation
import Testing
@testable import DJQCore

/// Round 22: failed posts heal themselves. No retry cap; YouTube quota retries go to the next YouTube slot after midnight
/// Pacific (the window rules are in `R17YouTubeWindowTests`); every retry and any media older than three days goes up
/// fresh; a media error retries quietly everywhere; a channel whose sign-in broke is one item per platform and its posts
/// wait, then go out by themselves. See DECISIONS-R22.md.
@Suite struct R22SelfHealingTests {
  typealias Rig = R6PostizLifecycleTests.Rig

  static let quota = R8PostizRetryTests.quota
  static let monday = R8PostizRetryTests.monday
  static let signIn = "Error validating access token: Session has expired"
  let r8 = R8PostizRetryTests()
  let r9 = R9PostizRetryTests()

  func utc(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    let p = day.split(separator: "-").compactMap { Int($0) }
    return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute))!
  }

  func settled(_ n: Int = 1, _ platforms: [Platform], change: ((inout Settings) -> Void)? = nil) throws -> Rig {
    let rig = try Rig(n, platforms: platforms, change: change)
    rig.settle()
    return rig
  }

  func post(_ rig: Rig, _ p: Platform, day: String = monday) throws -> PlatformPost { try #require(try rig.f.post(p, day: day)) }

  /// Postiz errors the post's job at its time; the Mac sees it a minute later.
  @discardableResult
  func fail(_ rig: Rig, _ p: PlatformPost, _ error: String?) throws -> PostizJob { try r9.fail(rig, p, error) }

  func notes(_ rig: Rig, _ prefix: String) -> [AppNotification] { rig.notifier.delivered.filter { $0.key.hasPrefix(prefix) } }

  // MARK: R4 (d) and R5: reading the error, both ways

  static let mediaMessages = ["Media upload expired", "The media file could not be retrieved", "Failed to fetch media from URL: 404",
                              "Upload URL is invalid or expired", "File not found", "Could not download the file from the provided URL",
                              "media not found", "The uploaded file has expired, upload it again"]

  @Test(arguments: mediaMessages)
  func aMediaProblemRetriesOnEveryPlatform(_ m: String) {
    #expect(PostizService.isMediaProblem(m))
    for p in Platform.allCases {
      #expect(PostizService.classify(m, on: p) == .media, "\(p.rawValue): \(m)")
      #expect(PostizService.retriesByItself(m, on: p))
    }
  }

  static let signInMessages = [signIn, "access_token_invalid", "scope_not_authorized", "Please re-authenticate your account",
                               "Refresh token expired, reconnect the channel", "You need to log in", "Please reauthorize the app",
                               "Unauthenticated", "Request failed with status code 401", "Token expired",
                               "Your login expired, sign in again", "Media upload failed: access token expired"]

  /// A sign-in or token "expired" is never a media problem: it's the channel's login.
  @Test(arguments: signInMessages)
  func aSignInProblemIsNeverMedia(_ m: String) {
    #expect(!PostizService.isMediaProblem(m))
    for p in Platform.allCases { #expect(PostizService.classify(m, on: p) == .signIn, "\(p.rawValue): \(m)") }
  }

  @Test(arguments: [
    (Platform.instagram, "Unsupported video format"), (.threads, "Missing required field: media"),
    (.instagram, "Media published but permalink lookup failed"), (.instagram, "This media has already been posted"),
    (.facebook, "Your video violates our Community Standards"), (.facebook, "The video file you tried to upload is too large."),
    (.x, "Request failed with status code 403"), (.x, "Your account is suspended"), (.tiktok, "Media expired: your account is banned"),
    (.youtube, "We uploaded your video but the thumbnail URL expired"), (.youtube, "Rate limit reached while setting the thumbnail"),
    (.youtube, "Internal server error"), (.x, "Video longer than 2:20"),
  ] as [(Platform, String)])
  func whatARetryCantFixStays(_ p: Platform, _ m: String) {
    #expect(PostizService.classify(m, on: p) == .stays, "\(m)")
    #expect(!PostizService.retriesByItself(m, on: p))
  }

  @Test func copyrightStaysCopyrightWhateverElseItSays() {
    for m in ["Copyright claim: media not found", "Music rights: session expired"] {
      #expect(PostizService.classify(m, on: .instagram) == .copyright)
    }
  }

  // MARK: R2

  /// Monday's 10:00 am YouTube post (15:00 UTC, 7 am Pacific) hits the quota: Tuesday's 10:00 am slot, after midnight Pacific.
  @Test func aYouTubeQuotaFailureRetriesOnTheNextSlotAfterMidnightPacific() throws {
    let rig = try settled(1, [.youtube]) { s in
      s.enabledPlatforms = [.youtube]
      s.slotMinutes[.youtube] = 10 * 60
    }
    let yt = try post(rig, .youtube)
    #expect(yt.scheduledAt == utc("2026-11-02", 15))
    try fail(rig, yt, Self.quota)
    let a = try #require(try r8.attempts(rig, yt).last)
    #expect(a.kind == .retry && a.scheduledAt == utc("2026-11-03", 15))
    rig.tick(2)
    #expect(try rig.job(a)?.remoteDate == utc("2026-11-03", 15))
    #expect(try r8.problems(rig).isEmpty)
  }

  // MARK: R3

  /// What v0.15 left after five tries: no promise, the count at five and its "used up" note. It is no Problem any more,
  /// before any tick, and the retry step re-queues it by itself, taking the old note off.
  @Test func aFailureAnOlderBuildGaveUpOnReQueuesByItself() throws {
    let rig = try settled(1, [.x])
    let x = try post(rig, .x)
    let j = try #require(try rig.job(x))
    rig.fake.fail(j.postizId!, error: "Something went wrong")
    rig.f.clock.set(j.remoteDate.addingTimeInterval(60))
    try rig.f.updateSettings { $0.paused = true }
    rig.tick(2)  // read during a pause: a promise and no attempt
    #expect(try r8.attempts(rig, x).count == 1)
    var r = try rig.service.autoRetries(x)
    r.failedPostId = nil
    r.count = 5
    r.nextRetryAt = nil
    try rig.store.setKV(PostizService.autoRetryKey(x), r)
    var f = try #require(try rig.store.post(id: x.id))
    f.errorMessage = "Something went wrong — automatic retries used up, mark Fixed when it's ready"
    try rig.store.save(f, note: "test")
    #expect(try PostActions(store: rig.store).problems().isEmpty)
    try rig.f.updateSettings { $0.paused = false }
    rig.tick(2)
    let list = try r8.attempts(rig, x)
    #expect(list.count == 2 && list[1].kind == .retry)
    let cur = try #require(try rig.store.post(id: x.id))
    #expect(cur.resolution == "retried" && cur.errorMessage == "Something went wrong — retrying automatically")
    #expect(try rig.service.autoRetries(x).count == 6)
    #expect(try rig.job(list[1])?.phase == .live)
    #expect(notes(rig, "problem:").isEmpty)
  }

  /// The quiet backoff past three: the next slot, every day.
  @Test func fromTheThirdRetryItIsThePlatformsNextSlot() throws {
    var s = Settings()
    s.slotMinutes[.tiktok] = 19 * 60
    let dm = DayMath(settings: s)
    let t = dm.at("2026-11-04", minutes: 18 * 60 + 30)
    for n in [3, 6, 20] {
      #expect(PostizRetrySchedule.next(after: t, retry: n, platform: .tiktok, settings: s) == dm.at("2026-11-05", minutes: 19 * 60))
    }
    #expect(PostizRetrySchedule.next(after: dm.at("2026-11-04", minutes: 17 * 60), retry: 3, platform: .tiktok, settings: s)
            == dm.at("2026-11-04", minutes: 19 * 60))
  }

  // MARK: R4

  /// (a) Every automatic retry uploads its media again: Postiz's link from the first upload may be gone by then.
  @Test func everyAutomaticRetryUploadsItsMediaAgain() throws {
    let rig = try settled(1, [.x])
    let first = try post(rig, .x)
    var p = first
    for n in 1...2 {
      let uploads = rig.fake.uploadCount
      try fail(rig, p, "Something went wrong")
      rig.tick(2)
      p = try #require(try r8.attempts(rig, first).last)
      #expect(p.attemptNo == n + 1 && p.renderId == first.renderId, "retry \(n)")
      #expect(try rig.job(p)?.phase == .live, "retry \(n)")
      #expect(rig.fake.uploadCount > uploads, "retry \(n)")
      #expect(try rig.store.postizMedia(renderId: p.renderId!, kind: "video")!.uploadedAt >= p.createdAt)
    }
  }

  /// (b) Cached media older than three days goes up again at create; younger is reused.
  @Test func mediaUploadedMoreThanThreeDaysAgoGoesUpAgain() throws {
    let rig = try settled(1, [.x, .threads, .instagram]) { s in
      s.publishing.publishers[.threads] = .manual
      s.publishing.publishers[.instagram] = .manual
    }
    let x = try post(rig, .x), th = try post(rig, .threads), ig = try post(rig, .instagram)
    let rid = try #require(x.renderId)
    #expect(th.renderId == rid && ig.renderId == rid)
    let age = { (days: Double) in
      try rig.store.db.run("UPDATE postiz_media SET uploaded_at=? WHERE render_id=?", [rig.f.clock.now.addingTimeInterval(-days * 86400), rid])
    }
    try age(2)
    var uploads = rig.fake.uploadCount
    try rig.f.updateSettings { $0.publishing.publishers[.threads] = .postiz }
    rig.tick(2)
    #expect(try rig.job(th)?.phase == .live && rig.fake.uploadCount == uploads)  // reused
    try age(4)
    #expect(try rig.service.freshMedia(rid, "video", for: ig) == nil)
    uploads = rig.fake.uploadCount
    try rig.f.updateSettings { $0.publishing.publishers[.instagram] = .postiz }
    rig.tick(2)
    #expect(try rig.job(ig)?.phase == .live && rig.fake.uploadCount > uploads)
    #expect(try rig.store.postizMedia(renderId: rid, kind: "video")?.uploadedAt == rig.f.clock.now)
  }

  /// (c) Postiz refuses a create over media it forgot: the cache goes and the next pass uploads it again, with no
  /// refusal, no fallback and no notification. Once: a second refusal, with fresh media, is a normal refusal.
  @Test func aCreateRefusedOverCachedMediaUploadsAgainQuietlyOnce() throws {
    let rig = try settled(1, [.x, .threads, .instagram]) { s in
      s.publishing.publishers[.threads] = .manual
      s.publishing.publishers[.instagram] = .manual
    }
    let th = try post(rig, .threads), ig = try post(rig, .instagram)
    var uploads = rig.fake.uploadCount
    rig.fake.expireMedia()  // a create naming the old upload is refused: "media not found"
    try rig.f.updateSettings { $0.publishing.publishers[.threads] = .postiz }
    rig.tick()
    #expect(try rig.store.finalPostizJob(postId: th.id) == nil && rig.job(th) == nil)
    #expect(try rig.store.postizMedia(renderId: th.renderId!, kind: "video") == nil || rig.fake.uploadCount > uploads)
    rig.tick()
    #expect(try rig.job(th)?.phase == .live && rig.fake.uploadCount > uploads)
    #expect(notes(rig, "postiz.rejected").isEmpty)
    if case .fellBack? = try rig.service.displayState(for: rig.store.post(id: th.id)!) { Issue.record("fell back to manual") }
    // Twice for Instagram: quiet the first time (cached media), refused the second (its media was fresh).
    uploads = rig.fake.uploadCount
    rig.fake.createRefusals = ["Media URL expired", "Media URL expired"]
    try rig.f.updateSettings { $0.publishing.publishers[.instagram] = .postiz }
    rig.tick()
    #expect(try rig.store.finalPostizJob(postId: ig.id) == nil)
    rig.tick()
    #expect(try rig.store.finalPostizJob(postId: ig.id)?.closeReason == .rejected)
    #expect(rig.fake.uploadCount > uploads)
    #expect(notes(rig, "postiz.rejected").count == 1)
  }

  /// (d) A Postiz ERROR saying the media couldn't be fetched retries everywhere, YouTube too (no video was made), on the
  /// regular backoff, and the retry uploads it again.
  @Test(arguments: [Platform.youtube, .tiktok])
  func aMediaErrorRetriesWithFreshMedia(_ platform: Platform) throws {
    let rig = try settled(1, [platform])
    let first = try post(rig, platform)
    let uploads = rig.fake.uploadCount
    let j = try fail(rig, first, "The media file could not be retrieved (404)")
    let a = try #require(try r8.attempts(rig, first).last)
    #expect(a.kind == .retry && a.scheduledAt == j.remoteDate.addingTimeInterval(3600))  // +1 h: it's not the quota
    #expect(try r8.problems(rig).isEmpty)
    #expect(try rig.store.post(id: first.id)?.errorMessage?.hasSuffix(PostizService.retryingNote) == true)
    rig.tick(2)
    #expect(try rig.job(a)?.phase == .live && rig.fake.uploadCount > uploads)
  }

  // MARK: R5

  /// Problems hold only what needs Eric: copyright, a failure a retry can't fix and a YouTube error where the video may
  /// exist. A retry coming and a channel's sign-in are not posts' problems.
  @Test func problemsHoldOnlyWhatNeedsEric() throws {
    let rig = try settled(1, [.x, .tiktok, .youtube, .instagram, .threads])
    let x = try post(rig, .x), tt = try post(rig, .tiktok), yt = try post(rig, .youtube), ig = try post(rig, .instagram)
    let th = try post(rig, .threads)
    for (p, m) in [(x, "Video longer than 2:20"), (tt, Self.signIn), (yt, "Internal server error"),
                   (ig, "This audio isn't available: the song is restricted by its rights holder"), (th, "Service temporarily unavailable")] {
      let j = try #require(try rig.job(p))
      rig.fake.fail(j.postizId!, error: m)
    }
    rig.f.clock.set(rig.f.at(Self.monday, "23:30"))
    rig.tick(3)
    #expect(Set(try r8.problems(rig)) == [x.id, yt.id, ig.id])
    #expect(try AgentAPI.posts(store: rig.store, problems: true).map(\.id).sorted() == [x.id, yt.id, ig.id].sorted())
    #expect(try rig.service.signInProblems().map(\.platform) == [.tiktok])
    #expect(Set(notes(rig, "problem:").compactMap(\.postId)) == [x.id, yt.id, ig.id])
    #expect(try r8.attempts(rig, th).count == 2)  // the temporary one retried quietly
    let doctor = DoctorPostizTests.doctor(rig.store, keys: rig.keys).run()
    #expect(doctor.findings.first { $0.id == "posts.failed" }?.where_.contains { $0.contains(tt.id) } == false)
    #expect(doctor.findings.first { $0.id == "postiz.sign_in" }?.where_ == ["tiktok"])
  }

  /// Three TikTok posts fail on the channel's sign-in: one item, one notification, no red failures, no attempts while
  /// it's out, never handed to the Calendar or dropped; reconnected (the list says so), all three go out by themselves.
  @Test func aSignInOutageIsOneItemThenEveryPostResumes() throws {
    let rig = try settled(3, [.tiktok, .x])
    let tts = try rig.f.posts(.tiktok).sorted { $0.scheduledAt < $1.scheduledAt }
    #expect(tts.count == 3)
    for p in tts {
      let j = try #require(try rig.job(p))
      rig.fake.fail(j.postizId!, error: Self.signIn)
    }
    rig.f.clock.set(tts[0].scheduledAt.addingTimeInterval(60))
    rig.tick(3)
    let creates = rig.fake.calls("POST posts").count
    #expect(try r8.problems(rig).isEmpty)
    let items = try rig.service.signInProblems()
    #expect(items.count == 1 && items[0].platform == .tiktok && items[0].waiting == 3)
    #expect(items[0].summary == "Reconnect TikTok in Postiz · 3 posts wait")
    #expect(notes(rig, "postiz.signIn:tiktok:").count == 1 && notes(rig, "problem:").isEmpty)
    for p in tts {
      #expect(try r8.attempts(rig, p).count == 1)  // no attempt while the channel is out
      #expect(try rig.service.displayState(for: rig.store.post(id: p.id)!)
              == .retrying(PostizService.signInBadge, line: "Retrying once TikTok is reconnected in Postiz"))
    }
    // Hours out: still waiting, nothing made, nothing sent.
    rig.f.clock.advance(5 * 3600)
    rig.tick(2)
    #expect(try rig.store.posts(where: "platform='tiktok'").count == 3 && rig.fake.calls("POST posts").count == creates)
    // A day and more out (one timed try went to Postiz meanwhile): no per-post alert, nothing handed over or dropped,
    // still the one item.
    rig.f.clock.advance(26 * 3600)
    rig.tick(2)
    #expect(rig.fake.calls("POST posts").count == creates + 1)
    #expect(notes(rig, "postiz.retryWaits").isEmpty && notes(rig, "postiz.signIn:tiktok:").count == 1)
    #expect(try rig.service.signInProblems().count == 1 && r8.problems(rig).isEmpty)
    let waiting = try rig.store.posts(where: "platform='tiktok' AND kind='retry'").filter { try rig.job($0) == nil }
    #expect(waiting.count == 2)
    for a in waiting {
      #expect(try rig.service.displayState(for: a) == .retrying(PostizService.signInBadge, line: "Retrying once TikTok is reconnected in Postiz"))
      #expect(a.state != .overdue && a.errorMessage == nil)
    }
    // The list says it needs a refresh, then that it's fine again: reconnected. Everything goes out by itself.
    func flag(_ on: Bool) throws {
      rig.fake.integrations = rig.fake.integrations.map { var c = $0; if c.platform == .tiktok { c.refreshNeeded = on }; return c }
      _ = try rig.service.channels()
      rig.tick()
    }
    try flag(true)
    #expect(try rig.service.signInWait(.tiktok)?.flagged == true)
    #expect(rig.fake.calls("POST posts").count == creates + 1)
    try flag(false)
    rig.tick(2)
    #expect(try rig.service.signInWait(.tiktok) == nil && rig.service.signInProblems().isEmpty)
    let attempts = try rig.store.posts(where: "platform='tiktok' AND kind='retry'")
    #expect(attempts.count == 3)
    #expect(try attempts.allSatisfy { try rig.job($0)?.phase == .live })
    #expect(rig.fake.calls("POST posts").count == creates + 3)
    #expect(notes(rig, "postiz.signIn:tiktok:").count == 1)
    #expect(try rig.invariants().isEmpty)
  }

  /// No word from the channel list: one post tries again every six hours; once one goes out, the rest follow.
  @Test func withNoWordFromTheListOnePostTriesEverySixHours() throws {
    let rig = try settled(2, [.tiktok])
    let tts = try rig.f.posts(.tiktok).sorted { $0.scheduledAt < $1.scheduledAt }
    for p in tts {
      let j = try #require(try rig.job(p))
      rig.fake.fail(j.postizId!, error: Self.signIn)
    }
    rig.f.clock.set(tts[0].scheduledAt.addingTimeInterval(60))
    rig.tick(3)
    let creates = rig.fake.createCount
    rig.f.clock.advance(3 * 3600)
    rig.tick(2)
    #expect(rig.fake.createCount == creates)
    rig.f.clock.advance(3 * 3600 + 60)
    rig.tick(2)
    #expect(rig.fake.createCount == creates + 1)  // one try
    let tried = try #require(try rig.store.posts(where: "platform='tiktok' AND kind='retry'").first { try rig.job($0) != nil })
    rig.fake.publish(try #require(try rig.job(tried)?.postizId), url: "https://www.tiktok.com/@dj.lovd/video/1")
    _ = try rig.service.sync(force: true)
    #expect(try rig.service.signInWait(.tiktok) == nil)
    rig.tick(2)
    #expect(rig.fake.createCount == creates + 2)
    #expect(try rig.service.signInProblems().isEmpty)
  }

  /// The channel list shows the channel disabled or needing a refresh before anything failed: its posts aren't sent and
  /// don't fall back to Manual; past their time they are never missed; reconnected, they go out by themselves.
  @Test func aChannelTheListFlagsHoldsItsPostsWithoutFallingBack() throws {
    let rig = try Rig(1, platforms: [.tiktok, .x])
    rig.fake.integrations = rig.fake.integrations.map { var c = $0; if c.platform == .tiktok { c.refreshNeeded = true }; return c }
    _ = try rig.service.channels()
    rig.settle()
    let tt = try post(rig, .tiktok), x = try post(rig, .x)
    #expect(try rig.job(tt) == nil && rig.job(x) != nil)
    #expect(try rig.service.displayState(for: tt) == .retrying(PostizService.signInBadge, line: "Goes out once TikTok is reconnected in Postiz"))
    #expect(try PostActions(store: rig.store).problems().isEmpty)
    #expect(try rig.service.signInProblems().map(\.summary) == ["Reconnect TikTok in Postiz · 1 post waits"])
    #expect(notes(rig, "postiz.signIn:tiktok:").count == 1)
    rig.f.clock.set(tt.scheduledAt.addingTimeInterval(2 * 86400))
    rig.tick(2)
    let cur = try #require(try rig.store.post(id: tt.id))
    #expect(cur.state != .overdue && !rig.notifier.delivered.contains { $0.postId == tt.id })
    #expect(try !rig.service.handedToToday(cur))
    rig.fake.integrations = rig.fake.integrations.map { var c = $0; c.refreshNeeded = false; return c }
    _ = try rig.service.channels()
    rig.tick(2)
    #expect(try rig.job(rig.store.post(id: tt.id)!)?.phase == .live)
    #expect(try rig.service.signInProblems().isEmpty)
    #expect(notes(rig, "postiz.signIn:tiktok:").count == 1)
  }

  /// Postiz's `refreshNeeded` is read from the channel list, and an older cache without it still decodes.
  @Test func theChannelListsRefreshFlagIsRead() throws {
    let rig = try Rig(1, platforms: [.tiktok])
    rig.fake.integrations = rig.fake.integrations.map { var c = $0; if c.platform == .tiktok { c.refreshNeeded = true }; return c }
    let list = try rig.service.channels()
    #expect(list.first { $0.platform == .tiktok }?.refreshNeeded == true && list.first { $0.platform == .x }?.refreshNeeded == nil)
    let old = #"{"id":"a","name":"A","identifier":"x","disabled":false}"#
    let decoded = try JSONDecoder().decode(PostizIntegration.self, from: Data(old.utf8))
    #expect(decoded.refreshNeeded == nil && !decoded.needsSignIn)
  }
  // MARK: R7

  /// Post now on a platform set to Postiz sends it through Postiz at the soonest time, never to the Calendar by hand: the
  /// live case was a YouTube post marked Fixed and then Post now.
  @Test func postNowOnAPostizPlatformGoesThroughPostiz() throws {
    let rig = try settled(1, [.youtube])
    let yt = try post(rig, .youtube)
    try fail(rig, yt, "Internal server error")  // YouTube may have it: Eric checks, then marks it Fixed
    let actions = PostActions(store: rig.store)
    let a = try actions.fixed(postId: yt.id)
    #expect(a.scheduledAt > rig.f.clock.now.addingTimeInterval(3600))
    #expect(try actions.postNowGoesThroughPostiz(a))
    try actions.postNow(postId: a.id)
    let cur = try #require(try rig.store.post(id: a.id))
    #expect(try !rig.service.handedToToday(cur))
    #expect(try rig.service.deliversThroughPostiz(cur, router: rig.service.router()))
    let now = rig.f.clock.now
    rig.tick()
    let job = try #require(try rig.job(cur))
    #expect(job.remoteDate.timeIntervalSince(now) >= PostizService.leadTime && job.remoteDate.timeIntervalSince(now) < PostizService.leadTime + 60)
    if case .fellBack? = try rig.service.displayState(for: rig.store.post(id: a.id)!) { Issue.record("fell back to manual") }
    let doctor = DoctorPostizTests.postiz(DoctorPostizTests.doctor(rig.store, keys: rig.keys).run())
    #expect(doctor["postiz.fallback"] == nil)
    #expect(!rig.notifier.delivered.contains { $0.postId == a.id && $0.key.hasPrefix("due:") })
  }

  /// A post Postiz never got that already went to the Calendar (missed): Post now through Postiz takes it back.
  @Test func postNowAfterAHandOverStillGoesThroughPostiz() throws {
    let rig = try settled(1, [.x])
    var x = try post(rig, .x)
    x.state = .due
    try rig.store.save(x, note: "due")  // handed to the Calendar earlier
    #expect(try rig.service.handedToToday(x))
    try PostActions(store: rig.store).postNow(postId: x.id)
    #expect(try !rig.service.handedToToday(rig.store.post(id: x.id)!))
  }

  /// A Manual platform keeps Post now as Eric's task on the Calendar.
  @Test func postNowOnAManualPlatformStaysByHand() throws {
    let rig = try settled(1, [.x])
    let fb = try post(rig, .facebook)
    let actions = PostActions(store: rig.store)
    #expect(try !actions.postNowGoesThroughPostiz(fb))
    try actions.postNow(postId: fb.id)
    #expect(try rig.service.handedToToday(rig.store.post(id: fb.id)!))
    #expect(try rig.store.history(postId: fb.id).last?.note == "post now")
  }
}
