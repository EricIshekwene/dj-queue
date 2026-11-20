import Foundation

/// The Score screen's 0–100 box (round 40). It's a real text field: ⌫ / ⌦, ⌘A, the caret, ⌥/⌘ arrows and ⌘Z behave as in
/// any Mac field. The screen keeps a few keys the field would otherwise use; this says which, by the AppKit command a key
/// press turns into (`doCommandBy:`), so a keyboard remap still lands on the same action.
public enum ScoreFieldKeys {
  public enum Command: Equatable, Sendable {
    /// ↩: save the score and show the next clip.
    case save
    /// ⇥ / ⇧⇥: leave this clip unscored, show the next / previous (wrapping).
    case skip(Int)
    /// ← / → with an empty box: previous / next clip.
    case move(Int)
    /// ⌘⌫: exclude the clip.
    case exclude
    /// esc: empty the box (an empty one stays empty, never the field's own completion beep).
    case clear
    /// Keys the field would answer with a completion list or a beep (⌥esc / F5): nothing.
    case ignore
  }

  /// What the screen does for this command, or nil to let the field handle it (caret moves, deletes, select all…).
  /// ← / → only change clips while the box is empty: with a number in it they move the caret, as in any field.
  public static func command(for selector: String, text: String) -> Command? {
    switch selector {
    case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": return .save
    case "insertTab:", "insertTabIgnoringFieldEditor:": return .skip(1)
    case "insertBacktab:": return .skip(-1)
    case "moveLeft:": return text.isEmpty ? .move(-1) : nil
    case "moveRight:": return text.isEmpty ? .move(1) : nil
    case "deleteToBeginningOfLine:": return .exclude
    case "cancelOperation:": return .clear
    case "complete:": return .ignore
    default: return nil
    }
  }

  /// What a typed or pasted `text` becomes in the box: its digits ("72\n" → "72", "7a" → "7"), when those fit.
  public static func cleaned(_ text: String) -> String? {
    let digits = String(text.filter { $0.isASCII && $0.isNumber })
    return accepts(digits) ? digits : nil
  }

  /// Whether the box may hold `text`: empty, or up to three digits that make a number from 0 to 100. A typed letter
  /// or a paste that would break that is turned away and the box keeps what it had.
  public static func accepts(_ text: String) -> Bool {
    if text.isEmpty { return true }
    guard text.count <= 3, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text) else { return false }
    return n <= 100
  }
}
