import DJQCore
import SwiftUI

// What ⌘K finds and where each result goes (round 10). The engine and the corpus live in DJQCore/Search; this file
// turns hits into palette rows. Rows are made only for what's on screen, so a keystroke stays cheap, and a hit whose
// clip or post just went away is dropped instead of crashing.

/// The palette's list at one moment: sections of rows with their position in keyboard order.
struct PaletteContent {
  struct Row: Identifiable {
    let index: Int
    var command: PaletteCommand
    var id: Int { index }
  }

  struct Section {
    var title: String
    var rows: [Row]
  }

  var sections: [Section] = []
  var flat: [PaletteCommand] = []
  /// Hits per chip; empty when not searching.
  var counts: [SearchScope: Int] = [:]
  /// The chip this list really shows: one with no hits falls back to All.
  var scope = SearchScope.all
  /// Set when a chip's list is cut short.
  var note: String?

  var isSearch: Bool { !counts.isEmpty }

  mutating func add(_ title: String, _ commands: [PaletteCommand]) {
    guard !commands.isEmpty else { return }
    var rows: [Row] = []
    for c in commands {
      rows.append(Row(index: flat.count, command: c))
      flat.append(c)
    }
    sections.append(Section(title: title, rows: rows))
  }
}

extension AppModel {
  static let searchHelp = "Search clips, posts, weeks, sessions, settings and actions"
  /// Rows per section under All.
  static let paletteGroupCap = 5
  /// Rows in one chip's list.
  static let paletteListCap = 100

  // MARK: Opening

  /// What a result that leaves the current view does first: the editor closes through its usual path (`editor = nil`,
  /// the same as ⌘-number), then Settings and anything else that was open under the palette.
  func leaveForScreen(_ s: Screen) {
    editor = nil
    showSettings = false
    closeModals()
    screen = s
  }

  /// Dialogs ⌘K can sit above. They'd cover where a result lands, or come back with the screen they belong to.
  func closeModals() {
    showShortcuts = false
    previewVideo = nil
    markPostedTarget = nil
    reportTarget = nil
    longformTarget = nil
    cancelPendingBulk()
    BrowseUI.shared.quickLook = nil
    BrowseUI.shared.longformTargets = []
    BrowseUI.shared.scoreTargets = []
    BrowseUI.shared.pendingPostBulk = nil
  }

  /// ⌘K: however the palette closes, the next one starts empty.
  func togglePalette() {
    if showPalette { closePalette() } else { showPalette = true }
  }

  func closePalette() {
    showPalette = false
    BrowseUI.shared.paletteQuery = ""
    BrowseUI.shared.paletteClipId = nil
    BrowseUI.shared.paletteReturnQuery = ""
  }

  /// ⌘K with `text` already in the field (a list's "Search everywhere").
  func openSearch(_ text: String) {
    BrowseUI.shared.paletteClipId = nil
    BrowseUI.shared.paletteScope = .all
    BrowseUI.shared.paletteQuery = text
    showPalette = true
  }

  /// Posts with this post's card open, its row in view and the inspector showing. Filters that could hide it are
  /// cleared, and so is the status chip: All holds every post.
  func openPost(_ id: String) {
    guard let p = postById[id] else { return }
    leaveForScreen(.posts)
    ListPrefs.shared.clearFilters(.posts)
    ListPrefs.shared.setStatus(.posts, nil)
    PostsCardState.shared.expanded.insert("\(p.videoId)|\(dm.key(p.scheduledAt))")
    postsSelection = id
    postsScrollTarget = id
  }

  /// The Calendar's Week view on that week, for this session (the remembered view stays what Eric chose).
  func openWeek(_ weekStart: String) {
    leaveForScreen(.calendar)
    calendarMode = .week
    calendarAnchor = weekStart == thisWeek ? "" : weekStart
  }

  /// Library filtered to one session: whatever else narrowed the list goes, so every clip of the session shows.
  func openSession(_ id: String) {
    leaveForScreen(.library)
    ListPrefs.shared.clearFilters(.library)
    ListPrefs.shared.setStatus(.library, nil)
    ListPrefs.shared.setFilter(.library, ListFilterKey.session, id)
  }

