import Foundation

/// A platform whose Postiz channel needs signing in again (round 22, DECISIONS-R22.md): kv `postiz.signIn.<platform>`,
/// no schema change. It starts with a sign-in ERROR on a post, or when the channel list shows the channel disabled or
/// `refreshNeeded`. Its posts don't fall back to Manual and don't each show a failure: they wait, and go out by
/// themselves once the channel works again. It is never dropped by itself.
public struct PostizSignInWait: Codable, Sendable, Hashable {
  /// When the outage started (one notification per outage is keyed on it).
  public var since: Date
  /// When a post last went to Postiz (or failed) on the channel: a timed try comes `signInRetryEvery` after it.
  public var lastTry: Date
  /// The sign-in error Postiz gave, when one did.
  public var message: String?
  /// The channel list showed the channel needing sign-in during this outage, so the list showing it healthy again
  /// means it was reconnected.
  public var flagged = false

  public init(since: Date, lastTry: Date, message: String? = nil, flagged: Bool = false) {
    self.since = since; self.lastTry = lastTry; self.message = message; self.flagged = flagged
  }
}

/// The one item Eric sees for a channel whose sign-in broke: "Reconnect TikTok in Postiz · 3 posts wait".
public struct PostizSignInProblem: Sendable, Hashable, Identifiable {
  public var platform: Platform
  public var channelName: String?
  public var since: Date
  public var message: String?
  /// Posts held for it: failures waiting on it, and posts ready for Postiz that can't go yet.
  public var waiting: Int
  public var id: String { platform.rawValue }

  public init(platform: Platform, channelName: String?, since: Date, message: String?, waiting: Int) {
    self.platform = platform; self.channelName = channelName; self.since = since; self.message = message; self.waiting = waiting
  }

  /// "Reconnect TikTok in Postiz".
  public var title: String { "Reconnect \(platform.displayName) in Postiz" }
  /// "3 posts wait", "Nothing waits yet".
  public var waitingText: String { waiting == 0 ? "Nothing waits yet" : "\(waiting) post\(waiting == 1 ? "" : "s") wait\(waiting == 1 ? "s" : "")" }
  /// "Reconnect TikTok in Postiz · 3 posts wait".
  public var summary: String { "\(title) · \(waitingText)" }
  /// The "how it works" line under it.
  public static let howItWorks = "They go out by themselves once the channel works again. Nothing to do here."
}

extension PostizService {
  static let signInPrefix = "postiz.signIn."
  /// With no word from the channel list, a post is tried again this long after the last one (one at a time).
  public static let signInRetryEvery: TimeInterval = 6 * 3600
  /// The channel list is read this often while a sign-in wait is open (6 h otherwise), so posts resume soon after Eric
  /// reconnects. One budgeted call each.
  public static let signInChannelCheck: TimeInterval = 30 * 60

  static func signInKey(_ p: Platform) -> String { signInPrefix + p.rawValue }

  public func signInWait(_ p: Platform) throws -> PostizSignInWait? { try store.kv(Self.signInKey(p)) }

  func anySignInWait() throws -> Bool {
    try store.db.one("SELECT 1 AS x FROM kv WHERE substr(key, 1, ?) = ?", [Self.signInPrefix.count, Self.signInPrefix]) != nil
  }

  /// Nothing goes to Postiz on `p` now: its channel needs signing in again (the list says so, or a sign-in error came
  /// in the last `signInRetryEvery`). After that long with no word from the list, one post is let through to try.
  public func signInDown(_ p: Platform, router: PostizRouter) throws -> Bool {
    guard router.settings.publishing.publisher(for: p) == .postiz else { return false }
    if router.channelNeedingSignIn(p) != nil { return true }
    guard let w = try signInWait(p) else { return false }
    return now.timeIntervalSince(w.lastTry) < Self.signInRetryEvery
  }

  /// `p` can't go to Postiz until its channel is reconnected: it's held, never overdue and never handed to the Calendar.
  /// While the outage is open (a timed try under way, or the list just said it's back and this tick's publish step
  /// hasn't sent it yet) it still counts as waiting, so it's never "missed" on its way out.
  public func waitsForSignIn(_ p: PlatformPost, router: PostizRouter) throws -> Bool {
    guard !p.state.isTerminal, Self.settingsAllow(p.platform, router.settings), router.route(p.platform).isPostiz,
          try store.livePostizJob(postId: p.id) == nil, try store.finalPostizJob(postId: p.id) == nil, try !handedToToday(p) else { return false }
    return try signInDown(p.platform, router: router) || signInWait(p.platform) != nil
  }

