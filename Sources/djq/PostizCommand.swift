import DJQCore
import Foundation

/// `djq postiz …` (round 6, docs/postiz.md). Live calls go through `PostizService` (budgeted, the key read from the
/// Keychain at call time and never printed). Channel ids are shown only with `--ids`. Settings changes print exactly
/// what changes, honour `--dry-run`, are journaled (undo: `djq bulk undo <batch>`) and need `--yes` when they would
/// make approved posts go out for real through Postiz.
enum PostizCommand {
  static let usage = """
    usage: djq postiz <command> [--json]

      status [--offline] [--ids]          key and connection (one live check unless --offline), call budget, test run,
                                          per platform: publisher, channel, route, posts in Postiz; last sync.
                                          Exit 0 = connected with all six channels mapped; 2 = not ready (reasons listed)
      channels [--cached] [--refresh] [--ids]   the live channel list + each channel's caption limit
      map [--dry-run] [--yes]             auto-map the six DJ channels by provider (instagram-standalone,
                                          tiktok-business, threads, facebook, x, youtube) into Settings → Publishing
      map <platform> <channel name|id> | map <platform> --clear   [--dry-run] [--yes]
      publisher <platform|all> manual|postiz [--dry-run] [--yes]
      test-mode on|off [--dry-run] [--yes]
      test <video> --dry-run | --draft    the six payloads for a clip: --dry-run prints them (key redacted, no call);
                                          --draft creates Postiz drafts only (nothing reaches a platform)
      link <post> [<url>|<release-id>] [--release-id ID]   a post Postiz published without a link: list the
                                          platform's recent posts, or record the right one
      release <post> --yes                test run: release a Postiz draft so it posts at its time
      sync [--force]                      one sync now, budget permitting (asks DJ Queue's engine when it's running)

    Settings changes print what changes; --dry-run changes nothing. A change that makes approved posts go out for
    real through Postiz (a platform to Postiz with a channel, a new channel, test run off) needs --yes: that's
    Eric's call. Undo a settings change with `djq bulk undo <batch>`.
    """

  static func run(_ store: Store, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json"), ids = flag("--ids")
    guard let sub = args.first else { print(usage); return 0 }
    args.removeFirst()
    let svc = PostizService(store: store)
    switch sub {
    case "help", "-h", "--help": print(usage); return 0
    case "status": return try status(store, svc, json: json, ids: ids, offline: flag("--offline"))
    case "channels": return try channels(store, svc, json: json, ids: ids, cached: flag("--cached"), refresh: flag("--refresh"), wrote: &wrote)
    case "map": return try map(store, svc, json: json, ids: ids, wrote: &wrote)
    case "publisher": return try publisher(store, json: json, ids: ids, wrote: &wrote)
    case "test-mode": return try testMode(store, json: json, ids: ids, wrote: &wrote)
    case "test": return try test(store, svc, json: json, ids: ids, wrote: &wrote)
    case "link": return try link(store, svc, json: json, wrote: &wrote)
    case "release": return try release(store, svc, json: json, wrote: &wrote)
    case "sync": return try sync(store, svc, json: json, wrote: &wrote)
    default: throw CLIError("unknown postiz command \(sub)\n\n\(usage)")
    }
  }

  // MARK: Shared

  static func cache(_ store: Store) throws -> PostizChannelCache? { try store.kv(PostizChannelCache.kvKey) }

  /// "DJ Lovd TikTok (tiktok-business)", "(none)", or the id itself when the channel isn't in the cached list.
  static func channelLabel(_ id: String?, _ cache: PostizChannelCache?, ids: Bool) -> String {
    guard let id, !id.isEmpty else { return "(none)" }
    guard let c = cache?.integrations.first(where: { $0.id == id }) else { return ids ? "unknown channel \(id)" : "a channel not in the cached list" }
    return "\(c.name) (\(c.identifier))" + (c.disabled ? " [disabled]" : "") + (ids ? " · id \(id)" : "")
  }

