import AppKit
import AVFoundation
import DJQCore
import SwiftUI

/// `DJQ_TEXT_LAYERS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 16 end to end in the REAL main window
/// with the REAL `AppModel` on a throwaway copy of the database. Clicks, drags and keys go to this window only, and every check
/// reads the store. It exports the clip through `Renderer` and compares the canvas with the file, frame by frame.
///
/// The window is off every display (`Backstage`), where the window server still draws it: the player only shows in that
/// capture. Exits 1 on a FAIL.
@MainActor
enum TextLayersScript {
  /// Mean difference (0…255) under a text's solid pixels below which that text counts as showing.
  private static let shownBelow = 30.0

  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    let summary = script.log.joined(separator: "\n")
    try? summary.write(to: out.appendingPathComponent("text-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    print("text-script: \(script.failed) failed, \(script.passed) passed")
    return script.failed == 0 ? 0 : 1
  }

  @MainActor
  private final class Runner {
    let store: Store, out: URL, appearance: String
    var log: [String] = []
    var failed = 0, passed = 0, step = 0
    var app: AppModel!
    var window: NSWindow!
    var clip = ""
    var baseline: (state: VideoState, sent: Bool)?
    var lockedNoted = false

    init(store: Store, out: URL, appearance: String) { self.store = store; self.out = out; self.appearance = appearance }

    func note(_ s: String) { print("text-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if ok { passed += 1 } else { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Window

    var host: NSView { window.contentView! }
    var editor: EditorModel? { EditorModel.live }

    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }

    /// A control by name, scrolled into view.
    func control(_ label: String) async -> NSRect? {
      guard let a = anchor(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return nil }
      a.scrollToVisible(a.bounds)
      await wait(250)
      return a.convert(a.bounds, to: nil)
    }

    /// `ProbeFrames` are SwiftUI global coordinates (top-left); events want window coordinates (bottom-left).
    func probe(_ key: String) -> NSRect? {
      guard let f = ProbeFrames.frames[key] else { note("no frame “\(key)”"); return nil }
      return NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(e)
      }
    }

    func clickAt(_ p: NSPoint) async {
      mouse(.leftMouseDown, p)
      await wait(40)
      mouse(.leftMouseUp, p)
      await wait(350)
    }

    @discardableResult func click(_ label: String) async -> Bool {
      guard let f = await control(label) else { return false }
      await clickAt(NSPoint(x: f.midX, y: f.midY))
      return true
    }

    /// Segment `i` of `n` in a full-width segmented control.
    @discardableResult func clickSegment(_ label: String, _ i: Int, of n: Int) async -> Bool {
      guard let f = await control(label) else { return false }
      await clickAt(NSPoint(x: f.minX + f.width * (CGFloat(i) + 0.5) / CGFloat(n), y: f.midY))
      return true
    }

    func drag(from a: NSPoint, to b: NSPoint) async {
      mouse(.leftMouseDown, a)
      await wait(40)
      for i in 1...10 {
        let t = CGFloat(i) / 10
        mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        await wait(25)
      }
      mouse(.leftMouseUp, b)
      await wait(500)
    }

    func type(_ text: String) async {
      for ch in text {
        let s = String(ch)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                    isARepeat: false, keyCode: 0) {
          window.sendEvent(e)
        }
        await wait(15)
      }
      await wait(500)
    }

    /// True when the control sits inside the inspector's visible part right now. It doesn't scroll, so it says where a jump
    /// landed.
    func onScreen(_ label: String) -> Bool {
      guard let a = anchor(host, ScriptAnchor.prefix + label), let scroll = a.enclosingScrollView else { return false }
      let r = a.convert(a.bounds, to: nil), box = scroll.convert(scroll.bounds, to: nil)
      return r.minY >= box.minY - 1 && r.maxY <= box.maxY + 1
    }

    /// Clicks a time field and replaces what's in it, leaving it uncommitted.
    func typeInField(_ label: String, _ text: String) async {
      await click(label)
      await wait(200)
      guard let field = window.firstResponder as? NSTextView else { check("\(label) takes the keyboard", false); return }
      field.selectAll(nil)
      await type(text)
    }

    /// The same, then ↩.
    func typeTime(_ label: String, _ text: String) async {
      await typeInField(label, text)
      if let k = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                  isARepeat: false, keyCode: 36) {
        window.sendEvent(k)
      }
      await wait(500)
    }

