import DJQCore
import SwiftUI

/// The bulk bar for a screen's selection (DESIGN-v2 §5): ✕ clear · "4 selected" · Select all (until everything
/// shown is selected) · divider · ≤ 4 labelled actions · More ▾ (`more`, native menu items) · `primary`.
///
/// ```swift
/// .dsBulkBar(isPresented: !model.selected(.edit).isEmpty) {
///   ScreenBulkBar(model: model, screen: .edit) {
///     Button("Accept top title", systemImage: "text.badge.checkmark") { … }
///   } more: {
///     Button("Copy agent prompt") { model.copyAgentPrompt(model.selectedIds(.edit)) }
///   } primary: {
///     DSButton("Send to Queue with defaults", variant: .primary) { … }
///   }
/// }
/// ```
/// Actions are plain `Button`s (the bar styles them as labelled ghost capsules). Anything touching > 1 clip goes
/// through `model.requestBulk` (confirmation + undo toast).
struct ScreenBulkBar<Actions: View, More: View, Primary: View>: View {
  @Bindable var model: AppModel
  let screen: Screen
  @ViewBuilder var actions: Actions
  @ViewBuilder var more: More
  @ViewBuilder var primary: Primary

  init(model: AppModel, screen: Screen, @ViewBuilder actions: () -> Actions, @ViewBuilder more: () -> More = { EmptyView() },
       @ViewBuilder primary: () -> Primary = { EmptyView() }) {
    self.model = model
    self.screen = screen
    self.actions = actions()
    self.more = more()
    self.primary = primary()
  }

  var body: some View {
    let count = model.selected(screen).count
    let all = model.visibleIds[screen]?.count ?? 0
    DSBulkBar(count: count, onSelectAll: count < all ? { model.selectAll(screen) } : nil,
              onClear: { model.clearSelection(screen) }) {
      actions
    } trailing: {
      if More.self != EmptyView.self {
        Menu {
          more
        } label: {
          HStack(spacing: 6) {
            Text("More")
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
          }
        }
        .menuStyle(.button)
        .buttonStyle(DSBulkActionStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .dsTooltip("More actions for the selected clips")
        .dsTooltip("More actions for the selected clips")
      }
      if Primary.self != EmptyView.self {
        primary.padding(.leading, 2)
      }
    }
  }
}
