import AppKit
import DJQCore

/// The editor's ⌘Z / ⇧⌘Z (round 3, F8). While a text field is being edited they go to the field's own undo (typing);
/// otherwise they step through the editor's change history (EditorModel.undo/redo), which also saves. While an overlay
/// covers the editor they're left alone: the app-level ⌘Z (`ShortcutButtons`) takes them, which is otherwise off.
///
/// v0.8.1: read from the key event in `EditorView`'s key monitor. Two hidden SwiftUI buttons sharing "z" fired Redo for
/// a plain ⌘Z (which one won changed from launch to launch), so nothing got undone. The decision is
/// `EditorLogic.undoKey`, covered by `swift test`.
enum EditorUndoKeys {
  /// True when `e` was ⌘Z or ⇧⌘Z and has been handled.
  @MainActor static func handle(_ e: NSEvent, model: EditorModel) -> Bool {
    let f = e.modifierFlags
    switch EditorLogic.undoKey(characters: e.charactersIgnoringModifiers, command: f.contains(.command), shift: f.contains(.shift),
                               option: f.contains(.option), control: f.contains(.control),
                               textEditing: e.window?.firstResponder is NSTextView, covered: model.isCovered?() == true) {
    case .ignore: return false
    case .fieldUndo: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    case .fieldRedo: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    case .undo: model.undo()
    case .redo: model.redo()
    }
    return true
  }
}
