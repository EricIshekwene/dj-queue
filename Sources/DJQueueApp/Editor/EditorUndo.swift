import AppKit
import SwiftUI

/// The editor's ⌘Z / ⇧⌘Z (round 3, F8). While a text field is being edited they go to the field's own undo
/// (typing); otherwise they step through the editor's change history (EditorModel.undo/redo), which also saves.
/// The app-level ⌘Z (UndoHistory) is off while the editor is open.
struct EditorUndoShortcuts: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    ZStack {
      Button("") {
        if ShortcutButtons.textFieldIsEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undo() }
      }
      .keyboardShortcut("z", modifiers: .command)
      Button("") {
        if ShortcutButtons.textFieldIsEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model.redo() }
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