  static func ago(_ d: Date?, _ now: Date, _ s: Settings) -> String {
    guard let d else { return "never" }
    let m = Int(now.timeIntervalSince(d) / 60)
    return "\(fmt(d, s)) (\(m < 1 ? "just now" : m < 120 ? "\(m) min ago" : "\(m / 60) h ago"))"
  }

  /// What test run does to each platform (docs/postiz.md §6).
  static func testEffect(_ p: Platform) -> String {
    switch p {
    case .tiktok: "TikTok inbox"
    case .youtube: "unlisted"
    default: "Postiz draft"
    }
  }

  /// The live channel list, else the cached one with a note (offline, budget, …). Throws only when neither exists.
  static func channelList(_ store: Store, _ svc: PostizService) throws -> (list: [PostizIntegration], note: String?, live: Bool) {
    guard svc.hasKey() else {
      // No key: don't spend a budget slot on a call that can't be made.
      guard let c = try cache(store) else { throw CLIError("no Postiz API key saved (Eric adds it in Settings → Publishing) and no cached channel list") }
      return (c.integrations, "no API key saved; using the cached list from \(fmt(c.fetchedAt, try store.settings()))", false)
    }
    do {
      return (try svc.channels(refresh: true), nil, true)
    } catch {
      guard let c = try cache(store) else { throw CLIError("couldn't list Postiz channels: \(error)") }
      return (c.integrations, "live list unavailable (\(error)); using the list from \(fmt(c.fetchedAt, try store.settings()))", false)
    }
  }

  // MARK: status

  struct StatusOut: Encodable {
    struct Channel: Encodable { var name: String; var provider: String; var disabled: Bool; var id: String? }
    struct Row: Encodable {
      var platform: String
      var publisher: String
      var channel: Channel?
      var channelSet: Bool
      var route: String
      var fallback: String?
      var fallbackCode: String?
      var testRun: String?
      var openJobs: Int
      var remoteStates: [String: Int]
    }
    var state: String
    var ready: Bool
    var problems: [String]
    var hasKey: Bool
    var keyInvalid: String?
    var connected: Bool?
    var checkError: String?
    var rateLimited: Bool
    var pausedUntil: Date?
    var budgetUsed: Int
    var budgetLimit: Int
    var testMode: Bool
    var apiBase: String
    var lastSync: Date?
    var channelsFetchedAt: Date?
    var openJobs: Int
    var stuck: [String]
    var linkMissing: [String]
    var platforms: [Row]
  }

