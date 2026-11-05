import Foundation
import Testing

@testable import DJQCore

private func item(_ id: String, _ kind: SearchKind = .clip, title: String, _ fields: [SearchField] = [], rank: Int = 0) -> SearchItem {
  SearchItem(id: id, kind: kind, title: title, fields: fields, rank: rank)
}

private func ids(_ index: SearchIndex, _ q: String) -> [String] { index.search(SearchQuery(q)).map(\.id) }

@Suite struct R10SearchEngineTests {
  @Test func foldsCaseAndDiacritics() {
    let i = SearchIndex(items: [item("a", title: "Beyoncé Déjà Vu"), item("b", title: "CAFÉ blend")])
    #expect(ids(i, "beyonce") == ["a"])
    #expect(ids(i, "DEJA") == ["a"])
    #expect(ids(i, "déjà") == ["a"])
    #expect(ids(i, "cafe") == ["b"])
    #expect(ids(i, "  cafe   BLEND ") == ["b"])
  }

  @Test func everyWordMustHitSomeField() {
    let i = SearchIndex(items: [
      item("a", title: "Golden Hour", [SearchField("Caption", "rooftop encore")]),
      item("b", title: "Golden Hour", [SearchField("Caption", "basement")]),
    ])
    #expect(ids(i, "golden rooftop") == ["a"])
    #expect(ids(i, "rooftop basement").isEmpty)
    #expect(ids(i, "").isEmpty)
    #expect(ids(i, "   ").isEmpty)
  }

  @Test func aMatchNeverSpansTwoFields() {
    let i = SearchIndex(items: [item("a", title: "abc", [SearchField("x", "def")])])
    #expect(ids(i, "cdef").isEmpty)
    #expect(ids(i, "c d").isEmpty == false)  // two words, each in a field
  }

  @Test func tiersOrderHits() {
    let i = SearchIndex(items: [
      item("body", title: "Sunset", [SearchField("Caption", "low tide")], rank: 0),
      item("inside", title: "Bellow Tide", rank: 1),  // "low" inside a word
      item("prefix", title: "Low Tide x Paper Moon", rank: 2),
      item("exact", title: "Low Tide", rank: 3),
    ])
    let hits = i.search(SearchQuery("low tide"))
    #expect(hits.map(\.id) == ["exact", "prefix", "inside", "body"])
    #expect(hits.map(\.tier) == [.exact, .wordPrefix, .titleContains, .otherField])
  }

  @Test func primaryFieldsRankLikeTheTitle() {
    let i = SearchIndex(items: [item("go", .goTo, title: "Go to Score", [SearchField("", "Score", role: .primary)])])
    #expect(i.search(SearchQuery("score")).first?.tier == .exact)
    #expect(i.search(SearchQuery("go to")).first?.tier == .wordPrefix)
  }

  @Test func rankBreaksTiesAndKeepsInputOrder() {
    let i = SearchIndex(items: [item("b", title: "Blend", rank: 2), item("a", title: "Blend", rank: 1), item("c", title: "Blend", rank: 2)])
    #expect(ids(i, "blend") == ["a", "b", "c"])
  }

  @Test func phrasesMatchTheWholeQueryOnly() {
    let i = SearchIndex(items: [
      item("w", .week, title: "Week of 9 Nov", [SearchField("", "12 nov", role: .phrase), SearchField("", "nov 12", role: .phrase)]),
      item("x", .week, title: "Week of 30 Nov", [SearchField("", "1 dec", role: .phrase), SearchField("", "2026-12-01", role: .phrase)]),
    ])
    #expect(ids(i, "12 nov") == ["w"])  // never "12" from one date and "nov" from another
    #expect(i.search(SearchQuery("12 nov")).first?.tier == .exact)
    #expect(i.search(SearchQuery("12 n")).first?.tier == .wordPrefix)
    #expect(ids(i, "1 dec") == ["x"])
    #expect(ids(i, "dec 1").isEmpty)
  }

