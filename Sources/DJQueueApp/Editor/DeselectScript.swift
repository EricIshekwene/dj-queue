import AppKit
import DJQCore
import SwiftUI

/// `DJQ_DESELECT_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 28. Eric: clicking an empty spot
/// anywhere in the editor should let go of what's selected, so the editor never feels stuck. Drives the REAL editor on a
/// throwaway copy of the dev database: a selected text, a selected trim handle and a text field's cursor, each let go by a
/// click on an empty spot of the picture, the timeline, the header and the inspector's background; and the keys work
/// again after it (← / → move the playhead, not the trim; Space plays, not types). Mouse and keys are events sent to this
/// window only (off every display, never focused). Every check reads the model, the player or the window. Saves
/// `deselect-NN-<step>-<appearance>.png` and `checks-<appearance>.txt`.
@MainActor
enum DeselectScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("deselect-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    // A clip with in/out markers whose file is in the dev root, long enough for two texts and a trim.
    let shorts = ids.compactMap { try? store.video(id: $0) }.filter { v in
      ((try? store.fileURL(for: v)) ?? nil).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    let first = shorts.first { $0.markerIn != nil && $0.markerOut != nil && $0.duration > 20 }?.id ?? video

    let app = AppModel(store: store)
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: first)
    model.appHooks = EditorAppHooks(isCovered: { false }, arrowStep: { app.playback.arrowStep },
                                    setArrowStep: { s in app.setPlayback { $0.arrowStep = s } })
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    try? await Task.sleep(for: .seconds(3))
    let pb = model.playback

    // MARK: Helpers

    var step = 0
    func shot(_ name: String) async {
      await wait(300)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
      host.cacheDisplay(in: host.bounds, to: rep)
      let file = out.appendingPathComponent(String(format: "deselect-%02d-%@-%@.png", step, name, appearance))
      try? rep.representation(using: .png, properties: [:])?.write(to: file)
      note("shot \(file.lastPathComponent)")
    }
    func press(_ chars: String, code: UInt16) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code) else { return }
      NSApp.sendEvent(e)
      await wait()
    }
    func click(_ p: NSPoint) async {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          NSApp.sendEvent(e)
        }
        await wait(40)
      }
      await wait()
    }
    /// `ProbeFrames` are SwiftUI global coordinates (top-left); events want window coordinates (bottom-left).
    func probe(_ key: String) -> NSRect? {
      guard let f = ProbeFrames.frames[key] else { note("no frame “\(key)”"); return nil }
      return NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
    }
    func centre(_ key: String) async -> Bool {
      guard let r = probe(key) else { return false }
      await click(NSPoint(x: r.midX, y: r.midY))
      return true
    }
    func zone(_ z: EditorClickRelease.Zone) -> NSRect? {
      guard let v = EditorKeysScript.zones(in: host).first(where: { ($0 as? EditorClickAway.ZoneView)?.zone == z }) else {
        note("no click-away zone \(z)"); return nil
      }
      return v.convert(v.bounds, to: nil)
    }
    /// An empty spot of the picture area: beside the output frame, halfway down.
    func emptyCanvas() -> NSPoint? {
      guard let c = zone(.canvas), let o = probe("canvas-output") else { return nil }
      return NSPoint(x: (c.minX + o.minX) / 2, y: o.midY)
    }
    /// The inspector's background: its left margin, halfway down what's on screen.
    func emptyInspector() -> NSPoint? {
      guard let i = zone(.inspector) else { return nil }
      let p = NSPoint(x: i.minX + 4, y: i.midY)
      let hit = host.superview?.hitTest(p) ?? host.hitTest(p)
      check("the inspector's margin is empty (the press lands on its backdrop)", hit is EditorEmptyBackdrop.Backdrop)
      return p
    }
    func typing() -> Bool { window.firstResponder is NSTextView }
    func titleField() -> NSTextField? {
      EditorKeysScript.fields(in: host).first { $0.placeholderString == "Title" || $0.placeholderString == "Type a title" }
    }
    func handle(_ id: String) -> String? {
      model.textImages.first { $0.layerId == id && $0.shows(at: pb.time) }.map { "canvas-text-\($0.id)" }
    }

    check("player loaded on a clip with in/out markers", pb.player != nil && model.video?.markerIn != nil)
    model.zonePlatforms = []
    model.canvasMode = .zones
    model.fitTimeline()
    // Two texts showing at the playhead, so there is something to select and an outline to see.
    pb.seek(model.trim.start + 1, exact: true)
    await wait()
    if model.selectedLayer.text.isEmpty { model.setText("DROP AT 0:42") }
    if model.texts.count < 2 {
      model.addText()
      model.updateText(model.selectedText, coalesce: false) { $0.text = "SECOND TEXT" }
    }
    let second = model.texts.count > 1 ? model.texts[1].id : model.selectedText
    window.makeFirstResponder(nil)
    pb.seek(model.trim.start + 2, exact: true)
    await wait(800)
    check("two texts on the clip (\(model.texts.count))", model.texts.count >= 2)

    // MARK: 1. A selected text, let go by a click on the picture's empty space

    check("text 2's bar selects it", await centre("text-bar-2") && model.shownText == second)
    await shot("text-selected")
    if let p = emptyCanvas() { await click(p) } else { check("an empty spot on the canvas", false) }
    check("a click beside the picture lets go of the text (no outline, no highlighted bar)", model.shownText == nil)
    check("…while the Text section still edits it", model.selectedText == second)
    await shot("canvas-click-deselects")
    if let h = handle(second) {
      check("clicking the text on the picture selects it again", await centre(h) && model.shownText == second)
    } else { check("text 2 is on the picture", false) }

    // MARK: 2. A selected trim handle, let go by a click on the picture: ← / → move the playhead again

    let end0 = model.trim.end
    check("clicking the end handle selects it", await centre("trim-end") && model.trimEdge == .end)
    check("…and lets go of the text", model.shownText == nil)
    await shot("trim-selected")
    if let p = emptyCanvas() { await click(p) }
    check("a click on the picture lets go of the handle", model.trimEdge == nil)
    let t0 = pb.time
    await press("\u{F703}", code: EditorKeys.right)
    check("→ then moves the playhead (\(f2(pb.time - t0)) s), not the trim", abs(pb.time - t0 - 2) < 0.05 && abs(model.trim.end - end0) < 0.0001)
    await shot("trim-released")
    pb.pause()
    // Back to where both texts show.
    pb.seek(model.trim.start + 2, exact: true)
    await wait(600)

    // MARK: 3. The inspector's background lets go of a handle, a text and a field's cursor

    check("the end handle again", await centre("trim-end") && model.trimEdge == .end)
    if let p = emptyInspector() { await click(p) } else { check("the inspector's background", false) }
    check("a click on the inspector's background lets go of the handle", model.trimEdge == nil)
    // A press on a handle shows its frame: back to where both texts show.
    pb.seek(model.trim.start + 2, exact: true)
    await wait(600)
    if let h = handle(second) { _ = await centre(h) }
    check("text 2 selected on the picture", model.shownText == second)
    if let p = emptyInspector() { await click(p) }
    check("a click on the inspector's background lets go of the text", model.shownText == nil)

    if let f = titleField() {
      window.makeFirstResponder(f)
      await wait(200)
      check("the Title field has the cursor", typing())
      if let p = emptyInspector() { await click(p) }
      check("a click on the inspector's background takes the cursor out of the Title", !typing())
      await press(" ", code: EditorKeys.space)
      check("Space plays right after (not a space in the Title)", pb.isPlaying)
      await press(" ", code: EditorKeys.space)
    } else { check("the Title field", false) }
    pb.pause()

    // A control in the inspector is not an empty spot: text 2's number keeps (or makes) the selection.
    pb.seek(model.trim.start + 2, exact: true)
    await wait(600)
    if let h = handle(second) { _ = await centre(h) }
    check("text 2 selected again", model.shownText == second)
    if let chip = EditorKeysScript.anchors(in: host, named: "Text 2").first {
      let f = chip.convert(chip.bounds, to: nil)
      await click(NSPoint(x: f.midX, y: f.midY))
      check("a click on a control in the inspector keeps the text selected", model.shownText == second)
    } else {
      note("no “Text 2” anchor: the control check is skipped")
    }

    // MARK: 4. The timeline's and the header's empty space

    check("the start handle selected", await centre("trim-start") && model.trimEdge == .start)
    if let t = zone(.timeline) {
      await click(NSPoint(x: t.minX + 3, y: t.maxY - 3))
      check("a click in the timeline card's corner lets go of the handle", model.trimEdge == nil)
    } else { check("the timeline zone", false) }
    if let h = handle(second) { _ = await centre(h) }
    check("the end handle selected", await centre("trim-end") && model.trimEdge == .end)
    if let hd = zone(.header), let f = titleField() {
      window.makeFirstResponder(f)
      await wait(200)
      // The header between the clip's name and Done is empty.
      await click(NSPoint(x: hd.midX + 120, y: hd.midY))
      check("a click on the header's empty space lets go of the handle", model.trimEdge == nil)
      check("…and of the Title's cursor", !typing())
    } else { check("the header zone", false) }
    await shot("all-released")

    // Esc still lets go of a handle (round 24), and a trim handle still nudges after being clicked again.
    check("the end handle once more", await centre("trim-end") && model.trimEdge == .end)
    let e1 = model.trim.end
    await press("\u{F702}", code: EditorKeys.left)
    check("← moves a freshly selected handle (\(f2(e1 - model.trim.end)) s)", abs(e1 - model.trim.end - 2) < 0.01)
    await press("\u{1b}", code: EditorKeys.escape)
    check("Esc lets it go", model.trimEdge == nil)

    note("\(failed == 0 ? "all passed" : "\(failed) failed")")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