  static func status(_ store: Store, _ svc: PostizService, json: Bool, ids: Bool, offline: Bool) throws -> Int32 {
    let st = try svc.status(check: !offline && svc.hasKey())
    let settings = try store.settings()
    let now = store.clock.now
    let cache = try cache(store)
    let open = try store.openPostizJobs()
    let paused = st.pausedUntil != nil
    let state: String
    if st.keyInvalid != nil { state = "key_invalid" }
    else if !st.hasKey { state = "no_key" }
    else if paused && st.connected != true { state = "rate_limited" }
    else if st.connected == true { state = "connected" }
    else if st.connected == false { state = "unreachable" }
    else { state = "unchecked" }

    var problems: [String] = []
    switch state {
    case "key_invalid": problems.append("Postiz refused the API key: \(st.keyInvalid!.isEmpty ? "401" : st.keyInvalid!) (Eric saves it again in Settings → Publishing)")
    case "no_key": problems.append("no Postiz API key saved (Eric adds it in Settings → Publishing)")
    case "rate_limited": problems.append("rate limited: no calls until \(fmt(st.pausedUntil!, settings))")
    case "unreachable": problems.append("Postiz didn't answer: \(st.checkError ?? "?")")
    default: break
    }
    var rows: [StatusOut.Row] = []
    for r in st.platforms {
      let c = r.channelId.flatMap { id in cache?.integrations.first { $0.id == id } }
      let jobs = open.filter { $0.platform == r.platform }
      let states = Dictionary(grouping: jobs, by: { $0.remoteState ?? $0.phase.rawValue }).mapValues(\.count)
      rows.append(.init(platform: r.platform.rawValue, publisher: r.publisher.rawValue,
                        channel: c.map { .init(name: $0.name, provider: $0.identifier, disabled: $0.disabled, id: ids ? $0.id : nil) },
                        channelSet: r.channelId != nil, route: r.route, fallback: r.fallback, fallbackCode: r.fallbackCode,
                        testRun: st.testMode && r.publisher == .postiz ? testEffect(r.platform) : nil, openJobs: r.openJobs,
                        remoteStates: states))
      if r.channelId == nil { problems.append("\(r.platform.displayName): no channel mapped") }
      else if cache != nil && c == nil { problems.append("\(r.platform.displayName): the mapped channel isn't in Postiz any more") }
      else if c?.disabled == true { problems.append("\(r.platform.displayName): channel \(c!.name) is disabled or expired") }
    }
    if !st.stuck.isEmpty { problems.append("\(st.stuck.count) post(s) still QUEUE in Postiz an hour after the slot") }
    // Ready: connected (or, with --offline, a saved key Postiz hasn't refused) and all six channels mapped and usable.
    let keyOK = state == "connected" || (offline && state == "unchecked")
    let ready = keyOK && problems.isEmpty
    let out = StatusOut(state: state, ready: ready, problems: problems, hasKey: st.hasKey, keyInvalid: st.keyInvalid,
                        connected: st.connected, checkError: st.checkError, rateLimited: paused, pausedUntil: st.pausedUntil,
                        budgetUsed: st.budgetUsed, budgetLimit: st.budgetLimit, testMode: st.testMode, apiBase: st.apiBase,
                        lastSync: st.lastSync, channelsFetchedAt: st.channelsFetchedAt, openJobs: st.openJobs, stuck: st.stuck,
                        linkMissing: st.linkMissing, platforms: rows)
    if json { try printJSON(out); return ready ? 0 : 2 }

    let conn: String
    switch state {
    case "connected": conn = "connected (checked now)"
    case "no_key": conn = "not connected · no API key saved"
    case "key_invalid": conn = "key refused · \(st.keyInvalid!.isEmpty ? "401" : st.keyInvalid!)"
    case "rate_limited": conn = "rate limited · paused until \(fmt(st.pausedUntil!, settings))"
    case "unreachable": conn = "didn't answer · \(st.checkError ?? "?")"
    default: conn = "key saved · not checked (--offline)"
    }
    print("Postiz     \(conn)")
    print("API        \(st.apiBase == PublishingSettings.cloudAPIBase ? "cloud" : st.apiBase)")
    print("Budget     \(st.budgetUsed)/\(st.budgetLimit) calls this hour\(paused ? " · paused until \(fmt(st.pausedUntil!, settings)) (429)" : "")")
    print("Test run   \(st.testMode ? "ON — TikTok → inbox, YouTube → unlisted, others → Postiz drafts" : "off")")
    print("Last sync  \(ago(st.lastSync, now, settings)) · channels listed \(ago(st.channelsFetchedAt, now, settings))")
    let allStates = Dictionary(grouping: open, by: { $0.remoteState ?? $0.phase.rawValue }).mapValues(\.count)
    print("In Postiz  \(st.openJobs) open\(allStates.isEmpty ? "" : " (" + allStates.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + ")")")
    print("")
    for (r, row) in zip(st.platforms, rows) {
      var line = "  \(pad(r.platform.displayName, 15)) \(pad(r.publisher.displayName, 7)) \(pad(channelLabel(r.channelId, cache, ids: ids), 44))"
      switch r.route {
      case "postiz": line += " → Postiz"
      case "fallback": line += " → Today: \(r.fallback ?? "?")"
      default: line += " → Today (manual)"
      }
      if let t = row.testRun { line += " · test: \(t)" }
      if r.openJobs > 0 { line += " · \(r.openJobs) in Postiz (" + row.remoteStates.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")" }
      print(line)
    }
    if !st.stuck.isEmpty { print("\nStuck      \(st.stuck.count) post(s) still QUEUE an hour after the slot (djq doctor: postiz.stuck)") }
    if !st.linkMissing.isEmpty { print("No link    " + st.linkMissing.map { short($0) }.joined(separator: " ") + " (djq postiz link <post>)") }
    print("")
    if ready {
      print("Ready: connected, all six channels mapped.")
    } else {
      print("Not ready:")
      for p in problems { print("  - \(p)") }
      if problems.isEmpty { print("  - connection not checked (run without --offline)") }
    }
    return ready ? 0 : 2
  }

