import Foundation
import Observation

/// The six clip lists that share one header (round 4 S3): Score, Edit, Queue, Library, Posts and Week's backlog
/// drawer. Each keeps its own search, status chip, filters and sort.
enum ListPage: String, CaseIterable, Codable, Sendable {
  case score, edit, queue, library, posts, backlog

  /// The list on `screen` (Week → its backlog drawer); nil for screens without one (Today, Health).
  static func of(_ screen: Screen) -> ListPage? {
    switch screen {
    case .score: .score
    case .edit: .edit
    case .queue: .queue
    case .library: .library
    case .posts: .posts
    case .week: .backlog
    case .today, .health: nil
    }
  }
}

/// One list's header state. Every value is an id string so it survives relaunch unchanged (UserDefaults JSON).
struct ListState: Codable, Equatable, Sendable {
  var search = ""
  /// The page status chip (nil = "All"): an `EditFilter.id`, a session id, `scheduled`/`unscheduled`, a Library
  /// pill, a Posts tab…
  var status: String?
  /// Filters popover: section id → chosen option id (absent = not applied).
  var filters: [String: String] = [:]
  /// Sort option id (nil = the page's default).
  var sort: String?

  var hasFilters: Bool { !filters.isEmpty }
  /// Anything narrowing the list (search, status chip or a filter).
  var isNarrowed: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty || status != nil || !filters.isEmpty }
}

/// Per-page list header state, remembered across relaunch in UserDefaults (a UI preference, not app data — the
/// same place view modes and playback settings live). Snapshot runs never read or write it.
///
/// ⌘F: `focusSearch(_:)` bumps the page's token; the header's search field watches it and takes focus.
@MainActor
@Observable
final class ListPrefs {
  static let shared = ListPrefs()

  private(set) var states: [ListPage: ListState] = [:]
  /// ⌘F requests per page (the header's search field focuses when its token changes).
  private(set) var focusTokens: [ListPage: Int] = [:]
  @ObservationIgnored private let persists: Bool
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard, persists: Bool? = nil) {
    self.defaults = defaults
    let persists = persists ?? !AppModel.isSnapshotRun
    self.persists = persists
    guard persists else { return }
    for p in ListPage.allCases {
      if let d = defaults.data(forKey: Self.key(p)), let s = try? JSONDecoder().decode(ListState.self, from: d) { states[p] = s }
    }
  }

  static func key(_ p: ListPage) -> String { "djq.list.\(p.rawValue)" }

  subscript(_ p: ListPage) -> ListState {
    get { states[p] ?? ListState() }
    set {
      guard states[p] != newValue else { return }
      states[p] = newValue
      save(p)
    }
  }

  // MARK: Edits (one call per header control)

  func setSearch(_ p: ListPage, _ text: String) { self[p].search = text }
  func setStatus(_ p: ListPage, _ id: String?) { self[p].status = id }
  func setSort(_ p: ListPage, _ id: String?) { self[p].sort = id }

  /// Sets (or, with nil, removes) one filter.
  func setFilter(_ p: ListPage, _ section: String, _ option: String?) {
    var s = self[p]
    s.filters[section] = option
    self[p] = s
  }

  /// "Clear all": every filter and the search; the status chip and sort stay (they're the page's view, not a filter).
  func clearFilters(_ p: ListPage) {
    var s = self[p]
    s.filters = [:]
    s.search = ""
    self[p] = s
  }

  /// Back to the defaults (snapshots, tests).
  func reset(_ p: ListPage? = nil) {
    for page in p.map({ [$0] }) ?? ListPage.allCases {
      states[page] = nil
      if persists { defaults.removeObject(forKey: Self.key(page)) }
    }
  }

  /// A ⌘F that hasn't reached a search field yet (Week: the drawer's field appears after the drawer opens).
  private(set) var pendingFocus: ListPage?

  func focusSearch(_ p: ListPage) {
    pendingFocus = p
    focusTokens[p, default: 0] += 1
  }

  /// The page's search field took focus (clears the pending ⌘F).
  func searchFocused(_ p: ListPage) { if pendingFocus == p { pendingFocus = nil } }
  func focusToken(_ p: ListPage) -> Int { focusTokens[p] ?? 0 }

  private func save(_ p: ListPage) {
    guard persists else { return }
    if let s = states[p], s != ListState(), let d = try? JSONEncoder().encode(s) {
      defaults.set(d, forKey: Self.key(p))
    } else {
      defaults.removeObject(forKey: Self.key(p))
    }
  }
}

extension ListState {
  /// Search or a filter narrows the list (the status chip aside).
  func isNarrowed(ignoringStatus: Bool) -> Bool {
    !search.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty || (!ignoringStatus && status != nil)
  }
}
