import AppKit
import DJQCore
import SwiftUI

/// `DJQ_BULK_CROP_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): drives the real main window with the real
/// `AppModel` on a throwaway copy of the database. Clicks and drags go to this window only, and every check reads the store.
@MainActor
enum BulkCropScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("crop-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    let app = AppModel(store: store)
    app.refreshNow()
    app.loaded = true
    app.screen = .edit
    let edit = app.editList.filter { $0.type == .short && !$0.missing }
    let plain = edit.filter { ((try? store.edit(videoId: $0.id))?.crop) == nil }.prefix(3).map(\.id)
    guard plain.count == 3 else { note("needs three uncropped clips in Edit"); return 1 }
    let own = edit.first { !plain.contains($0.id) }?.id ?? plain[0]
    if own != plain[0], (try? store.edit(videoId: own))?.crop == nil {
      var e = (try? store.edit(videoId: own)) ?? Edit()
      e.crop = CropRect(x: 2000, y: 0, w: 1216, h: 2160)
      try? store.save(e, videoId: own)
    }
    let ownCrop = (try? store.edit(videoId: own))?.crop
    let ids = Array(plain) + [own]
    app.refreshNow()
    app.selectAll(.edit, ids: ids)
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: MainWindowView(model: app))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    await wait(2000)

    var step = 0
    func shot(_ name: String) async {
      await wait(500)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "crop-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }
    func frame(_ label: String) -> NSRect? {
      guard let a = anchor(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return nil }
      return a.convert(a.bounds, to: nil)
    }
    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(e)
      }
    }
    func click(_ label: String) async -> Bool {
      guard let f = frame(label) else { return false }
      let p = NSPoint(x: f.midX, y: f.midY)
      mouse(.leftMouseDown, p)
      mouse(.leftMouseUp, p)
      await wait(600)
      return true
    }
    func drag(from a: NSPoint, to b: NSPoint) async {
      mouse(.leftMouseDown, a)
      for i in 1...8 {
        let t = CGFloat(i) / 8
        mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        await wait(30)
      }
      mouse(.leftMouseUp, b)
      await wait(500)
    }
    func key(_ chars: String, code: UInt16) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code) else { return }
      if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
      await wait(700)
    }
    func crop(_ id: String) -> CropRect? { (try? store.edit(videoId: id))?.crop }
    func offset(_ id: String) -> Double {
      guard let c = crop(id), let v = try? store.video(id: id), let w = v.sourceWidth else { return .nan }
      return CropChange.offset(of: c, source: CGSize(width: w, height: v.sourceHeight ?? 2160))
    }

    await shot("selected")
    check("the bar's Crop button opens the dialog", await click("Crop") && app.cropDialogIds?.count == 4)
    await wait(2500)
    let order = app.selectedIds(.edit)
    await shot("dialog-open")
    check("opening it writes nothing", plain.allSatisfy { crop($0) == nil })

    // The slider moves every clip.
    if let f = frame("All clips") {
      let track = NSPoint(x: f.minX + f.width * 0.70, y: f.minY + 8)
      await drag(from: NSPoint(x: f.midX, y: f.minY + 8), to: track)
    }
    await shot("slider-moved")

    check("Next goes to the second clip", await click("Next clip"))
    await wait(1500)
    await shot("second-clip")

    // Dragging the crop on the frame moves this clip alone.
    if let f = frame("Crop frame") {
      await drag(from: NSPoint(x: f.midX + 60, y: f.midY), to: NSPoint(x: f.midX - 40, y: f.midY))
    }
    await shot("second-clip-dragged")
    _ = await click("Next clip")
    await wait(1000)
    _ = await click("Next clip")
    await wait(1500)
    await shot("clip-with-own-crop")
    check("still nothing written", plain.allSatisfy { crop($0) == nil })

    await key("\r", code: 36)
    await wait(1200)
    await shot("applied")
    // The dialog walks the clips in the order they show on screen.
    let dragged = order[1]
    let rest = plain.filter { $0 != dragged }
    let b = offset(dragged), a = offset(rest[0]), c = offset(rest.count > 1 ? rest[1] : rest[0])
    note(String(format: "slider %.3f %.3f, dragged %.3f", a, c, b))
    check("the slider's offset landed on the other clips", a > 0.03 && abs(a - c) < 0.002)
    check("the dragged clip has its own offset", abs(b - a) > 0.02 && b < a)
    check("a clip with a crop kept it", crop(own) == ownCrop)
    check("the selection stayed", app.selected(.edit).count == 4)
    app.undoLast()
    await wait(1000)
    check("one Undo takes it all back", plain.allSatisfy { crop($0) == nil })

    // A search after a bulk edit drops clips it hides, as it always did: nothing Eric can't see stays in the bar.
    app.selectAll(.edit, ids: Array(plain))
    await wait(600)
    if let first = app.editList.first(where: { !plain.contains($0.id) }) {
      app.bulkEdited[.edit] = (ids: Set(plain), until: Date().addingTimeInterval(-1))
      app.visibleIds[.edit] = [first.id]
      check("an old bulk edit doesn't keep hidden clips", app.keptSelection(.edit, shown: [first.id]) == [first.id])
      app.bulkEdited[.edit] = (ids: Set(plain), until: Date().addingTimeInterval(3))
      check("a bulk edit just now keeps them", app.keptSelection(.edit, shown: [first.id]).isSuperset(of: plain))
      app.bulkEdited[.edit] = nil
      app.visibleIds[.edit] = app.editList.map(\.id)
    }

    // A clip that isn't 9:16 stays inside its pane.
    if var e = try? store.edit(videoId: plain[0]) {
      e.aspectOverride = .r1x1
      try? store.save(e, videoId: plain[0])
    }
    app.refreshNow()
    app.cropDialogIds = [plain[0]]
    await wait(2500)
    await shot("square-clip")
    app.cropDialogIds = nil
    await wait(400)

    // Selection: every clip leaving the screen takes the bar with it, even when the list gives way to the empty state.
    let everything = app.editList.map(\.id)
    app.selectAll(.edit, ids: everything)
    await wait(600)
    _ = try? app.bulk.setExcluded(everything, true)
    app.refreshNow()
    await wait(900)
    await shot("all-clips-left")
    check("no clips left in Edit", app.editList.isEmpty)
    check("the selection went with them, so the bar is gone", app.selected(.edit).isEmpty)

    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("crop-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
