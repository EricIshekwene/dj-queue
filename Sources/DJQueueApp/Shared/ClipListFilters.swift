import DJQCore
import SwiftUI

// One place for what every list header filters and sorts by (round 4 S3/S4): search, the Filters popover sections
// (Session · Kind · Score, plus Stage on Library and Platform on Posts) and the sort menu. Screens keep only their
// status chips. State lives in `ListPrefs` (per page, remembered across relaunch).

/// Filters popover section ids (stored in `ListState.filters`).
enum ListFilterKey {
  static let session = "session"
  static let kind = "kind"
  static let score = "score"
  static let stage = "stage"
  static let platform = "platform"
}

/// Clip orders offered by the sort menus. `natural` is the page's own order (Score: set order; Edit: score, worst
/// first; backlog: queue order).
enum ClipSort: String, CaseIterable {
  case natural, session, newest, scoreHigh, scoreLow, title
}

extension ListPage {
  /// Filters popover sections, in order. Score's sessions are its status chips, and it has no scores yet.
  var filterKeys: [String] {
    switch self {
    case .score: [ListFilterKey.kind]
    case .edit, .queue, .backlog: [ListFilterKey.session, ListFilterKey.kind, ListFilterKey.score]
    case .library: [ListFilterKey.session, ListFilterKey.kind, ListFilterKey.score, ListFilterKey.stage]
    case .posts: [ListFilterKey.platform, ListFilterKey.session, ListFilterKey.kind, ListFilterKey.score]
    }
  }

  /// Sort choices (Queue's order is Settings › Queue sort, Posts sorts by date: both have their own menus).
  var sorts: [ClipSort] {
    switch self {
    case .score: [.natural, .newest, .title]
    case .edit: [.natural, .scoreHigh, .session, .newest, .title]
    case .library: [.session, .newest, .scoreHigh, .scoreLow, .title]
    case .backlog: [.natural, .scoreHigh, .scoreLow, .newest, .title]
    case .queue, .posts: []
    }
  }

  var defaultSort: ClipSort { sorts.first ?? .natural }

  func title(_ s: ClipSort) -> String {
    switch s {
    case .natural:
      switch self {
      case .edit: "Score, worst first"
      case .backlog: "Queue order"
      default: "Set order"
      }
    case .session: "Session order"
    case .newest: "Newest first"
    case .scoreHigh: "Score, best first"
    case .scoreLow: "Score, worst first"
    case .title: "Title A–Z"
    }
  }

  var searchPlaceholder: String { self == .posts ? "Search posts" : "Search clips" }
}

extension ListPrefs {
  func searchBinding(_ p: ListPage) -> Binding<String> {
    Binding(get: { self[p].search }, set: { self.setSearch(p, $0) })
  }

  func statusBinding(_ p: ListPage) -> Binding<String?> {
    Binding(get: { self[p].status }, set: { new in dsWithAnimation { self.setStatus(p, new) } })
  }

  /// The page's sort (falls back to its default when the stored one is no longer offered).
  func sort(_ p: ListPage) -> ClipSort {
    self[p].sort.flatMap(ClipSort.init(rawValue:)).flatMap { p.sorts.contains($0) ? $0 : nil } ?? p.defaultSort
  }

  func sortBinding(_ p: ListPage) -> Binding<String> {
    Binding(get: { self.sort(p).rawValue }, set: { new in self.setSort(p, new == p.defaultSort.rawValue ? nil : new) })
  }
}

extension AppModel {
  // MARK: Matching

  /// Title, raw tag or file name contains `q` (case-insensitive).
  func listSearchMatches(_ v: Video, _ q: String) -> Bool {
    q.isEmpty || displayName(v).localizedCaseInsensitiveContains(q) || v.tag.localizedCaseInsensitiveContains(q)
      || v.name.localizedCaseInsensitiveContains(q)
  }

  /// Does `v` pass the clip filter `key` = `value`? (Platform is a post filter: always true here.)
  func listFilterMatches(_ v: Video, _ key: String, _ value: String) -> Bool {
    switch key {
    case ListFilterKey.session: v.sessionId == value
    case ListFilterKey.kind: v.kind.rawValue == value
    case ListFilterKey.score: v.type == .short && (LibraryScoreFilter(rawValue: value)?.matches(v.score) ?? true)
    case ListFilterKey.stage: ClipStage.of(v)?.rawValue == value
    default: true
    }
  }

