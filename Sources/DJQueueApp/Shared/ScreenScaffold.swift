import DJQCore
import SwiftUI

extension EnvironmentValues {
  /// Horizontal screen gutter (DESIGN-v2 §2.3): 24, or 32 when the content area is ≥ 1100 pt. Set by ScreenScaffold.
  @Entry var screenGutter: CGFloat = 24
}

enum ScreenMetrics {
  static func gutter(for width: CGFloat) -> CGFloat { width >= 1100 ? DS.space.xxl : DS.space.xl }
  /// Bottom padding inside scroll views so the floating bulk bar (48 + 16 + margin) never covers the last row.
  static let bulkBarInset: CGFloat = 88
}

/// The frame every screen draws inside the shell's content area (DESIGN-v2 §3):
///
/// ```
/// ┌ DSToolbar 52: title · subtitle ··········· trailing (view toggle, ⋯, one primary) ┐
/// │ sub-toolbar row (optional: filter chips, segmented)                               │
/// │ attention cards (problems / paused / engine off / low runway / load error)        │
/// │ content (fills the rest; gutters come from `\.screenGutter`)                      │
/// └───────────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ```swift
/// ScreenScaffold(model: model, screen: .edit, subtitle: "9") {
///   DSViewModeSwitcher(mode: model.viewModeBinding(.edit), modes: [.wide, .grid, .list])
///   DSButton("Send to Queue with defaults", variant: .primary) { … }
/// } subToolbar: {
///   DSChip("All", isSelected: true, count: 9) {}
/// } content: {
///   ClipCollection(…)
/// }
/// ```
/// `readingColumn: true` centres the sub-toolbar and attention cards in the 880 pt column (text-heavy screens and
/// Cards view); otherwise they span the full width with gutters. The problems card is hidden on Posts (that
/// screen is where it leads); the paused card shows only on Posts (the sidebar status is the indicator elsewhere).
struct ScreenScaffold<Trailing: View, SubToolbar: View, Header: View, Content: View>: View {
  @Bindable var model: AppModel
  let screen: Screen
  var title: String
  var subtitle: String?
  var readingColumn: Bool
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var subToolbar: SubToolbar
  /// Clip lists: the shared `DSListHeader` replaces the toolbar and sub-toolbar (round 4 S3).
  @ViewBuilder var header: Header
  @ViewBuilder var content: Content
  @State private var width: CGFloat = 1180

  init(model: AppModel, screen: Screen, title: String? = nil, subtitle: String? = nil, readingColumn: Bool = false,
       @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder subToolbar: () -> SubToolbar = { EmptyView() },
       @ViewBuilder content: () -> Content) where Header == EmptyView {
    self.model = model
    self.screen = screen
    self.title = title ?? screen.title
    self.subtitle = subtitle
    self.readingColumn = readingColumn
    self.trailing = trailing()
    self.subToolbar = subToolbar()
    self.header = EmptyView()
    self.content = content()
  }

  /// A clip list: `header` (a `DSListHeader`) sits where the toolbar and sub-toolbar would, with the screen gutter.
  init(model: AppModel, screen: Screen, readingColumn: Bool = false, @ViewBuilder header: () -> Header,
       @ViewBuilder content: () -> Content) where Trailing == EmptyView, SubToolbar == EmptyView {
    self.model = model
    self.screen = screen
    self.title = screen.title
    self.subtitle = nil
    self.readingColumn = readingColumn
    self.trailing = EmptyView()
    self.subToolbar = EmptyView()
    self.header = header()
    self.content = content()
  }

  private var gutter: CGFloat { ScreenMetrics.gutter(for: width) }

  var body: some View {
    VStack(spacing: 0) {
      if Header.self != EmptyView.self {
        header
          .padding(.horizontal, gutter)
          .background { WindowDragArea() }
      } else {
        DSToolbar(title, subtitle: subtitle) { EmptyView() } trailing: { trailing }
          .padding(.horizontal, gutter - DS.space.xl)
          .background { WindowDragArea() }
      }
      if SubToolbar.self != EmptyView.self {
        HStack(spacing: DS.space.xs) { subToolbar }
          .frame(maxWidth: readingColumn ? DS.size.readingColumn : .infinity, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: readingColumn ? .center : .leading)
          .padding(.horizontal, gutter)
          .padding(.bottom, DS.space.sm)
      }
      AttentionStack(model: model, screen: screen)
        .frame(maxWidth: readingColumn ? DS.size.readingColumn : .infinity)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, gutter)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environment(\.screenGutter, gutter)
    .background(DS.color.background)
    .background {
      // ⌘F focuses this screen's list search (round 4 S3). A window-level hidden button wins over the Edit menu, so
      // the system text items (Find, Spelling, Substitutions…) stay for text fields elsewhere (the editor has no
      // scaffold, so ⌘F there is the text view's own).
      Button("") { model.focusListSearch() }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .onChange(of: model.screen) { ListPrefs.shared.cancelPendingFocus() }
  }
}

/// The attention cards for a screen (DESIGN-v2 §3), stacked with 8 pt gaps and 12 pt below.
struct AttentionStack: View {
  @Bindable var model: AppModel
  let screen: Screen

  var body: some View {
    // Posts is where problems lead (no card there) and the only screen with the "Posting paused" card; elsewhere
    // the sidebar's posting status says "Posting paused" and is the control.
    let items = model.attentionItems.filter { i in
      !(screen == .posts && i.id == "problems") && !(screen != .posts && i.id == "paused")
    }
    if !items.isEmpty {
      VStack(spacing: DS.space.xs) {
        ForEach(items) { i in
          DSAttentionCard(title: i.title, message: i.message, tone: i.tone, actionTitle: i.actionTitle,
                          onDismiss: i.dismissible ? { dsWithAnimation { model.dismissWarning(i.id) } } : nil,
                          action: i.action)
        }
      }
      .padding(.bottom, DS.space.sm)
      .transition(.opacity)
    }
  }
}

/// Transparent area that drags the window (the title bar is hidden; toolbars and the sidebar top act as it).
struct WindowDragArea: View {
  var body: some View {
    Color.clear
      .contentShape(Rectangle())
      .gesture(WindowDragGesture())
      .allowsWindowActivationEvents(true)
  }
}
