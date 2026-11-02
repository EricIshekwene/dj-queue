import DJQCore
import SwiftUI

/// Score (DESIGN-v2 §6.1) — FOUNDATION STUB, rewritten by the pipeline leaf. Working minimal version: single /
/// grid view of `model.scoreList`, a score field + Save & next in the single view's side panel, empty state.
struct ScoreView: View {
  @Bindable var model: AppModel
  @State private var index = 0

  var body: some View {
    let list = model.scoreList
    let mode = model.viewMode(.score)
    ScreenScaffold(model: model, screen: .score, subtitle: list.isEmpty ? nil : "\(list.count) to score") {
      DSViewModeSwitcher(mode: model.viewModeBinding(.score), modes: [.single, .grid])
    } content: {
      if !model.loaded {
        Color.clear
      } else if list.isEmpty {
        DSEmptyState(icon: "checkmark.circle", title: "Everything is scored", message: "New clips appear here after intake.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else {
        ClipCollection(model: model, screen: .score, videos: list, mode: mode, focusIndex: $index,
                       onOpen: { v in model.openEditor(v.id, in: list.map(\.id)) }) { v in
          if mode == .single { ScoreEntry(model: model, video: v) }
        } contextMenu: { v in
          VideoContextMenu(model: model, video: v, ids: model.selectedIds(.score))
        }
      }
    }
  }
}

/// Score field + Save & next (Enter). Saving moves the clip out of the list, so the next one slides in.
private struct ScoreEntry: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var text = ""

  private var value: Int? { Int(text).flatMap { (0...100).contains($0) ? $0 : nil } }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      DSTextField("Score", placeholder: "0–100", text: $text, hint: "Type 0–100 · ↩ save & next", size: .lg, onSubmit: save)
      DSButton("Save & next", icon: "return", variant: .primary, fullWidth: true,
               disabledReason: value == nil ? "Type a score from 0 to 100" : nil, action: save)
    }
    .id(video.id)
  }

  private func save() {
    guard let n = value else { return }
    model.setScore([video.id], n)
    text = ""
  }
}
