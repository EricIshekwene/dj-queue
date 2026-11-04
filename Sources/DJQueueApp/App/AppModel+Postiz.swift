import DJQCore
import Foundation

/// Postiz data read off the main thread with the rest of `AppModel.load` (no Keychain, no network).
struct PostizLoaded: Sendable {
  var keyInvalid: String?
  var pausedUntil: Date?
  /// nil = never listed.
  var channels: [PostizIntegration]?
  var channelsFetchedAt: Date?
  /// Platform post id → its newest Postiz job (open or closed).
  var jobs: [String: PostizJob] = [:]

  static func load(store: Store, now: Date) throws -> PostizLoaded {
    var l = PostizLoaded()
    l.keyInvalid = try store.postizKeyInvalid()?.message
    let b = try store.postizBudget()
    l.pausedUntil = b.isPaused(now: now) ? b.pausedUntil : nil
    if let c: PostizChannelCache = try store.kv(PostizChannelCache.kvKey) {
      l.channels = c.integrations
      l.channelsFetchedAt = c.fetchedAt
    }
    for j in try store.postizJobs(where: "kind='post'", order: "created_at") { l.jobs[j.postId] = j }
    return l
  }
}

/// What the app shows about Postiz. DB-backed fields come from `PostizLoaded`; the key's presence and the last
/// check live only in the app (the key's value is never read here).
struct PostizUI: Equatable {
  var keyInvalid: String?
  var pausedUntil: Date?
  var channels: [PostizIntegration]?
  var channelsFetchedAt: Date?
  var jobs: [String: PostizJob] = [:]
  /// nil = not looked up yet.
  var hasKey: Bool?
  var checking = false
  var checkedAt: Date?
  var checkError: String?

  mutating func apply(_ l: PostizLoaded) {
    keyInvalid = l.keyInvalid
    pausedUntil = l.pausedUntil
    channels = l.channels
    channelsFetchedAt = l.channelsFetchedAt
    if jobs != l.jobs { jobs = l.jobs }
  }

  func channel(_ id: String?) -> PostizIntegration? { id.flatMap { id in channels?.first { $0.id == id } } }
}

/// The connection line in Settings → Publishing.
enum PostizConnection: Equatable {
  case notSetUp
  /// A key is saved but hasn't been checked in this session.
  case saved
  case connected
  case keyInvalid(String)
  case rateLimited(until: Date)
  case unreachable(String)
}

extension AppModel {
  var postizConnection: PostizConnection {
    if postiz.hasKey == false { return .notSetUp }
    if let m = postiz.keyInvalid { return .keyInvalid(m) }
    if let until = postiz.pausedUntil, until > now { return .rateLimited(until: until) }
    if let e = postiz.checkError { return .unreachable(e) }
    if postiz.checkedAt != nil || postiz.channels != nil { return .connected }
    return .saved
  }

  /// The route the engine takes for `p` right now (an unknown key counts as present until it's looked up).
  func postizRoute(_ p: Platform) -> PublishRoute {
    PostizRouter(settings: settings, hasKey: postiz.hasKey ?? true, keyInvalid: postiz.keyInvalid != nil,
                 channels: postiz.channels).route(p)
  }

  /// Why `p` can't be switched to Postiz (nil = it can).
  func postizUnavailableReason(_ p: Platform) -> String? {
    if postiz.hasKey == false { return "Add your Postiz API key first" }
    if postiz.keyInvalid != nil { return "Postiz refused the API key — save it again" }
    guard let id = settings.publishing.channels[p], !id.isEmpty else { return "Pick a Postiz channel for \(p.displayName) first" }
    if postiz.channels != nil && postiz.channel(id) == nil { return "The picked channel isn't in Postiz any more — pick it again" }
    return nil
  }

  /// Channels Postiz lists for `p` (by provider).
  func postizChannels(for p: Platform) -> [PostizIntegration] { (postiz.channels ?? []).filter { $0.platform == p } }

  var postizTestRun: Bool { settings.publishing.testMode }

  // MARK: Key and check (off the main thread; the key itself never comes back here)

  /// Looks up whether a key is saved (once per launch, again after save/remove). The installed app asks the Keychain
  /// only when Settings → Publishing opens or a platform already uses Postiz.
  func loadPostizKey(force: Bool = false) {
    guard force || postiz.hasKey == nil else { return }
    let bridge = postizBridge
    Task.detached {
      let has = bridge.hasKey()
      await MainActor.run { self.postiz.hasKey = has }
    }
  }

  func savePostizKey(_ raw: String, done: @escaping (String?) -> Void) {
    let key: String
    do { key = try KeychainPostizKeyStore.validate(raw) } catch { done("\(error)"); return }
    let bridge = postizBridge
    Task.detached {
      let err: String? = { do { try bridge.saveKey(key); return nil } catch { return "\(error)" } }()
      await MainActor.run {
        done(err)
        if let err { self.show(err, error: true); return }
        self.postiz.hasKey = true
        self.postiz.checkError = nil
        self.show("Postiz API key saved in the Keychain")
        self.checkPostiz()
      }
    }
  }

