import DJQCore
import SwiftUI

/// Clips in one of the four view modes (DESIGN-v2 §4), with selection, posters, proxies and autoplay wired up.
///
/// - **Cards** (`.wide`): LazyVStack, centred, max 880, 8 pt gaps.
/// - **Grid**: LazyVGrid adaptive 168–220, 16 pt gaps, full width with the screen gutter.
/// - **Single**: one large card with ‹ › buttons; ←/→ move. The shown index is `focusIndex` (pass a binding to
///   drive it, e.g. Score's "Save & next"), else internal state.
/// - **List**: 52 pt rows under a header row of column labels, centred, max 880.
///
/// Clicks: checkbox → toggle; ⇧-click → range from the anchor; ⌘-click → toggle; plain click → `onOpen` when
/// nothing is selected, otherwise it toggles (selection mode — the same rule DSClipCard applies). A suggestion
/// chip sets the Title through `acceptSuggestion` (undoable). Items request their poster and preview proxy as they
/// appear. Autoplay follows `model.playback` via `PreviewPlayback.plays` (focus-only → only the hovered / shown item
/// plays; Grid with "play on hover only" → posters, the hovered tile plays and its neighbours' proxies prefetch).
///
/// The collection registers its ids in `model.visibleIds[screen]` (⌘A, Select all) and drops selected ids that
/// left the list. Empty lists: show a DSEmptyState instead of the collection (the screen's job).
/// `header` scrolls above the items (Cards/Grid/List) or sits above the player (Single).
struct ClipCollection<Actions: View, Menu: View, Header: View>: View {
  @Bindable var model: AppModel
  let screen: Screen
  let videos: [Video]
  let mode: DSViewMode
  /// Custom card model (default `model.dsClip(v, for: screen)`); post-process there (positions, tags…).
  var clip: ((Video) -> DSClip)?
  /// Queue: ⋮⋮ handle on hover (Cards mode). Reordering itself is the screen's job.
  var showsDragHandle = false
  var focusIndex: Binding<Int>?
  let onOpen: (Video) -> Void
  let actions: (Video) -> Actions
  let contextMenu: (Video) -> Menu
  let header: Header

  @State private var visible: Set<String> = []
  @State private var hovered: String?
  @State private var ownFocus = 0
  @FocusState private var keyFocus: Bool
  @Environment(\.screenGutter) private var gutter

  init(model: AppModel, screen: Screen, videos: [Video], mode: DSViewMode, clip: ((Video) -> DSClip)? = nil,
       showsDragHandle: Bool = false, focusIndex: Binding<Int>? = nil, onOpen: @escaping (Video) -> Void,
       @ViewBuilder actions: @escaping (Video) -> Actions, @ViewBuilder contextMenu: @escaping (Video) -> Menu,
       @ViewBuilder header: () -> Header) {
    self.model = model
    self.screen = screen
    self.videos = videos
    self.mode = mode
    self.clip = clip
    self.showsDragHandle = showsDragHandle
    self.focusIndex = focusIndex
    self.onOpen = onOpen
    self.actions = actions
    self.contextMenu = contextMenu
    self.header = header()
  }

  private var ids: [String] { videos.map(\.id) }
  private var focus: Int {
    get { min(max(0, focusIndex?.wrappedValue ?? ownFocus), max(0, videos.count - 1)) }
  }
  private func setFocus(_ i: Int) {
    let i = min(max(0, i), max(0, videos.count - 1))
    if let focusIndex { focusIndex.wrappedValue = i } else { ownFocus = i }
  }

  var body: some View {
    Group {
      switch mode {
      case .wide: cards
      case .grid: grid
      case .single: single
      case .list: list
      }
    }
    .onAppear { register(ids) }
    .onChange(of: ids) { _, new in register(new) }
    .task(id: proxyKey) {
      try? await Task.sleep(for: .milliseconds(model.frozen ? 0 : 250))
      guard !Task.isCancelled, model.playback.autoplay else { return }
      let t = PreviewPlayback.proxyTargets(model.playback, layout: mode.playbackLayout, visible: proxyOrder,
                                           hovered: mode == .single ? nil : hovered)
      model.requestProxies(t.now, prefetch: t.prefetch)
    }
  }

