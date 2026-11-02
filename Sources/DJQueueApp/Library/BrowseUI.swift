import DJQCore
import Observation
import SwiftUI

// MARK: - Library filters

/// Library filter pills (DESIGN-v2 §6.6): `All · Posted · Excluded · Missing · Long-form`.
enum LibraryFilter: String, CaseIterable, Identifiable {
  case all, posted, excluded, missing, longform
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "All"
    case .posted: "Posted"
    case .excluded: "Excluded"
    case .missing: "Missing"
    case .longform: "Long-form"
    }
  }
}

enum LibraryKindFilter: String, CaseIterable, Identifiable {
  case any, djVid, talking
  var id: String { rawValue }
  var title: String {
    switch self {
    case .any: "Any kind"
    case .djVid: "DJ vid"
    case .talking: "Talking"
    }
  }
}

enum LibraryScoreFilter: String, CaseIterable, Identifiable {
  case any, unscored, top, good, middle, low
  var id: String { rawValue }
  var title: String {
    switch self {
    case .any: "Any score"
    case .unscored: "Unscored"
    case .top: "80 and up"
    case .good: "60 – 79"
    case .middle: "40 – 59"
    case .low: "Under 40"
    }
  }

  func matches(_ score: Int?) -> Bool {
    switch self {
    case .any: true
    case .unscored: score == nil
    case .top: (score ?? -1) >= 80
    case .good: (60...79).contains(score ?? -1)
    case .middle: (40...59).contains(score ?? -1)
    case .low: (0...39).contains(score ?? -1)
    }
  }
}

enum LibrarySort: String, CaseIterable, Identifiable {
  case session, newest, scoreHigh, scoreLow, title
  var id: String { rawValue }
  var title: String {
    switch self {
    case .session: "Session order"
    case .newest: "Newest first"
    case .scoreHigh: "Score, best first"
    case .scoreLow: "Score, worst first"
    case .title: "Title A–Z"
    }
  }
}

// MARK: - Posts tabs

/// Posts segmented tabs (DESIGN-v2 §6.7): `Problems · Scheduled · Posted · All`.
enum PostsTab: String, CaseIterable, Identifiable {
  case problems, scheduled, posted, all
  var id: String { rawValue }
  var title: String {
    switch self {
    case .problems: "Problems"
    case .scheduled: "Scheduled"
    case .posted: "Posted"
    case .all: "All"
    }
  }
}

/// A bulk post operation waiting for confirmation (PostActions has no batch API: confirm, apply, toast).
struct PostBulk: Identifiable {
  enum Op: String { case reset, skip, retry }
  let id = UUID()
  var op: Op
  var postIds: [String]
}

// MARK: - Shared UI state

/// UI state of the Browse screens (Library, Posts, Health) and the ⌘K palette. Lives outside AppModel (the
/// foundation owns that file) and survives screen switches, so Eric comes back to the same filter. Snapshot shots
/// set it directly; `reset()` restores the defaults.
@MainActor
@Observable
final class BrowseUI {
  static let shared = BrowseUI()

  // Library
  var filter: LibraryFilter = .all
  var search = ""
  var kind: LibraryKindFilter = .any
  var score: LibraryScoreFilter = .any
  var sort: LibrarySort = .session
  /// Long-form / missing / removed clip quick look (in-screen dialog).
  var quickLook: Video?
  /// "Mark posted" URL dialog for one or more long-form clips.
  var longformTargets: [Video] = []
  /// Bulk "Score…" dialog for these clip ids.
  var scoreTargets: [String] = []

  // Posts
  var postsTab: PostsTab = .all
  var postsSearch = ""
  var postsPlatform: Platform?
  var pendingPostBulk: PostBulk?

  // ⌘K palette
  var paletteQuery = ""
  /// Clip whose actions the palette shows (second page), by id.
  var paletteClipId: String?

  var libraryFiltered: Bool { filter != .all || !search.isEmpty || kind != .any || score != .any }

  func clearLibraryFilters() {
    filter = .all
    search = ""
    kind = .any
    score = .any
  }

  func reset() {
    clearLibraryFilters()
    sort = .session
    quickLook = nil
    longformTargets = []
    scoreTargets = []
    postsTab = .all
    postsSearch = ""
    postsPlatform = nil
    pendingPostBulk = nil
    paletteQuery = ""
    paletteClipId = nil
  }
}

// MARK: - Shared small views

/// A filter menu in the sub-toolbar, drawn like a DSChip with a chevron ("Session ▾"; the chosen value when set,
/// in the chip's selected look) → native menu with a check on the current value.
struct BrowseFilterMenu<Value: Hashable>: View {
  let placeholder: String
  @Binding var selection: Value
  let anyValue: Value
  let options: [(Value, String)]
  var tooltip: String
  @State private var hovering = false

  var body: some View {
    let current = options.first { $0.0 == selection }
    let active = selection != anyValue
    Menu {
      ForEach(Array(options.enumerated()), id: \.offset) { _, o in
        Button {
          dsWithAnimation { selection = o.0 }
        } label: {
          if o.0 == selection { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text(active ? (current?.1 ?? placeholder) : placeholder).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.color.textTertiary)
      }
      .font(DS.type.captionMedium)
      .foregroundStyle(DS.color.text)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(active ? DS.color.selected : hovering ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(active ? DS.color.text.opacity(0.35) : DS.color.borderStrong, lineWidth: active ? 1.2 : 1))
      .contentShape(Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { hovering = $0 }
    .dsTooltip(tooltip)
  }
}

/// A clip's cover as a rounded thumbnail (poster only), loading it on appear. Fixed `width`×`height`, or pass
/// `aspect` (no size) to fill the available width at that aspect ratio.
struct BrowsePoster: View {
  @Bindable var model: AppModel
  let video: Video?
  var width: CGFloat? = nil
  var height: CGFloat? = nil
  var aspect: CGFloat? = nil
  var radius: CGFloat = DS.radius.xs

  var body: some View {
    Color.clear
      .frame(width: width, height: height)
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let v = video, let img = model.poster(v) {
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
          DSPosterPlaceholder()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.color.border) }
      .onAppear { if let v = video { model.requestPoster(v) } }
  }
}

/// In-screen modal: scrim over the screen + centred e3 card; click outside or Esc dismisses. (The window-level
/// ModalHost lives in the foundation's MainWindowView; Browse dialogs are screen-scoped.)
struct BrowseModal<Content: View>: View {
  let onDismiss: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    ZStack {
      DS.color.scrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onDismiss)
      content
        .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
        .onExitCommand(perform: onDismiss)
    }
    .transition(.opacity)
  }
}

extension View {
  /// Tooltip that also shows on a disabled control (it's attached to an always-enabled container).
  func browseHelp(_ text: String?) -> some View {
    contentShape(Rectangle()).dsTooltip(text)
  }
}

/// Horizontal screen gutter from the scaffold (`\.screenGutter`), read where the view is rendered.
struct BrowseGutter: ViewModifier {
  @Environment(\.screenGutter) private var gutter
  func body(content: Content) -> some View { content.padding(.horizontal, gutter) }
}