  /// Asks first: posts set to Postiz then go to Today.
  func removePostizKey() {
    let n = settings.publishing.postizPlatforms.count
    confirm(ConfirmRequest(
      title: "Remove the Postiz API key?",
      message: n == 0 ? "It's deleted from the Keychain. You can paste it again any time."
        : "It's deleted from the Keychain. \(n == 1 ? "The platform" : "The \(n) platforms") set to Postiz go to Today as manual posts until you add it again. Posts already in Postiz stay there.",
      verb: "Remove key", icon: "key", destructive: true) { [weak self] in
        guard let self else { return }
        let bridge = self.postizBridge
        Task.detached {
          let err: String? = { do { try bridge.deleteKey(); return nil } catch { return "\(error)" } }()
          await MainActor.run {
            if let err { self.show(err, error: true); return }
            self.postiz.hasKey = false
            self.postiz.checkedAt = nil
            self.postiz.checkError = nil
            self.show("Postiz API key removed")
            self.refresh()
          }
        }
      })
  }

  /// `Check connection`: is-connected + the channel list (two calls from the shared hourly budget).
  func checkPostiz() {
    guard !postiz.checking else { return }
    postiz.checking = true
    let bridge = postizBridge
    Task.detached {
      let out: Result<[PostizIntegration], Error> = Result { try bridge.check() }
      await MainActor.run {
        self.postiz.checking = false
        self.postiz.checkedAt = self.now
        switch out {
        case .success(let list):
          self.postiz.checkError = nil
          self.show("Connected to Postiz · \(list.count) channel\(list.count == 1 ? "" : "s")")
        case .failure(let e):
          // A refused key and a 429 are kept in the database (shown from there); anything else is shown here.
          switch e as? PostizError {
          case .unauthorized?, .rateLimited?: self.postiz.checkError = nil
          case .overBudget?: self.postiz.checkError = "This hour's Postiz requests are used up — try again later"
          default: self.postiz.checkError = "\(e)"
          }
        }
        self.refresh()
      }
    }
  }

  // MARK: Settings changes (undoable through `update`)

  func setPublisher(_ p: Platform, _ kind: PublisherKind) {
    update("\(p.displayName) now posts \(kind == .postiz ? "through Postiz" : "manually")") { $0.publishing.publishers[p] = kind }
  }

  func setPostizChannel(_ p: Platform, _ id: String?) {
    let name = postiz.channel(id)?.name
    update(name.map { "\(p.displayName) → Postiz channel \($0)" } ?? "\(p.displayName) has no Postiz channel") { s in
      s.publishing.channels[p] = id
      if id == nil { s.publishing.publishers[p] = .manual }
    }
  }

  /// Picks, for every platform without a usable channel, the first enabled Postiz channel of its provider (or the
  /// only one, even when disabled, so the row says why). Platforms already mapped to a listed channel keep theirs.
  func autoMapPostizChannels() {
    let plan = postizAutoMap()
    guard !plan.isEmpty else { show("Every platform already has its Postiz channel"); return }
    update("Matched \(plan.count) Postiz channel\(plan.count == 1 ? "" : "s")") { s in
      for (p, id) in plan { s.publishing.channels[p] = id }
    }
  }

  func postizAutoMap() -> [Platform: String] {
    var out: [Platform: String] = [:]
    for p in Platform.allCases {
      let mine = postizChannels(for: p)
      if let cur = settings.publishing.channels[p], mine.contains(where: { $0.id == cur }) { continue }
      if let pick = mine.first(where: { !$0.disabled }) ?? mine.first { out[p] = pick.id }
    }
    return out
  }
}

// MARK: Post status (P4)

/// What Postiz is doing with one platform post. nil from `AppModel.postizState` = a manual post (shown as before).
enum PostizPostState: Equatable {
  /// Routed to Postiz; sent once its render exists and the week is approved.
  case queued
  /// The create is in flight, or a replace is waiting for its delete.
  case sending
  case scheduled(Date)
  /// Postiz still holds it after its time: it's going out now.
  case posting
  /// Test run: a Postiz draft until released.
  case draft
  case posted(url: String?)
  /// Test-run TikTok: in the TikTok app's inbox; finish it there, then Mark posted.
  case inbox
  case failed(String)
  case copyright(String)
  /// Set to Postiz but back on Today (the sentence says why).
  case fellBack(String)

  var text: String {
    switch self {
    case .queued: "To Postiz"
    case .sending: "Sending to Postiz"
    case .scheduled: "Scheduled in Postiz"
    case .posting: "Posting…"
    case .draft: "Draft in Postiz"
    case .posted: "Posted"
    case .inbox: "In TikTok inbox"
    case .failed: "Failed"
    case .copyright: "© Blocked"
    case .fellBack: "Fell back to manual"
    }
  }