  /// A Settings pane, scrolled to `anchor`. Settings opens over the current view, like ⌘, does.
  func openSettings(_ pane: SettingsPane, anchor: String? = nil) {
    guard let s = SettingsSection(rawValue: pane.rawValue) else { return }
    closeModals()
    SettingsUIState.shared.scrollTarget = anchor
    settingsSection = s
    showSettings = true
  }

  // MARK: Rows

  private func searchRow(_ id: String, _ title: String, symbol: String, group: SearchKind, subtitle: String?,
                         run: @escaping () -> Void) -> PaletteCommand {
    PaletteCommand(id: id, title: title, symbol: symbol, group: group.title, subtitle: subtitle, run: run)
  }

  func palettePostRow(_ p: PlatformPost) -> PaletteCommand {
    let clip = video(p.videoId).map(displayName) ?? p.videoId
    return searchRow(SearchId.post(p.id), "\(p.platform.displayName) · \(clip)", symbol: p.platform.dsSymbol, group: .post,
                     subtitle: "\(PostText.pill(p).text) · \(PostText.date(p, model: self))") { [weak self] in self?.openPost(p.id) }
  }

  func paletteWeekRow(_ ws: String) -> PaletteCommand {
    var parts = [weekContext(ws)]
    let n = weekClips[ws] ?? 0
    parts.append(n == 0 ? "No clips planned" : "\(n) clip\(n == 1 ? "" : "s")")
    return searchRow(SearchId.week(ws), weekTitle(ws), symbol: "calendar", group: .week, subtitle: parts.joined(separator: " · ")) {
      [weak self] in self?.openWeek(ws)
    }
  }

  func paletteSessionRow(_ s: Session) -> PaletteCommand {
    let n = videos.lazy.filter { $0.sessionId == s.id }.count
    let date = s.date.map { Fmt.day(dm.date($0), tz: tz, style: "d MMM yyyy") }
    let subtitle = ([date, "\(n) clip\(n == 1 ? "" : "s")"] as [String?]).compactMap { $0 }.joined(separator: " · ")
    return searchRow(SearchId.session(s.id), Captions.setName(s.name), symbol: "rectangle.stack", group: .session, subtitle: subtitle) {
      [weak self] in self?.openSession(s.id)
    }
  }

  private func paletteSettingRow(id: String, title: String, pane: SettingsPane, group: String?, anchor: String?) -> PaletteCommand {
    let path = ([pane.title, group] as [String?]).compactMap { $0 }.joined(separator: " › ")
    let symbol = SettingsSection(rawValue: pane.rawValue)?.symbol ?? "gearshape"
    return searchRow(id, title, symbol: symbol, group: .setting, subtitle: anchor == nil ? "Settings" : path) { [weak self] in
      self?.openSettings(pane, anchor: anchor)
    }
  }

  /// A row, group header or your own list entry in Settings; nil once it's gone.
  func paletteSettingRow(_ entryId: String) -> PaletteCommand? {
    let id = SearchId.setting(entryId)
    if let e = SettingsSearchRegistry.entry(id: entryId) {
      return e.isDrawn(settings) ? paletteSettingRow(id: id, title: e.title, pane: e.pane, group: e.group, anchor: e.anchor) : nil
    }
    let prefix = "\(SettingsPane.captions.rawValue)."
    guard entryId.hasPrefix(prefix) else { return nil }
    let anchor = String(entryId.dropFirst(prefix.count))
    let tail = anchor.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
    func row(_ title: String, _ group: String) -> PaletteCommand {
      paletteSettingRow(id: id, title: title, pane: .captions, group: group, anchor: anchor)
    }
    if anchor == SettingsAnchor.hashtagGroup(tail) { return hashtagSets.first { $0.id == tail }.map { row($0.name, "Hashtag groups") } }
    if anchor == SettingsAnchor.captionTemplate(tail) { return captionTemplates.first { $0.id == tail }.map { row($0.name, "Caption templates") } }
    if anchor == SettingsAnchor.titleTemplate(tail) {
      return settings.youtubeTitleTemplates.first { $0.id == tail }.map { row($0.name, "YouTube title templates") }
    }
    return nil
  }

