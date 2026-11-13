import Foundation

/// Round 31 (DECISIONS-R31.md): every version of a clip is its own post in the plan. A clip's units are each version × that
/// version's post count (`Settings.postsPerVersion`, 2 by default; a version can set its own, `Version.postCount`), and the
/// planner schedules units, never clips: "v1 · 1 of 2", "v2 · 1 of 2", "v1 · 2 of 2", …
///
/// A unit is done on a platform once any post of it exists there (posted, live, failed with its retries, or skipped by
/// Eric), and for v1 · post 1 also when Eric marked the clip already posted there. A unit needs a day while it has no slot
/// and some active platform the clip isn't turned off for still lacks it. All versions of a clip share the clip's score:
/// the Queue order is the clip's.
public enum PostUnits {
  /// kv: `[videoId: highest version number]` of the clips that had finished posting when round 31 installed (schema 12).
  /// Those versions keep the one post they had (v1 once, older v2+ never by themselves), so the update doesn't send the
  /// back catalogue out again; a version added later, or a count Eric sets, follows the new rule.
  public static let finishedKey = "plan.finishedBeforeR31"

  /// The most posts one version can ask for (the editor's stepper and `djq post-count` stop here).
  public static let maxCount = 9

  /// Post count of version `number`: its own, else the default (a clip finished before round 31 keeps what it had).
  public static func count(_ number: Int, own: Int?, settings: Settings, finishedUpTo: Int?) -> Int {
    if let own { return min(max(0, own), maxCount) }
    if let top = finishedUpTo, number <= top { return number == 1 ? 1 : 0 }
    return min(max(0, settings.postsPerVersion), maxCount)
  }
}

/// One clip's posts as the planner sees them, read once (`UnitBook`).
public struct ClipUnits: Sendable {
  public var videoId: String
  /// Version number → how many times it posts on each platform.
  public var counts: [Int: Int]
  /// Units with a plan slot (a stale past draft slot doesn't count: it can't post any more).
  public var slotted: Set<PostUnit>
  /// Platform → units that platform already has (any post row), plus v1 · post 1 where the clip was posted by hand before.
  public var taken: [Platform: Set<PostUnit>]
  /// Platforms the clip is turned off for in the editor.
  public var skipped: Set<Platform>
  /// Days the clip posts or posted on, with the version: slot days and the days of posts that have no slot.
  public var days: [(version: Int, day: String)]

  /// Every unit, in planning order (first posts before repeats, older versions first).
  public var all: [PostUnit] {
    counts.flatMap { n, c in (0..<c).map { PostUnit(version: n, post: $0 + 1) } }.sorted()
  }

  /// Total posts this clip makes per platform over all its versions.
  public var total: Int { counts.values.reduce(0, +) }

  public func needsPost(_ u: PostUnit, on platforms: [Platform]) -> Bool {
    platforms.contains { !skipped.contains($0) && !(taken[$0]?.contains(u) ?? false) }
  }

  /// Units still waiting for a day.
  public func pending(_ platforms: [Platform]) -> [PostUnit] {
    all.filter { !slotted.contains($0) && needsPost($0, on: platforms) }
  }

  /// The latest day ≤ `day` the clip posts on (nil when it has none yet).
  func lastDay(before day: String) -> String? { days.map(\.day).filter { $0 <= day }.max() }
}

/// Every clip's units, read from the whole database in a few queries (the engine and the UI call it every tick).
public struct UnitBook: Sendable {
  public private(set) var clips: [String: ClipUnits] = [:]
  public let settings: Settings

