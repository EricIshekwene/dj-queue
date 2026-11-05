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
    func textField(_ placeholder: String) -> NSTextField? {
      EditorGroupScript.fields(in: host).first { $0.placeholderString == placeholder }
    }
    func type(_ text: String, into e: NSTextView?) async {
      guard let e else { note("no text view"); return }
      window.makeFirstResponder(e)
      e.selectAll(nil)
      e.insertText(text, replacementRange: e.selectedRange())
      await wait(300)
    }
    func type(_ text: String, into f: NSTextField?) async {
      guard let f else { note("no field"); return }
      window.makeFirstResponder(f)
      await wait(100)
      guard let e = f.currentEditor() as? NSTextView else { note("no field editor"); return }
      e.selectAll(nil)
      for ch in text { e.insertText(String(ch), replacementRange: e.selectedRange()) }
      await wait(300)
    }
    func press(return _: Void) async {
      if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                  isARepeat: false, keyCode: 36) {
        window.sendEvent(e)
      }
      await wait(800)
    }
    func templateBody() -> NSTextView? {
      EditorCaptionScript.textViews(in: host).first { !$0.isFieldEditor && $0.isEditable && $0.string == model.templateForm?.template }
    }

    // Set as default
    check("no action on the default template", model.defaultCandidate == nil)
    await shot("default-no-action")
    let postedBefore = posted(), freshBefore = (try? store.versions(videoId: fresh)) ?? []
    model.setCaptionTemplate("short")
    await wait(800)
    check("the action is offered for a chosen template", model.defaultCandidate?.id == "short")
    await shot("set-as-default-visible")
    // Template actions are in a native menu, which would hold this script in its tracking loop: each item's own call instead.
    model.setDefaultTemplate("short")
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

    // Own templates
    model.setCaptionTemplate(nil)
    await wait(600)
    model.openTemplateForm()
    await wait(600)
    check("New template opens the form", model.templateForm != nil)
    await shot("template-form-new")
    await type("Full set plug", into: textField("e.g. Full set plug"))
    await type("{text} #mine\n\n{link}\n{hashtags}", into: templateBody())
    await shot("template-form-filled")
    await type("Short", into: textField("e.g. Full set plug"))
    await wait(300)
    await shot("template-form-duplicate-name")
    await type("Full set plug", into: textField("e.g. Full set plug"))
    await press(return: ())
    let made = ((try? store.captionTemplates()) ?? []).first { $0.name == "Full set plug" }
    check("Return saves the template", made?.template == "{text} #mine\n\n{link}\n{hashtags}")
    check("the form closes", model.templateForm == nil)
    check("it goes on for this clip", model.resolved.captionTemplateId == made?.id)
    check("the field shows it, tag and link", model.mainCaption.contains("#mine") && model.mainCaption.contains(Defaults.captionLink))
    await shot("template-saved-on")

    model.flushAndWait()
    let chosen = ids.first { $0 != video && $0 != scheduled && $0 != fresh } ?? fresh
    var pin = Version(number: 1)
    pin.captionTemplateId = made?.id
    pin.text = "Scheduled words"
    try? store.save(pin, videoId: chosen)
    _ = try? store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('tpl-post-2',?,'instagram',1,1,'regular',0,'planned','manual',0,0)
      """, [chosen])
    func scheduledCaption() -> String {
      guard let v = try? store.video(id: chosen), let r = try? store.resolvedVersion(videoId: chosen, number: 1),
            let name = try? store.session(id: v.sessionId)?.name, let sets = try? store.hashtagSets(),
            let templates = try? store.captionTemplates(), let settings = try? store.settings() else { return "?" }
      return Captions.caption(for: .instagram, version: r, video: v, sessionName: name, sets: sets, templates: templates, settings: settings)
    }
    let frozenBefore = scheduledCaption()
    model.openTemplateForm(model.selectedTemplate)
    check("edit counts the scheduled clip", model.templateForm?.impact?.kept == 1)
    await wait(600)
    await shot("template-form-edit")
    await type("Edited {text}\n{hashtags}", into: templateBody())
    if let f = model.templateForm { check("edit saves", model.saveTemplate(name: f.name, template: "Edited {text}\n{hashtags}")) }
    await wait(800)
    check("this clip follows the edit", model.mainCaption.hasPrefix("Edited"))
    check("the scheduled caption didn't move", scheduledCaption() == frozenBefore)
    await shot("template-edited")
    if let t = made {
      var edited = t
      edited.template = "Edited {text}\n{hashtags}"
      app.confirmDeleteTemplate(edited, undoHint: "Undo on the message that follows brings it back.")
      note("confirm says: \(app.pendingConfirm?.message ?? "nothing")")
      // The edit above froze the scheduled clip, so it no longer builds from this template.
      check("delete asks first, with the count", app.pendingConfirm?.message.contains("1 other clip goes back to the default template") == true)
      let confirm = app.pendingConfirm?.action
      app.pendingConfirm = nil
      confirm?()
      await wait(1500)
      check("delete removes it", ((try? store.captionTemplates()) ?? []).first { $0.id == t.id } == nil)
      check("the scheduled caption survives the delete", scheduledCaption() == frozenBefore)
      check("this clip goes back to the default", model.resolved.captionTemplateId == nil && !model.captionIsWritten)
      await shot("template-deleted")
      if let b = app.undoHistory.top?.batchId { app.undo(batch: b) }
      await wait(1500)
      check("Undo brings it back and on", model.resolved.captionTemplateId == t.id && model.templates.contains { $0.id == t.id })
      check("the scheduled caption still reads the same", scheduledCaption() == frozenBefore)
    }
    if let def = model.templates.first(where: { $0.id == model.defaults.captionTemplateId }) {
      check("the default can't be deleted", CaptionTemplates.blocker(of: def.id, settings: model.settings) != nil)
      app.confirmDeleteTemplate(def, undoHint: "")
      check("deleting it is refused, no dialog", app.pendingConfirm == nil && ((try? store.captionTemplates()) ?? []).contains { $0.id == def.id })
    }
    model.typeCaption("Hand words #typed")
    model.commitCaptionDraft()
    await wait(400)
    model.openSaveAsTemplate()
    check("Save as keeps hand-typed tags", model.templateForm?.template == "Hand words #typed\n\n{hashtags}")
    await shot("template-save-as")
    model.templateForm = nil

    // Part chips, on the caption from Eric's screenshot.
    model.resetCaptionToTemplate()
    model.typeCaption("#djlovd #afrobeats #amapiano")
    model.commitCaptionDraft()
    model.setText("Amarider blend")
    await wait(800)
    func field() -> String { captionView()?.string ?? "?" }
    func values() -> CaptionParts.Values { model.partValues ?? .init(text: "", set: "", link: "", title: nil) }
    func on(_ p: CaptionPart) -> Bool { CaptionParts.isOn(p, in: field(), values()) }
    /// The chips sit in their own row just above the Hashtag groups label.
    func chip(_ p: CaptionPart) async {
      guard let a = EditorGroupScript.anchor(in: host) else { note("no anchor"); return }
      let f = a.convert(a.bounds, to: nil)
      let x: CGFloat = [.text: 24, .set: 76, .link: 128, .title: 184][p] ?? 24
      await click(NSPoint(x: f.minX + x, y: f.maxY + 54))
      await wait(500)
    }
    await shot("parts-eric-caption")
    let start = field()
    await chip(.text)
    check("Text goes above the hashtags", field() == "Amarider blend\n\n#djlovd #afrobeats #amapiano")
    await chip(.link)
    check("Link follows it", field() == "Amarider blend\n\(Defaults.captionLink)\n\n#djlovd #afrobeats #amapiano")
    await chip(.set)
    check("Set lands between them", field().components(separatedBy: "\n")[1] == values().set && on(.link) && on(.text))
    await shot("parts-three-on")
    await chip(.set)
    await chip(.link)
    await chip(.text)
    check("off again restores the exact text", field() == start)
    await shot("parts-all-off")
    await chip(.title)
    check("no title yet: the chip does nothing", field() == start)
    await type("Typed by hand Amarider blend #djlovd #afrobeats #amapiano", into: captionView())
    await wait(600)
    check("a chip follows a hand edit", on(.text))
    check("hand typing stays written", model.captionIsWritten)
    await shot("parts-hand-edit")
    model.resetCaptionToTemplate()
    await wait(500)
    check("↺ goes back to the template", !model.captionIsWritten)
    await shot("parts-on-template")
    await chip(.link)
    check("a chip makes a template caption written", model.captionIsWritten)

    // Hashtag caps: order in the caption is the priority.
    model.flushAndWait()
    app.saveHashtagCap(1, for: .threads)
    await wait(1200)
    await type("Love #amapiano tonight\n\n#djlovd #afrobeats #piano", into: captionView())
    await wait(700)
    check("the field stays whole", model.mainCaption == "Love #amapiano tonight\n\n#djlovd #afrobeats #piano")
    check("Threads keeps the first tag, in the text", model.caption(for: .threads) == "Love #amapiano tonight")
    check("TikTok keeps them all", model.caption(for: .tiktok) == model.mainCaption)
    check("the line says what's dropped", model.capNotes.map(\.message) == ["Threads keeps 1 of 4: drops #djlovd #afrobeats #piano"])
    model.previewPlatform = .threads
    await wait(600)
    await shot("cap-threads-keeps-1-of-4")
    await type("Love tonight\n\n#piano #djlovd #afrobeats", into: captionView())
    await wait(700)
    check("hand edits set the order", model.caption(for: .threads) == "Love tonight\n\n#piano")
    await shot("cap-hand-reorder")
    model.setPlatformCaption(.threads, "Own words #a #b #c")
    model.flushAndWait()
    await wait(600)
    check("an own caption is left as written", model.caption(for: .threads) == "Own words #a #b #c")
    check("and warned about", model.capNotes.first?.own == true)
    model.openPlatformCaption = .threads
    await wait(600)
    await shot("cap-own-caption-warned")
    model.setPlatformCaption(.threads, "")
    model.openPlatformCaption = nil
    model.flushAndWait()
    let capPosted = posted()
    app.saveHashtagCap(0, for: .tiktok)
    await wait(1000)
    check("a cap doesn't move a scheduled caption", posted() == capPosted)
    app.saveHashtagCap(nil, for: .tiktok)
    await wait(600)

    note(failed == 0 ? "all passed" : "\(failed) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("tpl-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    model.flushAndWait()
    return failed == 0 ? 0 : 1
  }
}
