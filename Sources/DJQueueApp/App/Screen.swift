import DJQCore
import SwiftUI

/// The sidebar destinations (round 2 #13, pipeline navigation): the clip's life Score → Edit → Queue → Week →
/// Today, then Browse (Library, Posts, Health). ⌘1…⌘8 in this order. Settings is not a screen: it's the in-window
/// modal (`AppModel.showSettings`, DESIGN-v2 §6.9).
enum Screen: String, CaseIterable, Identifiable {
  case score, edit, queue, week, today, library, posts, health
  var id: String { rawValue }

  var title: String {
    switch self {
    case .score: "Score"
    case .edit: "Edit"
    case .queue: "Queue"
    case .week: "Week"
    case .today: "Today"
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
    case .week: "calendar"
    case .today: "sun.max"
    case .library: "rectangle.stack"
    case .posts: "paperplane"
    case .health: "heart"
    }
  }

  /// ⌘1…⌘8.
  var key: KeyEquivalent { KeyEquivalent(Character("\((Screen.allCases.firstIndex(of: self) ?? 0) + 1)")) }

  /// The pipeline group (no header in the sidebar); the rest sit under "Browse".
  var isPipeline: Bool { [.score, .edit, .queue, .week, .today].contains(self) }

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
}

/// Autoplay preferences (decision #12), persisted in UserDefaults `djq.playback`. Settings → Playback & autoplay
/// edits them through `AppModel.setPlayback`.
struct PlaybackPrefs: Codable, Equatable, Sendable {
  /// Muted autoplay of visible clips from their 540×960 proxies.
  var autoplay = true
  /// Unmute the clip under the pointer (never auto-unmutes otherwise).
  var unmuteOnHover = false
  /// Only the hovered / keyboard-focused clip plays (instead of every visible clip, ≤ 4 players).
  var focusOnly = false
  /// What the proxies loop: the resolved trim (what will post) or the whole clip file.
  var loop: ProxyRange = .trim
}