  public init(store: Store, settings: Settings? = nil, videos: [Video]? = nil) throws {
    let settings = try settings ?? store.settings()
    self.settings = settings
    let dm = DayMath(settings: settings)
    let vids = try videos ?? store.videos(where: "type='short-form'")
    let finished: [String: Int] = (try? store.kv(PostUnits.finishedKey, as: [String: Int].self)) ?? [:]
    var versions: [String: [Int: Int?]] = [:]
    for r in try store.db.query("SELECT video_id, number, json FROM versions") {
      guard let id = r.string("video_id"), let n = r.int("number") else { continue }
      let own = r.string("json").flatMap { try? JSONCoding.decoder.decode(Version.self, from: Data($0.utf8)) }?.postCount
      versions[id, default: [:]][n] = own
    }
    let stale = Set(try store.stalePastDraftSlots(today: dm.key(store.clock.now)).map(\.id))
    let slots = Dictionary(grouping: try store.planSlots().filter { !stale.contains($0.id) }, by: \.videoId)
    let posts = Dictionary(grouping: try store.posts(), by: \.videoId)
    let defaults = settings.defaults
    for v in vids where v.type == .short {
      var counts: [Int: Int] = [:]
      var own = versions[v.id] ?? [:]
      if own[1] == nil { own[1] = .some(nil) }
      for (n, c) in own { counts[n] = PostUnits.count(n, own: c, settings: settings, finishedUpTo: finished[v.id]) }
      var taken: [Platform: Set<PostUnit>] = [:]
      for p in v.alreadyPostedOn { taken[p, default: []].insert(.first) }
      var days: [(Int, String)] = []
      let mySlots = slots[v.id] ?? []
      let slotIds = Set(mySlots.map(\.id))
      for s in mySlots { days.append((s.versionNo, s.date)) }
      for p in posts[v.id] ?? [] {
        taken[p.platform, default: []].insert(p.unit)
        guard p.state != .skipped, !slotIds.contains(p.planSlotId ?? "") else { continue }
        if p.state == .posted || !p.state.isTerminal { days.append((p.versionNo, dm.key(p.postedAt ?? p.scheduledAt))) }
      }
      let edit = (try? store.edit(videoId: v.id)) ?? Edit()
      let skipped = Set(Platform.allCases.filter { edit.isSkipped($0, defaults: defaults) })
      clips[v.id] = ClipUnits(videoId: v.id, counts: counts, slotted: Set(mySlots.map(\.unit)), taken: taken, skipped: skipped,
                              days: days.map { (version: $0.0, day: $0.1) })
    }
  }

  public subscript(_ id: String) -> ClipUnits? { clips[id] }

  /// Units of `id` still waiting for a day, in planning order.
  public func pending(_ id: String) -> [PostUnit] { clips[id]?.pending(settings.activePlatforms) ?? [] }

  /// Post count of `version` on clip `id` (the default when the clip isn't short-form or unknown).
  public func count(_ id: String, version: Int) -> Int { clips[id]?.counts[version] ?? max(0, settings.postsPerVersion) }

  /// "v2 · 1 of 2" for a unit of clip `id`.
  public func label(_ id: String, _ u: PostUnit) -> String { u.label(of: count(id, version: u.version)) }

  public static func label(_ u: PostUnit, count: Int) -> String { u.label(of: count) }

  mutating func placed(_ id: String, _ u: PostUnit, day: String) {
    clips[id]?.slotted.insert(u)
    clips[id]?.days.append((version: u.version, day: day))
  }
}

/// Picks which unit takes an open (day, position), the round-31 spacing rules (DECISIONS-R31.md):
/// 1. two posts of one clip, any versions, are at least `sameClipGapDays` days apart (at least 1: never twice a day, so
///    never back to back), and the same version posts again only `sameVersionGapDays` after its previous post;
/// 2. among the clips that fit, the one that went longest without a post goes next (a clip with none yet first), so the
///    calendar goes round the clips; a tie goes to the Queue order (the clip's score, Settings → Queue sort);
/// 3. inside the clip, every version's first post comes before any repeat, older versions first.
/// 4. a clip's first post takes any open day up to the horizon (30 days); a clip that already has a day or a post
///    (its repeats and later versions) only takes days up to `repeatLimit` (a week ahead), so reposts never fill the
///    month ahead and a clip Eric sends to the Queue always finds a day within a week of what's already planned.
/// Nothing fits → the position stays open, and the next pass fills it when something does.
struct UnitPicker {
  var book: UnitBook
  /// Clip ids in the order ties go (the Queue order, or the relay's old order first).
  let order: [String]
  let dm: DayMath
  /// The last day a clip with a day or a post already may take (nil = no limit).
  let repeatLimit: String?
  /// Units that couldn't take a day in this pass (every platform was inside the lead or already done).
  var blocked: Set<String> = []

  init(book: UnitBook, order: [String], dm: DayMath, repeatLimit: String? = nil) {
    self.book = book
    self.order = order
    self.dm = dm
    self.repeatLimit = repeatLimit
  }