  @Test func foldsLettersFoundationLeavesAlone() {
    let i = SearchIndex(items: [item("a", title: "Łódź Nights"), item("b", title: "Ænima"), item("c", title: "Røyksopp Œuvre"),
                                item("d", title: "Don’t Stop"), item("e", title: "Đorđe"), item("f", title: "Ðenny")])
    #expect(ids(i, "lodz") == ["a"])
    #expect(ids(i, "aenima") == ["b"])
    #expect(ids(i, "royksopp") == ["c"])
    #expect(ids(i, "oeuvre") == ["c"])
    #expect(ids(i, "don't") == ["d"])
    #expect(ids(i, "don’t") == ["d"])
    #expect(ids(i, "dorde") == ["e"])
    #expect(ids(i, "denny") == ["f"])
    #expect(SearchText.ranges(in: "Ænima", SearchQuery("aenima")) == [0..<5])
    #expect(SearchText.ranges(in: "Røyksopp", SearchQuery("royk")) == [0..<4])
  }

  @Test func phraseRunsCombineWithOtherWords() throws {
    let i = SearchIndex(items: [
      item("p", .post, title: "TikTok · Golden Hour", [SearchField("State", "Failed"), SearchField("", "12 nov", role: .phrase),
                                                       SearchField("", "nov 12", role: .phrase), SearchField("", "november 12", role: .phrase)]),
    ])
    for q in ["tiktok 12 nov", "12 nov tiktok", "failed nov", "golden nov 12", "golden november 12", "nov golden", "tiktok 12 n", "failed no"] {
      #expect(ids(i, q) == ["p"], "\(q)")
    }
    #expect(i.search(SearchQuery("tiktok 12 nov")).first?.tier == .wordPrefix)
    #expect(i.search(SearchQuery("failed nov")).first?.tier == .otherField)
    for q in ["tiktok 13 nov", "tiktok 12 dec", "failed 12", "no tiktok", "tiktok 12 nov 2026"] { #expect(ids(i, q).isEmpty, "\(q)") }
  }

  @Test func sectionsSortByBestTierThenFixedOrder() {
    let i = SearchIndex(items: [
      item("clip", .clip, title: "Sunset", [SearchField("Caption", "captions rock")]),
      item("set", .setting, title: "Captions & titles"),
      item("post", .post, title: "TikTok · Captions rock"),
    ])
    let s = AppSearch.sections(i.search(SearchQuery("captions")))
    #expect(s.map(\.kind) == [.post, .setting, .clip])  // same best tier: Posts before Settings; a body hit last
  }

  @Test func chipsCountOnlyKindsWithHits() {
    let i = SearchIndex(items: [item("a", .clip, title: "Tide"), item("b", .health, title: "Tide"), item("c", .goTo, title: "Tide"),
                                item("d", .post, title: "Other")])
    let c = AppSearch.counts(i.search(SearchQuery("tide")))
    #expect(c == [.all: 3, .clips: 1, .actions: 2])
  }

  @Test func snippetShowsWhereABodyHitMatched() throws {
    let i = SearchIndex(items: [item("a", title: "Sunset", [
      SearchField("Notes", "nothing here"),
      SearchField("Caption", "A very long caption that goes on and on so the rooftop encore lands far from the start of the text, and keeps going after it"),
    ])])
    let q = SearchQuery("ROOFTOP")
    let hit = try #require(i.search(q).first)
    let s = try #require(i.snippet(hit, q))
    #expect(s.label == "Caption")
    #expect(s.text.hasPrefix("…"))
    #expect(s.text.hasSuffix("…"))
    #expect(s.text.count <= 84)
    let r = try #require(s.ranges.first)
    #expect(String(Array(s.text)[r]) == "rooftop")
  }

  @Test func snippetPrefersTheFieldWithMostWords() throws {
    let i = SearchIndex(items: [item("a", title: "Sunset", [SearchField("Tag", "alpha"), SearchField("Caption", "alpha beta")])])
    let q = SearchQuery("alpha beta")
    let hit = try #require(i.search(q).first)
    #expect(i.snippet(hit, q)?.label == "Caption")
  }

  @Test func titleHitHasNoSnippet() throws {
    let i = SearchIndex(items: [item("a", title: "Sunset")])
    let q = SearchQuery("sun")
    #expect(i.snippet(try #require(i.search(q).first), q) == nil)
  }

  @Test func rangesMapBackThroughFolding() {
    #expect(SearchText.ranges(in: "Déjà Vu", SearchQuery("deja")) == [0..<4])
    #expect(SearchText.ranges(in: "Straße", SearchQuery("stra")) == [0..<4])
    #expect(SearchText.ranges(in: "low tide low", SearchQuery("low")) == [0..<3, 9..<12])
    #expect(SearchText.ranges(in: "aaa", SearchQuery("aa a")) == [0..<3])
    #expect(SearchText.ranges(in: "🔥 tide", SearchQuery("tide")) == [2..<6])
  }

  @Test func oddTextIsSafe() {
    let i = SearchIndex(items: [item("a", title: ""), item("b", title: "🔥🔥", [SearchField("x", "")]), item("c", title: "a\u{0}b")])
    #expect(ids(i, "🔥") == ["b"])
    #expect(ids(i, "ab") == ["c"])  // a NUL in a title is dropped, never read as a separator
    #expect(SearchQuery("\u{0}").isEmpty)
  }

  /// S1-R2: 5,000 items in under 10 ms per query in a release build; debug builds get a loose bound.
  @Test func fiveThousandItemsStayFast() {
    var items: [SearchItem] = []
    for n in 0..<5000 {
      items.append(item("i\(n)", n % 2 == 0 ? .clip : .post, title: "Midnight Run x Afterglow \(n)", [
        SearchField("Tag", "yayo x johnny \(n)"), SearchField("Caption", String(repeating: "who knows this blend ", count: 6)),
        SearchField("Hashtags", "#amapiano #piano #dj #lovd #afrohouse"), SearchField("File", "Set \(n)/clip-\(n).mov"),
        SearchField("", "\(n % 28 + 1) nov", role: .phrase), SearchField("", "2026-11-\(n % 28 + 1)", role: .phrase),
      ], rank: n))
    }
    let index = SearchIndex(items: items)
    var worst = 0.0
    for text in ["blend", "no such text anywhere", "midnight run afterglow 4999", "12 nov", "#amapiano who"] {
      let q = SearchQuery(text)
      let t = Date()
      _ = index.search(q)
      worst = max(worst, Date().timeIntervalSince(t))
    }
    #if DEBUG
      #expect(worst < 0.5, "\(worst)")  // loose: the update gate runs tests under load
    #else
      #expect(worst < 0.01, "\(worst)")
    #endif
  }
}

@Suite struct R10SearchCorpusTests {
  private func settings() -> DJQCore.Settings { DJQCore.Settings() }