  // MARK: channels

  static func channels(_ store: Store, _ svc: PostizService, json: Bool, ids: Bool, cached: Bool, refresh: Bool, wrote: inout Bool) throws -> Int32 {
    let settings = try store.settings()
    var list: [PostizIntegration], note: String?
    if cached {
      guard let c = try cache(store) else { throw CLIError("no cached channel list yet — run `djq postiz channels`") }
      list = c.integrations
      note = "cached list from \(fmt(c.fetchedAt, settings))"
    } else {
      let r = try channelList(store, svc)
      list = r.list
      note = r.note
      wrote = r.live
    }
    list.sort { ($0.platform.map { Platform.allCases.sorted().firstIndex(of: $0)! } ?? 99, $0.name) < ($1.platform.map { Platform.allCases.sorted().firstIndex(of: $0)! } ?? 99, $1.name) }
    var limits: [String: Int?] = [:], errors: [String: String] = [:]
    let djq = list.filter { $0.platform != nil }
    if cached || note != nil {
      let c: PostizCaptionLimits = try store.kv(PostizCaptionLimits.kvKey) ?? PostizCaptionLimits()
      for ch in djq { if let e = c.entries[ch.id] { limits[ch.id] = e.maxLength } }
    } else {
      (limits, errors) = try svc.captionLimits(for: djq, refresh: refresh)
    }
    struct Row: Encodable {
      var name: String; var provider: String; var platform: String?; var mappedTo: [String]; var disabled: Bool
      var captionMax: Int?; var captionMaxError: String?; var djQueueCaptionLimit: Int?; var id: String?
    }
    let rows = list.map { c -> Row in
      let mapped = Platform.allCases.sorted().filter { settings.publishing.channels[$0] == c.id }.map(\.rawValue)
      return Row(name: c.name, provider: c.identifier, platform: c.platform?.rawValue, mappedTo: mapped, disabled: c.disabled,
                 captionMax: limits[c.id] ?? nil, captionMaxError: errors[c.id],
                 djQueueCaptionLimit: c.platform.flatMap { settings.limits[$0]?.captionLimit }, id: ids ? c.id : nil)
    }
    if json {
      struct Out: Encodable { var note: String?; var channels: [Row] }
      try printJSON(Out(note: note, channels: rows))
      return 0
    }
    print("Postiz channels\(note.map { " · \($0)" } ?? "")")
    if rows.isEmpty { print("  (none connected in Postiz)") }
    for r in rows {
      let cap = r.captionMax.map { "caption ≤ \($0)" } ?? (r.captionMaxError != nil ? "caption ?" : "caption —")
      let dj = r.djQueueCaptionLimit.map { " (DJ Queue \($0))" } ?? ""
      print("  \(pad(r.name, 28)) \(pad(r.provider, 22)) \(pad(r.platform.flatMap { Platform(rawValue: $0)?.displayName } ?? "not used", 15)) \(pad(cap + dj, 30))"
            + (r.mappedTo.isEmpty ? "" : " mapped: " + r.mappedTo.joined(separator: ", "))
            + (r.disabled ? " [disabled]" : "") + (r.id.map { " · id \($0)" } ?? ""))
    }
    if let e = errors.values.first { print("  (some caption limits couldn't be read: \(e))") }
    return 0
  }

  // MARK: Settings changes

