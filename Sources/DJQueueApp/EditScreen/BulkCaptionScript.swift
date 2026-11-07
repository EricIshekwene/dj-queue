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
    Backstage.show(window)
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
    let batches = captionBatches()
    let before = caption(ids[0])
    check("the bar's Caption button is real and opens the dialog", await click("Caption") && app.captionDialogIds?.count == 2)
    await wait(800)
    await shot("dialog-open")
    check("nothing is written by opening it", captionBatches() == batches && caption(ids[0]) == before)
    for name in ["DJ lovd", "General mashup", "Afrobeats"] where sets.contains(where: { $0.name == name }) {
      check("clicked \(name)", await click(name))
    }
    await wait(600)
    await shot("three-groups")
    check("still nothing written", captionBatches() == batches && caption(ids[0]) == before)
    check("clicked the template", await click("Text + hashtags"))
    await wait(600)
    await shot("template-and-groups")
    await key("\r", code: 36)
    await wait(1000)
    await shot("applied")
    check("↩ applied one batch", captionBatches() == batches + 1)
    check("the dialog closed", app.captionDialogIds == nil)
    check("the selection stayed", app.selected(.edit).count == 2)
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

    // Way 1: save the picks as a template, then use it. The Save button clicks through the real form.
    check("the dialog opens again", await click("Caption") && app.captionDialogIds?.count == 2)
    await wait(800)
    for name in ["DJ lovd", "General mashup", "Afrobeats"] { _ = await click(name) }
    check("Save as template opens the form", await click("Save as template"))
    await wait(600)
    await shot("save-as-template")
    await key("\u{1b}", code: 53)
    check("Esc in the form goes back to the dialog", app.captionDialogIds != nil)
    await wait(400)
    await shot("back-from-form")
    check("the picks survive and the form opens again", await click("Save as template"))
    await wait(600)
    func field(_ v: NSView) -> NSTextField? {
      if let f = v as? NSTextField, f.placeholderString == "e.g. Mashup" { return f }
      for c in v.subviews { if let hit = field(c) { return hit } }
      return nil
    }
    if let f = field(host) {
      window.makeFirstResponder(f)
      await wait(150)
      if let e = f.currentEditor() as? NSTextView { for ch in "My mashup" { e.insertText(String(ch), replacementRange: e.selectedRange()) } }
      await wait(300)
    }
    check("↩ in the Name field saves it", { (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:))); return true }())
    await wait(800)
    await shot("template-saved")
    let made = (try? store.captionTemplates())?.first { $0.name == "My mashup" }
    check("the template carries the tags", made?.template == "{text}\n\n\(want) {hashtags}")
    check("still nothing written to the clips", caption(ids[0]) == before)
    await key("\r", code: 36)
    await wait(1000)
    await shot("template-applied")
    for id in ids {
      let title = (try? store.video(id: id)?.displayName) ?? ""
      check("\(title): the saved template on its own gives the same caption", caption(id) == "\(title)\n\n\(want)")
    }

    // A mixed selection: one clip has Piano and a caption Eric wrote, one has neither, one has a scheduled post.
    let mixed = Array(app.videos.filter { $0.state == .needsEdit && $0.type == .short }.prefix(5).dropFirst(2).map(\.id))
    guard mixed.count == 3, let piano = sets.first(where: { $0.name == "Piano" }) else {
      check("three more clips and a Piano group", false)
      return 1
    }
    _ = try? app.bulk.setHashtagSets([mixed[0]], [piano.id])
    if var v = try? store.versions(videoId: mixed[0]).first { v.caption = "Written by hand\n#amapiano"; try? store.save(v, videoId: mixed[0]) }
    _ = try? store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('bulk-post',?,'tiktok',1,1,'regular',0,'planned','manual',0,0)
      """, [mixed[2]])
    let held = caption(mixed[2])
    app.refreshNow()
    app.selectAll(.edit, ids: mixed)
    await wait(800)
    check("the dialog opens on the mixed selection", await click("Caption") && app.captionDialogIds?.count == 3)
    await wait(800)
    await shot("mixed-selection")
    _ = await click("Short")
    _ = await click("Piano")
    await wait(600)
    await shot("mixed-template-piano")
    let untouched = caption(mixed[1])
    await key("\u{1b}", code: 53)
    check("Esc closes the dialog and keeps the selection", app.captionDialogIds == nil && app.selected(.edit).count == 3)
    await wait(600)
    check("Esc wrote nothing", caption(mixed[1]) == untouched && !untouched.contains("#amapiano"))
    check("the dialog opens again", await click("Caption"))
    await wait(800)
    _ = await click("Short")
    _ = await click("Piano")
    await wait(600)
    await key("\r", code: 36)
    await wait(1000)
    await shot("mixed-applied")
    check("Piano is now on the clip that lacked it", caption(mixed[1]).contains("#amapiano"))
    check("the written caption was replaced by the template", !caption(mixed[0]).contains("Written by hand"))
    check("the clip with a post stayed byte-identical", caption(mixed[2]) == held)
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("bulk-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
