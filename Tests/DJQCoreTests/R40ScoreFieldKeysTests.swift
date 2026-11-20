import Foundation
import Testing
@testable import DJQCore

/// Round 40: the Score box is a real text field. Only ↩ / ⇥ / ⇧⇥ / ⌘⌫ / esc (with text) are the screen's; ← / → are
/// the screen's only while the box is empty. Everything else (⌫, ⌦, select all, word moves…) stays the field's.
@Suite struct R40ScoreFieldKeysTests {
  typealias K = ScoreFieldKeys

  @Test func screenKeys() {
    #expect(K.command(for: "insertNewline:", text: "72") == .save)
    #expect(K.command(for: "insertTab:", text: "") == .skip(1))
    #expect(K.command(for: "insertBacktab:", text: "5") == .skip(-1))
    #expect(K.command(for: "deleteToBeginningOfLine:", text: "72") == .exclude)
    #expect(K.command(for: "cancelOperation:", text: "72") == .clear)
    #expect(K.command(for: "cancelOperation:", text: "") == nil)
  }

  @Test func arrowsMoveTheCaretWithTextAndChangeClipsWhenEmpty() {
    #expect(K.command(for: "moveLeft:", text: "") == .move(-1))
    #expect(K.command(for: "moveRight:", text: "") == .move(1))
    #expect(K.command(for: "moveLeft:", text: "8") == nil)
    #expect(K.command(for: "moveRight:", text: "80") == nil)
  }

  @Test func editingStaysTheFields() {
    for sel in ["deleteBackward:", "deleteForward:", "selectAll:", "moveWordLeft:", "moveToBeginningOfLine:",
                "moveLeftAndModifySelection:", "deleteWordBackward:"] {
      #expect(K.command(for: sel, text: "72") == nil, "\(sel)")
    }
  }

  @Test func acceptsOnlyZeroToHundred() {
    for ok in ["", "0", "7", "72", "100", "07"] { #expect(K.accepts(ok), "\(ok)") }
    for bad in ["101", "1000", "x", "7a", "-1", " 7", "4.5", "٣"] { #expect(!K.accepts(bad), "\(bad)") }
  }
}
