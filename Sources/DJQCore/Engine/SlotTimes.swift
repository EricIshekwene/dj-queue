import Foundation

/// What `djq slot` did, or would do. `moved` holds each post as it was and its new time.
public struct SlotChange: Sendable {
  public struct Move: Sendable {
    public var post: PlatformPost
    public var to: Date
  }
  public struct Kept: Sendable {
    public var post: PlatformPost
    public var why: String
  }
  public var before: Int
  public var moved: [Move] = []
  public var kept: [Kept] = []
  public var batchId: String?
  /// What replacing Postiz's copies takes (a delete and a create each), and what's left of this hour's budget.
  public var postizCalls = 0
  public var postizCallsLeft = 0
}

extension PostActions {
  /// Well clear of `decide`'s 5-minute hold, and the lead an undo's plan part needs: a closer post that moved couldn't go back.
  static let slotHold = Planner.autoScheduleLead

  private struct Rollback: Error {}

  /// Sets `p`'s slot and moves its unposted future posts onto it, one undo. Only `scheduledAt` changes: each post keeps its
  /// plan day and position, so the "never double-post" keys stay as they are, and the publish step replaces any copy Postiz
  /// holds (`decide`: "moved to…").
  public func setSlot(_ p: Platform, minutes: Int, dryRun: Bool = false) throws -> SlotChange {
    let settings = try store.settings()
    var change = SlotChange(before: settings.slot(for: p))
    change.postizCallsLeft = try store.postizBudget().remaining(now: now, limit: settings.publishing.hourlyBudget)
    if dryRun {
      do {
        try store.db.transaction {
          try retime(p, minutes: minutes, into: &change)
          throw Rollback()
        }
      } catch is Rollback {}
    } else {
      change.batchId = try BulkActions(store: store).record("slot", params: ["platform": p.rawValue], plan: true, settings: true) {
        try retime(p, minutes: minutes, into: &change)
      }.batchId
    }
    return change
  }

  private func retime(_ p: Platform, minutes: Int, into change: inout SlotChange) throws {
    var s = try store.settings()
    let dm = DayMath(settings: s)
    let soon = now.addingTimeInterval(Self.slotHold)
    let pinned = Set(try store.planSlots(where: "pinned=1").map(\.id))
    let exact = Set(try store.planSlots(where: "exact_at IS NOT NULL").map(\.id))
    // Regular posts first: reposts and manual retries stagger around where those land.
    let future = try store.posts(where: "platform=? AND scheduled_at>?", [p.rawValue, now])
      .filter { PostizService.openStates.contains($0.state) }
      .sorted { ($0.kind == .regular ? 0 : 1, $0.scheduledAt) < ($1.kind == .regular ? 0 : 1, $1.scheduledAt) }
    var days: [String: String] = [:]  // read under the slot the post was placed with
    for post in future where post.kind == .regular { days[post.id] = try store.planDay(of: post, dm: dm) }
    if s.slot(for: p) != minutes {  // a saved row reads as changed even when it isn't
      s.slotMinutes[p] = minutes
      try store.save(s)
    }
    func move(_ post: PlatformPost, to: Date) throws {
      var post = post
      change.moved.append(.init(post: post, to: to))
      if try store.livePostizJob(postId: post.id) != nil { change.postizCalls += 2 }
      post.scheduledAt = to
      if post.state == .due { post.state = post.renderId == nil ? .planned : .rendered }
      try store.save(post, note: "slot time → \(Sched.shortTime(to, s))")
    }
    var retries: [PlatformPost] = []
    for post in future {
      if let why = try keepsItsTime(post, pinned: pinned, exact: exact, soon: soon) {
        change.kept.append(.init(post: post, why: why))
        continue
      }
      if post.kind != .regular, try store.autoRetries(post).lastPostId == post.id {
        retries.append(post)
        continue
      }
      let to: Date
      if let day = days[post.id] {
        to = s.slotTime(p, date: day, position: try store.position(of: post), dm)
      } else {
        to = try Sched.staggered(store: store, platform: p, day: dm.key(post.scheduledAt), settings: s, dm: dm, excluding: [post.id])
      }
      guard to != post.scheduledAt else { continue }
      guard to > soon else {
        change.kept.append(.init(post: post, why: Self.tooSoon))
        continue
      }
      try move(post, to: to)
    }
    // An automatic retry keeps its time unless a post just landed next to it. A YouTube one can go earlier, down to the reset.
    for retry in retries {
      let earliest = p == .youtube ? max(PostizRetrySchedule.youTubeQuota(after: retry.scheduledAt.addingTimeInterval(-86400)).reset, soon) : nil
      let to = try Sched.retrySlot(store: store, platform: p, target: retry.scheduledAt, earliest: earliest, settings: s, excluding: [retry.id])
      if to == retry.scheduledAt { change.kept.append(.init(post: retry, why: "an automatic retry has its own time")) }
      else if to > soon { try move(retry, to: to) }
      else { change.kept.append(.init(post: retry, why: Self.tooSoon)) }
    }
  }

  private static var tooSoon: String { "the new time has passed or is under \(Int(slotHold / 60)) minutes away" }

  private func keepsItsTime(_ post: PlatformPost, pinned: Set<String>, exact: Set<String>, soon: Date) throws -> String? {
    if exact.contains(post.planSlotId ?? "") { return "it has a set time" }  // round 21: a set time is never a slot time
    if pinned.contains(post.planSlotId ?? "") { return "pinned" }
    let job = try store.livePostizJob(postId: post.id)
    if min(post.scheduledAt, job?.remoteDate ?? post.scheduledAt) <= soon { return "it goes out within \(Int(Self.slotHold / 60)) minutes" }
    return nil
  }
}
