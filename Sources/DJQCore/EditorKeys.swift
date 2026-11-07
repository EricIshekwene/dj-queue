import Foundation

/// The editor's bare-key shortcuts (round 19), pure so the rules are unit-tested. The app's key monitor asks this
/// first and only acts on a non-nil answer; anything else goes on to the focused control.
///
/// Space play/pause · ← / → jump by the arrow step (⇧ one frame) · ↑ / ↓ previous / next clip · I / O trim at the
/// playhead · Esc leaves a text field (so Space plays again).
public enum EditorKeyAction: Equatable, Sendable {
  case togglePlay
  case seek(direction: Int, fine: Bool)
  case clip(Int)
  case trimIn, trimOut
  case leaveTextField
}

public enum EditorKeys {
  /// Where the keyboard is: a text field or text view takes typing; a list (table/outline) takes ↑ / ↓ for its rows.
  /// Esc in a text field: the app lets a form's Cancel take it first, then leaves the field.
  public enum Focus: Sendable { case none, text, list }

  public static let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
  public static let escape: UInt16 = 53

  /// - `covered`: an overlay (Settings, a confirm) is over the editor: its keys are its own.
  /// - `hasClip`: the clip is loaded (playback keys do nothing without it; ↑ / ↓ still move between clips).
  /// - `commandLike`: ⌘, ⌥ or ⌃ is held (those are menu shortcuts, never ours here).
  public static func action(keyCode: UInt16, characters: String?, shift: Bool, commandLike: Bool, focus: Focus,
                            covered: Bool, hasClip: Bool) -> EditorKeyAction? {
    guard !covered, !commandLike else { return nil }
    if focus == .text { return keyCode == escape ? .leaveTextField : nil }
    switch keyCode {
    case up: return focus == .list ? nil : .clip(-1)
    case down: return focus == .list ? nil : .clip(1)
    default: break
    }
    guard hasClip else { return nil }
    switch keyCode {
    case space: return .togglePlay
    case left: return .seek(direction: -1, fine: shift)
    case right: return .seek(direction: 1, fine: shift)
    default: break
    }
    switch characters?.lowercased() {
    case "i": return .trimIn
    case "o": return .trimOut
    default: return nil
    }
  }
}