  var badgeStyle: DSBadgeStyle {
    switch self {
    case .queued, .sending, .scheduled, .draft: .outline
    case .posting: .soft(.info)
    case .posted: .soft(.success)
    case .inbox, .fellBack: .soft(.warning)
    case .failed, .copyright: .soft(.danger)
    }
  }

  var badgeIcon: String? {
    switch self {
    case .queued, .sending, .scheduled: "paperplane"
    case .posting: "arrow.up.circle"
    case .draft: "doc"
    case .posted: "checkmark"
    case .inbox: "tray.and.arrow.down"
    case .failed: "exclamationmark"
    case .copyright: nil  // the text carries the ©
    case .fellBack: "arrow.uturn.backward"
    }
  }

  /// Postiz holds it: nothing for Eric to do (no task on Today, no "due" count).
  var isHeld: Bool {
    switch self {
    case .queued, .sending, .scheduled, .posting, .draft: true
    default: false
    }
  }

  /// A problem shown loudly (its message on the row, not only in a tooltip).
  var isLoud: Bool {
    switch self {
    case .failed, .copyright: true
    default: false
    }
  }
}

extension AppModel {
  /// The Postiz side of `p` (nil = manual). Read from the job behind the post and, without one, the route.
  func postizState(_ p: PlatformPost) -> PostizPostState? {
    if let j = postiz.jobs[p.id] {
      if j.isOpen {
        switch j.phase {
        case .creating, .deleting: return .sending
        case .closed: break
        case .live:
          if j.remoteState == "DRAFT" { return .draft }
          return j.remoteDate <= now ? .posting : .scheduled(j.remoteDate)
        }
      } else if let r = j.closeReason {
        switch r {
        case .published: return .posted(url: p.url ?? j.releaseURL)
        case .inbox: return p.state == .posted ? .posted(url: p.url) : .inbox
        case .error where p.state == .failed:
          return .failed(j.remoteError ?? j.lastError ?? p.errorMessage ?? "Postiz reported an error (no details)")
        case .copyright where [.copyrightBlocked, .copyrightMuted, .removed].contains(p.state):
          return .copyright(j.remoteError ?? j.lastError ?? p.errorMessage ?? "Copyright problem")
        case .rejected where !p.state.isTerminal && p.publisher == "manual":
          return .fellBack(PostizFallbackReason.createRejected(j.lastError ?? "no details").message)
        case .vanished where !p.state.isTerminal && p.publisher == "manual":
          return .fellBack(PostizFallbackReason.vanished.message)
        case .error, .copyright, .rejected, .vanished: break  // reset since: decided by the route below
        case .testDraft: return nil
        case .replaced, .cancelled, .interrupted: break  // decided by the route below
        }
      }
    }
    guard !p.state.isTerminal, p.resolution == nil else { return nil }
    switch postizRoute(p.platform) {
    case .manual: return nil
    case .postiz: return p.state == .planned || p.state == .rendering ? .queued : .sending
    case .fallback(let r): return .fellBack(r.message)
    }
  }

  /// A test-run post: its job was made in test mode, or it will be (Test run on, not yet sent).
  func isTestRun(_ p: PlatformPost) -> Bool {
    if let j = postiz.jobs[p.id], j.kind == "post" { return j.testMode }
    guard settings.publishing.testMode, let s = postizState(p) else { return false }
    return s == .queued || s == .sending
  }

  /// One line under a post's title: what Postiz does, or why it didn't.
  func postizLine(_ p: PlatformPost, _ s: PostizPostState) -> String {
    let channel = postiz.channel(postiz.jobs[p.id]?.integrationId ?? settings.publishing.channels[p.platform])?.name
    let via = channel.map { "Postiz · \($0)" } ?? "Postiz"
    switch s {
    case .queued: return "\(via) · sent once rendered"
    case .sending: return "\(via) · sending now"
    case .scheduled(let d): return "\(via) · goes out at \(Self.clockText(d, tz: tz))"
    case .posting: return "\(via) · going out now"
    case .draft: return "\(via) · draft until released"
    case .posted: return "Posted by \(via)"
    case .inbox: return "Finish it in the TikTok app, then Mark posted with the link"
    case .failed(let m), .copyright(let m): return m
    case .fellBack(let why): return why
    }
  }

  /// Test run: release a Postiz draft so it posts at its time (asks first: it goes public).
  func releaseDraft(_ p: PlatformPost) {
    confirm(ConfirmRequest(
      title: "Release this \(p.platform.displayName) draft?",
      message: "Postiz posts it publicly at \(Self.clockText(p.scheduledAt, tz: tz)) (or within minutes if that time has passed). You can't take it back from DJ Queue once it's out.",
      verb: "Release", icon: "paperplane") { [weak self] in
        guard let self else { return }
        let bridge = self.postizBridge
        Task.detached {
          let err: String? = { do { try bridge.releaseDraft(postId: p.id); return nil } catch { return "\(error)" } }()
          await MainActor.run {
            if let err { self.show(err, error: true) } else { self.show("\(p.platform.displayName) draft released in Postiz") }
            self.refresh()
          }
        }
      })
  }
}
