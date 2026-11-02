import DJQCore
import SwiftUI

/// Queue → Cards (DESIGN-v2 §4 Cards + §6.3): the horizontal cards in posting order, drawn here instead of in
/// ClipCollection because Queue needs two things the shared collection doesn't offer: drag to reorder, and
/// actions that appear only while the card is hovered. Selection, posters, proxies and ⌘A work as everywhere.
///
/// Drag (core has no free reorder API — DECISIONS): drop a card on a **planned** clip → it takes that day,
/// pinned (BulkActions.pinConsecutive, undoable; the planner moves the other clip). The ready backlog follows the
/// sort, so dropping onto a backlog card explains that instead of pretending to reorder.
struct QueueCardList: View {
  @Bindable var model: AppModel
  let videos: [Video]
  let positions: [String: Int]
  let onPin: (String) -> Void

  @State private var visible: Set<String> = []
  @State private var hovered: String?
  @State private var dropTarget: String?
  @Environment(\.screenGutter) private var gutter

  var body: some View {
    let ids = videos.map(\.id)
    ScrollView {
      LazyVStack(spacing: DS.space.xs) {
        ForEach(videos) { v in card(v, ids: ids) }
      }
      .frame(maxWidth: DS.size.readingColumn)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, gutter)
      .padding(.top, DS.space.xxs)
      .padding(.bottom, ScreenMetrics.bulkBarInset)
    }
    .pipelineClipFeed(model, .queue, ids: ids, play: ids.filter { visible.contains($0) })
  }

  private func card(_ v: Video, ids: [String]) -> some View {
    let sel = model.selected(.queue)
    var c = model.dsClip(v, for: .queue)
    c.position = positions[v.id]
    var cfg = DSClipCardConfig()
    let p = model.playback
    cfg.autoplay = p.autoplay && (!p.focusOnly || hovered == v.id)
    cfg.unmuteOnHover = p.hoverSound
    cfg.selectionMode = !sel.isEmpty
    cfg.showsDragHandle = true
    let hot = hovered == v.id || SnapshotHover.id == v.id
    return DSClipCard(c, mode: .wide, isSelected: sel.contains(v.id), isFocused: dropTarget == v.id, config: cfg,
                      onToggleSelect: { model.toggleSelection(v.id, screen: .queue) },
                      onTap: { m in
                        guard model.select(v.id, modifiers: m, ordered: ids, screen: .queue) == .plainClick else { return }
                        if model.selected(.queue).isEmpty { model.openEditor(v.id, in: ids) } else { model.toggleSelection(v.id, screen: .queue) }
                      }) {
      QueueClipActions(model: model, video: v, mode: .wide, ids: ids, onPin: { onPin(v.id) })
        .opacity(hot ? 1 : 0)
        .allowsHitTesting(hot)
    }
    .contextMenu { QueueClipMenu(model: model, video: v, ids: ids, onPin: { t in t.count == 1 ? onPin(t[0]) : () }) }
    .draggable(v.id) {
      Text(model.displayName(v)).font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        .padding(.horizontal, 12).frame(height: 32)
        .dsFloatingSurface(radius: DS.radius.md)
    }
    .dropDestination(for: String.self) { items, _ in
      guard let id = items.first else { return false }
      return drop(id, onto: v)
    } isTargeted: { t in
      if t { dropTarget = v.id } else if dropTarget == v.id { dropTarget = nil }
    }
    .onHover { inside in
      if inside { hovered = v.id } else if hovered == v.id { hovered = nil }
    }
    .onAppear {
      visible.insert(v.id)
      model.requestPoster(v)
    }
    .onDisappear { visible.remove(v.id) }
  }

  private func drop(_ id: String, onto target: Video) -> Bool {
    guard id != target.id, model.video(id) != nil else { return false }
    guard let slot = model.nextSlotByVideo[target.id] else {
      model.show("The ready backlog follows the sort (\(model.settings.sort.displayName)). Drop on a planned clip, or pin a clip to a date.")
      return false
    }
    let day = Fmt.day(model.dm.date(slot.date), tz: model.tz)
    model.pipelineBulk("Move to \(day)?", verb: "Move", ids: [id], done: "Moved to \(day)") { b, dry in
      try b.pinConsecutive([id], from: slot.date, dryRun: dry)
    }
    return true
  }
}

/// The screen-owned slot of a Queue card, per view mode. Cards/List: Post today · Pin to date… · ⋯ (icon
/// buttons, tooltipped). Grid: round media buttons on hover. Single: the side panel's labelled stack.
struct QueueClipActions: View {
  @Bindable var model: AppModel
  let video: Video
  let mode: DSViewMode
  let ids: [String]
  let onPin: () -> Void

