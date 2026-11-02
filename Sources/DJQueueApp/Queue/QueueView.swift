import DJQCore
import SwiftUI

/// Queue (DESIGN-v2 §6.3) — FOUNDATION STUB, rewritten by the pipeline leaf. Working minimal version: planned
/// clips in date order then the ready backlog (`model.queueList`), position numbers, next date, platform states,
/// runway chip, Post today, a bulk bar, empty state.
struct QueueView: View {
  @Bindable var model: AppModel

  var body: some View {
    let list = model.queueList
    let mode = model.viewMode(.queue)
    let sel = model.selectedIds(.queue)
    let positions = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0 + 1) })
    ScreenScaffold(model: model, screen: .queue, subtitle: subtitle(list), readingColumn: mode == .wide) {
      RunwayChip(model: model)
      DSViewModeSwitcher(mode: model.viewModeBinding(.queue), modes: [.wide, .grid, .list])
    } content: {
      if !model.loaded {
        Color.clear
      } else if list.isEmpty {
        DSEmptyState(icon: "list.bullet", title: "Nothing ready yet", message: "Clips appear here once they're scored and edited.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else {
        ClipCollection(model: model, screen: .queue, videos: list, mode: mode, clip: { v in
          var c = model.dsClip(v, for: .queue)
          c.position = positions[v.id]
          return c
        }, onOpen: { v in model.openEditor(v.id, in: list.map(\.id)) }) { v in
          DSIconButton("bolt", tooltip: "Post today", size: .sm) { model.postToday(v.id) }
        } contextMenu: { v in
          VideoContextMenu(model: model, video: v, ids: model.selectedIds(.queue))
        }
      }
    }
    .dsBulkBar(isPresented: !sel.isEmpty) {
      ScreenBulkBar(model: model, screen: .queue) {
        Button("Post today", systemImage: "bolt") { run(sel, "Post", "Post \(sel.count) clips today?") { b, d in try b.postToday(sel, dryRun: d) } }
        Button("Exclude", systemImage: "minus.circle") {
          run(sel, "Exclude", "Exclude \(sel.count) clips?") { b, d in try b.setExcluded(sel, true, dryRun: d) }
        }
      }
    }
  }

  private func subtitle(_ list: [Video]) -> String? {
    guard !list.isEmpty else { return nil }
    let next = model.upcomingSlots.first.flatMap { model.video($0.videoId) }.map { model.dateText($0) }
    return "\(list.count) ready" + (next.map { " · next \($0)" } ?? "")
  }

  private func run(_ ids: [String], _ verb: String, _ title: String,
                   _ body: @escaping @Sendable (BulkActions, Bool) throws -> BulkResult) {
    let b = model.bulk
    model.requestBulk(BulkRequest(title: title, verb: verb, ids: ids) { dry in try body(b, dry) })
  }
}
