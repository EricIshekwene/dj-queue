import DJQCore
import Foundation

/// Round 28: what a click on an empty spot lets go of (`EditorClickRelease`). The keyboard side (a text field or list
/// giving up the cursor) is the window's: `EditorFocus.leave`.
extension EditorModel {
  /// The selected text as the canvas and timeline show it: nil after a click on an empty spot.
  var shownText: String? { textSelectionShown ? selectedText : nil }

  func apply(_ r: EditorClickRelease.Release) {
    if r.trimEdge { selectTrimEdge(nil) }
    if r.textSelection, textSelectionShown { textSelectionShown = false }
  }
}