  struct Change: Encodable { var platform: String?; var field: String; var from: String; var to: String }
  struct ChangeOut: Encodable {
    var command: String; var dryRun: Bool; var applied: Bool; var changes: [Change]; var notes: [String]
    var goesLive: [String]; var needsYes: Bool; var batchId: String?
  }

  static func diff(_ a: Settings, _ b: Settings, _ cache: PostizChannelCache?, ids: Bool) -> [Change] {
    var out: [Change] = []
    for p in Platform.allCases.sorted() {
      let pa = a.publishing.publisher(for: p), pb = b.publishing.publisher(for: p)
      if pa != pb { out.append(.init(platform: p.rawValue, field: "publisher", from: pa.displayName, to: pb.displayName)) }
      let ca = a.publishing.channels[p], cb = b.publishing.channels[p]
      if ca != cb { out.append(.init(platform: p.rawValue, field: "channel", from: channelLabel(ca, cache, ids: ids), to: channelLabel(cb, cache, ids: ids))) }
    }
    if a.publishing.testMode != b.publishing.testMode {
      out.append(.init(platform: nil, field: "test run", from: a.publishing.testMode ? "on" : "off", to: b.publishing.testMode ? "on" : "off"))
    }
    return out
  }

  /// Platforms whose approved posts would start going out for real through Postiz after this change.
  static func goesLive(_ a: Settings, _ b: Settings) -> [Platform] {
    guard !b.publishing.testMode else { return [] }
    return Platform.allCases.sorted().filter { p in
      guard b.publishing.publisher(for: p) == .postiz, b.publishing.channels[p] != nil, b.enabledPlatforms.contains(p) else { return false }
      return a.publishing.publisher(for: p) != .postiz || a.publishing.channels[p] != b.publishing.channels[p] || a.publishing.testMode
    }
  }

  static func change(_ store: Store, _ command: String, json: Bool, ids: Bool, notes: [String] = [], wrote: inout Bool,
                     _ edit: (inout Settings) throws -> Void) throws -> Int32 {
    let dry = flag("--dry-run"), yes = flag("--yes")
    let before = try store.settings()
    var after = before
    try edit(&after)
    let cache = try cache(store)
    let changes = diff(before, after, cache, ids: ids)
    let live = goesLive(before, after)
    var out = ChangeOut(command: "postiz \(command)", dryRun: dry, applied: false, changes: changes, notes: notes,
                        goesLive: live.map(\.rawValue), needsYes: !live.isEmpty && !yes, batchId: nil)
    let blocked = !dry && out.needsYes && !changes.isEmpty
    if !dry && !blocked && !changes.isEmpty {
      let r = try BulkActions(store: store).record("postiz \(command)", settings: true) { try store.save(after) }
      out.batchId = r.batchId
      out.applied = true
      wrote = true
      try store.logEvent("postiz", "Settings → Publishing changed from djq: "
                         + changes.map { "\($0.platform.flatMap { Platform(rawValue: $0)?.displayName }.map { $0 + " " } ?? "")\($0.field) \($0.from) → \($0.to)" }.joined(separator: "; "))
    }
    if json {
      try printJSON(out)
    } else {
      if changes.isEmpty { print("postiz \(command): nothing to change") }
      else {
        print("\(dry ? "[dry run] would change" : blocked ? "not changed (needs --yes)" : "changed"):")
        for c in changes {
          print("  \(c.platform.flatMap { Platform(rawValue: $0)?.displayName }.map { pad($0, 15) } ?? pad("", 15)) \(pad(c.field, 9)) \(c.from) → \(c.to)")
        }
      }
      for n in notes { print("  note: \(n)") }
      if !live.isEmpty && !changes.isEmpty {
        print("  \(blocked || dry ? "would schedule" : "schedules") real posts: from the next tick, approved posts for "
              + live.map(\.displayName).joined(separator: ", ") + " go out through Postiz (test run is off).")
        if blocked { print("  That's Eric's call: run it again with --yes (or --dry-run to preview).") }
      }
      if let b = out.batchId { print("  undo: djq bulk undo \(short(b))") }
    }
    return blocked ? 1 : 0
  }