  func paletteHealthRow(_ h: HealthPlace) -> PaletteCommand {
    // Health doesn't show the runway: the Queue's toolbar does.
    let target: Screen = h.id == "runway" ? .queue : .health
    var subtitle = h.subtitle
    if h.id == "runway" { subtitle = "\(runway.approvedDays) days scheduled · \(runway.totalDays) days in total" }
    return searchRow(SearchId.health(h.id), h.title, symbol: h.id == "runway" ? "gauge.with.needle" : "heart", group: .health, subtitle: subtitle) {
      [weak self] in self?.leaveForScreen(target)
    }
  }

  /// The row behind a search id, or nil when what it pointed at is gone (a stale recent).
  func searchCommand(id: String) -> PaletteCommand? {
    func tail(_ prefix: String) -> String? { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil }
    if let k = tail(SearchId.post("")) { return postById[k].map(palettePostRow) }
    if let k = tail(SearchId.week("")) { return k.split(separator: "-").count == 3 ? paletteWeekRow(k) : nil }
    if let k = tail(SearchId.session("")) { return sessionById[k].map(paletteSessionRow) }
    if let k = tail(SearchId.setting("")) { return paletteSettingRow(k) }
    if let k = tail("search.pane."), let p = SettingsPane(rawValue: k) {
      return paletteSettingRow(id: id, title: p.title, pane: p, group: nil, anchor: nil)
    }
    if let k = tail(SearchId.health("")) { return HealthPlace.all.first { $0.id == k }.map(paletteHealthRow) }
    return nil
  }

  /// A hit as a row: clips keep their action page; where a non-title match came from replaces the second line.
  private func command(_ hit: SearchHit, in index: SearchIndex, _ q: SearchQuery, local: [String: PaletteCommand]) -> PaletteCommand? {
    var c: PaletteCommand?
    switch hit.kind {
    case .clip: c = video(String(hit.id.dropFirst(5))).map { paletteClipRow($0) }
    case .action, .goTo: c = local[hit.id]
    default: c = searchCommand(id: hit.id)
    }
    guard var row = c else { return nil }
    row.titleMatches = SearchText.ranges(in: row.title, q)
    guard let s = index.snippet(hit, q) else { return row }
    switch hit.kind {
    case .clip, .post:
      if s.label == "State" || s.label == "Platform" { break }
      let prefix = s.label.isEmpty ? "" : "\(s.label): "
      row.subtitle = prefix + s.text
      row.subtitleMatches = s.ranges.map { ($0.lowerBound + prefix.count)..<($0.upperBound + prefix.count) }
    case .health:
      // The row's second line is its own text: bold the match there, never repeat it.
      row.subtitleMatches = row.subtitle.map { SearchText.ranges(in: $0, q) } ?? []
    case .setting:
      // The path stays; the matched text follows it.
      if ["Section", "Group", "Hashtag group", "Caption template", "YouTube title template"].contains(s.label) { break }
      let prefix = (row.subtitle.map { "\($0) · " } ?? "") + (s.label.isEmpty ? "" : "\(s.label): ")
      row.subtitle = prefix + s.text
      row.subtitleMatches = s.ranges.map { ($0.lowerBound + prefix.count)..<($0.upperBound + prefix.count) }
    case .action, .goTo:
      row.subtitleMatches = row.subtitle.map { SearchText.ranges(in: $0, q) } ?? []
    case .week, .session: break
    }
    return row
  }

  // MARK: The list

  /// Resting palette: Recents, Actions, Go to.
  private func restingContent() -> PaletteContent {
    var out = PaletteContent()
    out.add("Recents", recentCommands.compactMap(paletteCommand(id:)))
    out.add("Actions", paletteActions)
    out.add("Go to", paletteGoTo)
    return out
  }

