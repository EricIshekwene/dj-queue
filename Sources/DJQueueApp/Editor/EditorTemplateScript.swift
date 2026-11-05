import AppKit
import DJQCore
import SwiftUI

/// `DJQ_EDITOR_TEMPLATE_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): v0.8.3. Drives the real editor with the
/// real `AppModel` journal on a throwaway copy of the dev database, the way `EditorGroupScript` does: clicks and keys go to this
/// window only and every check reads the store or the field. Saves `tpl-NN-<step>-<appearance>.png` and `tpl-checks-<appearance>.txt`.
@MainActor
enum EditorTemplateScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("template-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    guard ids.count >= 3 else { note("needs three clips"); return 1 }
    let scheduled = ids.first { $0 != video } ?? ids[0], fresh = ids.last { $0 != video && $0 != scheduled } ?? ids[0]
    for g in (try? store.hashtagSets()) ?? [] { try? store.deleteHashtagSet(g.id) }
    if var st = try? store.settings() {
      st.defaults.hashtagSetIds = []
      st.defaults.captionTemplateId = "set-link"
      try? store.save(st)
    }
    for id in [video, scheduled, fresh] { _ = try? store.db.run("DELETE FROM versions WHERE video_id=?", [id]) }
    _ = try? store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('tpl-post',?,'tiktok',1,1,'regular',0,'planned','manual',0,0)
      """, [scheduled])
    func posted() -> String {
      guard let v = try? store.video(id: scheduled), let r = try? store.resolvedVersion(videoId: scheduled, number: 1),
            let name = try? store.session(id: v.sessionId)?.name, let sets = try? store.hashtagSets(),
            let templates = try? store.captionTemplates(), let settings = try? store.settings() else { return "?" }
      return Captions.caption(for: .tiktok, version: r, video: v, sessionName: name, sets: sets, templates: templates, settings: settings)
    }
    func defaultId() -> String? { (try? store.settings())?.defaults.captionTemplateId }

    let app = AppModel(store: store)
    app.refreshNow()
    app.editorSession = try? app.bulk.begin("editor", ids: [video])
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: video)
    model.appHooks.beforeGroupWrite = { app.splitEditorSession() }
    model.appHooks.afterGroupEdit = { app.groupEdited($0, message: $1) }
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    await wait(3000)
    model.canvasMode = .preview
    model.previewPlatform = .instagram
    model.scrollTarget = .caption
    await wait(1000)

    var step = 0
    func shot(_ name: String) async {
      await wait()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "tpl-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func click(_ p: NSPoint) async {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait()
    }
    func captionView() -> NSTextView? {
      EditorCaptionScript.textViews(in: host).first { !$0.isFieldEditor && $0.isEditable && $0.string == model.mainCaption }
    }
    /// The action sits between the Template dropdown and the Caption label, just above the caption field.
    func clickUnderTemplate() async {
      guard let c = captionView() else { note("no caption field"); return }
      let f = c.convert(c.bounds, to: nil)
      await click(NSPoint(x: f.minX + 40, y: f.maxY + 70))
    }

    // Set as default
    check("no action on the default template", model.defaultCandidate == nil)
    await shot("default-no-action")
    let postedBefore = posted(), freshBefore = (try? store.versions(videoId: fresh)) ?? []
    model.setCaptionTemplate("short")
    await wait(800)
    check("the action is offered for a chosen template", model.defaultCandidate?.id == "short")
    await shot("set-as-default-visible")
    await clickUnderTemplate()
    await wait(800)
    check("the button sets the default", defaultId() == "short")
    check("the label follows at once", model.defaults.captionTemplateId == "short")
    check("the action goes away", model.defaultCandidate == nil)
    check("the toast has Undo", app.toast?.actionTitle == "Undo")
    check("the scheduled caption didn't move", posted() == postedBefore)
    check("the scheduled clip is on the old template", (try? store.versions(videoId: scheduled))?.first?.captionTemplateId == "set-link")
    await shot("after-set-toast")
    model.setCaptionTemplate(nil)
    await wait(800)
    await shot("default-label-updated")
    if let s = app.editorSession { check("the session claims nothing but its own edits", (try? app.bulk.commit(s))?.changed.contains(scheduled) != true) }
    app.editorSession = try? app.bulk.begin("editor", ids: [video])

    model.load(fresh)
    await wait(1200)
    check("a new clip uses the new default", model.resolved.captionTemplateId == nil && freshBefore.isEmpty && model.mainCaption == Captions.templateCaption(
      "short", version: model.resolved, video: model.video!, sessionName: model.sessionName, sets: model.sets, templates: model.templates, settings: model.settings))
    await shot("new-clip-uses-it")
    model.load(video)
    await wait(1000)
    let batch = app.undoHistory.entries.last { $0.label.contains("default template") }?.batchId
    if let batch { app.undo(batch: batch) }
    await wait(1500)
    check("Undo puts the default back", defaultId() == "set-link" && model.defaults.captionTemplateId == "set-link")
    check("Undo unpins the scheduled clip", (try? store.versions(videoId: scheduled))?.first?.captionTemplateId == nil && posted() == postedBefore)
    await shot("after-undo")

    note(failed == 0 ? "all passed" : "\(failed) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("tpl-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    model.flushAndWait()
    return failed == 0 ? 0 : 1
  }
}
