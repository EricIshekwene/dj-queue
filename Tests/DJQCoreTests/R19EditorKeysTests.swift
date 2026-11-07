import Foundation
import Testing
@testable import DJQCore

/// Round 19: Space always plays outside a text field, Esc leaves one, ← / → jump by Eric's arrow step (⇧ a frame),
/// ↑ / ↓ move between clips except in lists and text, nothing reaches the editor under an overlay.
@Suite struct R19EditorKeysTests {
  func act(_ code: UInt16, _ chars: String? = nil, shift: Bool = false, cmd: Bool = false,
           focus: EditorKeys.Focus = .none, covered: Bool = false, clip: Bool = true) -> EditorKeyAction? {
    EditorKeys.action(keyCode: code, characters: chars, shift: shift, commandLike: cmd, focus: focus, covered: covered,
                      hasClip: clip)
  }

  @Test func spacePlaysUnlessTyping() {
    #expect(act(EditorKeys.space, " ") == .togglePlay)
    #expect(act(EditorKeys.space, " ", focus: .list) == .togglePlay)
    #expect(act(EditorKeys.space, " ", focus: .text) == nil)
    #expect(act(EditorKeys.space, " ", covered: true) == nil)
    #expect(act(EditorKeys.space, " ", clip: false) == nil)
  }

  @Test func escapeLeavesATextFieldOnly() {
    #expect(act(EditorKeys.escape, focus: .text) == .leaveTextField)
    #expect(act(EditorKeys.escape) == nil)
    #expect(act(EditorKeys.escape, focus: .text, covered: true) == nil)
  }

  @Test func arrowsSeekAndShiftIsAFrame() {
    #expect(act(EditorKeys.left) == .seek(direction: -1, fine: false))
    #expect(act(EditorKeys.right, shift: true) == .seek(direction: 1, fine: true))
    #expect(act(EditorKeys.right, focus: .text) == nil)
    #expect(act(EditorKeys.right, cmd: true) == nil)
  }

  @Test func upDownMoveBetweenClipsButNotInListsOrText() {
    #expect(act(EditorKeys.up) == .clip(-1))
    #expect(act(EditorKeys.down) == .clip(1))
    #expect(act(EditorKeys.down, clip: false) == .clip(1))
    #expect(act(EditorKeys.down, focus: .list) == nil)
    #expect(act(EditorKeys.up, focus: .text) == nil)
    #expect(act(EditorKeys.up, covered: true) == nil)
    #expect(act(EditorKeys.up, cmd: true) == nil)
  }

  @Test func trimKeys() {
    #expect(act(31, "i") == .trimIn)
    #expect(act(31, "o") == .trimOut)
    #expect(act(34, "I", shift: true) == .trimIn)
    #expect(act(31, "o", focus: .text) == nil)
  }

  @Test func arrowStepDefaultsToTwoSecondsAndSurvivesOldOrUnknownPrefs() throws {
    #expect(PlaybackPrefs().arrowStep == .twoSeconds)
    let old = try JSONDecoder().decode(PlaybackPrefs.self, from: Data(#"{"autoplay":false}"#.utf8))
    #expect(old.arrowStep == .twoSeconds && !old.autoplay)
    let unknown = try JSONDecoder().decode(PlaybackPrefs.self, from: Data(#"{"arrowStep":"fortnight","focusOnly":true}"#.utf8))
    #expect(unknown.arrowStep == .twoSeconds && unknown.focusOnly)
    var p = PlaybackPrefs(); p.arrowStep = .fiveSeconds
    #expect(try JSONDecoder().decode(PlaybackPrefs.self, from: JSONEncoder().encode(p)).arrowStep == .fiveSeconds)
  }

  @Test func seekTargetsClampAndShiftIsOneFrame() {
    #expect(EditorSeek.target(from: 10, step: .twoSeconds, fps: 30, direction: 1, fine: false, duration: 27) == 12)
    #expect(EditorSeek.target(from: 1, step: .fiveSeconds, fps: 30, direction: -1, fine: false, duration: 27) == 0)
    #expect(EditorSeek.target(from: 25, step: .fiveSeconds, fps: 30, direction: 1, fine: false, duration: 27) == 27)
    #expect(abs(EditorSeek.target(from: 10, step: .tenSeconds, fps: 30, direction: 1, fine: true, duration: 27) - (10 + 1.0 / 30)) < 1e-9)
    #expect(abs(ArrowStep.frame.seconds(fps: 25) - 0.04) < 1e-9)
    #expect(EditorSeek.target(from: 40, step: .tenSeconds, fps: 30, direction: 1, fine: false, duration: 0) == 50)
  }
}