  // MARK: Modes

  private var cards: some View {
    ScrollView {
      LazyVStack(spacing: DS.space.xs) {
        header
        ForEach(videos) { v in card(v) }
      }
      .frame(maxWidth: DS.size.readingColumn)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, gutter)
      .padding(.top, DS.space.xxs)
      .padding(.bottom, ScreenMetrics.bulkBarInset)
    }
  }

  private var grid: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DS.space.md) {
        header
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: DS.space.md, alignment: .top)],
                  alignment: .leading, spacing: DS.space.xl) {
          ForEach(videos) { v in card(v) }
        }
      }
      .padding(.horizontal, gutter)
      .padding(.top, DS.space.xxs)
      .padding(.bottom, ScreenMetrics.bulkBarInset)
    }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        header
        Section {
          ForEach(videos) { v in card(v) }
        } header: {
          ClipListColumns(selectable: true).background(DS.color.background)
        }
      }
      .frame(maxWidth: DS.size.readingColumn)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, gutter)
      .padding(.bottom, ScreenMetrics.bulkBarInset)
    }
  }

  private var single: some View {
    GeometryReader { geo in
      let h = max(320, min(720, geo.size.height - 2 * DS.space.xl))
      let i = focus
      VStack(spacing: DS.space.md) {
        header
        if videos.indices.contains(i) {
          HStack(spacing: DS.space.xl) {
            DSIconButton("chevron.left", tooltip: "Previous clip", variant: .ghost, size: .lg, shortcut: "←",
                         disabledReason: i == 0 ? "This is the first clip" : nil) { setFocus(i - 1) }
            card(videos[i], focused: true)
              .frame(width: h * 9 / 16 + DS.space.xxl + 280, height: h)
              .id(videos[i].id)
              .transition(.opacity)
            DSIconButton("chevron.right", tooltip: "Next clip", variant: .ghost, size: .lg, shortcut: "→",
                         disabledReason: i >= videos.count - 1 ? "This is the last clip" : nil) { setFocus(i + 1) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .padding(DS.space.xl)
      .frame(width: geo.size.width, height: geo.size.height)
    }
    // ←/→ go to a hidden focusable sibling (a focusable container would mark every button inside as focused).
    .background {
      Color.clear
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { setFocus(focus - 1); return .handled }
        .onKeyPress(.rightArrow) { setFocus(focus + 1); return .handled }
    }
    .onAppear { keyFocus = true }
    .dsAnimation(DS.motion.fade, value: focus)
  }

  // MARK: Card

  private func card(_ v: Video, focused: Bool = false) -> some View {
    let sel = model.selected(screen)
    let c = clip?(v) ?? model.dsClip(v, for: screen)
    var cfg = DSClipCardConfig()
    let p = model.playback
    cfg.autoplay = PreviewPlayback.plays(p, layout: mode.playbackLayout, hovered: hovered == v.id, focused: focused)
    cfg.unmuteOnHover = p.hoverSound
    cfg.selectionMode = !sel.isEmpty && mode != .single
    cfg.showsDragHandle = showsDragHandle && mode == .wide
    return DSClipCard(c, mode: mode, isSelected: sel.contains(v.id), isFocused: focused && mode != .single, config: cfg,
                      onToggleSelect: mode == .single ? nil : { model.toggleSelection(v.id, screen: screen) },
                      onTap: { m in tap(v, m) },
                      onAcceptSuggestion: { s in model.acceptSuggestion(v.id, s.text) }) {
      actions(v)
    }
    .modifier(OptionalContextMenu(enabled: Menu.self != EmptyView.self) { contextMenu(v) })
    .onHover { inside in
      if inside { hovered = v.id } else if hovered == v.id { hovered = nil }
    }
    .onAppear {
      visible.insert(v.id)
      model.requestPoster(v)
    }
    .onDisappear { visible.remove(v.id) }
  }

  private func tap(_ v: Video, _ m: EventModifiers) {
    guard model.select(v.id, modifiers: m, ordered: ids, screen: screen) == .plainClick else { return }
    if model.selected(screen).isEmpty { onOpen(v) } else { model.toggleSelection(v.id, screen: screen) }
  }

  // MARK: Bookkeeping

  private func register(_ new: [String]) {
    model.visibleIds[screen] = new
    let keep = Set(new)
    if let sel = model.selection[screen], !sel.isSubset(of: keep) { model.selection[screen] = sel.intersection(keep) }
  }

  /// Visible items in display order (Single: the shown clip and its neighbours).
  private var proxyOrder: [String] {
    if mode == .single {
      let i = focus
      return [i, i + 1, i - 1].filter { videos.indices.contains($0) }.map { videos[$0].id }
    }
    return ids.filter { visible.contains($0) }
  }

  private var proxyKey: String {
    proxyOrder.joined(separator: ",") + "|\(model.playback.loop.rawValue)|\(model.playback.autoplay)|\(mode.rawValue)"
      + "|\(model.playback.gridHoverOnly)|\(mode == .grid && model.playback.gridHoverOnly ? hovered ?? "" : "")"
  }
}

extension ClipCollection where Header == EmptyView {
  init(model: AppModel, screen: Screen, videos: [Video], mode: DSViewMode, clip: ((Video) -> DSClip)? = nil,
       showsDragHandle: Bool = false, focusIndex: Binding<Int>? = nil, onOpen: @escaping (Video) -> Void,
       @ViewBuilder actions: @escaping (Video) -> Actions, @ViewBuilder contextMenu: @escaping (Video) -> Menu) {
    self.init(model: model, screen: screen, videos: videos, mode: mode, clip: clip, showsDragHandle: showsDragHandle,
              focusIndex: focusIndex, onOpen: onOpen, actions: actions, contextMenu: contextMenu) { EmptyView() }
  }
}

extension ClipCollection where Header == EmptyView, Menu == EmptyView {
  init(model: AppModel, screen: Screen, videos: [Video], mode: DSViewMode, clip: ((Video) -> DSClip)? = nil,
       showsDragHandle: Bool = false, focusIndex: Binding<Int>? = nil, onOpen: @escaping (Video) -> Void,
       @ViewBuilder actions: @escaping (Video) -> Actions) {
    self.init(model: model, screen: screen, videos: videos, mode: mode, clip: clip, showsDragHandle: showsDragHandle,
              focusIndex: focusIndex, onOpen: onOpen, actions: actions, contextMenu: { _ in EmptyView() }) { EmptyView() }
  }
}

/// Column labels above List mode, aligned with DSClipCard `.list` (checkbox · thumb · title … score · next ·
/// platforms · actions).
struct ClipListColumns: View {
  var selectable = true
  var body: some View {
    HStack(spacing: DS.space.sm) {
      if selectable { Color.clear.frame(width: 20, height: 1) }
      Color.clear.frame(width: 24, height: 1)
      Text("Clip").frame(maxWidth: .infinity, alignment: .leading)
      Text("Score").frame(width: 40, alignment: .trailing)
      Text("Next").frame(width: 96, alignment: .leading)
      Text("Platforms").frame(width: 150, alignment: .leading)
      Color.clear.frame(width: 28, height: 1)
    }
    .font(DS.type.micro)
    .foregroundStyle(DS.color.textTertiary)
    .padding(.horizontal, DS.space.xs)
    .frame(height: 32)
    .overlay(alignment: .bottom) { DSSeparator() }
  }
}

/// `.contextMenu` only when the screen supplies one (an empty menu would still open).
private struct OptionalContextMenu<M: View>: ViewModifier {
  let enabled: Bool
  @ViewBuilder let menu: () -> M
  func body(content: Content) -> some View {
    if enabled { content.contextMenu { menu() } } else { content }
  }
}

extension DSViewMode {
  /// The playback rules' name for this layout (`PreviewPlayback`).
  var playbackLayout: PreviewPlayback.Layout {
    switch self {
    case .wide: .cards
    case .grid: .grid
    case .single: .single
    case .list: .list
    }
  }
}