  /// A sign-in ERROR (or refusal) on `p`: the platform waits for its channel.
  func noteSignInFailure(_ p: Platform, message: String) throws {
    var w = try signInWait(p) ?? PostizSignInWait(since: now, lastTry: now)
    w.lastTry = now
    w.message = message
    try store.setKV(Self.signInKey(p), w)
  }

  /// A post goes to Postiz on a channel that waits for its sign-in: the try is on, the next one waits its turn.
  func noteSignInTry(_ p: Platform) throws {
    guard var w = try signInWait(p) else { return }
    w.lastTry = now
    try store.setKV(Self.signInKey(p), w)
  }

  /// The channel works again: its posts go out by themselves.
  func clearSignIn(_ p: Platform, why: String) throws {
    guard try signInWait(p) != nil else { return }
    try store.db.run("DELETE FROM kv WHERE key=?", [Self.signInKey(p)])
    try store.logEvent("postiz", "\(p.displayName) works again in Postiz (\(why)): its waiting posts go out by themselves")
  }

  /// Every tick: follows the channel list (a channel it showed needing sign-in and now shows healthy was reconnected),
  /// and tells Eric once per outage, per platform.
  func reconcileSignIn(_ router: PostizRouter) throws {
    for p in Platform.allCases {
      var w = try signInWait(p)
      guard router.settings.publishing.publisher(for: p) == .postiz else {
        if w != nil { try store.db.run("DELETE FROM kv WHERE key=?", [Self.signInKey(p)]) }  // Manual now: nothing waits on Postiz
        continue
      }
      if router.channelNeedingSignIn(p) != nil {
        if w == nil {
          w = PostizSignInWait(since: now, lastTry: now, flagged: true)
          try store.setKV(Self.signInKey(p), w!)
          try store.logEvent("postiz", "\(p.displayName): the Postiz channel needs reconnecting — its posts wait for it")
        } else if w?.flagged == false {
          w!.flagged = true
          try store.setKV(Self.signInKey(p), w!)
        }
      } else if w?.flagged == true {
        try clearSignIn(p, why: "the channel list shows it connected")
        w = nil
      }
      guard let w, let item = try signInProblem(p, w, router: router) else { continue }
      _ = notify(AppNotification(key: "postiz.signIn:\(p.rawValue):\(Int(w.since.timeIntervalSince1970))", title: item.title,
                                 body: "\(item.waiting > 0 ? item.waitingText : "Its posts wait"). They go out by themselves once the channel works again.",
                                 critical: false, actions: [.open]))
    }
  }

  func signInProblem(_ p: Platform, _ w: PostizSignInWait, router: PostizRouter) throws -> PostizSignInProblem? {
    let failures = try store.posts(where: "platform=? AND state='failed' AND resolution IS NULL", [p.rawValue])
      .filter { try store.retryIsComing($0) }.count
    let held = try store.posts(where: "platform=? AND state IN ('planned','rendering','rendered','due') AND render_id IS NOT NULL", [p.rawValue])
      .filter { try store.livePostizJob(postId: $0.id) == nil && store.finalPostizJob(postId: $0.id) == nil }.count
    let id = router.settings.publishing.channels[p]
    let name = router.channels?.first { $0.id == id }?.name
    return PostizSignInProblem(platform: p, channelName: name, since: w.since, message: w.message, waiting: failures + held)
  }

  /// One item per platform whose channel needs signing in again, for every Problems surface, Doctor and `djq`.
  /// No Keychain and no network: without a router it reads the cached channel list (a missing key doesn't matter here).
  public func signInProblems(router: PostizRouter? = nil) throws -> [PostizSignInProblem] {
    let cache: PostizChannelCache? = try store.kv(PostizChannelCache.kvKey)
    let r = try router ?? PostizRouter(settings: store.settings(), hasKey: true, keyInvalid: store.postizKeyInvalid() != nil,
                                       channels: cache?.integrations)
    var out: [PostizSignInProblem] = []
    for p in Platform.allCases.sorted() where r.settings.publishing.publisher(for: p) == .postiz {
      let w: PostizSignInWait?
      if let stored = try signInWait(p) { w = stored }
      else if r.channelNeedingSignIn(p) != nil { w = PostizSignInWait(since: now, lastTry: now, flagged: true) }
      else { w = nil }
      if let w, let item = try signInProblem(p, w, router: r) { out.append(item) }
    }
    return out
  }
}
