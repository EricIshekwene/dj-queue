import Foundation

/// What a clip's latest version says (carry-forward applied): the text you typed, never a template filled in.
public struct SearchClipText: Sendable, Hashable {
  public var text = ""
  public var caption = ""
  public var platformCaptions: [String] = []
  public var hashtags: [String] = []
  public var youtubeTitle = ""
  public init() {}
}

/// Everything the corpus reads. Filled in the model's off-main load.
public struct SearchInput: Sendable {
  public var settings: Settings
  public var sessions: [Session]
  public var videos: [Video]
  public var posts: [PlatformPost]
  public var weekStates: [String: WeekState]
  /// Planned clips per week start.
  public var weekClips: [String: Int]
  public var clipText: [String: SearchClipText]
  public var hashtagSets: [HashtagSet]
  public var captionTemplates: [CaptionTemplate]
  public var now: Date

  public init(settings: Settings, sessions: [Session], videos: [Video], posts: [PlatformPost], weekStates: [String: WeekState],
              weekClips: [String: Int], clipText: [String: SearchClipText], hashtagSets: [HashtagSet],
              captionTemplates: [CaptionTemplate], now: Date) {
    self.settings = settings
    self.sessions = sessions
    self.videos = videos
    self.posts = posts
    self.weekStates = weekStates
    self.weekClips = weekClips
    self.clipText = clipText
    self.hashtagSets = hashtagSets
    self.captionTemplates = captionTemplates
    self.now = now
  }
}

/// Item ids. Each one is enough to rebuild its palette row later (a recent), or to find it's gone.
public enum SearchId {
  public static func clip(_ id: String) -> String { "clip.\(id)" }
  public static func post(_ id: String) -> String { "search.post.\(id)" }
  public static func week(_ key: String) -> String { "search.week.\(key)" }
  public static func session(_ id: String) -> String { "search.session.\(id)" }
  public static func setting(_ entryId: String) -> String { "search.setting.\(entryId)" }
  public static func pane(_ p: SettingsPane) -> String { "search.pane.\(p.rawValue)" }
  public static func health(_ id: String) -> String { "search.health.\(id)" }
}

/// A place worth finding by name. Opens Health, or the screen that shows it.
public struct HealthPlace: Sendable, Hashable {
  public var id: String
  public var title: String
  public var subtitle: String
  public var words: String

  public static let all: [HealthPlace] = [
    HealthPlace(id: "engine", title: "Engine status", subtitle: "Is the engine running, and when it last ticked", words: "heartbeat tick background"),
    HealthPlace(id: "runway", title: "Runway", subtitle: "Days of clips left, approved and in total", words: "days left approved"),
    HealthPlace(id: "backups", title: "Backups", subtitle: "When the database was last copied", words: "backup database copy"),
    HealthPlace(id: "awake", title: "Awake chart", subtitle: "When this Mac was awake, last 7 days", words: "sleep missed slots timeline"),
    HealthPlace(id: "doctor", title: "Doctor findings", subtitle: "What Doctor found, and how to fix it", words: "problems report check"),
    HealthPlace(id: "disk", title: "Disk space", subtitle: "Free space for renders", words: "storage free"),
    HealthPlace(id: "renders", title: "Render queue", subtitle: "Posts being made into video", words: "rendering ffmpeg proxies"),
  ]
}

/// Builds the data half of the search index (clips, posts, weeks, sessions, settings, Health). Actions and Go to
/// depend on the current selection, so the palette indexes those itself. Pure: same input, same items.
public enum SearchCorpus {
  public static func index(_ i: SearchInput) -> SearchIndex { SearchIndex(items: items(i)) }