  /// `vs` narrowed by the page's search and applied filters (all but `except`, for that section's counts).
  func listScope(_ page: ListPage, _ vs: [Video], except: String? = nil) -> [Video] {
    let s = ListPrefs.shared[page]
    let q = s.search.trimmingCharacters(in: .whitespaces)
    let active = s.filters.filter { $0.key != except && page.filterKeys.contains($0.key) && $0.key != ListFilterKey.platform }
    guard !q.isEmpty || !active.isEmpty else { return vs }
    return vs.filter { v in listSearchMatches(v, q) && active.allSatisfy { listFilterMatches(v, $0.key, $0.value) } }
  }

  // MARK: Sections

  /// The Filters popover sections for `page`, with per-option counts among `vs` (each section counted under the
  /// other applied filters). Posts pass `platformCount` (the posts per platform in scope).
  func listFilterSections(_ page: ListPage, _ vs: [Video], platformCount: ((Platform) -> Int)? = nil) -> [DSFilterSection] {
    let state = ListPrefs.shared[page]
    return page.filterKeys.compactMap { key in
      let scope = listScope(page, vs, except: key)
      func n(_ match: (Video) -> Bool) -> Int { scope.filter(match).count }
      var options: [DSFilterOption]
      let title: String
      switch key {
      case ListFilterKey.session:
        title = "Session"
        let ids = Set(vs.map(\.sessionId))
        options = sessions.filter { ids.contains($0.id) }.sorted { ($0.date ?? "", $0.name) > ($1.date ?? "", $1.name) }
          .map { s in DSFilterOption(id: s.id, title: Captions.setName(s.name), count: n { $0.sessionId == s.id }) }
      case ListFilterKey.kind:
        title = "Kind"
        options = Kind.allCases.map { k in DSFilterOption(id: k.rawValue, title: k.displayName, count: n { $0.kind == k }) }
      case ListFilterKey.score:
        title = "Score"
        options = LibraryScoreFilter.allCases.filter { $0 != .any }.map { f in
          DSFilterOption(id: f.rawValue, title: f.title, count: n { $0.type == .short && f.matches($0.score) })
        }
      case ListFilterKey.stage:
        title = "Stage"
        options = ClipStage.allCases.map { st in
          DSFilterOption(id: st.rawValue, title: st.displayName, count: n { ClipStage.of($0) == st }, tooltip: Self.stageHelp(st))
        }
      case ListFilterKey.platform:
        title = "Platform"
        options = settings.activePlatforms.map { p in
          DSFilterOption(id: p.rawValue, title: p.displayName, count: platformCount?(p), icon: p.dsSymbol)
        }
      default:
        return nil
      }
      // A remembered choice that's no longer listed (a session left the list) still shows, so it can be removed.
      if let sel = state.filters[key], !options.contains(where: { $0.id == sel }) {
        let title = key == ListFilterKey.session ? (sessionById[sel].map { Captions.setName($0.name) } ?? "Removed session") : sel
        options.append(DSFilterOption(id: sel, title: title, count: 0, tooltip: "No longer in this list — remove this filter"))
      }
      guard !options.isEmpty else { return nil }
      return DSFilterSection(id: key, title: title, options: options, selected: state.filters[key])
    }
  }

  /// What each stage holds (Library's Stage filter and stage chips).
  static func stageHelp(_ s: ClipStage) -> String {
    switch s {
    case .score: "Not scored yet"
    case .edit: "Scored; something is still missing"
    case .queue: "Complete and waiting for a day"
    case .scheduled: "Has days in the plan"
    case .posted: "Posted on its platforms"
    }
  }

  // MARK: Sorting

  /// `vs` in the page's chosen order (`natural` keeps the order given).
  func listSorted(_ page: ListPage, _ vs: [Video]) -> [Video] {
    switch ListPrefs.shared.sort(page) {
    case .natural: return vs
    case .session:
      return vs.sorted { a, b in
        let sa = sessionById[a.sessionId]?.date ?? "", sb = sessionById[b.sessionId]?.date ?? ""
        return (sb, a.part ?? 0, a.start ?? 0, a.id) < (sa, b.part ?? 0, b.start ?? 0, b.id)
      }
    case .newest: return vs.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    case .scoreHigh: return vs.sorted { ($0.score ?? -1, $1.id) > ($1.score ?? -1, $0.id) }
    case .scoreLow: return vs.sorted { ($0.score ?? 101, $0.id) < ($1.score ?? 101, $1.id) }
    case .title: return vs.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }
  }