  // MARK: map

  static func map(_ store: Store, _ svc: PostizService, json: Bool, ids: Bool, wrote: inout Bool) throws -> Int32 {
    let clear = flag("--clear")
    if let raw = args.first(where: { !$0.hasPrefix("--") }) {
      let p = try platform(raw)
      args.removeAll { $0 == raw }
      if clear {
        return try change(store, "map \(p.rawValue) --clear", json: json, ids: ids, wrote: &wrote) { $0.publishing.channels[p] = nil }
      }
      guard let want = args.first(where: { !$0.hasPrefix("--") }) else { throw CLIError("map <platform> <channel name|id> | map <platform> --clear") }
      args.removeAll { $0 == want }
      let (list, note, live) = try channelList(store, svc)
      if live { wrote = true }  // the cached channel list was refreshed
      let lw = want.lowercased()
      let m = list.filter { $0.id == want }.nonEmpty ?? list.filter { $0.name.lowercased() == lw }.nonEmpty
        ?? list.filter { $0.name.lowercased().contains(lw) }
      guard m.count == 1 else {
        throw CLIError(m.isEmpty ? "no Postiz channel matches \"\(want)\" (djq postiz channels)"
                                 : "\"\(want)\" matches \(m.count) channels: \(m.map(\.name).joined(separator: ", ")) — use the full name or --ids")
      }
      guard m[0].platform == p else {
        throw CLIError("\(m[0].name) is a \(m[0].identifier) channel, not for \(p.displayName) — nothing changed")
      }
      var notes = [note].compactMap { $0 }
      if m[0].identifier != PostizPlatforms.provider(p) { notes.append("\(m[0].identifier) isn't the provider DJ Queue expects for \(p.displayName) (\(PostizPlatforms.provider(p)))") }
      if m[0].disabled { notes.append("\(m[0].name) is disabled or expired in Postiz; posts go to Today until it's reconnected") }
      return try change(store, "map \(p.rawValue)", json: json, ids: ids, notes: notes, wrote: &wrote) { $0.publishing.channels[p] = m[0].id }
    }
    let (list, note, live) = try channelList(store, svc)
    if live { wrote = true }  // the cached channel list was refreshed
    let settings = try store.settings()
    var picks: [Platform: String] = [:]
    var notes = [note].compactMap { $0 }
    for p in Platform.allCases.sorted() {
      let want = PostizPlatforms.provider(p)
      let exact = list.filter { $0.identifier == want }
      if let cur = settings.publishing.channels[p], exact.contains(where: { $0.id == cur }) {
        picks[p] = cur
        continue
      }
      switch exact.count {
      case 1:
        picks[p] = exact[0].id
        if exact[0].disabled { notes.append("\(p.displayName): \(exact[0].name) is disabled or expired in Postiz (reconnect it there)") }
      case 0:
        let near = list.filter { $0.platform == p }
        notes.append("\(p.displayName): no \(want) channel in Postiz"
                     + (near.isEmpty ? "" : " (found \(near.map { "\($0.name) [\($0.identifier)]" }.joined(separator: ", ")); map it by hand if it's the DJ account: djq postiz map \(p.rawValue) \"<name>\")"))
      default:
        notes.append("\(p.displayName): \(exact.count) \(want) channels (\(exact.map(\.name).joined(separator: ", "))) — pick the DJ Lovd one: djq postiz map \(p.rawValue) \"<name>\"")
      }
    }
    return try change(store, "map", json: json, ids: ids, notes: notes, wrote: &wrote) { s in
      for (p, id) in picks { s.publishing.channels[p] = id }
    }
  }

  // MARK: publisher / test-mode

