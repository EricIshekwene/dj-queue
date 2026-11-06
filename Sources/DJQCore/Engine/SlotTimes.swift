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
}

extension PostActions {
  /// As for a crop: Postiz's 5-minute hold plus a margin for a tick, so a moved post never lands in `decide`'s `.hold`.
  static let slotHold = PostizService.safety * 2

  private struct Rollback: Error {}

  /// Sets `p`'s slot and moves its unposted future posts onto it, one undo. Only `scheduledAt` changes: each post keeps its
  /// plan day and position, so the "never double-post" keys stay as they are, and the publish step replaces any copy Postiz
  /// holds (`decide`: "moved to…").
  public func setSlot(_ p: Platform, minutes: Int, dryRun: Bool = false) throws -> SlotChange {
    var change = SlotChange(before: try store.settings().slot(for: p))
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
    for var post in future {
      if let why = try keepsItsTime(post, pinned: pinned, soon: soon) {
        change.kept.append(.init(post: post, why: why))
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
        change.kept.append(.init(post: post, why: "the new time has already passed"))
        continue
      }
      change.moved.append(.init(post: post, to: to))
      post.scheduledAt = to
      if post.state == .due { post.state = post.renderId == nil ? .planned : .rendered }
      try store.save(post, note: "slot time → \(Sched.shortTime(to, s))")
    }
  }

  private func keepsItsTime(_ post: PlatformPost, pinned: Set<String>, soon: Date) throws -> String? {
    if pinned.contains(post.planSlotId ?? "") { return "pinned" }
    if post.kind != .regular, try store.autoRetries(post).lastPostId == post.id { return "an automatic retry has its own time" }
    let job = try store.livePostizJob(postId: post.id)
    if min(post.scheduledAt, job?.remoteDate ?? post.scheduledAt) <= soon { return "it goes out within \(Int(Self.slotHold / 60)) minutes" }
    return nil
  }
}
