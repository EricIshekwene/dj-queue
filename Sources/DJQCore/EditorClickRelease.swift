import Foundation

/// Round 28: clicking an empty spot in the editor lets go of whatever was holding the keyboard or the last click, so
/// the editor never feels stuck. Pure, so the rules are unit-tested; `EditorClickAway` (app) asks this on every press.
///
/// What held on before: a clicked trim handle kept ← / → (they moved the trim, not the playhead) until Esc or a click on
/// the filmstrip; a text field or list kept the keyboard (Space typed, ↑ / ↓ moved rows) after a click on the inspector;
/// the selected text kept its outline on the canvas and its bar on the timeline whatever was clicked.
///
/// Everything that can be selected selects itself again on its own press (a trim handle, a text on the canvas, a text
/// bar, a text number in the inspector): the release runs first, so a click on another thing moves the selection there.
public enum EditorClickRelease {
  public enum Zone: Sendable { case header, canvas, timeline, inspector }

  public struct Release: Equatable, Sendable {
    /// A text field, text view or list gives up the keyboard (it commits as on any blur).
    public var leaveField: Bool
    /// A selected trim handle lets go: ← / → move the playhead again.
    public var trimEdge: Bool
    /// The selected text loses its outline on the canvas and its highlighted bar (the Text section still edits it).
    public var textSelection: Bool

    public init(leaveField: Bool, trimEdge: Bool, textSelection: Bool) {
      self.leaveField = leaveField
      self.trimEdge = trimEdge
      self.textSelection = textSelection
    }
  }

  /// - `onInput`: the press lands on a text field, a text view or a list (it keeps or takes the keyboard).
  /// - `onEmpty`: the press lands on nothing that takes clicks. Only the inspector tells, and there only its background
  ///   lets go of the text and the keyboard: its controls work on them (a style tile edits the selected text; New group
  ///   remembers the caption being typed in, so Cancel goes straight back to it).
  public static func release(zone: Zone, onInput: Bool, onEmpty: Bool = false) -> Release {
    let away = zone != .inspector || onEmpty
    return Release(leaveField: away && !onInput, trimEdge: true, textSelection: away)
  }
}