  // MARK: Actions

  func setListFilter(_ page: ListPage, _ key: String, _ value: String?) {
    dsWithAnimation { ListPrefs.shared.setFilter(page, key, value) }
  }

  func clearListFilters(_ page: ListPage) {
    dsWithAnimation { ListPrefs.shared.clearFilters(page) }
  }

  /// ⌘F: focus the current screen's search (Week: open the backlog drawer first). Nothing while a dialog, sheet or
  /// in-window overlay is up (native popovers are their own window and never see it).
  func focusListSearch() {
    guard editor == nil, !showSettings, !showPalette, !showShortcuts, pendingBulk == nil, pendingConfirm == nil,
          previewVideo == nil, markPostedTarget == nil, reportTarget == nil, longformTarget == nil, scorePrompt == nil,
          pinPrompt == nil, pendingReplace == nil, captionDialogIds == nil, !ListPrefs.shared.screenDialogOpen,
          BrowseUI.shared.quickLook == nil, BrowseUI.shared.longformTargets.isEmpty, BrowseUI.shared.scoreTargets.isEmpty,
          BrowseUI.shared.pendingPostBulk == nil,
          let page = ListPage.of(screen) else { return }
    if page == .backlog && !weekBacklogExpanded { dsWithAnimation { weekBacklogExpanded = true } }
    ListPrefs.shared.focusSearch(page)
  }
}

/// The sort menu for pages that use `ClipSort` (Score, Edit, Library, backlog).
struct ListSortMenu: View {
  let page: ListPage
  var size: DSButtonSize = .md

  var body: some View {
    DSSortMenu(options: page.sorts.map { DSSortOption(id: $0.rawValue, title: page.title($0)) },
               selection: ListPrefs.shared.sortBinding(page), tooltip: "Change the order of the clips", size: size)
  }
}

/// A clip list's header (`DSListHeader`) wired to its `ListPrefs` page: search (⌘F), Filters popover with
/// removable chips + Clear all. The screen supplies the count, view modes, status chips, sort and trailing extras.
struct ListHeader<Modes: View, Chips: View, Sort: View, Trailing: View>: View {
  let page: ListPage
  let title: String
  let count: Int?
  var total: Int?
  var detail: String?
  var filters: [DSFilterSection]
  var compact = false
  var readingColumn = false
  var columnTrailingInset: CGFloat = 0
  var showsSearch = true
  @ViewBuilder var modes: Modes
  @ViewBuilder var chips: Chips
  @ViewBuilder var sort: Sort
  @ViewBuilder var trailing: Trailing

  init(page: ListPage, title: String, count: Int?, total: Int? = nil, detail: String? = nil, filters: [DSFilterSection],
       compact: Bool = false, readingColumn: Bool = false, columnTrailingInset: CGFloat = 0, showsSearch: Bool = true,
       @ViewBuilder modes: () -> Modes = { EmptyView() }, @ViewBuilder chips: () -> Chips = { EmptyView() },
       @ViewBuilder sort: () -> Sort = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.page = page
    self.title = title
    self.count = count
    self.total = total
    self.detail = detail
    self.filters = filters
    self.compact = compact
    self.readingColumn = readingColumn
    self.columnTrailingInset = columnTrailingInset
    self.showsSearch = showsSearch
    self.modes = modes()
    self.chips = chips()
    self.sort = sort()
    self.trailing = trailing()
  }

  var body: some View {
    let prefs = ListPrefs.shared
    DSListHeader(title, count: count, of: total, detail: detail,
                 search: showsSearch ? prefs.searchBinding(page) : nil, searchPlaceholder: page.searchPlaceholder,
                 searchFocus: prefs.focusToken(page), searchAutoFocus: prefs.pendingFocus == page,
                 onSearchFocused: { prefs.searchFocused(page) }, filters: filters,
                 onFilter: { key, value in dsWithAnimation { prefs.setFilter(page, key, value) } },
                 onClearAll: { dsWithAnimation { prefs.clearFilters(page) } },
                 compact: compact, columnWidth: readingColumn ? DS.size.readingColumn : nil,
                 columnTrailingInset: columnTrailingInset) {
      modes
    } chips: {
      chips
    } sort: {
      sort
    } trailing: {
      trailing
    }
  }
}