  public static func items(_ i: SearchInput) -> [SearchItem] {
    let dm = DayMath(settings: i.settings)
    let sessions = Dictionary(i.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let videos = Dictionary(i.videos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [SearchItem] = []
    out.reserveCapacity(i.videos.count + i.posts.count + 200)
    for (n, v) in i.videos.enumerated() { out.append(clip(v, rank: n, session: sessions[v.sessionId], text: i.clipText[v.id])) }
    let nowT = i.now.timeIntervalSince1970
    let byNearness = i.posts.sorted { (abs($0.scheduledAt.timeIntervalSince1970 - nowT), $0.id) < (abs($1.scheduledAt.timeIntervalSince1970 - nowT), $1.id) }
    for (n, p) in byNearness.enumerated() {
      let v = videos[p.videoId]
      out.append(post(p, rank: n, clip: v.map { name($0, session: sessions[$0.sessionId]) } ?? p.videoId, day: dm.key(p.scheduledAt)))
    }
    out += weeks(i, dm: dm)
    out += sessionItems(i)
    out += settingsItems(i)
    out += HealthPlace.all.enumerated().map { n, h in
      SearchItem(id: SearchId.health(h.id), kind: .health, title: h.title,
                 fields: [SearchField("", h.subtitle), SearchField("", h.words)], rank: n)
    }
    return out
  }

  /// `Video.displayName`, or "Set · Part N" for an untitled long-form part (the app's own display name).
  static func name(_ v: Video, session: Session?) -> String {
    if v.type == .long && v.titleText == nil { return "\(Captions.setName(session?.name ?? "")) · Part \(v.part ?? 1)" }
    return v.displayName
  }

  static func clip(_ v: Video, rank: Int, session: Session?, text: SearchClipText?) -> SearchItem {
    var f: [SearchField] = []
    func add(_ label: String, _ t: String?) {
      guard let t, !t.isEmpty, !f.contains(where: { $0.text == t }) else { return }
      f.append(SearchField(label, t))
    }
    let title = name(v, session: session)
    // Most telling first: a tie between two fields shows the one that says most about the clip.
    add("Tag", v.tag == title ? nil : v.tag)
    if let text {
      add("Text", text.text == title ? nil : text.text)
      add("Caption", text.caption)
      for c in text.platformCaptions { add("Caption", c) }
      add("Hashtags", text.hashtags.joined(separator: " "))
      add("YouTube title", text.youtubeTitle)
    }
    for t in v.titleTracks ?? [] { add("Track", [t.title, t.artist].compactMap { $0 }.joined(separator: " · ")) }
    add("Notes", v.notes)
    add("Session", session.map { Captions.setName($0.name) })
    add("File", v.file)
    add("File", v.name == v.tag ? nil : v.name)
    add("Kind", v.kind.displayName)
    add("Stage", ClipStage.of(v)?.displayName)
    if v.excluded { add("State", "Excluded") }
    if v.missing { add("State", "File missing") }
    if v.type == .long { add("Type", "Long-form") }
    return SearchItem(id: SearchId.clip(v.id), kind: .clip, title: title, fields: f, rank: rank)
  }

  static func post(_ p: PlatformPost, rank: Int, clip: String, day: String) -> SearchItem {
    var f = [SearchField("Platform", p.platform.displayName, role: .primary)]
    func add(_ label: String, _ t: String?) { if let t, !t.isEmpty { f.append(SearchField(label, t)) } }
    add("State", p.state.displayName)
    if p.stateLabel != p.state.displayName { add("State", p.stateLabel) }
    add("Problem", p.errorType?.displayName)
    add("Error", p.errorMessage)
    add("Link", p.url)
    add("Post ID", p.externalId)
    for d in dayPhrases(day, year: false) { f.append(SearchField("Date", d, role: .phrase)) }
    return SearchItem(id: SearchId.post(p.id), kind: .post, title: "\(p.platform.displayName) · \(clip)", fields: f, rank: rank)
  }

  /// Every week with a plan or a state, plus this, next and last week; nearest first.
  static func weeks(_ i: SearchInput, dm: DayMath) -> [SearchItem] {
    let this = dm.weekStart(of: i.now), next = dm.addDays(this, 7), last = dm.addDays(this, -7)
    let keys = Set(i.weekStates.keys).union(i.weekClips.keys).union([this, next, last])
    // Same distance: the coming week before the past one.
    let distance = Dictionary(uniqueKeysWithValues: keys.map { ($0, dm.days(from: this, to: $0)) })
    let ordered = keys.sorted { (abs(distance[$0] ?? 0), -(distance[$0] ?? 0)) < (abs(distance[$1] ?? 0), -(distance[$1] ?? 0)) }
    return ordered.enumerated().map { n, ws in
      var f: [SearchField] = []
      switch ws {
      case this: f.append(SearchField("", "this week", role: .phrase))
      case next: f.append(SearchField("", "next week", role: .phrase))
      case last: f.append(SearchField("", "last week", role: .phrase))
      default: break
      }
      for d in dm.weekDays(ws) { f += dayPhrases(d, year: true).map { SearchField("", $0, role: .phrase) } }
      if let st = i.weekStates[ws] { f.append(SearchField("State", st == .approved ? (ws <= dm.key(i.now) ? "Locked" : "Approved") : "Draft")) }
      return SearchItem(id: SearchId.week(ws), kind: .week, title: "Week of \(shortDay(ws))", fields: f, rank: n)
    }
  }

  static func sessionItems(_ i: SearchInput) -> [SearchItem] {
    let used = Set(i.videos.map(\.sessionId))
    return i.sessions.filter { used.contains($0.id) }.sorted { ($0.date ?? "", $0.name) > ($1.date ?? "", $1.name) }.enumerated().map { n, s in
      var f: [SearchField] = []
      let set = Captions.setName(s.name)
      if set != s.name { f.append(SearchField("Folder", s.name, role: .primary)) }
      if let d = s.date { f += dayPhrases(d, year: true).map { SearchField("", $0, role: .phrase) } }
      return SearchItem(id: SearchId.session(s.id), kind: .session, title: set, fields: f, rank: n)
    }
  }

  static func settingsItems(_ i: SearchInput) -> [SearchItem] {
    var out = SettingsPane.allCases.enumerated().map { n, p in
      SearchItem(id: SearchId.pane(p), kind: .setting, title: p.title, fields: [SearchField("Section", "settings")], rank: n)
    }
    let start = out.count
    out += SettingsSearchRegistry.all.filter { $0.isDrawn(i.settings) }.enumerated().map { n, e in
      var f = [SearchField("Section", e.pane.title)]
      if let g = e.group { f.append(SearchField("Group", g)) }
      if let d = e.description { f.append(SearchField("", d)) }
      return SearchItem(id: SearchId.setting(e.id), kind: .setting, title: e.title, fields: f, rank: start + n)
    }
    func entry(_ pane: SettingsPane, _ anchor: String) -> String { SearchId.setting("\(pane.rawValue).\(anchor)") }
    let extra = out.count
    out += i.hashtagSets.enumerated().map { n, s in
      SearchItem(id: entry(.captions, SettingsAnchor.hashtagGroup(s.id)), kind: .setting, title: s.name,
                 fields: [SearchField("Hashtag group", "hashtag group"), SearchField("Hashtags", s.tags.joined(separator: " "))], rank: extra + n)
    }
    out += i.captionTemplates.enumerated().map { n, t in
      SearchItem(id: entry(.captions, SettingsAnchor.captionTemplate(t.id)), kind: .setting, title: t.name,
                 fields: [SearchField("Caption template", "caption template"), SearchField("Template", t.template)],
                 rank: extra + i.hashtagSets.count + n)
    }
    out += i.settings.youtubeTitleTemplates.enumerated().map { n, t in
      SearchItem(id: entry(.captions, SettingsAnchor.titleTemplate(t.id)), kind: .setting, title: t.name,
                 fields: [SearchField("YouTube title template", "youtube title template"), SearchField("Template", t.template)],
                 rank: extra + i.hashtagSets.count + i.captionTemplates.count + n)
    }
    return out
  }

  // MARK: Dates (English, like the rest of the app; never the Mac's language)

  private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                               "november", "december"]

  private static func parts(_ key: String) -> (year: Substring, month: Int, day: Int)? {
    let p = key.split(separator: "-")
    guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m) else { return nil }
    return (p[0], m, d)
  }