  /// `text` across the app, narrowed to `scope`. The chips always count the whole result, so they don't jump.
  func paletteContent(text: String, scope: SearchScope) -> PaletteContent {
    let q = SearchQuery(text)
    guard !q.isEmpty else { return restingContent() }
    // Actions follow the selection, so they're indexed here rather than in the refresh load.
    let actions = paletteActions, goTo = paletteGoTo
    let items = actions.enumerated().map { n, c in
      SearchItem(id: c.id, kind: .action, title: c.title, fields: c.subtitle.map { [SearchField("", $0)] } ?? [], rank: n)
    } + goTo.enumerated().map { n, c in
      SearchItem(id: c.id, kind: .goTo, title: c.title, fields: [SearchField("", c.title.replacingOccurrences(of: "Go to ", with: ""), role: .primary)], rank: n)
    }
    let local = SearchIndex(items: items)
    let commands = Dictionary((actions + goTo).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // Counted once here, so chips and "Show all" only ever promise rows that exist: a row can't repeat (its id is how
    // Recents and the keyboard find it), and a clip or post that just went away is dropped.
    var seen = Set<String>()
    let hits = (searchIndex.search(q) + local.search(q)).filter { h in
      switch h.kind {
      case .clip: guard videoById[String(h.id.dropFirst(5))] != nil else { return false }
      case .post: guard postById[String(h.id.dropFirst(SearchId.post("").count))] != nil else { return false }
      default: break
      }
      return seen.insert(h.id).inserted
    }
    var out = PaletteContent()
    var counts = AppSearch.counts(hits)
    if hits.isEmpty { counts[.all] = 0 }
    out.counts = counts
    // A chip that lost its hits as the text changed falls back to All.
    let scope = counts[scope] == nil ? .all : scope
    out.scope = scope
    let cap = scope == .all ? Self.paletteGroupCap : Self.paletteListCap
    var shown = 0, total = 0
    for section in AppSearch.sections(hits.filter { scope.contains($0.kind) }) {
      total += section.hits.count
      let index = section.kind == .action || section.kind == .goTo ? local : searchIndex
      let limit = min(cap, Self.paletteListCap - shown)
      var rows = section.hits.prefix(limit).compactMap { command($0, in: index, q, local: commands) }
      shown += rows.count
      if scope == .all, section.hits.count > rows.count { rows.append(showAllRow(section)) }
      out.add(section.kind.title, rows)
    }
    if scope != .all, total > shown { out.note = "First \(shown) of \(total). Keep typing to narrow it down." }
    return out
  }

  private func showAllRow(_ s: SearchSection) -> PaletteCommand {
    let scope = SearchScope.allCases.first { $0 != .all && $0.contains(s.kind) } ?? .all
    let noun: String
    switch s.kind {
    case .clip: noun = "clips"
    case .post: noun = "posts"
    case .week: noun = "weeks"
    case .session: noun = "sessions"
    case .setting: noun = "settings"
    case .health: noun = "Health places"
    case .action: noun = "actions"
    case .goTo: noun = "destinations"
    }
    return PaletteCommand(id: "show.\(s.kind.rawValue)", title: "Show all \(s.hits.count) \(noun)", symbol: "chevron.down", group: s.kind.title, keepsOpen: true,
                          isRecent: false) {
      BrowseUI.shared.paletteScope = scope
    }
  }
}

/// Remembers the list for the text it was made for: arrow keys and hovering redraw the palette, they don't search again.
@MainActor
final class PaletteMemo {
  private struct Key: Equatable {
    var text: String
    var scope: SearchScope
    var generation: Int
  }

  private var key: Key?
  private var value = PaletteContent()

  func content(_ model: AppModel, text: String, scope: SearchScope) -> PaletteContent {
    let k = Key(text: text, scope: scope, generation: model.searchGeneration)
    if k == key { return value }
    value = model.paletteContent(text: text, scope: scope)
    key = k
    return value
  }
}
