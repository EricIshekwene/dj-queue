import DJQCore
import SwiftUI

/// Edit (DESIGN-v2 §6.2) — FOUNDATION STUB, rewritten by the pipeline leaf. Working minimal version: cards of
/// `model.editList` with their missing chips + title suggestions, Open editor, the bulk bar and "Make ready with
/// defaults" through the shared confirmation sheet, empty state.
struct EditView: View {
  @Bindable var model: AppModel

  var body: some View {
    let list = model.editList
    let mode = model.viewMode(.edit)
    let sel = model.selectedIds(.edit)
    ScreenScaffold(model: model, screen: .edit, subtitle: list.isEmpty ? nil : "\(list.count) need work",
                   readingColumn: mode == .wide) {
      DSViewModeSwitcher(mode: model.viewModeBinding(.edit), modes: [.wide, .grid, .list])
      DSButton("Make ready with defaults", variant: .primary,
               disabledReason: list.isEmpty ? "Nothing to edit" : nil) { makeReady(sel.isEmpty ? list.map(\.id) : sel) }
    } content: {
      if !model.loaded {
        Color.clear
      } else if list.isEmpty {
        DSEmptyState(icon: "pencil", title: "Nothing to edit", message: "Scored clips that still need a crop, text or caption show here.",
                     actionTitle: "Open Queue") { model.screen = .queue }
      } else {
        ClipCollection(model: model, screen: .edit, videos: list, mode: mode,
                       onOpen: { v in model.openEditor(v.id, in: list.map(\.id)) }) { v in
          DSButton("Open editor", variant: .outline, size: .sm) { model.openEditor(v.id, in: list.map(\.id)) }
        } contextMenu: { v in
          VideoContextMenu(model: model, video: v, ids: model.selectedIds(.edit))
        }
      }
    }
    .dsBulkBar(isPresented: !sel.isEmpty) {
      ScreenBulkBar(model: model, screen: .edit) {
        Button("Accept top title", systemImage: "text.badge.checkmark") { acceptTop(sel) }
        Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(sel[0], in: sel) }
      } more: {
        Button("Copy agent prompt for \(sel.count) clips") { model.copyAgentPrompt(sel) }
      }
    }
  }

  private func makeReady(_ ids: [String]) {
    let bulk = model.bulk
    model.requestBulk(BulkRequest(title: "Make \(ids.count) clip\(ids.count == 1 ? "" : "s") ready?", verb: "Make ready", ids: ids,
                                  changes: [.init(field: "Crop", value: "Default anchor, confirmed"),
                                            .init(field: "Text, caption, cover", value: "Defaults")]) { dry in
      try bulk.makeReadyWithDefaults(ids, dryRun: dry)
    })
  }

  private func acceptTop(_ ids: [String]) {
    let bulk = model.bulk
    model.requestBulk(BulkRequest(title: "Accept the top title for \(ids.count) clips?", verb: "Accept titles", ids: ids,
                                  changes: [.init(field: "Title", value: "Top suggestion")]) { dry in
      try bulk.acceptTopTitleSuggestion(ids, dryRun: dry)
    })
  }
}