  static func publisher(_ store: Store, json: Bool, ids: Bool, wrote: inout Bool) throws -> Int32 {
    let rest = args.filter { !$0.hasPrefix("--") }
    guard rest.count == 2, let kind = PublisherKind(rawValue: rest[1].lowercased()) else {
      throw CLIError("publisher <platform|all> manual|postiz [--dry-run] [--yes]")
    }
    let ps = rest[0].lowercased() == "all" ? Platform.allCases.sorted() : [try platform(rest[0])]
    args.removeAll { rest.contains($0) }
    let settings = try store.settings()
    var notes: [String] = []
    if kind == .postiz {
      let unmapped = ps.filter { settings.publishing.channels[$0] == nil }
      if !unmapped.isEmpty {
        notes.append("no channel mapped for \(unmapped.map(\.displayName).joined(separator: ", ")): their posts go to Today until `djq postiz map`")
      }
      let off = ps.filter { !settings.enabledPlatforms.contains($0) }
      if !off.isEmpty { notes.append("\(off.map(\.displayName).joined(separator: ", ")) \(off.count == 1 ? "is" : "are") turned off in Settings → Platforms (nothing posts there)") }
    }
    return try change(store, "publisher \(rest[0].lowercased()) \(kind.rawValue)", json: json, ids: ids, notes: notes, wrote: &wrote) { s in
      for p in ps { s.publishing.publishers[p] = kind == .manual ? nil : .postiz }
    }
  }

  static func testMode(_ store: Store, json: Bool, ids: Bool, wrote: inout Bool) throws -> Int32 {
    guard let raw = args.first(where: { !$0.hasPrefix("--") }), raw == "on" || raw == "off" else {
      throw CLIError("test-mode on|off [--dry-run] [--yes]")
    }
    args.removeAll { $0 == raw }
    let open = try store.openPostizJobs().filter { $0.kind == "post" }.count
    var notes = raw == "off"
      ? ["posts Postiz already published keep their Test badge"]
      : ["TikTok → the TikTok inbox, YouTube → unlisted, Instagram/Facebook/Threads/X → Postiz drafts"]
    if open > 0 {
      notes.append("\(open) post\(open == 1 ? "" : "s") waiting in Postiz \(open == 1 ? "is" : "are") replaced on the next tick by "
                   + (raw == "off" ? "real scheduled posts" : "test-run versions"))
    }
    return try change(store, "test-mode \(raw)", json: json, ids: ids, notes: notes, wrote: &wrote) { $0.publishing.testMode = raw == "on" }
  }

  // MARK: test