  /// "12 nov", "november 12", "2026-11-12"… for one YYYY-MM-DD key.
  static func dayPhrases(_ key: String, year: Bool) -> [String] {
    guard let (y, m, d) = parts(key) else { return [key] }
    let full = months[m - 1], short = String(full.prefix(3))
    var out = ["\(d) \(short)", "\(d) \(full)", "\(short) \(d)", "\(full) \(d)", key]
    if year { out += ["\(d) \(short) \(y)", "\(d) \(full) \(y)", "\(short) \(d) \(y)", "\(full) \(d) \(y)"] }
    return out
  }

  /// "9 Nov".
  static func shortDay(_ key: String) -> String {
    guard let (_, m, d) = parts(key) else { return key }
    return "\(d) \(months[m - 1].prefix(3).capitalized)"
  }
}

extension Store {
  /// The latest version's text per clip, in one query (the off-main refresh load). Only what you typed: a caption
  /// that follows a template is found through that template in Settings.
  public func searchClipText(videos: [Video], settings: Settings, sets: [HashtagSet]) throws -> [String: SearchClipText] {
    var chains: [String: [Version]] = [:]
    for r in try db.query("SELECT video_id, json FROM versions ORDER BY video_id, number") {
      guard let id = r.string("video_id"), let s = r.string("json"), let v = try? JSONCoding.decoder.decode(Version.self, from: Data(s.utf8))
      else { continue }
      chains[id, default: []].append(v)
    }
    var out: [String: SearchClipText] = [:]
    for video in videos {
      let chain = chains[video.id] ?? []
      let r = VersionResolver.resolve(chain.isEmpty ? [Version(number: 1)] : chain, number: chain.last?.number ?? 1, settings: settings, video: video)
      var t = SearchClipText()
      if !r.noText { t.text = r.text }
      t.caption = r.caption
      t.platformCaptions = r.platformCaptions.keys.sorted().compactMap { r.platformCaptions[$0] }
      t.hashtags = Captions.hashtags(r, sets: sets)
      t.youtubeTitle = r.youtubeTitle
      out[video.id] = t
    }
    return out
  }
}

extension PlatformPost {
  /// The word every post row shows for its state, so what you read is what you can type.
  public var stateLabel: String {
    switch state {
    case .posted: "Posted"
    case .failed: resolution == nil ? (errorType?.displayName ?? "Failed") : "Retried"
    case .copyrightBlocked, .copyrightMuted, .removed:
      switch resolution {
      case "accepted": "Accepted"
      case "reuploaded": "Re-uploaded"
      default: state == .removed ? "Removed" : state == .copyrightMuted ? "Muted" : "Blocked"
      }
    case .overdue: "Missed"
    case .due: "Due now"
    case .planned: "Planned"
    case .rendering: "Rendering"
    case .rendered: "Rendered"
    case .skipped: "Skipped"
    }
  }
}
