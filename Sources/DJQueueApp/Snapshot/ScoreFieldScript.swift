import AppKit
import DJQCore
import SwiftUI

/// `DJQ_SCORE_FIELD_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 40). Eric: the score box on Score → Single wouldn't let
/// him backspace or clear what he'd typed. It's a real text field now; this drives it in the real main window on the
/// throwaway sample through key events handed to the window (the window sits off every display and never becomes key):
/// typing, ⌫ / ⌦, select all + ⌫, ← / → moving the caret with a number in the box and changing clips when it's empty,
/// a letter / 101 turned away, esc clearing, ⇥ skipping and ↩ saving. Then Library's type-to-score takes a waiting digit
/// back with ⌫. Letters go in the way a key press ends (`insertText`: a background app has no input method). Select all
/// is the Edit menu's `selectAll:` sent to the field (a menu can't open in a check), labelled a stand-in.
/// Saves `score-field-NN-<step>-<look>.png` and `score-field-checks-<look>.txt`.
@MainActor
enum ScoreFieldScript {
  static func run(model: AppModel, store: Store, out: URL) async -> Int32 {
    let look = ProcessInfo.processInfo.environment["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    var failures = 0
    var log: [String] = []
    func note(_ s: String) { print("score-field: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }
    defer { try? log.joined(separator: "\n").write(to: out.appendingPathComponent("score-field-checks-\(look).txt"), atomically: true, encoding: .utf8) }

    SnapshotContext.resetUI(model)
    PipelineUIState.shared.typedScores = [:]
    model.setViewMode(.single, for: .score)
    model.screen = .score
    // This run's throwaway copy: when everything is scored already, take the score off a few short clips to have some.
    if model.scoreList.count < 4 {
      for v in model.videos.filter({ $0.type == .short && !$0.excluded && !$0.missing && !$0.needsNoScore }).prefix(4) {
        try? store.setScore(v.id, nil)
      }
      model.refreshNow()
    }
    let toScore = model.scoreList.count
    note("clips to score: \(toScore)")
    guard toScore >= 3 else { note("FAIL the sample needs 3 clips to score"); return 1 }

    let window = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
    window.setContentSize(NSSize(width: Shot.standard.width, height: Shot.standard.height))
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    guard let host = window.contentView else { return 1 }
    await wait(2000)

    var step = 0
    func shot(_ name: String) async {
      await wait(500)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "score-field-%02d-%@-%@.png", step, name, look))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func find<T: NSView>(_ v: NSView, _ type: T.Type) -> T? {
      if let t = v as? T { return t }
      for c in v.subviews { if let hit = find(c, type) { return hit } }
      return nil
    }
    func anchors(_ v: NSView, _ prefix: String) -> [String] {
      var out: [String] = []
      if let id = v.identifier?.rawValue, id.hasPrefix(prefix) { out.append(String(id.dropFirst(prefix.count))) }
      for c in v.subviews { out += anchors(c, prefix) }
      return out
    }
    /// The clip on screen (its id from the control pill's anchor).
    func clip() -> String? { anchors(host, ScriptAnchor.prefix + "Score clip ").first }
    func field() -> ScoreTextField.Field? { find(host, ScoreTextField.Field.self) }
    func editor() -> NSTextView? {
      guard let f = field(), let tv = window.firstResponder as? NSTextView, tv.delegate === f else { return nil }
      return tv
    }
    func text() -> String { editor()?.string ?? field()?.stringValue ?? "?" }
    func caret() -> Int { editor()?.selectedRange().location ?? -1 }
    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code) else { return }
      // Straight to the window, as the system would hand it (a key equivalent first, then the first responder).
      if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
      await wait()
    }
    func type(_ s: String) async {
      for ch in s {
        if let tv = editor() { tv.insertText(String(ch), replacementRange: tv.selectedRange()) }
        await wait(60)
      }
      await wait(200)
    }
    let backspace = ("\u{7F}", UInt16(51)), forwardDelete = ("\u{F728}", UInt16(117))
    let left = ("\u{F702}", UInt16(123)), right = ("\u{F703}", UInt16(124))

    // MARK: the score box

    let first = clip()
    note("first clip \(first ?? "none")")
    check("the score box is a real text field with the cursor in it on arrival", editor() != nil)
    await type("85")
    check("typing 8 5 shows 85", text() == "85")
    await shot("typed-85")
    await key(backspace.0, code: backspace.1)
    check("⌫ deletes the last digit (85 → 8)", text() == "8")
    await shot("backspace")
    await type("0")
    await key(left.0, code: left.1)
    check("← with a number in the box moves the caret (2 → 1), not the clip", caret() == 1 && text() == "80" && clip() == first)
    await key(forwardDelete.0, code: forwardDelete.1)
    check("⌦ deletes the digit after the caret (80 → 8)", text() == "8")
    await key(right.0, code: right.1)
    check("→ with a number in the box moves the caret to the end, not the clip", caret() == 1 && clip() == first)
    await type("x")
    check("a letter is turned away (8 stays 8)", text() == "8")
    await type("01")
    check("a number over 100 is turned away (80 stays, 801 never)", text() == "80")
    note("stand-in: Edit ▸ Select All (⌘A) sends selectAll: to the field")
    editor()?.selectAll(nil)
    await wait()
    check("select all selects the whole number", editor()?.selectedRange() == NSRange(location: 0, length: 2))
    await shot("select-all")
    await key(backspace.0, code: backspace.1)
    check("select all then ⌫ empties the box", text() == "")
    await shot("cleared")
    await type("100")
    check("100 fits", text() == "100")
    await key("\u{1B}", code: 53)
    check("esc empties the box and stays on the clip", text() == "" && clip() == first)

    // Empty box: the arrows change clips again; the cursor follows to the next clip.
    await key(right.0, code: right.1)
    await wait(400)
    let second = clip()
    check("→ with an empty box shows the next clip", second != nil && second != first)
    check("the cursor is in the box on the next clip", editor() != nil)
    await key(left.0, code: left.1)
    await wait(400)
    check("← with an empty box goes back", clip() == first)
    await key("\t", code: 48)
    await wait(400)
    check("⇥ skips to the next clip", clip() == second)
    await type("7")
    await key("\u{19}", code: 48, flags: .shift)  // AppKit spells ⇧⇥ as U+0019
    await wait(400)
    check("⇧⇥ goes back a clip and the typed 7 doesn't follow", clip() == first && text() == "")

    // ↩ saves the typed score (after a ⌫ fix) and moves on.
    await type("64")
    await key(backspace.0, code: backspace.1)
    await type("2")
    await shot("typed-62")
    await key("\r", code: 36)
    await wait(1200)
    model.refreshNow()
    await wait(600)
    let saved = first.flatMap(model.video)?.score
    check("↩ saves the corrected score (64 → ⌫ → 62)", saved == 62)
    check("↩ moves on to another clip with an empty box", clip() != first && text() == "")
    await shot("saved")

    // ⌘⌫ still excludes (the field's deleteToBeginningOfLine).
    let toExclude = clip()
    await type("5")
    await key(backspace.0, code: backspace.1, flags: .command)
    await wait(1200)
    model.refreshNow()
    await wait(400)
    check("⌘⌫ excludes the clip", toExclude.flatMap(model.video)?.excluded == true)

    // MARK: Library type-to-score

    guard let short = model.videos.first(where: { $0.type == .short && !$0.excluded && !$0.missing }) else {
      note("FAIL no short clip for the Library check")
      return 1
    }
    let wasScore = short.score
    model.frozen = false  // Library takes its keys on appear only outside a still capture.
    model.screen = .library
    await wait(1200)
    model.setSelection([short.id], screen: .library)
    await wait(400)
    await key("4", code: 21)
    await key(backspace.0, code: backspace.1)
    await wait(1200)
    model.refreshNow()
    check("Library: 4 then ⌫ leaves the score as it was", model.video(short.id)?.score == wasScore)
    await key("4", code: 21)
    await key(backspace.0, code: backspace.1)
    await key("3", code: 20)
    await wait(1200)
    model.refreshNow()
    check("Library: 4 ⌫ 3 scores 3", model.video(short.id)?.score == 3)
    model.frozen = true

    note("\(failures == 0 ? "all passed" : "\(failures) failed")")
    return failures == 0 ? 0 : 1
  }
}
