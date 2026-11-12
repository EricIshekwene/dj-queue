import DJQCore
import XCTest

/// Round 28: a click on an empty spot lets go of what was selected, so the editor never feels stuck.
final class R28ClickAwayTests: XCTestCase {
  typealias R = EditorClickRelease

  func testPictureTimelineAndHeaderLetGoOfEverything() {
    for zone in [R.Zone.canvas, .timeline, .header] {
      XCTAssertEqual(R.release(zone: zone, onInput: false), .init(leaveField: true, trimEdge: true, textSelection: true), "\(zone)")
    }
  }

  func testAFieldOrListKeepsTheKeyboard() {
    for zone in [R.Zone.canvas, .timeline, .header, .inspector] {
      XCTAssertFalse(R.release(zone: zone, onInput: true).leaveField, "\(zone)")
      XCTAssertTrue(R.release(zone: zone, onInput: true).trimEdge, "a click into a field lets go of a trim handle (\(zone))")
    }
  }

  func testInspectorControlsKeepTheTextAndTheCursorButItsBackgroundLetsGo() {
    // A style tile edits the selected text; New group remembers the caption being typed in.
    XCTAssertEqual(R.release(zone: .inspector, onInput: false), .init(leaveField: false, trimEdge: true, textSelection: false))
    XCTAssertEqual(R.release(zone: .inspector, onInput: false, onEmpty: true), .init(leaveField: true, trimEdge: true, textSelection: true))
  }

  /// The trap: a handle stayed selected after a click elsewhere, so ← / → kept moving the trim.
  func testAfterTheReleaseArrowsMoveThePlayheadAgain() {
    let held = EditorKeys.action(keyCode: EditorKeys.right, characters: nil, shift: false, commandLike: false, focus: .none,
                                 covered: false, hasClip: true, trimEdgeSelected: true)
    XCTAssertEqual(held, .nudgeTrim(direction: 1, fine: false))
    let r = R.release(zone: .canvas, onInput: false)
    let after = EditorKeys.action(keyCode: EditorKeys.right, characters: nil, shift: false, commandLike: false, focus: .none,
                                  covered: false, hasClip: true, trimEdgeSelected: !r.trimEdge)
    XCTAssertEqual(after, .seek(direction: 1, fine: false))
  }
}
