import AppKit
import DJQCore
import SwiftUI

/// `DJQ_BULK_CAPTION_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): drives the real main window with the real
/// `AppModel` on a throwaway copy of the database. Clicks and keys go to this window only, and every check reads the store.
@MainActor
enum BulkCaptionScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("bulk-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    let app = AppModel(store: store)
    app.refreshNow()
    app.loaded = true
    app.screen = .edit
    let ids = Array(app.videos.filter { $0.state == .needsEdit && $0.type == .short }.prefix(2).map(\.id))
    guard ids.count == 2 else { note("needs two clips in Edit"); return 1 }
    app.selectAll(.edit, ids: ids)
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: MainWindowView(model: app))
    window.contentView = host
    window.isReleasedWhenClosed = false
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    await wait(2000)

    var step = 0
    func shot(_ name: String) async {
      await wait(400)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "bulk-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func key(_ chars: String, code: UInt16) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code) else { return }
      if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
      await wait(600)
    }
    /// Real controls, at the place they really are: `ScriptAnchor` marks them in the view tree, and the click goes through the
    /// window's hit testing.
    func anchors(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchors(c, name) { return hit } }
      return nil
    }
    func click(_ label: String) async -> Bool {
      guard let a = anchors(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      let f = a.convert(a.bounds, to: nil)
      let inWindow = NSPoint(x: f.midX, y: f.midY)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait(500)
      return true
    }
    func caption(_ id: String) -> String {
      guard let v = try? store.video(id: id), let r = try? store.resolvedVersion(videoId: id, number: 1),
            let name = try? store.session(id: v.sessionId)?.name, let sets = try? store.hashtagSets(), let t = try? store.captionTemplates(),
            let st = try? store.settings() else { return "?" }
      return Captions.sharedCaption(version: r, video: v, sessionName: name, sets: sets, templates: t, settings: st)
    }
    func captionBatches() -> Int { (try? store.db.one("SELECT count(*) AS n FROM batches WHERE action='caption'")?.int("n")) ?? -1 }

    // The groups and titles are the copy's own, so this is Eric's real data.
    let sets = (try? store.hashtagSets()) ?? []
    let plainId = "bulk-script-plain"
    try? store.save(CaptionTemplate(id: plainId, name: "Text + hashtags", template: "{text}\n\n{hashtags}", sort: 99))
    app.refreshNow()
    await wait(500)
    await shot("selected")
    check("the bar's Caption button is real and opens the dialog", await click("Caption") && app.captionDialogIds?.count == 2)
    await wait(800)
    await shot("dialog-open")
    let before = caption(ids[0])
    check("nothing is written by opening it", captionBatches() == 0)
    for name in ["DJ lovd", "General mashup", "Afrobeats"] where sets.contains(where: { $0.name == name }) {
      check("clicked \(name)", await click(name))
    }
    await wait(600)
    await shot("three-groups")
    check("still nothing written", captionBatches() == 0 && caption(ids[0]) == before)
    check("clicked the template", await click("Text + hashtags"))
    await wait(600)
    await shot("template-and-groups")
    await key("\r", code: 36)
    await wait(1000)
    await shot("applied")
    check("↩ applied one batch", captionBatches() == 1)
    check("the dialog closed", app.captionDialogIds == nil)
    let want = "#djlovd #djtransition #mashup #mix #afrobeats"
    for id in ids {
      let title = (try? store.video(id: id)?.displayName) ?? ""
      check("\(title): text, blank line, the three groups in click order", caption(id) == "\(title)\n\n\(want)")
    }
    note("caption: \(caption(ids[0]).replacingOccurrences(of: "\n", with: " / "))")
    let undo = app.undoHistory.entries.count
    app.undoLast()
    await wait(1000)
    await shot("undone")
    check("one Undo takes it all back", caption(ids[0]) == before && undo > 0)
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("bulk-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
