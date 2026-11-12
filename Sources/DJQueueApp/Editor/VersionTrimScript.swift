import AppKit
import DJQCore
import SwiftUI

/// `DJQ_VERSION_TRIM_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 30. Drives the REAL editor on a
/// throwaway copy of the dev database: a clip with v1, v2 and v3, editing v3. Dragging v3's trim handle gives v3 its own
/// trim and leaves v1, v2 and the clip's trim alone (and v2's late texts aren't clamped); the timeline badge and the Trim
/// field's switch and words say whose trim it is; v1 still shows the clip's trim; ⌘Z / ⌘⇧Z undo and redo it; "All
/// versions" puts v3 back on the shared trim, and a drag there moves the trim every version without its own uses.
/// Renders follow (each version's render plan uses its own trim). Mouse and keys are events sent to this window only
/// (off every display, never focused). Saves `vtrim-NN-<step>-<appearance>.png` and `checks-<appearance>.txt`.
@MainActor
enum VersionTrimScript {
  static func run(store: Store, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("vtrim-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    // A clip whose file is in the dev root, with markers and room to trim.
    let shorts = ids.compactMap { try? store.video(id: $0) }.filter { v in
      !v.isPhoto && v.duration > 20 && v.markerIn != nil
        && (((try? store.fileURL(for: v)) ?? nil).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
    guard let clip = shorts.first else { note("FAIL no clip with markers in the dev root"); return 1 }
    let id = clip.id
    note("clip \(clip.tag) [\(id.prefix(8))] \(f2(clip.duration)) s")

    // Set up v1…v3 standing alone, every version on the clip's trim, and a late text on v2 (it must never be clamped).
    do {
      let s = try store.settings()
      var e = try store.edit(videoId: id)
      e.trimIn = nil; e.trimOut = nil; e.platformTrims = [:]
      try store.save(e, videoId: id)
      var all = try store.versions(videoId: id)
      if !all.contains(where: { $0.number == 1 }) { all.insert(Version(number: 1), at: 0); try store.save(all[0], videoId: id) }
      for n in 2...3 where !all.contains(where: { $0.number == n }) {
        let copy = VersionCopy.duplicate(all, source: n - 1, as: n, settings: s, video: clip)
        try store.save(copy, videoId: id)
        all = try store.versions(videoId: id)
      }
      for var v in try store.versions(videoId: id) where v.hasOwnTrim || v.number == 2 {
        v.clearOwnTrim()
        if v.number == 2 {
          let d = try store.resolvedEdit(videoId: id, version: 2).trim().duration
          v.text = "Quiz answer late"; v.noText = false; v.textStart = max(0, d - 4); v.textEnd = d - 1
        }
        try store.save(v, videoId: id)
      }
    } catch { note("FAIL setting up versions: \(error)"); return 1 }
    let clipTrim = (try? store.resolvedEdit(videoId: id, version: 1).trim()) ?? TrimRange(start: 0, end: 0)
    let v2Text = (try? store.versions(videoId: id).first { $0.number == 2 }).flatMap { $0.map { ($0.textStart, $0.textEnd) } }

    let app = AppModel(store: store)
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    EditorDisclosures.shared.closeAll()
    EditorDisclosures.shared.set(.frame, true)
    let model = EditorModel(store: store, videoId: id)
    model.appHooks = EditorAppHooks(isCovered: { false }, arrowStep: { app.playback.arrowStep },
                                    setArrowStep: { s in app.setPlayback { $0.arrowStep = s } })
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close(); EditorDisclosures.shared.closeAll() }
    try? await Task.sleep(for: .seconds(3))

    var step = 0
    func shot(_ name: String) async {
      await wait(350)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
      host.cacheDisplay(in: host.bounds, to: rep)
      let file = out.appendingPathComponent(String(format: "vtrim-%02d-%@-%@.png", step, name, appearance))
      try? rep.representation(using: .png, properties: [:])?.write(to: file)
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
    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        NSApp.sendEvent(e)
      }
    }
    func probe(_ key: String) -> NSRect? {
      guard let f = ProbeFrames.frames[key] else { note("no frame “\(key)”"); return nil }
      return NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
    }
    func control(_ label: String) -> NSRect? {
      guard let a = EditorKeysScript.anchors(in: host, named: label).first else { return nil }
      return a.convert(a.bounds, to: nil)
    }
    func click(_ p: NSPoint) async {
      mouse(.leftMouseDown, p)
      await wait(40)
      mouse(.leftMouseUp, p)
      await wait()
    }
    func dragEnd(by dx: CGFloat) async -> Bool {
      guard let h = probe("trim-end") else { return false }
      let a = NSPoint(x: h.midX, y: h.midY)
      mouse(.leftMouseDown, a)
      await wait(40)
      for i in 1...12 {
        mouse(.leftMouseDragged, NSPoint(x: a.x + dx * CGFloat(i) / 12, y: a.y))
        await wait(20)
      }
      mouse(.leftMouseUp, NSPoint(x: a.x + dx, y: a.y))
      await wait(500)
      return true
    }
    func stored(_ n: Int) -> Version? { model.flushAndWait(); return (try? store.versions(videoId: id))?.first { $0.number == n } }
    func trimOf(_ n: Int) -> TrimRange { model.flushAndWait(); return (try? store.resolvedEdit(videoId: id, version: n).trim()) ?? TrimRange(start: 0, end: 0) }
    func same(_ a: TrimRange, _ b: TrimRange) -> Bool { abs(a.start - b.start) < 0.001 && abs(a.end - b.end) < 0.001 }

    check("three versions on the clip (\(model.versionNumbers))", model.versionNumbers == [1, 2, 3])
    model.fitTimeline()
    model.selectVersion(3)
    model.scrollTarget = .frame
    await wait(600)
    check("editing v3 of a clip with three versions, the handles change v3 only", model.trimScope == .version)
    check("the Trim field shows the switch", control("Trim scope switch") != nil)
    let hint0 = EditorFrameSection.trimHint(model, hasMarkers: model.video?.markerIn != nil && model.video?.markerOut != nil)
    check("…and says v1 and v2 keep theirs (“\(hint0)”)", hint0.contains("v1, v2 keep theirs"))
    await shot("v3-before")

    // MARK: 1. A drag on v3 gives v3 its own trim; nothing else moves.

    let renderer = Renderer(store: store)
    let h1Before = try? renderer.editHash(videoId: id, versionNo: 1, platform: nil)
    let h3Before = try? renderer.editHash(videoId: id, versionNo: 3, platform: nil)

    check("dragged v3's end handle", await dragEnd(by: -120))
    model.flushAndWait()
    let v3 = stored(3)
    check("v3 has its own trim (\(v3.map { "\(f2($0.trimIn ?? -1))–\(f2($0.trimOut ?? -1))" } ?? "none"))", v3?.hasOwnTrim == true)
    check("v3's trim is shorter than the clip's (\(f2(trimOf(3).end)) < \(f2(clipTrim.end)))", trimOf(3).end < clipTrim.end - 0.5)
    check("v3's start stayed where it was", abs(trimOf(3).start - clipTrim.start) < 0.001)
    check("v1 keeps the clip's trim", same(trimOf(1), clipTrim))
    check("v2 keeps the clip's trim", same(trimOf(2), clipTrim))
    let e = (try? store.edit(videoId: id)) ?? Edit()
    check("the clip's trim itself didn't change", e.trimIn == nil && e.trimOut == nil)
    let v2 = stored(2)
    check("v2's late text wasn't clamped (\(String(describing: v2?.textStart))–\(String(describing: v2?.textEnd)))",
          v2.map { $0.textStart == v2Text?.0 && $0.textEnd == v2Text?.1 } ?? false)
    await press("\u{1b}", code: EditorKeys.escape)  // let the dragged handle go, so the timeline shows whose trim it is
    check("the timeline says v3 only", control("Version trim badge") != nil)
    let h1After = try? renderer.editHash(videoId: id, versionNo: 1, platform: nil)
    let h3After = try? renderer.editHash(videoId: id, versionNo: 3, platform: nil)
    check("v3's render changes and v1's doesn't", h1After == h1Before && h3After != h3Before)
    await shot("v3-own-trim")

    // MARK: 2. v1 still shows the clip's trim.

    model.selectVersion(1)
    await wait(600)
    check("v1 in the editor shows the clip's trim", same(model.trim, clipTrim) && !model.hasOwnTrim)
    check("…without the v3 badge", control("Version trim badge") == nil)
    await shot("v1-keeps-its-trim")
    model.selectVersion(3)
    await wait(500)

    // MARK: 3. Undo / redo.

    await press("z", code: 6, flags: .command)
    check("⌘Z takes v3's own trim back off", stored(3)?.hasOwnTrim == false && same(trimOf(3), clipTrim))
    await press("z", code: 6, flags: [.command, .shift])
    check("⌘⇧Z puts it back", stored(3)?.hasOwnTrim == true && trimOf(3).end < clipTrim.end - 0.5)

    // MARK: 4. "All versions": v3 follows the shared trim, and a drag there moves it for every version without its own.

    if let sw = control("Trim scope switch") {
      await click(NSPoint(x: sw.minX + sw.width * 0.75, y: sw.midY))
    } else { model.setTrimScope(.clip) }
    await wait(500)
    check("“All versions” puts v3 back on the shared trim", stored(3)?.hasOwnTrim == false && model.trimScope == .clip)
    await shot("all-versions")
    check("dragged the shared end handle", await dragEnd(by: -80))
    let shared = trimOf(1)
    check("the shared trim moved (\(f2(shared.end)) < \(f2(clipTrim.end)))", shared.end < clipTrim.end - 0.5)
    check("v2 and v3 follow it", same(trimOf(2), shared) && same(trimOf(3), shared))
    await shot("all-versions-dragged")
    await press("z", code: 6, flags: .command)
    await press("z", code: 6, flags: .command)
    check("two ⌘Z: v3 has its own trim again and the shared trim is back", stored(3)?.hasOwnTrim == true && same(trimOf(1), clipTrim))

    try? (log.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    note(failed == 0 ? "all checks passed" : "\(failed) check(s) failed")
    return failed == 0 ? 0 : 1
  }
}
