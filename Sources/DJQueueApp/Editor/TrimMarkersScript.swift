import AppKit
import DJQCore
import SwiftUI

/// `DJQ_TRIM_MARKERS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 24. Drives the REAL editor's
/// timeline on a throwaway copy of the dev database: grabbing a trim handle from its wide edge, a press that never makes
/// it jump, ⌥ for a tenth-speed drag, the time pill, clicking a handle and nudging it with ← / →, M markers (add, remove,
/// undo, saved), snapping the trim, a text bar and the playhead to a marker, zoom with = / - and the buttons, the overview,
/// and a long file opening on its trim. Mouse and keys are events sent to this window only (off every display, never
/// focused). Every check reads the model, the player or the saved edit. Saves `trim-NN-<step>-<appearance>.png`,
/// `timeline-NN-…` crops of just the timeline, and `checks-<appearance>.txt`.
@MainActor
enum TrimMarkersScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("trim-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func f2(_ v: Double) -> String { String(format: "%.3f", v) }

    // A clip with in/out markers and a text, so every lane is there.
    let shorts = ids.compactMap { try? store.video(id: $0) }
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
    /// The whole window, and the timeline card cut out of it (for the README).
    func shot(_ name: String) async {
      await wait(300)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
      host.cacheDisplay(in: host.bounds, to: rep)
      let file = out.appendingPathComponent(String(format: "trim-%02d-%@-%@.png", step, name, appearance))
      try? rep.representation(using: .png, properties: [:])?.write(to: file)
      if let ruler = ProbeFrames.frames["ruler"], let film = ProbeFrames.frames["film-track"], let cg = rep.cgImage {
        let k = CGFloat(cg.width) / host.bounds.width
        // A fixed height (room for the overview under a zoomed timeline), so every crop is the same size for the GIF.
        let top = ruler.minY - 50, bottom = film.maxY + 30
        let r = CGRect(x: max(0, ruler.minX - 60) * k, y: max(0, top) * k, width: (ruler.width + 80) * k, height: (bottom - top) * k).integral
        if let crop = cg.cropping(to: r) {
          let t = out.appendingPathComponent(String(format: "timeline-%02d-%@-%@.png", step, name, appearance))
          try? NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])?.write(to: t)
        }
      }
      note("shot \(file.lastPathComponent)")
    }
    func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code) else { return }
      NSApp.sendEvent(e)
      await wait()
    }
    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ flags: NSEvent.ModifierFlags = []) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        NSApp.sendEvent(e)
      }
    }
    /// `ProbeFrames` are SwiftUI global coordinates (top-left); events want window coordinates (bottom-left).
    func probe(_ key: String) -> NSRect? {
      guard let f = ProbeFrames.frames[key] else { note("no frame “\(key)”"); return nil }
      return NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
    }
    func click(_ p: NSPoint, _ flags: NSEvent.ModifierFlags = []) async {
      mouse(.leftMouseDown, p, flags)
      await wait(40)
      mouse(.leftMouseUp, p, flags)
      await wait()
    }
    /// A drag in steps; `hold` leaves the button down (for a mid-drag picture) and returns before the release.
    func drag(from a: NSPoint, by dx: CGFloat, flags: NSEvent.ModifierFlags = [], hold: Bool = false) async {
      mouse(.leftMouseDown, a, flags)
      await wait(40)
      for i in 1...12 {
        mouse(.leftMouseDragged, NSPoint(x: a.x + dx * CGFloat(i) / 12, y: a.y), flags)
        await wait(20)
      }
      if !hold {
        mouse(.leftMouseUp, NSPoint(x: a.x + dx, y: a.y), flags)
        await wait(450)
      }
    }
    func control(_ label: String) -> NSRect? {
      guard let a = EditorKeysScript.anchors(in: host, named: label).first else { note("no control “\(label)”"); return nil }
      return a.convert(a.bounds, to: nil)
    }
    func saved() -> Edit { model.flushAndWait(); return (try? store.edit(videoId: model.videoId)) ?? Edit() }
    func spp() -> Double { model.viewport.secondsPerPoint(width: Double(probe("film-track")?.width ?? 800)) }

    check("player loaded on a clip with in/out markers", pb.player != nil && model.video?.markerIn != nil)
    model.fitTimeline()
    await wait()
    await shot("handles")

    // MARK: 1. Wide handles that don't jump

    guard let endH = probe("trim-end"), let startH = probe("trim-start") else {
      check("trim handles found", false)
      return 1
    }
    check("the end handle's grab area is wide (\(Int(endH.width)) pt)", endH.width >= 24)
    check("the start handle's grab area is wide (\(Int(startH.width)) pt)", startH.width >= 24)
    let end0 = model.trim.end
    // A press a few points outside the trim, released without moving: nothing changes.
    await click(NSPoint(x: endH.maxX - 3, y: endH.midY))
    check("a press on the handle's outer edge doesn't move the trim (\(f2(model.trim.end)) vs \(f2(end0)))",
          abs(model.trim.end - end0) < 0.0001)
    check("…and selects that handle", model.trimEdge == .end)
    await shot("end-selected")

    // Drag from the outer edge: the end follows the pointer's movement (60 pt left), not the pointer's spot.
    let s1 = spp()
    let from = NSPoint(x: endH.maxX - 3, y: endH.midY)
    await drag(from: from, by: -60, hold: true)
    await shot("dragging-readout")
    mouse(.leftMouseUp, NSPoint(x: from.x - 60, y: from.y))
    await wait(450)
    let moved = end0 - model.trim.end
    check("dragging the end 60 pt shortens the trim by ~\(f2(60 * s1)) s (\(f2(moved)))", abs(moved - 60 * s1) < 8 * s1 + 0.01)
    check("the playhead shows the new end", abs(pb.time - model.trim.end) < 0.1)

    // MARK: 2. ⌥ = fine

    let endBefore = model.trim.end
    if let h = probe("trim-end") {
      await drag(from: NSPoint(x: h.midX, y: h.midY), by: -60, flags: .option)
      let fine = endBefore - model.trim.end
      check("with ⌥ the same 60 pt moves a tenth as far (\(f2(fine)) s vs \(f2(60 * s1)))", abs(fine - 6 * s1) < 0.02 + s1)
    } else { check("end handle after a drag", false) }

    // MARK: 3. Arrow nudge on the selected handle

    check("the dragged handle is selected", model.trimEdge == .end)
    let e1 = model.trim.end
    await press("\u{F702}", code: EditorKeys.left)
    check("← moves the selected end back by the arrow step (2 s): \(f2(e1 - model.trim.end))", abs(e1 - model.trim.end - 2) < 0.01)
    await press("\u{F703}", code: EditorKeys.right, flags: .shift)
    check("⇧→ moves it one frame", abs(model.trim.end - (e1 - 2 + 1 / model.fps)) < 0.005)
    check("the playhead follows the nudged edge", abs(pb.time - model.trim.end) < 0.05)
    await shot("nudged")
    await press("\u{1b}", code: EditorKeys.escape)
    check("Esc lets the handle go", model.trimEdge == nil)
    let t0 = pb.time
    await press("\u{F703}", code: EditorKeys.right)
    check("…and → moves the playhead again", abs(pb.time - t0 - 2) < 0.05 && abs(model.trim.end - (e1 - 2 + 1 / model.fps)) < 0.005)

    // Put the trim back for the marker part.
    model.resetEdit(.trimIn, .trimOut); model.commitTrim()
    await wait()

    // MARK: 4. M markers

    let tr = model.trim
    let m1 = ((tr.start + tr.duration * 0.4) * 1000).rounded() / 1000
    let m2 = ((tr.start + tr.duration * 0.75) * 1000).rounded() / 1000
    pb.seek(m1, exact: true)
    await wait()
    await press("m", code: 46)
    check("M adds a marker at the playhead (\(model.marks))", model.marks.count == 1 && abs(model.marks[0] - m1) < 0.002)
    await press("m", code: 46)
    check("M on the marker removes it", model.marks.isEmpty)
    await press("m", code: 46)
    pb.seek(m2, exact: true)
    await wait()
    if let b = control("Add marker") { await click(NSPoint(x: b.midX, y: b.midY)) }
    check("the flag button adds one too (\(model.marks.count) markers)", model.marks.count == 2)
    check("markers are saved with the clip", saved().marks.count == 2)
    await press("z", code: 6, flags: .command)
    check("⌘Z takes the last marker back", model.marks.count == 1)
    await press("z", code: 6, flags: [.command, .shift])
    check("⇧⌘Z puts it back", model.marks.count == 2)
    await shot("markers")

    // MARK: 5. Snapping to a marker

    let mk = model.marks[1]
    // The end handle, dragged to a few points past the marker, lands exactly on it.
    if let h = probe("trim-end") {
      let k = 1 / spp()
      let dx = CGFloat((mk - model.trim.end) * k) + 4
      await drag(from: NSPoint(x: h.maxX - 3, y: h.midY), by: dx)
      check("the end snaps onto the marker (\(f2(model.trim.end)) vs \(f2(mk)))", abs(model.trim.end - mk) < 0.0005)
      await shot("end-snapped")
      // With ⌥ it doesn't snap.
      if let h2 = probe("trim-end") {
        await drag(from: NSPoint(x: h2.midX, y: h2.midY), by: 30, flags: .option)
        check("⌥ drags past a marker without snapping", abs(model.trim.end - mk) > 0.0005)
      }
    }
    model.resetEdit(.trimIn, .trimOut); model.commitTrim()
    await press("\u{1b}", code: EditorKeys.escape)
    await wait()
    // The playhead: a click 4 pt off the first marker puts it on the marker.
    if let film = probe("film-track") {
      let m0 = model.marks[0]
      let x = film.minX + CGFloat(model.viewport.x(m0, width: Double(film.width))) + 4
      await click(NSPoint(x: x, y: film.midY))
      check("a click 4 pt from a marker puts the playhead on it (\(f2(pb.time)) vs \(f2(m0)))", abs(pb.time - m0) < 0.0005)
      await click(NSPoint(x: x + 30, y: film.midY))
      check("a click away from it doesn't snap", abs(pb.time - m0) > 0.05)
    }
    // A text bar's end grip, dragged near a marker, snaps to it.
    if model.textBars.bars.first?.draggable == true, let grip = probe("text-end-1"), let film = probe("film-track") {
      let m0 = model.marks[0]
      let target = film.minX + CGFloat(model.viewport.x(m0, width: Double(film.width))) + 3
      await drag(from: NSPoint(x: grip.midX, y: grip.midY), by: target - grip.midX)
      let end = model.trim.start + (model.textBars.bars.first?.span.end ?? 0)
      check("a text bar's end snaps to the marker (\(f2(end)) vs \(f2(m0)))", abs(end - m0) < 0.002)
      await shot("text-snapped")
    } else {
      note("skip text bar snap: the clip's text has no bar to drag")
    }
    // A marker pin: click puts the playhead on it.
    pb.seek(model.trim.start, exact: true)
    if let pin = probe("marker-1") {
      await click(NSPoint(x: pin.midX, y: pin.midY))
      check("clicking a marker pin puts the playhead on it", abs(pb.time - model.marks[1]) < 0.002)
    } else { check("marker pin found", false) }

    // MARK: 6. Zoom

    let full = model.viewport
    check("a short clip opens on the whole file", !model.timelineZoomed)
    pb.seek(model.marks[0], exact: true)
    await wait()
    await press("=", code: 24)
    check("= zooms in around the playhead (\(f2(model.viewport.span)) s of \(f2(full.span)))",
          abs(model.viewport.span - full.span / 2) < 0.01 && model.viewport.start <= pb.time && model.viewport.end >= pb.time)
    await press("=", code: 24)
    await shot("zoomed")
    check("the overview shows under a zoomed timeline", ProbeFrames.frames["overview-window"] != nil)
    if let win = probe("overview-window") {
      let before = model.viewport.start
      await drag(from: NSPoint(x: win.midX, y: win.midY), by: 40)
      check("dragging the overview window pans (\(f2(before)) → \(f2(model.viewport.start)))", model.viewport.start > before)
    }
    // Zoomed on the end, a 60 pt drag is a quarter as many seconds as before.
    model.fitTimeline()
    pb.seek(model.trim.end - 1, exact: true)
    await wait()
    await press("=", code: 24)
    await press("=", code: 24)
    if let h = probe("trim-end") {
      let e0 = model.trim.end, s = spp()
      await drag(from: NSPoint(x: h.midX, y: h.midY), by: -60)
      check("zoomed in 4×, 60 pt is \(f2(60 * s)) s (\(f2(e0 - model.trim.end)))", abs((e0 - model.trim.end) - 60 * s) < 8 * s + 0.01 && s < spp() * 1.01)
    } else {
      note("the end handle is out of view at this zoom")
    }
    let zs = model.viewport.span
    await press("-", code: 27)
    check("- zooms out (\(f2(zs)) → \(f2(model.viewport.span)) s)", abs(model.viewport.span - zs * 2) < 0.01)
    if let b = control("Fit timeline") { await click(NSPoint(x: b.midX, y: b.midY)) }
    check("Fit shows the whole file again", !model.timelineZoomed)

    // MARK: 7. A long file opens on its trim

    let long = shorts.filter { $0.duration > 60 }.max { $0.duration < $1.duration }?.id ?? model.videoId
    model.load(long)
    try? await Task.sleep(for: .seconds(2))
    let ld = model.duration
    model.setTrimIn(ld * 0.45); model.setTrimOut(ld * 0.45 + 8); model.commitTrim()
    model.flushAndWait()
    model.load(long)
    try? await Task.sleep(for: .seconds(2))
    check("a \(Int(ld)) s file with an 8 s trim opens zoomed on the trim (\(f2(model.viewport.start))–\(f2(model.viewport.end)))",
          model.timelineZoomed && model.viewport.start <= model.trim.start && model.viewport.end >= model.trim.end && model.viewport.span < 30)
    check("…where a point is a few hundredths of a second (\(f2(spp())) s/pt)", spp() < 0.05)
    await shot("long-file")
    model.resetEdit(.trimIn, .trimOut); model.commitTrim()
    model.flushAndWait()

    note("\(failed == 0 ? "all passed" : "\(failed) failed")")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
