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
  /// Platform post id → core's display state (`PostizService.displayState(for:)`); absent = manual.
  var states: [String: PostizDisplayState] = [:]

  /// `hasKey` is the app's cached lookup (nil = not looked up yet, counts as present): the display never asks the
  /// Keychain itself.
  static func load(store: Store, now: Date, service: PostizService, hasKey: Bool?, posts: [PlatformPost]) throws -> PostizLoaded {
    var l = PostizLoaded()
    l.keyInvalid = try store.postizKeyInvalid()?.message
    let b = try store.postizBudget()
    l.pausedUntil = b.isPaused(now: now) ? b.pausedUntil : nil
    if let c: PostizChannelCache = try store.kv(PostizChannelCache.kvKey) {
      l.channels = c.integrations
      l.channelsFetchedAt = c.fetchedAt
    }
    for j in try store.postizJobs(where: "kind='post'", order: "created_at") { l.jobs[j.postId] = j }
    let settings = try store.settings()
    let router = PostizRouter(settings: settings, hasKey: hasKey ?? true, keyInvalid: l.keyInvalid != nil, channels: l.channels)
    // Only posts Postiz can have touched: open ones, and finished ones with a job.
    for p in posts where !p.state.isTerminal || l.jobs[p.id] != nil {
      if let st = try service.displayState(for: p, router: router) { l.states[p.id] = st }
    }
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
  var states: [String: PostizDisplayState] = [:]
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
    if states != l.states { states = l.states }
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
    if let c = postiz.channel(id), c.needsSignIn { return "The channel \(c.name) needs reconnecting in Postiz — reconnect it there" }
    return nil
  }

  /// Channels Postiz lists for `p` (by provider).
  func postizChannels(for p: Platform) -> [PostizIntegration] { (postiz.channels ?? []).filter { $0.platform == p } }

  var postizTestRun: Bool { settings.publishing.testMode }

  /// A confirmation shown where Eric is: inside the Settings modal when it's open (its own dialog over the pane),
  /// else the window's confirm dialog.
  func confirmHere(_ r: ConfirmRequest) {
    guard showSettings else { confirm(r); return }
    SettingsUIState.shared.confirm = SettingsConfirm(title: r.title, message: r.message, confirmTitle: r.verb,
                                                     destructive: r.destructive, icon: r.icon, action: r.action)
  }

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

  /// Asks first: posts set to Postiz then go to the Calendar as manual posts.
  func removePostizKey() {
    let n = settings.publishing.postizPlatforms.count
    confirmHere(ConfirmRequest(
      title: "Remove the Postiz API key?",
      message: n == 0 ? "It's deleted from the Keychain. You can paste it again any time."
        : "It's deleted from the Keychain. \(n == 1 ? "The platform" : "The \(n) platforms") set to Postiz go to the Calendar as manual posts until you add it again. Posts already in Postiz stay there.",
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

  /// Manual → Postiz with Test run off posts publicly from the next engine pass, so it asks first (with what goes
  /// out and when). Postiz → Manual, or anything while Test run is on, applies at once (undoable).
  func setPublisher(_ p: Platform, _ kind: PublisherKind) {
    let apply = { self.update("\(p.displayName) now posts \(kind == .postiz ? "through Postiz" : "manually")") { $0.publishing.publishers[p] = kind } }
    guard kind == .postiz, !settings.publishing.testMode, settings.publishing.publisher(for: p) != .postiz else { apply(); return }
    let upcoming = posts.filter { $0.platform == p && !$0.state.isTerminal && $0.resolution == nil && $0.state != .overdue }
      .sorted { $0.scheduledAt < $1.scheduledAt }
    let next = upcoming.first.map { "The next is \(Fmt.day($0.scheduledAt, tz: tz, style: "EEE d MMM")) at \(Self.clockText($0.scheduledAt, tz: tz))." }
    let n = upcoming.count
    confirmHere(ConfirmRequest(
      title: "Post \(p.displayName) publicly through Postiz?",
      message: [n == 0 ? "No \(p.displayName) posts are scheduled yet; scheduled ones will go out publicly at their slots."
                  : "\(n) planned \(p.displayName) post\(n == 1 ? "" : "s") go out publicly at their slots, with no step from you. \(next ?? "")",
                "A post whose time has already passed goes out within minutes. Turn on Test run first to try it without posting publicly."]
        .joined(separator: "\n\n"),
      verb: "Post through Postiz", icon: "paperplane", action: apply))
  }

  /// Test run on → off: from then on new Postiz posts are public (posts already in Postiz keep their test settings).
  func setTestRun(_ on: Bool) {
    let apply = { self.update(on ? "Test run turned on" : "Test run turned off") { $0.publishing.testMode = on } }
    guard !on, settings.publishing.testMode else { apply(); return }
    let ps = settings.publishing.postizPlatforms.map(\.displayName)
    confirmHere(ConfirmRequest(
      title: "Turn Test run off?",
      message: "From now on, new posts go out publicly\(ps.isEmpty ? "" : " on " + (ps.count > 1 ? ps.dropLast().joined(separator: ", ") + " and " + ps.last! : ps[0])). TikTok posts directly, YouTube as \(settings.publishing.youtube.visibility.displayName), the others at their slots. Posts already in Postiz keep their test settings (drafts, Unlisted, TikTok inbox) and keep their Test run badge.",
      verb: "Turn off Test run", icon: "testtube.2", action: apply))
  }

  /// An option that makes a platform's Postiz posts more public (TikTok inbox → Post directly, YouTube → Public)
  /// asks first while that platform posts through Postiz and Test run is off.
  func setPublishingOption(_ label: String, platform p: Platform, morePublic: Bool, _ change: @escaping (inout AppSettings) -> Void) {
    let apply = { self.update(label, change) }
    guard morePublic, !settings.publishing.testMode, settings.publishing.publisher(for: p) == .postiz else { apply(); return }
    confirmHere(ConfirmRequest(title: "\(label)?",
                           message: "\(p.displayName) posts Postiz makes from now on are public at their slots. Posts already in Postiz stay as they are.",
                           verb: "Make it public", icon: "globe", action: apply))
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

/// What Postiz is doing with one platform post: core's display state (one source for every screen and the engine).
typealias PostizPostState = PostizDisplayState

extension PostizDisplayState {
  var badgeStyle: DSBadgeStyle {
    switch self {
    case .queued, .sending, .scheduled, .draft: .outline
    case .retrying: .soft(.neutral)  // round 22: one quiet status pill (Shopify's "Scheduled"), never red
    case .unconfirmed: .soft(.warning)
    case .posting: .soft(.info)
    case .posted: .soft(.success)
    case .inbox, .fellBack: .soft(.warning)
    case .failed, .copyright: .soft(.danger)
    }
  }

  var badgeIcon: String? {
    switch self {
    case .queued, .sending, .scheduled: "paperplane"
    case .retrying: "clock.arrow.circlepath"
    case .unconfirmed: "questionmark.circle"
    case .posting: "arrow.up.circle"
    case .draft: "doc"
    case .posted: "checkmark"
    case .inbox: "tray.and.arrow.down"
    case .failed: "exclamationmark"
    case .copyright: nil  // the text carries the ©
    case .fellBack: "arrow.uturn.backward"
    }
  }

  /// A problem shown loudly (its message on the row, not only in a tooltip).
  var isLoud: Bool {
    switch self {
    case .failed, .copyright: true
    default: false
    }
  }

  var isRetrying: Bool {
    if case .retrying = self { return true }
    return false
  }
}

extension AppModel {
  /// The Postiz side of `p` (nil = manual), as core computed it in the last load.
  func postizState(_ p: PlatformPost) -> PostizPostState? { postiz.states[p.id] }

  /// What a post's row says about Postiz: a handled post shows its own state, unless its automatic retry is still coming.
  func postizRowState(_ p: PlatformPost) -> PostizPostState? {
    let s = postizState(p)
    return p.resolution == nil || s?.isRetrying == true ? s : nil
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
    case .unconfirmed: return Self.unconfirmedText
    case .scheduled(let d): return "\(via) · goes out at \(Self.clockText(d, tz: tz))"
    case .posting: return "\(via) · going out now"
    case .draft: return "\(via) · draft until released"
    case .posted: return "Posted by \(via)"
    case .inbox: return "In your TikTok inbox — finish it there, then Mark posted"
    case .failed(let m), .copyright(let m): return m
    case .retrying(_, let line): return line ?? "\(via) · nothing to do"
    case .fellBack(let why): return why
    }
  }

  /// Test run: release a Postiz draft so it posts at its time (asks first: it goes public).
  func releaseDraft(_ p: PlatformPost) {
    confirmHere(ConfirmRequest(
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

// MARK: Unconfirmed creates (Doctor postiz.create_unknown)

extension AppModel {
  static let unconfirmedText = "DJ Queue couldn't confirm Postiz got this post. Check the Postiz calendar."

  /// "It's in Postiz": kept as Postiz's (recorded posted, never sent again). "Not in Postiz — post it myself": back
  /// on the Calendar, which asks first — if Postiz does have it, it would post twice.
  func resolveUnconfirmed(_ p: PlatformPost, inPostiz: Bool) {
    let run = { [weak self] in
      guard let self else { return }
      let svc = self.postizBridge.service
      Task.detached {
        let out: Result<String, Error> = Result { try svc.resolveUnconfirmed(postId: p.id, inPostiz: inPostiz) }
        await MainActor.run {
          switch out {
          case .success: self.show(inPostiz ? "\(p.platform.displayName): kept as Postiz's — add its link when it's up"
                                            : "\(p.platform.displayName) is on the Calendar to post by hand")
          case .failure(let e): self.show("\(e)", error: true)
          }
          ChangeSignal.post()
          self.refresh()
        }
      }
    }
    guard !inPostiz else { run(); return }
    confirmHere(ConfirmRequest(
      title: "Post \(p.platform.displayName) yourself?",
      message: "Only if it isn't in the Postiz calendar. If Postiz does have it, it would go out twice: once from Postiz and once by you. It stays on the Calendar as a manual post.",
      verb: "Post it myself", icon: "exclamationmark.triangle", destructive: true, action: run))
  }
}