  private func video(_ id: String, title: String? = nil, session: String = "s1", tag: String = "yayo x johnny", file: String = "clip.mov",
                     notes: String = "", type: VideoType = .short) throws -> Video {
    let f = try Fixture()
    try Intake(store: f.store).run()
    var v = try #require(try f.store.videos(where: "type='short-form'").first)
    v.id = id
    v.sessionId = session
    v.title = title
    v.tags = [tag]
    v.file = file
    v.notes = notes
    v.type = type
    return v
  }

  private func input(videos: [Video] = [], posts: [PlatformPost] = [], weeks: [String: WeekState] = [:], clips: [String: Int] = [:],
                     text: [String: SearchClipText] = [:], sets: [HashtagSet] = [], templates: [CaptionTemplate] = [],
                     now: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> SearchInput {
    let s = Session(id: "s1", folder: "/x", name: "2026-10-24 – Block Party", date: "2026-10-24", discoveredAt: now, missing: false)
    return SearchInput(settings: settings(), sessions: [s], videos: videos, posts: posts, weekStates: weeks, weekClips: clips, clipText: text,
                       hashtagSets: sets, captionTemplates: templates, now: now)
  }

  private func post(_ id: String, video: String, at: Date, state: PostState = .posted, platform: Platform = .instagram,
                    error: String? = nil, url: String? = nil, external: String? = nil) -> PlatformPost {
    PlatformPost(id: id, videoId: video, platform: platform, versionNo: 1, attemptNo: 1, kind: .regular, planSlotId: nil, scheduledAt: at,
                 renderId: nil, state: state, publisher: "manual", externalId: external, url: url, postedAt: nil, errorType: error == nil ? nil : .uploadFailed,
                 errorMessage: error, rawResponse: nil, resolution: nil, metrics: nil, createdAt: at, updatedAt: at)
  }

  @Test func clipFieldsAreAllSearchable() throws {
    var v = try video("v1", title: "Golden Hour", notes: "Crowd went wild")
    v.titleTracks = [Track(title: "Paper Moon", artist: "Demo Collective")]
    var t = SearchClipText()
    t.text = "Who knows this blend?"
    t.caption = "Rooftop encore"
    t.hashtags = ["#amapiano"]
    let index = SearchCorpus.index(input(videos: [v], text: ["v1": t]))
    for (q, label) in [("yayo", "Tag"), ("clip.mov", "File"), ("block party", "Session"), ("crowd", "Notes"), ("paper moon", "Track"),
                       ("who knows", "Text"), ("rooftop", "Caption"), ("#amapiano", "Hashtags"), ("talking", nil), ("demo collective", "Track")] {
      let query = SearchQuery(q)
      let hits = index.search(query).filter { $0.kind == .clip }
      if let label {
        let hit = try #require(hits.first, "\(q)")
        #expect(index.snippet(hit, query)?.label == label, "\(q)")
      } else {
        #expect(hits.isEmpty, "\(q)")
      }
    }
    #expect(index.search(SearchQuery("dj vid")).contains { $0.kind == .clip })
  }

  @Test func untitledLongFormReadsLikeTheApp() throws {
    var v = try video("v1", type: .long)
    v.part = 2
    let index = SearchCorpus.index(input(videos: [v]))
    #expect(index.items.first { $0.kind == .clip }?.title == "Block Party · Part 2")
  }

  @Test func postsMatchEveryField() throws {
    let at = Date(timeIntervalSince1970: 1_793_000_000)
    let p = post("p1", video: "v1", at: at, state: .failed, error: "Upload timed out", url: "https://instagram.com/reel/abc123", external: "ext-77")
    let index = SearchCorpus.index(input(videos: [try video("v1", title: "Golden Hour")], posts: [p]))
    let id = SearchId.post("p1")
    for q in ["instagram", "golden hour", "failed", "upload failed", "timed out", "reel/abc123", "ext-77", "instagram failed"] {
      #expect(index.search(SearchQuery(q)).contains { $0.id == id }, "\(q)")
    }
    let day = DayMath(settings: settings()).key(at)
    #expect(index.search(SearchQuery(day)).contains { $0.id == id })
  }

  @Test func weeksFindByDateMonthAndName() throws {
    let now = Date(timeIntervalSince1970: 1_793_000_000)  // Nov 2026
    let dm = DayMath(settings: settings())
    let this = dm.weekStart(of: now)
    let far = dm.addDays(this, 21)
    let index = SearchCorpus.index(input(weeks: [far: .draft], clips: [far: 7], now: now))
    #expect(index.search(SearchQuery("this week")).first?.id == SearchId.week(this))
    #expect(index.search(SearchQuery("next week")).first?.id == SearchId.week(dm.addDays(this, 7)))
    #expect(index.search(SearchQuery("last week")).first?.id == SearchId.week(dm.addDays(this, -7)))
    let wed = dm.addDays(far, 2)
    let p = wed.split(separator: "-")
    let month = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"][Int(p[1])!]
    let q = "\(Int(p[2])!) \(month)"
    let hits = index.search(SearchQuery(q)).filter { $0.kind == .week }
    #expect(hits.map(\.id) == [SearchId.week(far)], "\(q)")
    #expect(index.search(SearchQuery("\(month) \(Int(p[2])!)")).contains { $0.id == SearchId.week(far) })
    #expect(index.search(SearchQuery("november")).contains { $0.kind == .week })
    #expect(index.search(SearchQuery("draft")).contains { $0.id == SearchId.week(far) })
  }

  /// A date can't be stitched from two dates, or from a title's day and another date of the week.
  @Test func datesCombineWithWordsButNotWithEachOther() throws {
    let dm = DayMath(settings: settings())
    let at = dm.at("2026-11-12", minutes: 600)
    let p = post("p1", video: "v1", at: at, state: .failed, platform: .tiktok)
    let index = SearchCorpus.index(input(videos: [try video("v1", title: "Golden Hour")], posts: [p],
                                         weeks: ["2026-11-09": .draft, "2026-10-26": .draft, "2026-11-30": .draft], now: at))
    let id = SearchId.post("p1"), week = SearchId.week("2026-11-09")
    for q in ["tiktok 12 nov", "12 nov tiktok", "failed nov", "golden nov 12"] {
      #expect(index.search(SearchQuery(q)).contains { $0.id == id }, "\(q)")
    }
    for q in ["draft 12 nov", "week 12 nov"] { #expect(index.search(SearchQuery(q)).contains { $0.id == week }, "\(q)") }
    #expect(!index.search(SearchQuery("tiktok 13 nov")).contains { $0.id == id })
    func weeks(_ q: String) -> Set<String> { Set(index.search(SearchQuery(q)).filter { $0.kind == .week }.map(\.id)) }
    #expect(!weeks("26 nov").contains(SearchId.week("2026-10-26")))  // 26 Oct to 1 Nov
    #expect(!weeks("1 nov").contains(SearchId.week("2026-11-30")))  // 30 Nov to 6 Dec
    #expect(!weeks("dec 30").contains(SearchId.week("2026-11-30")))
    #expect(weeks("dec 1").contains(SearchId.week("2026-11-30")))
    #expect(weeks("1 dec").contains(SearchId.week("2026-11-30")))
  }

  @Test func postsMatchWhatTheirRowReads() {
    let at = Date(timeIntervalSince1970: 1_793_000_000)
    var accepted = post("a", video: "v1", at: at, state: .copyrightBlocked)
    accepted.resolution = "accepted"
    var uploaded = post("u", video: "v1", at: at, state: .copyrightMuted)
    uploaded.resolution = "reuploaded"
    var retried = post("r", video: "v1", at: at, state: .failed)
    retried.resolution = "retried"
    let missed = post("m", video: "v1", at: at, state: .overdue)
    let index = SearchCorpus.index(input(posts: [accepted, uploaded, retried, missed]))
    for (q, id) in [("accepted", "a"), ("re-uploaded", "u"), ("retried", "r"), ("missed", "m")] {
      #expect(index.search(SearchQuery(q)).contains { $0.id == SearchId.post(id) }, "\(q)")
    }
    #expect(accepted.stateLabel == "Accepted")
    #expect(post("x", video: "v1", at: at, state: .copyrightBlocked).stateLabel == "Blocked")
  }

  /// Schedule and Queue draw a row per platform that's on: an off platform's row isn't there to land on.
  @Test func rowsOfAnOffPlatformAreNotOffered() {
    var s = settings()
    s.enabledPlatforms.remove(.x)
    var i = input()
    i.settings = s
    let index = SearchCorpus.index(i)
    let ids = Set(index.items.map(\.id))
    #expect(!ids.contains(SearchId.setting("schedule.row:X")))
    #expect(!ids.contains(SearchId.setting("queue.row:X")))
    #expect(ids.contains(SearchId.setting("schedule.row:TikTok")))
    #expect(ids.contains(SearchId.setting("platforms.row:X")))  // the switch that turns it back on stays
    #expect(ids.contains(SearchId.setting("publishing.row:X")))
    #expect(SettingsSearchRegistry.entry(id: "schedule.row:X")?.isDrawn(s) == false)
    #expect(SettingsSearchRegistry.entry(id: "schedule.row:X")?.isDrawn(settings()) == true)
  }

  @Test func sessionsFindByNameAndDate() throws {
    let index = SearchCorpus.index(input(videos: [try video("v1")]))
    let id = SearchId.session("s1")
    #expect(index.search(SearchQuery("block party")).first?.id == id)
    #expect(index.search(SearchQuery("24 oct")).first?.id == id)
    #expect(index.search(SearchQuery("2026-10-24")).first?.id == id)
    #expect(index.search(SearchQuery("october 24")).first?.id == id)
    let unused = SearchCorpus.index(input())
    #expect(!unused.items.contains { $0.kind == .session })  // a session with no clips opens an empty Library
  }

  @Test func settingsCoverRowsGroupsSectionsAndYourOwnLists() {
    let index = SearchCorpus.index(input(
      sets: [HashtagSet(id: "g1", name: "Afro house", category: "My groups", tags: ["#afro", "#house"], sort: 0)],
      templates: [CaptionTemplate(id: "t1", name: "Link in bio", template: "{text} tickets in bio", sort: 0)]))
    #expect(index.search(SearchQuery("repost cooldown")).first?.id == SearchId.setting("schedule.row:Repost cooldown"))
    #expect(index.search(SearchQuery("late grace")).first?.tier == .exact)
    #expect(index.search(SearchQuery("captions & titles")).first?.id == SearchId.pane(.captions))
    #expect(index.search(SearchQuery("tiktok slot")).first?.id == SearchId.setting("schedule.row:TikTok"))
    #expect(index.search(SearchQuery("afro house")).first?.id == SearchId.setting("captions.hashtag:g1"))
    #expect(index.search(SearchQuery("#afro")).contains { $0.id == SearchId.setting("captions.hashtag:g1") })
    #expect(index.search(SearchQuery("tickets in bio")).contains { $0.id == SearchId.setting("captions.template:t1") })
    #expect(index.search(SearchQuery("dj lovd")).contains { $0.kind == .setting })  // a built-in YouTube title template
  }

  @Test func healthPlacesMatchTitleAndSubtitle() {
    let index = SearchCorpus.index(input())
    for (q, id) in [("engine status", "engine"), ("runway", "runway"), ("backups", "backups"), ("awake", "awake"), ("doctor", "doctor"),
                    ("last copied", "backups")] {
      #expect(index.search(SearchQuery(q)).contains { $0.id == SearchId.health(id) }, "\(q)")
    }
  }

  @Test func idsAreUniqueAcrossTheCorpus() throws {
    let at = Date(timeIntervalSince1970: 1_793_000_000)
    let items = SearchCorpus.items(input(videos: [try video("v1")], posts: [post("p1", video: "v1", at: at)],
                                         sets: [HashtagSet(id: "g", name: "G", category: "c", tags: [], sort: 0)]))
    #expect(Set(items.map(\.id)).count == items.count)
  }
}

@Suite struct R10SearchStoreTests {
  @Test func latestVersionTextCarriesForwardWithOneQuery() throws {
    let f = try Fixture()
    try Intake(store: f.store).run()
    let v = try #require(try f.store.videos(where: "type='short-form'").first)
    var a = Version(number: 1)
    a.caption = "First caption"
    a.text = "Overlay words"
    a.extraHashtags = ["amapiano"]
    try f.store.save(a, videoId: v.id)
    var b = Version(number: 2)
    b.caption = "Second caption"
    b.platformCaptions = [.tiktok: "TikTok only line"]
    try f.store.save(b, videoId: v.id)
    let s = try f.store.settings()
    let t = try #require(try f.store.searchClipText(videos: [v], settings: s, sets: []).first?.value)
    #expect(t.caption == "Second caption")
    #expect(t.text == "Overlay words")  // carried forward
    #expect(t.hashtags == ["#amapiano"])
    #expect(t.platformCaptions == ["TikTok only line"])
  }

  @Test func noTextHidesOverlay() throws {
    let f = try Fixture()
    try Intake(store: f.store).run()
    let v = try #require(try f.store.videos(where: "type='short-form'").first)
    var a = Version(number: 1)
    a.text = "Gone"
    a.noText = true
    try f.store.save(a, videoId: v.id)
    let t = try f.store.searchClipText(videos: [v], settings: try f.store.settings(), sets: [])
    #expect(t[v.id]?.text == "")
  }

  @Test func readingWritesNothing() throws {
    let f = try Fixture()
    try Intake(store: f.store).run()
    let v = try #require(try f.store.videos(where: "type='short-form'").first)
    let before = try f.store.db.query("SELECT COUNT(*) AS n FROM events").first?.int("n")
    _ = try f.store.searchClipText(videos: [v], settings: try f.store.settings(), sets: [])
    #expect(try f.store.db.query("SELECT COUNT(*) AS n FROM events").first?.int("n") == before)
    #expect(try f.store.versions(videoId: v.id).isEmpty)
  }
}

/// Every label a Settings view spells out must be in the registry, in the right pane, with the same description.
@Suite struct SettingsRegistryTests {
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The view structs of each pane. A new one fails `everyPaneIsMapped` until it's listed here.
  private static let panes: [String: SettingsPane] = [
    "GeneralSettings": .general, "PlatformsSettings": .platforms, "PublishingSection": .publishing, "PostizKeyRow": .publishing,
    "ScheduleSettings": .schedule, "QueueSettings": .queue, "NewClipDefaultsSettings": .newClipDefaults, "CaptionsSettings": .captions,
    "RenderingSettings": .rendering, "PlaybackSettings": .playback, "AlertsSettings": .alerts, "EngineSettings": .engine,
    "AutoUpdateSettings": .engine,
  ]
  /// Views that hold no rows of their own (they wrap or lay out rows).
  private static let helpers: Set<String> = ["SettingsRow", "SettingsGroupHeader", "SettingsGroupHeaderWithAction", "SettingsScroll"]

  struct Literal {
    var file: String
    var view: String
    var call: String
    var label: String
    var description: String?
  }

  /// Every `SettingsRow("…"`, `SettingsGroupHeader("…"`, `SettingsGroupHeaderWithAction(title: "…"` and `folder("…"`.
  static func literals() throws -> [Literal] {
    let dir = root.appendingPathComponent("Sources/DJQueueApp/Settings")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
    let string = #""((?:[^"\\]|\\.)*)""#
    let pattern = try NSRegularExpression(pattern: #"\b(SettingsRow|SettingsGroupHeader|SettingsGroupHeaderWithAction|folder)\((?:title:\s*)?"# + string
                                          + #"(?:,\s*description:\s*"# + string + ")?")
    let structs = try NSRegularExpression(pattern: #"^\s*(?:private |fileprivate )?struct (\w+)"#, options: .anchorsMatchLines)
    var out: [Literal] = []
    for f in files.sorted(by: { $0.path < $1.path }) {
      let s = try String(contentsOf: f, encoding: .utf8)
      let ns = s as NSString
      let views = structs.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ($0.range.location, ns.substring(with: $0.range(at: 1))) }
      for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let view = views.last { $0.0 < m.range.location }?.1 ?? ""
        let d = m.range(at: 3)
        out.append(Literal(file: f.lastPathComponent, view: view, call: ns.substring(with: m.range(at: 1)), label: ns.substring(with: m.range(at: 2)),
                           description: d.location == NSNotFound ? nil : ns.substring(with: d)))
      }
    }
    return out
  }

  @Test func scannerFindsTheRows() throws {
    let l = try Self.literals()
    #expect(l.count > 90)
    #expect(l.contains { $0.label == "Repost cooldown" && $0.view == "ScheduleSettings" })
    #expect(l.contains { $0.label == "Platforms" && $0.call == "SettingsGroupHeaderWithAction" })
    #expect(l.contains { $0.label == "Backups" && $0.call == "folder" })
  }

  @Test func everyPaneIsMapped() throws {
    for l in try Self.literals() where !Self.helpers.contains(l.view) {
      #expect(Self.panes[l.view] != nil, "\(l.file): \(l.view) has settings rows but no pane in SettingsRegistryTests.panes")
    }
  }

  @Test func everyLiteralIsInTheRegistry() throws {
    for l in try Self.literals() {
      guard let pane = Self.panes[l.view] else { continue }
      let anchor = l.call.hasPrefix("SettingsGroupHeader") ? SettingsAnchor.group(l.label) : SettingsAnchor.row(l.label)
      let e = SettingsSearchRegistry.entry(id: "\(pane.rawValue).\(anchor)")
      #expect(e != nil, "\(l.file): \(l.call)(\"\(l.label)\") is missing from SettingsSearchRegistry (\(pane))")
      if let d = l.description, let e { #expect(e.description == d, "\(l.file): \(l.label): the registry's description differs") }
    }
  }

  /// The other way round: a row deleted from Settings must leave the registry.
  @Test func registryHasNoGhostRows() throws {
    let lits = try Self.literals()
    let dir = Self.root.appendingPathComponent("Sources/DJQueueApp/Settings")
    let sources = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    for e in SettingsSearchRegistry.fixed {
      let label = e.anchor.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
      #expect(lits.contains { $0.label == label && Self.panes[$0.view] == e.pane }, "\(e.pane): \"\(label)\" is in the registry but no view has it")
    }
    #expect(sources.contains(#"SettingsAnchor.row("Installed build")"#))  // the one computed label passes its anchor
  }

  @Test func panesMatchTheAppEnum() throws {
    let src = try String(contentsOf: Self.root.appendingPathComponent("Sources/DJQueueApp/Settings/SettingsModal.swift"), encoding: .utf8)
    let line = try #require(src.split(separator: "\n").first { $0.contains("case general, platforms") })
    let cases = line.replacingOccurrences(of: "case", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(cases == SettingsPane.allCases.map(\.rawValue))
  }

  @Test func idsAreUnique() {
    let ids = SettingsSearchRegistry.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }
}
