import DJQCore
import Foundation

/// Round 6 sample (throwaway snapshot DB only): Postiz connected with six sample channels (Threads' disabled), every
/// platform but Facebook set to Postiz, and a Postiz job behind posts in every state — independent of the weekday:
/// - today: Facebook posted by hand · Threads fell back to manual (channel disabled) · YouTube posting… · X scheduled ·
///   Instagram a test-run draft;
/// - yesterday (extra posts of the first planned clip): YouTube posted by Postiz with a link, X failed with Postiz's
///   message, Instagram © blocked, TikTok in the TikTok inbox (test run, overdue → back on Today);
/// - tomorrow: X scheduled, the rest queued for Postiz.
/// Round 9: today's TikTok failed and its automatic retry waits in Postiz for tomorrow 8:00 am; yesterday's Threads
/// failed and its retry waits for the channel to come back.
extension SampleData {
  static func seedPostiz(store: Store, clock: FixedClock, now: Date) throws {
    clock.set(now)
    var st = try store.settings()
    for p in Platform.allCases {
      st.publishing.publishers[p] = p == .facebook ? .manual : .postiz
      st.publishing.channels[p] = PostizSamples.channels.first { $0.platform == p }?.id
    }
    try store.save(st)
    struct Cache: Encodable { var fetchedAt: Date; var integrations: [PostizIntegration] }
    try store.setKV(PostizChannelCache.kvKey, Cache(fetchedAt: now.addingTimeInterval(-25 * 60), integrations: PostizSamples.channels))

    let dm = DayMath(settings: st)
    let today = dm.key(now), yesterday = dm.addDays(today, -1), tomorrow = dm.addDays(today, 1)
    let channel = { (p: Platform) in PostizSamples.channels.first { $0.platform == p }?.id ?? "" }

    func job(_ p: PlatformPost, phase: PostizJobPhase, remote: String?, close: PostizCloseReason? = nil, test: Bool = false,
             at: Date? = nil, error: String? = nil, url: String? = nil) throws {
      let d = at ?? p.scheduledAt
      var j = PostizJob(postId: p.id, videoId: p.videoId, platform: p.platform, integrationId: channel(p.platform), phase: phase,
                        postizId: "sample-\(p.id.prefix(6))", renderId: p.renderId, contentHash: "sample", scheduledAt: p.scheduledAt,
                        remoteDate: d, testMode: test, postType: remote == "DRAFT" ? "draft" : "schedule", remoteState: remote,
                        remoteError: error, releaseURL: url, submittedAt: d.addingTimeInterval(-86400), syncedAt: now.addingTimeInterval(-300),
                        createdAt: d.addingTimeInterval(-86400), updatedAt: now)
      if let close {
        j.closedAt = min(now, d.addingTimeInterval(120))
        j.closeReason = close
        if let error { j.lastError = error }
      }
      try store.save(j)
    }

    let posts = try store.posts()
    for p in posts where dm.key(p.scheduledAt) == today {
      var q = p
      switch p.platform {
      case .threads:  // channel disabled → back on Today, by hand
        q.state = .due
        q.url = nil
        q.postedAt = nil
        try store.save(q)
      case .youtube:
        q.state = .due
        try store.save(q)
        try job(q, phase: .live, remote: "QUEUE")
      case .x: try job(p, phase: .live, remote: "QUEUE")
      case .instagram: try job(p, phase: .live, remote: "DRAFT", test: true)
      default: break
      }
    }
    for p in posts where dm.key(p.scheduledAt) == tomorrow && p.platform == .x { try job(p, phase: .live, remote: "QUEUE") }
    // Tomorrow's YouTube: a create Postiz never confirmed (Doctor postiz.create_unknown) — Eric checks the calendar.
    if var p = posts.first(where: { dm.key($0.scheduledAt) == tomorrow && $0.platform == .youtube }) {
      if p.renderId == nil { p.renderId = posts.first { $0.videoId == p.videoId && $0.renderId != nil }?.renderId }
      var j = PostizJob(postId: p.id, videoId: p.videoId, platform: .youtube, integrationId: channel(.youtube), phase: .creating,
                        renderId: p.renderId, contentHash: "sample", scheduledAt: p.scheduledAt, remoteDate: p.scheduledAt,
                        testMode: false, postType: "schedule", remoteState: PostizJob.unconfirmed,
                        submittedAt: now.addingTimeInterval(-3600), createdAt: now.addingTimeInterval(-3600), updatedAt: now)
      j.lastError = "The create timed out and the post isn't in the Postiz list"
      try store.save(j)
    }

    // Yesterday's clip: its X post failed in Postiz ("1 failed" on its card).
    if var p = posts.first(where: { dm.key($0.scheduledAt) == yesterday && $0.platform == .x && $0.planSlotId != nil }) {
      let msg = "X refused the video: the file is over its size limit"
      p.state = .failed
      p.url = nil
      p.postedAt = nil
      p.errorType = .uploadFailed
      p.errorMessage = msg
      try store.save(p, note: msg)
      try job(p, phase: .closed, remote: "ERROR", close: .error, error: msg)
    }

    // Yesterday: four extra posts of the first planned clip, one per outcome.
    guard let videoId = posts.first(where: { dm.key($0.scheduledAt) == today })?.videoId,
          let renderId = posts.first(where: { $0.videoId == videoId && $0.renderId != nil })?.renderId else { return }
    func extra(_ p: Platform, _ state: PostState, error: (ErrorType, String)? = nil, url: String? = nil) throws -> PlatformPost {
      let at = dm.at(yesterday, minutes: st.slot(for: p))
      let post = PlatformPost(id: newId(), videoId: videoId, platform: p, versionNo: 1, attemptNo: 1, kind: .regular, planSlotId: nil,
                              scheduledAt: at, renderId: renderId, state: state, publisher: "postiz", externalId: nil, url: url,
                              postedAt: state == .posted ? at.addingTimeInterval(90) : nil, errorType: error?.0, errorMessage: error?.1,
                              rawResponse: nil, resolution: nil, metrics: nil, createdAt: at.addingTimeInterval(-86400), updatedAt: at)
      try store.save(post, note: error?.1)
      return post
    }
    let yt = try extra(.youtube, .posted, url: "https://www.youtube.com/shorts/sample01")
    try job(yt, phase: .closed, remote: "PUBLISHED", close: .published, url: yt.url)
    let xMsg = "Video is longer than 2:20, the longest X allows"
    try job(try extra(.x, .failed, error: (.tooLong, xMsg)), phase: .closed, remote: "ERROR", close: .error, error: xMsg)
    let igMsg = "This audio isn't available: the song is restricted by its rights holder"
    try job(try extra(.instagram, .copyrightBlocked, error: (.copyrightBlocked, igMsg)), phase: .closed, remote: "ERROR", close: .copyright,
            error: igMsg)
    var tt = try extra(.tiktok, .overdue)
    tt.publisher = "manual"
    try store.save(tt)
    try job(tt, phase: .closed, remote: "PUBLISHED", close: .inbox, test: true)
    try seedRetries(store: store, now: now, today: today, tomorrow: tomorrow, dm: dm, renderId: renderId) {
      try job($0, phase: $1, remote: $2, close: $3, test: false, at: nil, error: $4, url: nil)
    }
    let thMsg = "Something went wrong at the platform"
    let th = try extra(.threads, .failed, error: (.uploadFailed, thMsg + " — \(PostizService.retryingNote)"))
    try job(th, phase: .closed, remote: "ERROR", close: .error, error: thMsg)
    var waiting = PostizAutoRetries()
    waiting.failedPostId = th.id
    waiting.failedAt = th.scheduledAt
    waiting.nextRetryAt = th.scheduledAt.addingTimeInterval(3600)
    try store.setKV("postiz.autoRetry.\(th.videoId)#threads#v\(th.versionNo)", waiting)
    try store.db.run("UPDATE platform_posts SET raw_response='postiz:sample' WHERE id=?", [th.id])
    try store.refreshState(videoId: videoId)
  }