  static func key(_ id: String, _ u: PostUnit) -> String { "\(id)#\(u)" }

  /// The unit for `day`, or nil when no clip fits. `allowed` is the optional overlap rule (Settings → avoid overlap).
  func pick(day: String, allowed: (String) throws -> Bool = { _ in true }) rethrows -> (videoId: String, unit: PostUnit)? {
    let s = book.settings
    let clipGap = max(1, s.sameClipGapDays), versionGap = max(1, s.sameVersionGapDays)
    var best: (last: String, rank: Int, id: String, unit: PostUnit)?
    for (rank, id) in order.enumerated() {
      guard let c = book[id] else { continue }
      if let repeatLimit, day > repeatLimit, !c.days.isEmpty { continue }
      if c.days.contains(where: { abs(dm.days(from: $0.day, to: day)) < clipGap }) { continue }
      let unit = c.pending(s.activePlatforms).first { u in
        !blocked.contains(Self.key(id, u))
          && !c.days.contains { $0.version == u.version && abs(dm.days(from: $0.day, to: day)) < versionGap }
      }
      guard let unit, try allowed(id) else { continue }
      let last = c.lastDay(before: day) ?? ""
      if best == nil || (last, rank) < (best!.last, best!.rank) { best = (last, rank, id, unit) }
    }
    return best.map { ($0.id, $0.unit) }
  }

  mutating func placed(_ id: String, _ u: PostUnit, day: String) { book.placed(id, u, day: day) }

  mutating func block(_ id: String, _ u: PostUnit) { blocked.insert(Self.key(id, u)) }
}

extension Store {
  /// How many times version `version` of a clip posts on each platform.
  public func postCount(videoId: String, version: Int, settings: Settings? = nil) throws -> Int {
    let s = try settings ?? self.settings()
    let finished: [String: Int] = (try? kv(PostUnits.finishedKey, as: [String: Int].self)) ?? [:]
    let own = try versions(videoId: videoId).first { $0.number == version }?.postCount
    return PostUnits.count(version, own: own, settings: s, finishedUpTo: finished[videoId])
  }

  /// Units of a clip still waiting for a day (nothing for long-form).
  public func pendingUnits(videoId: String, settings: Settings? = nil) throws -> [PostUnit] {
    guard let v = try video(id: videoId), v.type == .short else { return [] }
    return try UnitBook(store: self, settings: settings, videos: [v]).pending(videoId)
  }

  /// Sets version `number`'s own post count (nil = back to the default). Writes only that version's JSON: `updated_at`
  /// stays (the count changes no pixels, so previews and renders aren't touched). The clip's state is refreshed, since
  /// a count decides whether it still has posts to make. Returns false when it was already that way.
  @discardableResult
  public func setPostCount(videoId: String, number: Int, _ count: Int?) throws -> Bool {
    guard let v = try video(id: videoId) else { throw EngineError("No video \(videoId)") }
    guard v.type == .short else { throw EngineError("\(v.tag) is long-form: long-form is never reposted") }
    if let count, !(0...PostUnits.maxCount).contains(count) {
      throw EngineError("A version posts 0 to \(PostUnits.maxCount) times on each platform")
    }
    var changed = false
    try db.transaction {
      let all = try versions(videoId: videoId)
      if var ver = all.first(where: { $0.number == number }) {
        guard ver.postCount != count else { return }
        ver.postCount = count
        try db.run("UPDATE versions SET json=? WHERE video_id=? AND number=?", [JSONCoding.string(ver), videoId, number])
      } else {
        guard number == 1 else { throw EngineError("\(v.tag) has no v\(number)") }
        guard count != nil else { return }
        var ver = Version(number: 1)
        ver.postCount = count
        // updated_at 0: v1 still looks exactly as before (its preview stamp only notes that a row exists).
        try db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,0)", [videoId, 1, JSONCoding.string(ver)])
      }
      changed = true
      try logEvent("version", count.map { "v\(number) posts \($0) time\($0 == 1 ? "" : "s") on each platform" }
                     ?? "v\(number) posts the default number of times", videoId: videoId)
      try refreshState(videoId: videoId)
    }
    return changed
  }
}
