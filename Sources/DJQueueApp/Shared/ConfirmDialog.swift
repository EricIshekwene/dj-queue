import DJQCore
import SwiftUI

/// "Are you sure?" for destructive or plan-wide one-click actions (round 3, F8): `model.confirm(ConfirmRequest(…))`.
/// Cancel is the default (esc); the primary runs `action`. Reversible actions still get "· Undo" afterwards.
struct ConfirmRequest: Identifiable {
  let id = UUID()
  var title: String
  var message: String
  var verb: String
  var icon: String = "exclamationmark.triangle"
  /// Red primary (deletes, wipes); otherwise the near-black primary.
  var destructive = false
  var action: () -> Void
}

struct ConfirmDialogHost: View {
  @Bindable var model: AppModel

  var body: some View {
    if let r = model.pendingConfirm {
      ModalHost(onDismiss: { model.pendingConfirm = nil }) {
        DSDialog(r.title, description: r.message, icon: r.icon, iconTone: r.destructive ? .danger : .neutral,
                 onClose: { model.pendingConfirm = nil }) {
          EmptyView()
        } footer: {
          DSButton("Cancel", variant: .ghost, tooltip: "Close without changing anything", shortcut: "esc") { model.pendingConfirm = nil }
            .keyboardShortcut(.cancelAction)
          DSButton(r.verb, variant: r.destructive ? .destructiveSolid : .primary, shortcut: "↩") {
            model.pendingConfirm = nil
            r.action()
          }
          .keyboardShortcut(.defaultAction)
        }
        // The dialog's own card (like the Settings modal's confirm and the bulk sheet); without it the dialog drew
        // straight onto the scrim.
        .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
      }
    }
  }
}
