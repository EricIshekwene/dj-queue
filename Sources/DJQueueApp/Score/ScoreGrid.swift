import DJQCore
import SwiftUI

/// Score → Grid (DESIGN-v2 §4 Grid + §6.1): portrait tiles (DSClipCard `.grid`) with an inline score field under
/// each. ⇥ / ↩ move to the next tile's field; a valid typed score selects its tile so the bulk bar (with
/// **Save scores**) appears. Clicking a tile focuses its field; ⇧/⌘-click and the checkbox select as everywhere.
/// Tiles show only what scoring needs: cover (autoplay), length, title, session. No suggestions or chips.
struct ScoreGridView: View {
  @Bindable var model: AppModel
  let videos: [Video]
  @FocusState private var focus: String?
  @State private var visible: Set<String> = []
  @State private var hovered: String?
  @Environment(\.screenGutter) private var gutter
  private var ui: PipelineUIState { .shared }

  var body: some View {
    let ids = videos.map(\.id)
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: DS.space.md, alignment: .top)],
                alignment: .leading, spacing: DS.space.xl) {
        ForEach(Array(videos.enumerated()), id: \.element.id) { i, v in
          tile(v, next: videos.indices.contains(i + 1) ? videos[i + 1].id : nil, ids: ids)
        }
      }
      .padding(.horizontal, gutter)
      .padding(.top, DS.space.xxs)
      .padding(.bottom, ScreenMetrics.bulkBarInset)
    }
    .pipelineClipFeed(model, .score, ids: ids, play: ids.filter { visible.contains($0) }, layout: .grid,
                      hovered: hovered ?? focus)
  }

  private func tile(_ v: Video, next: String?, ids: [String]) -> some View {
    let sel = model.selected(.score)
    var c = model.dsClip(v, for: .score)
    c.suggestions = []
    c.issues = []
    c.blocks = []
    var cfg = DSClipCardConfig()
    let p = model.playback
    cfg.autoplay = PreviewPlayback.plays(p, layout: .grid, hovered: hovered == v.id, focused: focus == v.id)
    cfg.unmuteOnHover = p.hoverSound
    cfg.selectionMode = !sel.isEmpty
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      DSClipCard(c, mode: .grid, isSelected: sel.contains(v.id), isFocused: focus == v.id, config: cfg,
                 onToggleSelect: { model.toggleSelection(v.id, screen: .score) },
                 onTap: { m in
                   if model.select(v.id, modifiers: m, ordered: ids, screen: .score) == .plainClick { focus = v.id }
                 })
      ScoreTileField(model: model, id: v.id, focus: $focus, next: next)
    }
    .dsPlaybackHover { inside in
      if inside { hovered = v.id } else if hovered == v.id { hovered = nil }
    }
    .onAppear {
      visible.insert(v.id)
      model.requestPoster(v)
    }
    .task(id: c.previewStamp) { if visible.contains(v.id) { model.requestPoster(v) } }
    .onDisappear { visible.remove(v.id) }
  }
}

/// Compact score field under a grid tile (DS input box, tabular digits). Typing a valid score selects the tile.
private struct ScoreTileField: View {
  @Bindable var model: AppModel
  let id: String
  var focus: FocusState<String?>.Binding
  let next: String?
  @State private var hovering = false
  private var ui: PipelineUIState { .shared }

  var body: some View {
    let text = Binding(get: { ui.typedScores[id] ?? "" }, set: { new in
      let digits = String(new.filter(\.isNumber).prefix(3))
      ui.typedScores[id] = digits.isEmpty ? nil : digits
      if PipelineUIState.score(digits) != nil, !model.isSelected(id, in: .score) { model.toggleSelection(id, screen: .score) }
    })
    let invalid = !text.wrappedValue.isEmpty && PipelineUIState.score(text.wrappedValue) == nil
    let focused = focus.wrappedValue == id
    HStack(spacing: 6) {
      Text("Score").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      TextField("0–100", text: text)
        .textFieldStyle(.plain)
        .font(DS.type.bodyMedium.monospacedDigit())
        .foregroundStyle(DS.color.text)
        .multilineTextAlignment(.trailing)
        .focused(focus, equals: id)
        .onSubmit { focus.wrappedValue = next }
    }
    .padding(.horizontal, 10)
    .frame(height: DS.size.controlSm + 2)
    .modifier(DSFieldBox(focused: focused, hovering: hovering, error: invalid, disabled: false))
    .onHover { hovering = $0 }
    .dsTooltip(invalid ? "Scores go from 0 to 100" : "Type 0–100; Save scores in the bar below")
    .accessibilityLabel("Score")
  }
}
