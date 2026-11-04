import AppKit

/// The editor's ⌘Z / ⇧⌘Z (round 3, F8). While a text field is being edited they go to the field's own undo (typing);
/// otherwise they step through the editor's change history (EditorModel.undo/redo), which also saves. The app-level
/// ⌘Z (UndoHistory) is off while the editor is open.
///
/// v0.8.1: read from the key event in `EditorView`'s key monitor. Two hidden SwiftUI buttons sharing "z" fired Redo for
/// a plain ⌘Z on some launches (which one won changed from launch to launch), so nothing got undone.
enum EditorUndoKeys {
  /// True when `e` was ⌘Z or ⇧⌘Z and has been handled.
  @MainActor static func handle(_ e: NSEvent, model: EditorModel) -> Bool {
    guard e.charactersIgnoringModifiers?.lowercased() == "z",
          e.modifierFlags.intersection([.command, .option, .control]) == .command else { return false }
    let redo = e.modifierFlags.contains(.shift)
    if e.window?.firstResponder is NSTextView {
      NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
    } else if redo {
      model.redo()
    } else {
      model.undo()
    }
    return true
  }
}