    /// A real ⌘Z event into what the editor's key monitor calls first (nothing here pumps the app's event queue).
    func commandZ() async {
      guard let k = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                     isARepeat: false, keyCode: 6), let e = editor else { return }
      check("⌘Z reaches the editor's history", EditorUndoKeys.handle(k, model: e))
      await wait(700)
    }

    /// True while the Mac is locked or its display is off: the window server draws no window then.
    var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

    /// The view tree drawn by AppKit, which needs no screen: everything but the player, which shows black.
    func viewTreePNG() -> Data? {
      window.displayIfNeeded()
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
      host.cacheDisplay(in: host.bounds, to: rep)
      return rep.representation(using: .png, properties: [:])
    }

    /// The window as the window server has it. A capture of one colour is tried again rather than trusted. On a locked Mac
    /// there's no screen to read, so it says so and uses the view tree.
    func frontCapture() async -> Data? {
      if screenLocked {
        if !lockedNoted { lockedNoted = true; note("screen locked: captures are the view tree, with the player black") }
        await wait(250)
        return viewTreePNG()
      }
      for _ in 0..<12 {
        Backstage.front(window)
        await wait(250)
        if let data = WindowCapture.png(window), let img = NSBitmapImageRep(data: data)?.cgImage, !Self.isBlank(img) { return data }
        note("blank capture, trying again")
        await wait(1000)
      }
      return nil
    }

    func shot(_ name: String) async {
      await wait(450)
      step += 1
      let file = out.appendingPathComponent(String(format: "text-%02d-%@-%@.png", step, name, appearance))
      guard let data = await frontCapture(), (try? data.write(to: file)) != nil else { check("captured \(name)", false); return }
      note("shot \(file.lastPathComponent)")
    }

    func capture() async -> CGImage? {
      await frontCapture().flatMap { NSBitmapImageRep(data: $0)?.cgImage }
    }

    // MARK: Store

    /// What's saved right now.
    func saved(_ id: String? = nil, version: Int = 1) -> ResolvedVersion? {
      EditorModel.flushLiveAndWait()
      guard let settings = try? store.settings() else { return nil }
      return (try? store.resolvedVersion(videoId: id ?? clip, number: version, settings: settings)) ?? nil
    }

    /// A version row as stored, before anything is resolved.
    func raw(_ id: String? = nil, version: Int = 1) -> Version? {
      EditorModel.flushLiveAndWait()
      return (try? store.versions(videoId: id ?? clip))?.first { $0.number == version }
    }

    func state() -> (state: VideoState, sent: Bool)? { (try? store.video(id: clip)).flatMap { $0 }.map { ($0.state, $0.sentToQueue) } }

    func stageHolds(_ when: String) {
      guard let b = baseline, let s = state() else { check("stage readable \(when)", false); return }
      check("stage and Send to Queue unchanged \(when)", s.state == b.state && s.sent == b.sent)
    }

    /// Typed keys land a beat later when the Mac is busy: wait up to `ms` for `done` before a check reads the store.
    func settle(_ ms: Int = 2500, _ done: () -> Bool) async {
      var waited = 0
      while !done(), waited < ms { await wait(100); waited += 100 }
    }

    func near(_ a: Double?, _ b: Double, _ tol: Double = 0.25) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    /// The playhead at `t` seconds after the trim start, through the call the filmstrip's scrub ends in: its SwiftUI gesture
    /// doesn't see events sent to the window.
    func seek(_ t: Double) async {
      guard let e = editor else { return }
      e.playback.pause()
      e.playback.seek(e.trim.start + t, exact: true)
      await wait(600)
    }

    func xFor(_ t: Double) -> CGFloat? {
      guard let e = editor, let f = probe("film-track"), e.duration > 0 else { return nil }
      return f.minX + f.width * CGFloat((e.trim.start + t) / e.duration)
    }

    // MARK: The run

    func main() async {
      let a = AppModel(store: store)
      app = a
      a.refreshNow()
      a.loaded = true
      a.screen = .edit
      // The shortest file that fits: the drags aim at seconds on a film strip as wide as the whole file, so on a 3-minute
      // file a point is 0.18 s and a 4 s target misses by more than the checks allow (round 26, the 11-12 seed).
      guard let v = a.editList.filter({ v in
        v.type == .short && !v.missing && v.duration > 22 && ((try? store.edit(videoId: v.id))?.crop) == nil
      }).min(by: { $0.duration < $1.duration }), let other = a.editList.first(where: { $0.type == .short && !$0.missing && $0.id != v.id }) else {
        check("an Edit clip with no crop", false)
        return
      }
      // Clips with only their first version first: the versions checks count on v2 and v3 being new.
      func versionCount(_ id: String) -> Int { (try? store.versions(videoId: id).count) ?? 0 }
      let more = a.editList.filter { $0.type == .short && !$0.missing && $0.id != v.id && $0.id != other.id && $0.duration > 12 }
        .sorted { versionCount($0.id) < versionCount($1.id) }
      guard more.count >= 2 else { check("two more Edit clips", false); return }
      clip = v.id
      note("clip \(v.id.prefix(8)) “\(a.displayName(v))”")
      EditorDisclosures.shared.closeAll()
      baseline = state()

      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      window = w
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }

      a.openEditor(clip, in: [clip, other.id])
      await wait(3500)
      guard let e = editor, e.videoId == clip, e.playback.player != nil else { check("the real editor is open", false); return }
      e.zonePlatforms = []
      e.canvasMode = .zones
      await wait(1500)

      await closedRows()
      await frameAndChip()
      await addingTexts()
      await timeline()
      await canvas()
      await stackedExport()
      await deleteAndUndo()
      await countdown()
      await capAndClipChange(other.id, third: more[0].id, broken: more[1].id)
      await listPreview()
      stageHolds("at the end")
    }

    func closedRows() async {
      await shot("default-closed-rows")
      check("every collapsible row starts closed", EditorDisclosures.shared.open.isEmpty)
      check("the closed Frame row has the crop problem to show", editor?.liveIssues.contains { $0.kind == .noCrop } == true)
      check("the Text section has no Advanced control showing", anchor(host, ScriptAnchor.prefix + "Add text") == nil)
      check("Frame opens with a click", await click("Frame") && EditorDisclosures.shared.isOpen(.frame))
      await shot("frame-open-by-click")
      await click("Frame")
      check("and closes with a click", !EditorDisclosures.shared.isOpen(.frame))
      await click("Index Cover")
      check("the mini-index opens Cover", EditorDisclosures.shared.isOpen(.cover))
      await shot("cover-open-from-index")
      await click("Cover")
    }

    func frameAndChip() async {
      check("the to-fix chip opens the closed Frame section", await click("To fix") && EditorDisclosures.shared.isOpen(.frame))
      await wait(600)
      check("the jump landed with the crop fix on screen", onScreen("Use this crop"))
      await shot("reason-chip-opened-frame")
      await click("Use this crop")
      check("Use this crop saved a crop", ((try? store.edit(videoId: clip))?.crop) != nil || { EditorModel.flushLiveAndWait(); return ((try? store.edit(videoId: clip))?.crop) != nil }())
      stageHolds("after confirming the crop")
      await click("Frame")
      await click("Index Text")
      check("Advanced opens with a click", await click("Advanced") && EditorDisclosures.shared.isOpen(.advanced))
      await shot("advanced-open")
    }

    func addingTexts() async {
      guard let e = editor else { return }
      let d = e.trim.duration
      note(String(format: "trim %.2f s", d))
      // A sloppy press on a whole-clip bar moves nothing, so it must write nothing.
      let untouched = raw()
      if let f = probe("text-bar-1") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX + 6, y: f.midY))
      }
      check("a stray drag on a whole-clip bar pins no window (\(raw()?.textStart ?? -1) – \(raw()?.textEnd ?? -1))",
            raw()?.textStart == untouched?.textStart && raw()?.textEnd == untouched?.textEnd)

      if let f = probe("text-end-1") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX + 30, y: f.midY))
      }
      check("nor does a grip dragged against the end of the trim", raw()?.textStart == untouched?.textStart && raw()?.textEnd == untouched?.textEnd)

      // The ringed swatch is the default: a tap changes nothing, so nothing gets written. Which one that is follows the
      // style (black on a white box, white otherwise), and New clip defaults decide the style.
      check("the default swatch is there", await click(TextLook.defaultColor(e.resolved.style) == "#000000" ? "swatch text colour Black" : "swatch text colour White"))
      check("tapping the default colour writes no look", raw()?.textLook == nil)

      // The first text ends at 4 s, so the others have room.
      if let f = probe("text-end-1"), let x = xFor(4) {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: x, y: f.midY))
      }
      var r = saved()
      check("dragging the first text's end grip saved its end near 4 s (\(r?.textEnd ?? -1))", near(r?.textEnd, 4))
      window.makeFirstResponder(nil)
      await wait(200)
      await commandZ()
      check("⌘Z takes the grip drag back in the store, on a clip that had no version row (\(raw()?.textEnd ?? -1))", raw()?.textEnd == nil)
      e.redo()
      await wait(500)
      check("Redo puts it back", near(raw()?.textEnd, 4))
      check("the first text's timing can go back to the default", await click("Back to the default timing"))
      check("↺ clears the first text's window", raw()?.textStart == nil && raw()?.textEnd == nil)
      window.makeFirstResponder(nil)
      await wait(200)
      await commandZ()
      r = saved()
      check("⌘Z undoes ↺", near(r?.textEnd, 4))

      await seek(6)
      check("the playhead is at 6 s", near(e.playback.time - e.trim.start, 6, 0.3))
      await click("Add text")
      r = saved()
      check("Add text added a second text", r?.moreText.count == 1)
      let second = r?.moreText.first
      check("it starts at the playhead and lasts 3 s", near(second?.start, 6, 0.3) && near(second?.end, 9, 0.3))
      check("it's selected", e.selectedText == second?.id)
      check("the field has the keyboard", window.firstResponder is NSTextView)
      await type("Second hook")
      await settle { saved()?.moreText.first?.text == "Second hook" }
      r = saved()
      check("typing went into the second text (“\(r?.moreText.first?.text ?? "")”)", r?.moreText.first?.text == "Second hook")
      check("the first text kept its words", r?.text == e.resolved.text && r?.text != "Second hook" && r?.hasText == true)
      await shot("second-text")

      check("a swatch click is there", await click("swatch text colour Red"))
      r = saved()
      check("the swatch colour saved on the selected text", r?.moreText.first?.look?.color == "#FF3B30")
      check("the first text's look didn't change", r?.textLook == nil)
      // A font is picked in a native menu, which would hold this script in its tracking loop: the item's own call.
      e.setLook { $0.font = .impact }
      r = saved()
      check("the font saved", r?.moreText.first?.look?.font == .impact)
      await shot("colour-and-font")
      _ = await control("Back to default look")
      await shot("advanced-bottom")

      await seek(14)
      await click("Add text")
      await type("Third line")
      await settle { saved()?.moreText.last?.text == "Third line" }
      r = saved()
      check("a third text at another time", r?.moreText.count == 2 && near(r?.moreText.last?.start, 14, 0.3))
      check("it copied the look", r?.moreText.last?.look?.color == "#FF3B30" && r?.moreText.last?.look?.font == .impact)
      check("the words are its own", r?.moreText.last?.text == "Third line")
      check("no overlap, one lane", e.textBars.laneCount == 1)
      await shot("third-text")
      stageHolds("after adding texts")
    }

    func timeline() async {
      guard let e = editor else { return }
      // Grip: the second text's end, 9 → 11.
      if let f = probe("text-end-2"), let x = xFor(11) {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: x, y: f.midY))
      }
      var r = saved()
      check("the grip moved the end (\(r?.moreText.first?.end ?? -1))", near(r?.moreText.first?.end, 11))
      check("and left the start alone", near(r?.moreText.first?.start, 6, 0.31))
      check("the grip selected that text", e.selectedText == r?.moreText.first?.id)

      // Body: the third text from 14 onto the second one.
      let before = r?.moreText.last
      if let f = probe("text-bar-3"), let x0 = xFor(15), let x1 = xFor(10) {
        await drag(from: NSPoint(x: x0, y: f.midY), to: NSPoint(x: x1, y: f.midY))
      }
      r = saved()
      let third = r?.moreText.last
      check("the body moved it left (\(third?.start ?? -1))", near(third?.start, 9))
      check("its length held", near(((third?.end ?? 0) - (third?.start ?? 0)), (before?.end ?? 0) - (before?.start ?? 0), 0.02))
      check("overlapping texts take a second lane", e.textBars.laneCount == 2)
      check("the first and second keep their lanes", e.textBars.bars.prefix(2).allSatisfy { $0.lane == 0 })
      await shot("overlap-second-lane")

      // A click that doesn't move selects and changes nothing.
      let at = r?.moreText.first
      if let f = probe("text-bar-2") { await clickAt(NSPoint(x: f.minX + 30, y: f.midY)) }
      r = saved()
      check("a click on a bar selects it", e.selectedText == at?.id)
      check("and doesn't move it", r?.moreText.first?.start == at?.start && r?.moreText.first?.end == at?.end)
      await shot("bar-selected")

      // Show from and to: typed, wrong, and from the playhead.
      await typeTime("Show from", "0:06.5")
      r = saved()
      check("a typed Show from saved (\(r?.moreText.first?.start ?? -1))", near(r?.moreText.first?.start, 6.5, 0.02))
      await typeTime("Show from", "soon")
      r = saved()
      check("a time that isn't one changes nothing", near(r?.moreText.first?.start, 6.5, 0.02))
      await shot("bad-time")
      await seek(7)
      await click("Show from playhead")
      r = saved()
      check("Use playhead set Show from", near(r?.moreText.first?.start, 7, 0.1))
      check("and left Show to alone", near(r?.moreText.first?.end, at?.end ?? -1, 0.02))
      stageHolds("after dragging on the timeline")
    }

    func canvas() async {
      guard let e = editor else { return }
      await seek(10)
      guard let third = e.resolved.moreText.last, let second = e.resolved.moreText.first else { return }
      check("both show at 10 s", e.textImages.filter { $0.shows(at: e.playback.time) }.count == 2)
      // The third sits on top of the second: the press takes the top one, and dragging it selects it.
      e.selectText(second.id)
      await wait(300)
      let y0 = third.posY
      let others = e.textImages.filter { $0.id != third.id }.map(\.image)
      if let f = probe("canvas-text-\(third.id)") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX, y: f.midY - 170))
      }
      var r = saved()
      check("the canvas drag took the top text and selected it", e.selectedText == third.id)
      check("it moved down (\(r?.moreText.last?.posY ?? -1))", (r?.moreText.last?.posY ?? 0) > y0 + 0.1)
      check("the text under it stayed", r?.moreText.first?.posY == second.posY)
      check("dragging one text redrew no other", zip(others, e.textImages.filter { $0.id != third.id }.map(\.image)).allSatisfy { $0 === $1 })
      await shot("canvas-drag")
      // A click on the other one moves the selection.
      if let f = probe("canvas-text-\(second.id)") { await clickAt(NSPoint(x: f.midX, y: f.midY)) }
      check("a click on the canvas selects that text", e.selectedText == second.id)
      await shot("canvas-click-selects")
      r = saved()
      check("a click moves nothing", r?.moreText.first?.posY == second.posY)
      // The switcher reaches the same selection.
      await click("Index Text")
      check("the switcher selects too", await click("Text 1") && e.selectedText == TextLayer.firstId)
      await shot("switcher")

      // A hidden selected text at the same place as a showing one: the pointer belongs to the one on screen.
      await click("Text 2")
      await seek(2)
      let start = saved()
      let firstY = start?.posY ?? 0, secondY = start?.moreText.first?.posY
      check("only the first text shows at 2 s", e.textImages.filter { $0.shows(at: e.playback.time) }.map(\.id) == [TextLayer.firstId])
      if let f = probe("canvas-text-\(TextLayer.firstId)") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX, y: f.midY - 60))
      }
      r = saved()
      check("the drag moved the text on screen (\(firstY) → \(r?.posY ?? -1))", (r?.posY ?? 0) > firstY + 0.03)
      check("not the hidden one under it", r?.moreText.first?.posY == secondY)
      check("and selected the one it moved", e.selectedIsFirst)
      await shot("hidden-text-gave-way")
      window.makeFirstResponder(nil)
      await wait(200)
      await commandZ()
      check("⌘Z puts it back", saved()?.posY == firstY)
      stageHolds("after the canvas")
    }

    /// The canvas at times around each window, then the same frames from a real export: which text shows must match the
    /// windows in both, and what the texts look like must match between them.
    func stackedExport() async {
      guard let e = editor, let r = saved() else { return }
      let layers = r.layers
      let times = [2.0, 5.0, 7.5, 10.0, 18.0]
      var shots: [(t: Double, canvas: CGImage)] = []
      await click("Index Title")
      // What the export would be: the canvas with no dimmed text or handles over it.
      e.plainCanvasForScript = true
      defer { e.plainCanvasForScript = false }
      for t in times {
        await seek(t)
        await wait(900)
        let want = e.textImages.filter { $0.shows(at: e.playback.time) }.map(\.id)
        await shot(String(format: "scrub-%04.1f", t))
        guard let f = probe("canvas-output"), let full = await capture() else { check("canvas captured at \(t)", false); continue }
        let scale = CGFloat(full.width) / host.bounds.width
        let flipped = CGRect(x: f.minX * scale, y: (host.bounds.height - f.maxY) * scale, width: f.width * scale, height: f.height * scale)
        guard let c = full.cropping(to: flipped.integral) else { check("canvas cropped at \(t)", false); continue }
        shots.append((t, c))
        note(String(format: "t %.1f: %d showing", t, want.count))
      }
      await wait(100)
      let root = out.appendingPathComponent("render-\(appearance)")
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let storeRef = store, id = clip
      note("rendering")
      let file: String? = await Task.detached(priority: .userInitiated) {
        do {
          return try Renderer(store: storeRef, outputRoot: root).ensureRender(videoId: id, versionNo: 1, platform: nil).outputPath
        } catch {
          print("text-script: render failed: \(error)")
          return nil
        }
      }.value
      check("the clip rendered through Renderer", file != nil)
      guard let file else { return }
      note("rendered \(file)")
      let w = 540, h = Int((Double(w) / e.aspect.ratio).rounded())
      for (t, canvas) in shots {
        let png = out.appendingPathComponent(String(format: "export-%04.1f-%@.png", t, appearance))
        let ok = Self.extract(file, at: t, to: png)
        guard ok, let exported = NSImage(contentsOf: png).flatMap({ Self.pixels($0.cgImage(forProposedRect: nil, context: nil, hints: nil), w, h) }),
              let shown = Self.pixels(canvas, w, h) else { check("export frame at \(t)", false); continue }
        var line: [String] = []
        for l in layers {
          guard let mask = TextOverlay.image(for: l, aspect: e.aspect).flatMap({ Self.pixels($0, w, h) }) else { continue }
          let inCanvas = Self.scoreUnder(mask, shown), inExport = Self.scoreUnder(mask, exported)
          let window = PreviewKeys.layerWindows(r, trimDuration: e.trim.duration).first { $0.layer.id == l.id }?.window
          let want = window?.contains(t) ?? false
          let name = l.id == TextLayer.firstId ? "first" : l.text
          check(String(format: "t %.1f “%@” %@: canvas %.0f, export %.0f", t, name, want ? "shows" : "hidden", inCanvas, inExport),
                (inCanvas < TextLayersScript.shownBelow) == want && (inExport < TextLayersScript.shownBelow) == want)
          line.append(String(format: "%@ %.0f/%.0f", name, inCanvas, inExport))
        }
        note("t \(t): " + line.joined(separator: " · "))
        Self.sideBySide(canvas: canvas, export: exported, w: w, h: h, to: out.appendingPathComponent(String(format: "compare-%04.1f-%@.png", t, appearance)))
      }
      stageHolds("after the export")
    }

    func deleteAndUndo() async {
      guard let e = editor else { return }
      let fingerprint = { (r: ResolvedVersion?) -> String in
        (r?.allLayers ?? []).map { "\($0.text)|\($0.start ?? -1)|\($0.end ?? -1)|\($0.posY)|\($0.look?.color ?? "")" }.joined(separator: "#") + "|\(r?.noText ?? false)"
      }
      let s0 = saved()
      await click("Index Text")
      await click("Text 1")
      // A time typed for the text being deleted goes with it.
      await typeInField("Show from", "1.5")
      await click("Delete")
      window.makeFirstResponder(nil)
      await wait(400)
      let s1 = saved()
      check("deleting the first text promotes the next one", s1?.text == "Second hook" && s1?.moreText.count == 1)
      check("the promoted text kept its window and look", near(s1?.textStart, s0?.moreText.first?.start ?? -1, 0.01) && s1?.textLook?.color == "#FF3B30")
      check("selection is on the promoted text", e.selectedIsFirst && e.selectedLayer.text == "Second hook")
      await shot("first-deleted-promoted")

      // The switch is a SwiftUI tap, which events sent to the window don't reach: its own call.
      e.setNoText(true)
      await wait(400)
      let s2 = saved()
      check("No text on saved", s2?.noText == true)
      check("it keeps the others stored", s2?.moreText.count == 1)
      check("the canvas shows nothing", e.textImages.isEmpty)
      check("the timeline shows the one No text bar", e.textBars.bars.count == 1)
      await shot("no-text-on")
      e.setNoText(false)
      await wait(400)
      let s3 = saved()
      check("No text off brings them back", s3?.noText == false && s3?.moreText.count == 1 && e.textImages.count == 2)
      await shot("no-text-off")

      // Back to the canvas's focus, so ⌘Z is the editor's, not the text field's.
      window.makeFirstResponder(nil)
      await wait(200)
      await commandZ()
      check("⌘Z undoes No text off", fingerprint(saved()) == fingerprint(s2))
      await commandZ()
      check("⌘Z undoes No text on", fingerprint(saved()) == fingerprint(s1))
      await commandZ()
      check("⌘Z undoes the delete, the first text and its look back", fingerprint(saved()) == fingerprint(s0))
      let before = saved()?.moreText.last?.posY
      await commandZ()
      check("⌘Z undoes the canvas drag as one step", saved()?.moreText.last?.posY != before)
      await shot("after-undo")
      if let e = editor { e.redo(); await wait(500) }
      check("Redo brings the drag back", saved()?.moreText.last?.posY == before)
      // Add and a look change are a step each.
      let n = saved()?.moreText.count ?? 0
      await click("Index Text")
      await click("Add text")
      await click("swatch text colour Blue")
      window.makeFirstResponder(nil)
      await wait(200)
      check("the new text took the swatch", saved()?.moreText.last?.look?.color == "#007AFF")
      await commandZ()
      check("⌘Z undoes the swatch alone", saved()?.moreText.count == n + 1 && saved()?.moreText.last?.look?.color != "#007AFF")
      await commandZ()
      check("⌘Z undoes the add alone", saved()?.moreText.count == n)
      stageHolds("after undo")
    }

    /// Round 26: one text counts down 3, 2, 1 in one slot, set by a real click on the Countdown control.
    func countdown() async {
      guard let e = editor else { return }
      await click("Index Text")
      await seek(4)
      let n = e.texts.count
      await click("Add text")
      window.makeFirstResponder(nil)
      await wait(300)
      guard let id = e.resolved.moreText.last?.id, e.texts.count == n + 1 else { check("a text to count down", false); return }
      check("the Countdown control is there for a text after the first", await control("Countdown") != nil)
      await clickSegment("Countdown", 1, of: 4)  // Off · 3 · 5 · 10
      await wait(500)
      guard let l = saved()?.moreText.first(where: { $0.id == id }) else { check("the countdown saved", false); return }
      check("a click on 3 makes it count down from 3", l.countdown == 3)
      let span = TextTimeline.span(l, trimDuration: e.trim.duration)
      // Big, a white box, and clear of the other texts, to read in the shots. Straight after the size change (its new
      // images still drawing) another text's window moves: the canvas must still end up with every image drawn for
      // its own key, never the old picture kept as a stand-in (review finding 1).
      e.setSelectedStyle(.box)
      e.setSelectedSize(110)
      e.moveText(id, x: 0.5, y: 0.45)
      if let other = e.resolved.moreText.first(where: { $0.id != id && $0.countdown == nil }) {
        e.updateText(other.id) { $0.end = ($0.end ?? e.trim.duration) - 0.2 }
      }
      for _ in 0..<12 where e.textImages.contains(where: \.placeholder) { await wait(250) }
      check("every text image is drawn for its own key after quick edits", !e.textImages.contains(where: \.placeholder))
      check("one second a number, ending where the text ended (\(span.start)–\(span.end))", near(span.end - span.start, 3, 0.01) && near(span.end, 7, 0.05))
      check("its bar reads 3 · 2 · 1", e.textBars.bars.first { $0.id == id }?.label == "3 · 2 · 1")
      await wait(800)
      let steps = e.textImages.filter { $0.layerId == id }
      check("the canvas has one image per number (\(steps.count))", steps.count == 3)
      for k in 0..<3 {
        await seek(span.start + Double(k) + 0.5)
        let showing = e.textImages.filter { $0.layerId == id && $0.shows(at: e.playback.time) }.compactMap(\.step)
        check("at \(k + 1) s into it only “\(3 - k)” shows (\(showing))", showing == [k])
        await shot("countdown-shows-\(3 - k)")
      }
      // Words around the number: typed in the text field, "{n}" is where the number goes.
      e.focusTextField += 1
      await wait(400)
      if let field = window.firstResponder as? NSTextView { field.insertText("Next in {n}", replacementRange: field.selectedRange()) }
      else { check("the text field takes the keyboard", false) }
      await wait(600)
      window.makeFirstResponder(nil)
      await wait(800)
      check("the words are kept with the countdown", saved()?.moreText.first { $0.id == id }?.text == "Next in {n}")
      check("its bar reads Next in 3 · 2 · 1", e.textBars.bars.first { $0.id == id }?.label == "Next in 3 · 2 · 1")
      await shot("countdown-with-words")
      // Duplicate keeps it a countdown (review finding 4).
      let before = e.texts.count
      e.duplicateText()
      await wait(400)
      let copy = saved()?.moreText.last
      check("Duplicate of a countdown counts down too", e.texts.count == before + 1 && copy?.countdown == 3 && copy?.id != id)
      if let c = copy?.id { e.selectText(c); e.deleteText() }
      e.selectText(id)
      window.makeFirstResponder(nil)  // Duplicate puts the keyboard in the text field; ⌘Z is the editor's here
      await wait(400)
      await clickSegment("Countdown", 0, of: 4)
      await wait(500)
      check("Off makes it a plain text again, window kept", saved()?.moreText.first { $0.id == id }.map { $0.countdown == nil && near($0.start, span.start, 0.01) } == true)
      await commandZ()
      check("⌘Z brings the countdown back", saved()?.moreText.first { $0.id == id }?.countdown == 3)
      // Out of the way of the cap run: removed again.
      e.selectText(id)
      e.deleteText()
      await wait(400)
      check("the countdown deletes like any text", saved()?.moreText.contains { $0.id == id } == false)
    }

    func capAndClipChange(_ other: String, third: String, broken: String) async {
      guard let e = editor else { return }
      let selected = e.selectedText
      check("a text is selected before leaving the clip", !selected.isEmpty)
      let open = EditorDisclosures.shared.open
      // A time typed and not committed belongs to this clip, whatever comes next.
      await click("Index Text")
      await click("Text 1")
      let otherBefore = raw(other), endBefore = saved()?.textEnd
      await typeInField("Show from", "1.5")
      check("a click on Next clip is there", await click("Next clip"))
      await wait(2500)
      check("the header went to the next clip", e.videoId == other)
      let a = saved(clip), b = raw(other)
      check("a typed Show from stays on its clip (\(a?.textStart ?? -1))", near(a?.textStart, 1.5, 0.02) && near(a?.textEnd, endBefore ?? -1, 0.02))
      check("and never reaches the next one (\(b?.textStart ?? -1))", b?.textStart == otherBefore?.textStart && b?.textEnd == otherBefore?.textEnd)
      check("the selection is on the first text of the next clip", e.selectedIsFirst)
      check("open rows stay open across clips", EditorDisclosures.shared.open == open)
      await click("Index Text")
      var n = e.texts.count
      while n < TextLayers.maxCount, e.addTextOffReason == nil {
        await click("Add text")
        await type("Text \(n + 1)")
        n += 1
      }
      check("the cap holds \(TextLayers.maxCount)", e.texts.count == TextLayers.maxCount)
      check("Add says why it's off", e.addTextOffReason != nil)
      await click("Add text")
      check("one more click adds nothing", e.texts.count == TextLayers.maxCount)
      // Round 26: more texts than the editor's image cache holds (~19 at full size) all stay on the canvas.
      await wait(2500)
      let drawn = e.resolved.layers.count
      check("all \(drawn) texts have their image on the canvas (\(e.textImages.count))", e.textImages.count == drawn)
      await shot("thirty-two-texts-four-lanes")
      check("no more than four lanes", e.textBars.laneCount <= TextTimeline.maxLanes)
      if let f = ProbeFrames.frames["canvas-output"] { check("the canvas keeps its height at 1440×900 (\(Int(f.height)) pt)", f.height >= 300) }

      // The selected bar comes up over the others sharing the last lane, so it can be picked up.
      let shared = e.textBars.bars.filter { $0.lane == TextTimeline.maxLanes - 1 }
      if shared.count > 1, let b = shared.first {
        e.selectText(b.id)
        await wait(400)
        if let f = probe("text-bar-\(b.number)") { await clickAt(NSPoint(x: f.minX + 30, y: f.midY)) }
        check("a click lands on the selected bar in a shared lane", e.selectedText == b.id)
      }

      // An emptied first text stays empty across No text, and the cover says what it shows.
      await click("Text 1")
      e.focusTextField += 1
      await wait(400)
      if let field = window.firstResponder as? NSTextView {
        field.selectAll(nil)
        field.delete(nil)
      }
      await wait(600)
      window.makeFirstResponder(nil)
      await wait(300)
      let images = e.textImages.count
      check("the emptied first text is stored empty", raw(other)?.text == "")
      e.setNoText(true)
      await wait(400)
      check("with No text the cover has no text to show", !e.coverHasText)
      await shot("no-text-timing-fields")
      e.setNoText(false)
      await wait(600)
      // Round 26: with up to 32 texts, the ones the image cache let go are drawn again; give that time.
      for _ in 0..<20 where e.textImages.count < images { await wait(250) }
      check("No text off leaves the first text empty", raw(other)?.text == "")
      check("and the Title doesn't come back on the video (\(e.textImages.count) of \(images))", e.textImages.count == images)

      e.flushAndWait()
      await versionsAndTrim(third)
      await readOnlyRows(broken)
      e.load(clip)
      await wait(2500)
    }

    /// Trim commits, new versions and an inherited list, on a clip of its own.
    func versionsAndTrim(_ id: String) async {
      guard let e = editor else { return }
      e.load(id)
      await wait(2500)
      await click("Index Text")
      let d = e.trim.duration
      await seek(d * 0.8)
      await click("Add text")
      await type("Late text")
      guard let late = e.resolved.moreText.last else { check("a late text", false); return }
      check("a text late in the clip", near(late.start, d * 0.8, 0.3))
      // Through the call the O key makes; dragging the trim handle is a SwiftUI gesture.
      e.setTrimOut(e.trim.start + d * 0.5)
      await wait(600)
      let inside = raw(id)?.moreText?.last, short = e.trim.duration
      check("a committed trim pulls the text inside it", (inside?.end ?? 99) <= short + 0.01 && (inside?.start ?? 99) < short)
      e.undo()
      await wait(600)
      check("⌘Z takes the trim and the clamp back", near(raw(id)?.moreText?.last?.start, late.start ?? -1, 0.01))

      // The clip may already have later versions of its own (every Edit clip in the 11-12 seed has a v2): a new version
      // follows the last one and inherits its list, so the numbers and the list come from the clip, not from v1.
      let last = (try? store.versions(videoId: id))?.map(\.number).max() ?? 1
      let inherited = saved(id, version: last)?.moreText.map(\.id) ?? []
      e.newVersion(copying: nil)
      await wait(600)
      let fresh = e.versionNo
      check("a new version follows the last (v\(fresh))", fresh == last + 1)
      check("a new version inherits the list and stores none", raw(id, version: fresh)?.moreText == nil && e.resolved.moreText.map(\.id) == inherited)
      if e.resolved.moreText.isEmpty {  // nothing inherited to edit: give it a text of its own first
        note("v\(fresh) inherited no texts: the copy-on-first-edit check runs on a text added to it")
        await click("Add text")
        await type("Inherited")
        window.makeFirstResponder(nil)
        await wait(300)
      }
      guard let target = e.resolved.moreText.last else { check("a text to edit on the new version", false); return }
      let earlierSize = saved(id, version: last)?.moreText.last?.size
      e.selectText(target.id)
      await wait(300)
      e.setSelectedSize(target.size == 90 ? 91 : 90)  // the slider's own call: its drag is a SwiftUI gesture
      await wait(600)
      check("the first edit copies the list into that version", raw(id, version: fresh)?.moreText?.last?.size == (target.size == 90 ? 91 : 90))
      check("and leaves the earlier version alone", saved(id, version: last)?.moreText.last?.size == earlierSize)
      e.newVersion(copying: 1)
      await wait(600)
      let copy = e.versionNo
      check("a copy of an older version carries its texts", copy == fresh + 1 && raw(id, version: copy)?.moreText == saved(id)?.moreText)

      e.selectText(late.id)  // the late text is in this copy of v1; the one edited above may not be
      await wait(300)
      await typeInField("Show from", "1.5")
      e.selectVersion(1)
      await wait(800)
      check("a typed time stays on its version", near(raw(id, version: copy)?.moreText?.last?.start, 1.5, 0.02))
      check("and doesn't reach the one selected next", raw(id)?.moreText?.last?.start == late.start)

      // Undo takes away the version a time was typed in: the time goes too, and Redo keeps what's typed off the one it leaves.
      let stored = raw(id)?.moreText?.last?.start
      e.newVersion(copying: nil)
      await wait(600)
      let number = e.versionNo
      await typeInField("Show from", "2.5")
      await click("Undo")
      window.makeFirstResponder(nil)
      await wait(800)
      check("Undo removed the new version", e.versionNo == 1 && raw(id, version: number) == nil)
      check("a time typed in it doesn't land on the version Undo goes to (\(raw(id)?.moreText?.last?.start ?? -1))", raw(id)?.moreText?.last?.start == stored)
      e.flushAndWait()
      check("nor later", raw(id)?.moreText?.last?.start == stored)
      await typeInField("Show from", "3.5")
      await click("Redo")
      window.makeFirstResponder(nil)
      await wait(800)
      e.flushAndWait()
      check("a time typed before Redo lands nowhere", raw(id)?.moreText?.last?.start == stored && raw(id, version: number)?.moreText == nil)
      e.selectVersion(1)
      await wait(500)
    }

    /// A read-only clip can still be read: rows open, and what's in them stays off.
    func readOnlyRows(_ id: String) async {
      guard let e = editor else { return }
      _ = try? store.db.run("INSERT OR REPLACE INTO edits(video_id,json,updated_at) VALUES(?,'not json',0)", [id])
      e.load(id)
      await wait(2500)
      check("the clip is read only", e.readOnly)
      EditorDisclosures.shared.closeAll()
      await wait(400)
      check("Advanced opens on a read-only clip", await click("Advanced") && EditorDisclosures.shared.isOpen(.advanced))
      check("Size and position too", await click("Size and position") && EditorDisclosures.shared.isOpen(.sizeAndPosition))
      let n = e.texts.count
      await click("Add text")
      check("and what's in them stays off", e.texts.count == n)
      await shot("read-only-rows")
      await click("Size and position")
    }

    func listPreview() async {
      guard let e = editor else { return }
      // A change after the export, so the preview plays the proxy with its overlays instead of the rendered file.
      await click("Index Text")
      e.selectText(e.resolved.moreText.last?.id ?? TextLayer.firstId)
      await wait(300)
      e.setSelectedWords("Third line!")
      let r = saved()
      await shot("before-list")
      app.closeEditor()
      await wait(1200)
      app.refreshNow()
      guard let v = app.video(clip) else { check("clip back in the list", false); return }
      app.previewVideo = v
      var view: DSPlayerNSView?
      var waited = 0
      while waited < 90 {
        await wait(1000)
        waited += 1
        view = Self.find(host) { ($0 as? DSPlayerNSView).flatMap { $0.isPlaying && $0.debugShownTexts.count >= 3 ? $0 : nil } }
        if view != nil { break }
      }
      check("the list preview plays with one overlay per text (\(view?.debugShownTexts.count ?? 0))", view?.debugShownTexts.count == r?.layers.count)
      guard let view else { return }
      await shot("list-preview-playing")
      let dur = app.clipPreview(v).overlays
      var on = Array(repeating: false, count: dur.count), off = on, wrong = 0, samples = 0
      for _ in 0..<450 where samples < 100 || !(on + off).allSatisfy({ $0 }) {  // a whole loop at most
        await wait(100)
        let t = view.debugTime
        guard t.isFinite else { continue }
        samples += 1
        for (i, shown) in view.debugShownTexts.enumerated() where i < dur.count {
          if shown { on[i] = true } else { off[i] = true }
          // A sample can land right on a window's edge, one observer tick behind the clock.
          let w = dur[i].window
          let edge = w.map { abs(t - $0.lowerBound) < 0.15 || abs(t - $0.upperBound) < 0.15 } ?? false
          if !edge, shown != dur[i].shows(at: t) { wrong += 1 }
        }
      }
      note("sampled \(samples): on \(on) off \(off) wrong \(wrong)")
      check("every timed text toggled on while playing", on.allSatisfy { $0 })
      check("and off again", off.allSatisfy { $0 })
      check("each one only inside its window (\(wrong) of \(samples) wrong)", wrong == 0 && samples > 60)
      // Eviction: the cache loses an image, and the playing preview draws it again.
      if let key = dur.last?.key {
        AppModel.overlayCache.remove { $0 == key }
        app.reloadOverlay(clip)
        await wait(2500)
        check("an evicted overlay comes back", AppModel.overlayCache.value(key) != nil)
      }
      app.previewVideo = nil
      await wait(500)
    }

    // MARK: Pixels

    static func find<T>(_ v: NSView, _ match: (NSView) -> T?) -> T? {
      if let hit = match(v) { return hit }
      for c in v.subviews { if let hit = find(c, match) { return hit } }
      return nil
    }

    static func isBlank(_ img: CGImage) -> Bool {
      guard let p = pixels(img, 64, 40) else { return true }
      let first = Array(p.prefix(3))
      return stride(from: 0, to: p.count, by: 4).allSatisfy { i in (0..<3).allSatisfy { abs(Int(p[i + $0]) - Int(first[$0])) < 6 } }
    }

    /// One frame of `file`, `t` seconds in, by ffmpeg.
    static func extract(_ file: String, at t: Double, to png: URL) -> Bool {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: Tools.ffmpeg ?? "/opt/homebrew/bin/ffmpeg")
      p.arguments = ["-y", "-loglevel", "error", "-ss", String(format: "%.3f", t), "-i", file, "-frames:v", "1", png.path]
      guard (try? p.run()) != nil else { return false }
      p.waitUntilExit()
      return p.terminationStatus == 0
    }

    /// RGBA, top row first, scaled to w × h.
    static func pixels(_ image: CGImage?, _ w: Int, _ h: Int) -> [UInt8]? {
      guard let image else { return nil }
      var data = [UInt8](repeating: 0, count: w * h * 4)
      let ok: Bool = data.withUnsafeMutableBytes { b in
        guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      return ok ? data : nil
    }

    /// Mean difference between `frame` and a text's own image, under the text's solid pixels. Small = the text is there.
    static func scoreUnder(_ mask: [UInt8], _ frame: [UInt8]) -> Double {
      var sum = 0.0, n = 0.0
      var i = 0
      while i + 3 < mask.count {
        if mask[i + 3] > 245 {
          for c in 0..<3 { sum += abs(Double(mask[i + c]) - Double(frame[i + c])) }
          n += 3
        }
        i += 4
      }
      return n > 0 ? sum / n : 255
    }

    static func sideBySide(canvas: CGImage, export: [UInt8], w: Int, h: Int, to url: URL) {
      guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2 + 20, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
      ctx.draw(canvas, in: CGRect(x: 0, y: 0, width: w, height: h))
      var e = export
      e.withUnsafeMutableBytes { b in
        if let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let img = c.makeImage() {
          ctx.draw(img, in: CGRect(x: w + 20, y: 0, width: w, height: h))
        }
      }
      try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
  }
}
