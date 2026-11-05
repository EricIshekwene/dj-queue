import DJQCore
import Observation
import SwiftUI

// MARK: - Library filters

/// Library status chips (DESIGN-v2 §6.6): `All · Posted · Excluded · Missing · Long-form` (stored in
/// `ListPrefs[.library].status`; nil = All).
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

/// Score bands for the Filters popover's Score section (`any` = not applied).
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

// MARK: - Posts tabs

/// Posts status chips (DESIGN-v2 §6.7): `All · Problems · Scheduled · Posted` (stored in `ListPrefs[.posts].status`).
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

/// UI state of the Browse screens (Library, Posts, Health) and the ⌘K palette: dialogs and palette state. Lives
/// outside AppModel and survives screen switches. List search, status chips, filters and sort live in `ListPrefs`
/// (per page, remembered across relaunch). Snapshot shots set it directly; `reset()` restores the defaults.
@MainActor
@Observable
final class BrowseUI {
  static let shared = BrowseUI()

  // Library
  /// Long-form / missing / removed clip quick look (in-screen dialog).
  var quickLook: Video?
  /// "Mark posted" URL dialog for one or more long-form clips.
  var longformTargets: [Video] = []
  /// Bulk "Score…" dialog for these clip ids.
  var scoreTargets: [String] = []

  // Posts
  var pendingPostBulk: PostBulk?

  // ⌘K palette
  var paletteQuery = ""
  /// Clip whose actions the palette shows (second page), by id.
  var paletteClipId: String?
  /// What was typed before a clip's page opened (Back returns to those results).
  var paletteReturnQuery = ""
  /// The type chip under the search field.
  var paletteScope = SearchScope.all

  func reset() {
    quickLook = nil
    longformTargets = []
    scoreTargets = []
    pendingPostBulk = nil
    paletteQuery = ""
    paletteClipId = nil
    paletteReturnQuery = ""
    paletteScope = .all
  }
}

// MARK: - Shared small views

/// A clip's cover as a rounded thumbnail (poster only), loading it on appear. Fixed `width`×`height`, or pass
/// `aspect` (no size) to fill the available width at that aspect ratio. The cover is the edited one (round 4 S6):
/// for `post`, that post's version (and its render's cover when current), else version 1.
struct BrowsePoster: View {
  @Bindable var model: AppModel
  let video: Video?
  var width: CGFloat? = nil
  var height: CGFloat? = nil
  var aspect: CGFloat? = nil
  var radius: CGFloat = DS.radius.xs
  var post: PlatformPost? = nil

  var body: some View {
    let postCover = post.flatMap { model.clipPreview(post: $0)?.cover }
    Color.clear
      .frame(width: width, height: height)
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let img = postCover {
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let v = video, let img = model.poster(v) {
          Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
          DSPosterPlaceholder()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.color.border) }
      .onAppear { request() }
      .task(id: post.map { model.previewStamp($0.videoId, version: $0.versionNo) } ?? video.map { model.previewStamp($0.id) } ?? "") {
        request()
      }
  }

  private func request() {
    if let post { model.requestPreview(post: post) } else if let v = video { model.requestPoster(v) }
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
