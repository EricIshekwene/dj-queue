import DJQCore
import SwiftUI

/// The sidebar destinations (round 2 #13, pipeline navigation): the clip's life Score → Edit → Queue → Calendar, then
/// Browse (Library, Posts, Health). ⌘1…⌘7 in this order. Settings is not a screen: it's the in-window modal
/// (`AppModel.showSettings`, DESIGN-v2 §6.9).
enum Screen: String, CaseIterable, Identifiable {
  case score, edit, queue, calendar, library, posts, health
  var id: String { rawValue }

  var title: String {
    switch self {
    case .score: "Score"
    case .edit: "Edit"
    case .queue: "Queue"
    case .calendar: "Calendar"
    case .library: "Library"
    case .posts: "Posts"
    case .health: "Health"
    }
  }

  /// 16 pt SF Symbol for the sidebar row (DESIGN-v2 §3).
  var symbol: String {
    switch self {
    case .score: "target"
    case .edit: "pencil"
    case .queue: "list.bullet"
    case .calendar: "calendar"
    case .library: "rectangle.stack"
    case .posts: "paperplane"
    case .health: "heart"
    }
  }

  /// ⌘1…⌘7.
  var key: KeyEquivalent { KeyEquivalent(Character("\((Screen.allCases.firstIndex(of: self) ?? 0) + 1)")) }

  /// The pipeline group (no header in the sidebar); the rest sit under "Browse".
  var isPipeline: Bool { [.score, .edit, .queue, .calendar].contains(self) }

  /// View mode used until Eric picks another (decision #12): Score single, Edit/Queue cards, Library grid,
  /// Posts list, others cards.
  var defaultViewMode: DSViewMode {
    switch self {
    case .score: .single
    case .library: .grid
    case .posts: .list
    default: .wide
    }
  }
}

struct EditorRequest: Equatable {
  var videoId: String
  var videoIds: [String]
  var fixPostId: String?
  /// F6 "Trim for X" from the Edit list: open with X's trim lane added at X's limit.
  var trimPlatform: Platform? = nil
}