  var body: some View {
    switch mode {
    case .grid:
      Button(model.stageBackTitle(video), systemImage: "chevron.left") { model.stageBack([video.id]) }
        .disabled(model.stageBlocker(video, .back) != nil)
        .help(model.stageBlocker(video, .back) ?? model.stageBackHelp(video))
      Button("Post today", systemImage: "bolt") { postToday() }.help("Post today")
      Button("Pin to date…", systemImage: "pin") { onPin() }.help("Pin to date…")
    case .single:
      VStack(alignment: .leading, spacing: DS.space.sm) {
        DSButton("Post today", icon: "bolt", variant: .outline, tooltip: "Put it on today; the rest of the plan moves a day") { postToday() }
        DSButton("Pin to date…", icon: "pin", variant: .ghost, tooltip: "Pin it to a day the planner won't change") { onPin() }
        StageControl(model: model, video: video, size: .md)
        HStack(spacing: 4) {
          DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .ghost) { model.openEditor(video.id, in: ids) }
          PipelineMoreMenu { QueueClipMenu(model: model, video: video, ids: ids, onPin: { _ in onPin() }) }
        }
      }
    case .list:
      StageControl(model: model, video: video, compact: true)
      DSIconButton("bolt", tooltip: "Post today", size: .sm) { postToday() }
      DSIconButton("pin", tooltip: "Pin to date…", size: .sm) { onPin() }
      PipelineMoreMenu { QueueClipMenu(model: model, video: video, ids: ids, onPin: { _ in onPin() }) }
    default:
      StageControl(model: model, video: video)
      DSIconButton("bolt", tooltip: "Post today", size: .sm) { postToday() }
      DSIconButton("pin", tooltip: "Pin to date…", size: .sm) { onPin() }
      PipelineMoreMenu { QueueClipMenu(model: model, video: video, ids: ids, onPin: { _ in onPin() }) }
    }
  }

  private func postToday() {
    let id = video.id
    model.pipelineBulk("Post today?", verb: "Post today", ids: [id], done: "Posting today") { b, dry in try b.postToday([id], dryRun: dry) }
  }
}

/// ⋯ / right-click menu of a Queue clip: Post today · Pin to date… · Skip next · Remove from queue · stage moves ·
/// Open editor · Exclude. Acts on the
/// selection (where it makes sense) when the clip is part of it.
struct QueueClipMenu: View {
  @Bindable var model: AppModel
  let video: Video
  let ids: [String]
  let onPin: ([String]) -> Void

  var body: some View {
    let sel = model.selectedIds(.queue)
    let targets = sel.count > 1 && sel.contains(video.id) ? sel : [video.id]
    let n = AppModel.pipelineClips(targets.count)
    Button(targets.count == 1 ? "Post today" : "Post \(n) today", systemImage: "bolt") {
      model.pipelineBulk("Post \(n) today?", verb: "Post today", ids: targets, done: targets.count == 1 ? "Posting today" : nil) { b, dry in
        try b.postToday(targets, dryRun: dry)
      }
    }
    Button(targets.count == 1 ? "Pin to date…" : "Pin \(n) to days…", systemImage: "pin") { onPin(targets) }
    if targets.count == 1 {
      Button("Skip next", systemImage: "forward.end") { model.skipNext(video.id) }
        .help(model.nextSlotByVideo[video.id] == nil ? "Moves it one place later in the backlog" : "Swaps it with the next open slot")
    }
    Divider()
    Button(targets.count == 1 ? "Remove from queue" : "Remove \(n) from queue", systemImage: "arrow.uturn.backward") {
      model.removeFromQueue(targets)
    }
    .disabled(model.removeFromQueueBlocker(targets) != nil)
    .help(model.removeFromQueueBlocker(targets) ?? AppModel.removeFromQueueHelp)
    if targets.count == 1 && ClipStage.of(video) != .queue {
      StageMenuItems(model: model, video: video, targets: targets)
    } else {
      // Back for a Queue clip IS "Remove from queue" (above); only forward is left.
      let fwd = targets.count == 1 ? model.stageBlocker(video, .forward) : nil
      Button(targets.count == 1 ? model.stageForwardTitle(video) : "Forward a stage (\(targets.count))", systemImage: "arrow.forward") {
        model.stageForward(targets)
      }
      .disabled(fwd != nil)
      .help(fwd ?? (targets.count == 1 ? model.stageForwardHelp(video) : "Each clip moves forward one stage"))
    }
    Divider()
    Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id, in: ids) }
    Divider()
    Button(targets.count == 1 ? "Exclude" : "Exclude \(n)", systemImage: "minus.circle") {
      model.pipelineBulk("Exclude \(n)?", verb: "Exclude", ids: targets,
                         changes: [.init(field: "Excluded", value: "Yes · they leave the queue and never post")], done: "Excluded") { b, dry in
        try b.setExcluded(targets, true, dryRun: dry)
      }
    }
  }
}

/// Snapshot-only: draws one clip's hover actions without a pointer (nil in the app).
@MainActor
enum SnapshotHover {
  static var id: String?
}