  static func test(_ store: Store, _ svc: PostizService, json: Bool, ids: Bool, wrote: inout Bool) throws -> Int32 {
    let dry = flag("--dry-run"), draft = flag("--draft"), yes = flag("--yes")
    let v = try resolveVideo(store, try arg(0, "video id"))
    if dry && draft { throw CLIError("pick one: --dry-run (no call) or --draft (Postiz drafts)") }
    guard dry || draft else {
      throw CLIError(yes
        ? "djq postiz test never schedules real posts: they'd bypass DJ Queue's tracking (no double-post guard, no live links back). Real posts go out only from an approved week (docs/postiz-test.md). Use --dry-run or --draft."
        : "djq postiz test needs --dry-run (prints the six payloads, no call) or --draft (Postiz drafts only, nothing reaches a platform)")
    }
    let settings = try store.settings()
    if draft && settings.publishing.channels.isEmpty { throw CLIError("no Postiz channel mapped yet — `djq postiz map` first") }
    let r = try svc.testPost(videoId: v.id, draft: draft)
    if draft { wrote = true }
    let cache = try cache(store)
    // Channel ids stay out of the output unless --ids (they're in the body's integration.id).
    func redact(_ s: String) -> String {
      guard !ids else { return s }
      var s = s
      for id in Set(settings.publishing.channels.values) where !id.isEmpty { s = s.replacingOccurrences(of: "\"\(id)\"", with: "\"<channel id>\"") }
      return s
    }
    var out = r
    out.platforms = r.platforms.map { row in
      var row = row
      row.body = redact(row.body)
      if !ids { row.channelId = row.channelId == nil ? nil : "<channel id>" }
      return row
    }
    if json { try printJSON(out); return 0 }
    print("\(draft ? "Postiz drafts" : "Dry run (no call)") for \(v.tag) · render \(short(r.renderId)) · test run \(settings.publishing.testMode ? "on" : "off")")
    print("Headers: " + r.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
    for row in out.platforms {
      let ch = channelLabel(r.platforms.first { $0.platform == row.platform }?.channelId, cache, ids: ids)
      var head = "── \(row.platform.displayName) → \(ch)"
      if let s = row.skipped { head += " · skipped: \(s)" }
      if let id = row.postizId { head += " · draft \(id) saved in Postiz" }
      print(head)
      if !draft || row.postizId != nil { print(row.body) }
    }
    if draft { print("Nothing reaches a platform: release or delete the drafts in the Postiz calendar.") }
    return 0
  }

  // MARK: link / release / sync

  static func link(_ store: Store, _ svc: PostizService, json: Bool, wrote: inout Bool) throws -> Int32 {
    let releaseOpt = option("--release-id")
    let p = try resolvePost(store, try arg(0, "post id"))
    let candidates = try svc.linkCandidates(postId: p.id)
    struct Cand: Encodable { var id: String; var url: String }
    guard args.count > 1 else {
      if json { try printJSON(candidates.map { Cand(id: $0.id, url: $0.url) }); return 0 }
      print("\(p.platform.displayName) · \(tagOf(store, p.videoId)) · recent posts on the platform (pick the one Postiz published):")
      if candidates.isEmpty { print("  (none returned)") }
      for c in candidates { print("  \(pad(c.id, 24)) \(c.url)") }
      print("Set it: djq postiz link \(short(p.id)) <url>")
      return 0
    }
    let a = args[1]
    let releaseId: String, url: String
    if a.lowercased().hasPrefix("http") {
      url = a
      guard let id = releaseOpt ?? candidates.first(where: { $0.url == a })?.id else {
        throw CLIError("\(a) isn't one of the platform's recent posts — pass --release-id <the platform's post id>")
      }
      releaseId = id
    } else {
      guard let c = candidates.first(where: { $0.id == a }) else { throw CLIError("\(a) isn't one of the listed post ids (djq postiz link \(short(p.id)))") }
      releaseId = c.id
      url = c.url
    }
    try svc.link(postId: p.id, releaseId: releaseId, url: url)
    wrote = true
    if json { try printJSON(Cand(id: releaseId, url: url)); return 0 }
    print("linked \(p.platform.displayName) · \(tagOf(store, p.videoId)) → \(url)")
    return 0
  }

  static func release(_ store: Store, _ svc: PostizService, json: Bool, wrote: inout Bool) throws -> Int32 {
    let yes = flag("--yes")
    let p = try resolvePost(store, try arg(0, "post id"))
    guard yes else {
      throw CLIError("releasing the draft makes \(p.platform.displayName) · \(tagOf(store, p.videoId)) post for real at its time — Eric's call: add --yes")
    }
    try svc.releaseDraft(postId: p.id)
    wrote = true
    if json { try printJSON(["released": p.id]); return 0 }
    print("released \(p.platform.displayName) · \(tagOf(store, p.videoId)): Postiz posts it at \(fmt(p.scheduledAt, try store.settings()))")
    return 0
  }

  static func sync(_ store: Store, _ svc: PostizService, json: Bool, wrote: inout Bool) throws -> Int32 {
    let force = flag("--force")
    let lock = EngineLock.acquire(store.paths)
    if lock == nil && !force {
      // DJ Queue's engine owns the tick: ask it (one engine per database).
      try svc.requestSync()
      ChangeSignal.post()
      if json { try printJSON(["result": "asked DJ Queue's engine to sync on its next tick"]); return 0 }
      print("Engine is running in DJ Queue; asked it to sync now (see djq postiz status in a minute)")
      return 0
    }
    defer { lock?.release() }
    let r = try svc.sync(force: true)
    wrote = true
    if json { try printJSON(["result": r]); return 0 }
    print("sync: \(r)")
    return 0
  }
}

extension Array {
  var nonEmpty: [Element]? { isEmpty ? nil : self }
}