  /// Today's TikTok: failed, with its retry already in Postiz for tomorrow 8:00 am (the state a post is in for most of
  /// a retry's life: nothing for Eric to do).
  private static func seedRetries(store: Store, now: Date, today: String, tomorrow: String, dm: DayMath, renderId: String,
                                  job: (PlatformPost, PostizJobPhase, String?, PostizCloseReason?, String?) throws -> Void) throws {
    guard var failed = try store.posts().first(where: { dm.key($0.scheduledAt) == today && $0.platform == .tiktok }) else { return }
    let msg = "Postiz reported an error (no details)"
    let at = dm.at(tomorrow, minutes: 8 * 60)
    failed.state = .failed
    failed.renderId = failed.renderId ?? renderId
    failed.publisher = "postiz"
    failed.errorType = .uploadFailed
    failed.errorMessage = msg + " — \(PostizService.retryingNote)"
    failed.rawResponse = "postiz:sample"
    failed.resolution = "retried"
    failed.scheduledAt = now.addingTimeInterval(-3 * 3600)
    try store.save(failed, note: "auto-retry → attempt 2")
    try job(failed, .closed, "ERROR", .error, msg)
    let attempt = PlatformPost(id: newId(), videoId: failed.videoId, platform: .tiktok, versionNo: failed.versionNo, attemptNo: 2, kind: .retry,
                               planSlotId: failed.planSlotId, scheduledAt: at, renderId: failed.renderId, state: .rendered, publisher: "postiz",
                               externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil,
                               metrics: nil, createdAt: now, updatedAt: now)
    try store.save(attempt, note: "auto-retry: upload_failed")
    try job(attempt, .live, "QUEUE", nil, nil)
    var r = PostizAutoRetries()
    r.count = 1
    r.lastPostId = attempt.id
    r.failedAt = failed.scheduledAt
    r.nextRetryAt = at
    try store.setKV("postiz.autoRetry.\(failed.videoId)#tiktok#v\(failed.versionNo)", r)
  }
}
