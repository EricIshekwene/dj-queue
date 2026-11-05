import AppKit
import DJQCore
import SwiftUI

/// `DJQ_EDITOR_GROUP_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): makes a hashtag group in the REAL
/// (non-snapshot) editor on a throwaway copy of the dev database, the way `EditorCaptionScript` drives the caption:
/// text goes through the real fields' `NSTextView.insertText`, buttons and keys are events handed to this window only.
/// Nothing reaches the system event queue, so Eric's pointer and apps are never touched, and the window never takes
/// focus. `SnapshotRunner` sets `DJQ_NO_SIGNAL`, so `ChangeSignal` stays inside this process: the installed app is never
/// nudged. Every check reads the field or the store, not the view model's intent. Saves
/// `group-NN-<step>-<appearance>.png` and `checks-<appearance>.txt`, then Settings and New clip defaults on the same database.
@MainActor
enum EditorGroupScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("group-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 600) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // No groups at all, like a fresh install.
    for g in (try? store.hashtagSets()) ?? [] { try? store.deleteHashtagSet(g.id) }
    if var st = try? store.settings() { st.defaults.hashtagSetIds = []; try? store.save(st) }

    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: video)
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    try? await Task.sleep(for: .seconds(3))
    model.resetVersion(["caption", "platformCaptions", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
    model.scrollTarget = .caption
    try? await Task.sleep(for: .seconds(1))

    var step = 0
    func shot(_ name: String) async {
      await wait(500)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "group-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }

    func captionView() -> NSTextView? {
      EditorCaptionScript.textViews(in: host).first { !$0.isFieldEditor && $0.isEditable && $0.string == model.mainCaption }
    }
    func textField(_ placeholder: String) -> NSTextField? { fields(in: host).first { $0.placeholderString == placeholder } }
    /// Clicks into a field and types, keystroke by keystroke, into its real field editor.
    func type(_ text: String, into f: NSTextField) async {
      window.makeFirstResponder(f)
      await wait(100)
      guard let e = f.currentEditor() as? NSTextView else { note("no field editor"); return }
      for ch in text { e.insertText(String(ch), replacementRange: e.selectedRange()); await wait(5) }
      await wait(200)
    }
    /// A mouse click handed to this window, through its real hit testing. SwiftUI buttons have no views of their own,
    /// so the place comes from the groups area's anchor: New group sits bottom-left, Save group bottom-right of the form.
    enum Target { case newGroup, save }
    func click(_ target: Target) async -> Bool {
      guard let a = anchor(in: host) else { return false }
      let f = a.convert(a.bounds, to: nil)
      let p = target == .newGroup ? NSPoint(x: f.minX + 50, y: f.minY + 14) : NSPoint(x: f.maxX - 50, y: f.minY + 26)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait(400)
      return true
    }
    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber, context: nil, characters: chars.lowercased(), charactersIgnoringModifiers: chars,
                       isARepeat: false, keyCode: code)
    }
    /// A key the way AppKit routes it: shortcuts first, then the first responder.
    func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
      guard let e = key(chars, code: code, flags: flags) else { return }
      let shortcut = window.performKeyEquivalent(with: e)
      if !shortcut { window.sendEvent(e) }
      note("key \(code): \(shortcut ? "taken as a shortcut" : "sent to the first responder")")
      await wait(400)
    }
    /// ⌘Z / ⇧⌘Z arrive at the app like a real key: `sendEvent` runs the editor's key monitor.
    func sendKey(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) async {
      guard let e = key(chars, code: code, flags: flags) else { return }
      NSApp.sendEvent(e)
      await wait(400)
    }
    func groups() -> [HashtagSet] { (try? store.hashtagSets()) ?? [] }

    // 1. Empty state: the main path is here.
    check("no groups yet", groups().isEmpty && model.sets.isEmpty)
    await shot("empty")

    // 2. Typing a custom caption; New group is clicked before the typing has even been applied.
    guard let field = captionView() else {
      check("caption field found", false)
      return finish()
    }
    let typedWords = "My own words, still typing"
    field.window?.makeFirstResponder(field)
    field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
    field.insertText(typedWords, replacementRange: field.selectedRange())
    check("New group clicked", await click(.newGroup))
    await wait(400)
    check("form is open", model.groupForm != nil)
    let name = textField("e.g. Piano"), tags = textField("#amapiano #piano")
    check("Name and Hashtags fields are real fields", name != nil && tags != nil)
    check("the keyboard moved to Name", name?.currentEditor() != nil && (window.firstResponder as? NSTextView) === name?.currentEditor())
    check("the caption text is untouched", field.string == typedWords)
    await shot("form-open")

    // 3. Save stays shut until the form makes sense.
    _ = await click(.save)
    check("Save does nothing on a blank form", groups().isEmpty && model.groupForm != nil)
    if let name { await type("Piano", into: name) }
    _ = await click(.save)
    check("Save does nothing without hashtags", groups().isEmpty && model.groupForm != nil)
    if let tags { await type("Amapiano, #PIANO  piano yanos", into: tags) }
    check("typed into the real fields", name?.stringValue == "Piano" && tags?.stringValue == "Amapiano, #PIANO  piano yanos")
    await shot("filled")

    // 4. ↩ saves: group in the shared store, on for this clip, caption updated IN the field, typed words kept.
    await press("\r", code: 36)
    await wait(800)
    let made = groups().first
    check("↩ saved one group in the store", groups().count == 1 && made?.name == "Piano")
    check("tags normalised, no duplicates", made?.tags == ["#amapiano", "#piano", "#yanos"])
    check("form closed", model.groupForm == nil)
    check("group is on for this clip", made.map { model.resolved.hashtagSetIds.contains($0.id) } == true)
    let saved = "\(typedWords)\n#amapiano #piano #yanos"
    check("the field holds the typed words and the tags", field.string == saved)
    check("nothing keeps the keyboard, so ⌘Z is the clip's", !(window.firstResponder is NSTextView))
    await shot("saved-group-on")
    await wait(3200)  // the toast clears

    // 5. ⌘Z / ⇧⌘Z through the editor's real shortcut.
    await sendKey("z", code: 6, flags: .command)
    if field.string != typedWords { note("after ⌘Z: field “\(field.string)”, model “\(model.mainCaption)”, canUndo \(model.canUndo), canRedo \(model.canRedo), first responder \(String(describing: window.firstResponder))") }
    check("⌘Z takes the group off, the field keeps the typed words", field.string == typedWords)
    check("the group itself stays", groups().count == 1 && model.sets.count == 1)
    await shot("undo")
    model.appHooks.isCovered = { true }
    await sendKey("Z", code: 6, flags: [.command, .shift])
    await sendKey("z", code: 6, flags: .command)
    check("while an overlay covers the editor ⌘Z leaves the clip alone", field.string == typedWords)
    model.appHooks.isCovered = nil
    await sendKey("Z", code: 6, flags: [.command, .shift])
    if field.string != saved { note("after ⇧⌘Z: field “\(field.string)”, model “\(model.mainCaption)”, canRedo \(model.canRedo), first responder \(String(describing: window.firstResponder))") }
    check("⇧⌘Z puts it back", field.string == saved)
    await wait(3200)

    // 6. A duplicate name is refused; Esc discards and hands the caption back the keyboard.
    field.window?.makeFirstResponder(field)
    await wait(200)
    _ = await click(.newGroup)
    await wait(300)
    if let n = textField("e.g. Piano") { await type("piano", into: n) }
    if let t = textField("#amapiano #piano") { await type("#other", into: t) }
    await shot("duplicate-name")
    _ = await click(.save)
    check("a duplicate name doesn't save", groups().count == 1 && model.groupForm != nil)
    await press("\u{1b}", code: 53)
    await wait(300)
    check("Esc closes the form", model.groupForm == nil)
    check("Esc discards it", groups().count == 1)
    check("Esc gives the caption the keyboard back", window.firstResponder === field)
    await shot("cancelled")

    // 7. New group at the very bottom of the inspector, under a long caption: the form must come into view.
    let para = "That log drum switch into the second track still gets me every time, live at the Afroween Jazz Piano set. "
    model.updateVersion(coalesce: false) { $0.caption = String(repeating: para, count: 20) }
    model.toast = nil
    await wait(800)
    model.scrollTarget = .caption
    await wait(800)
    if let a = anchor(in: host), let sv = a.enclosingScrollView {
      let f = a.convert(a.bounds, to: sv.contentView), clip = sv.contentView.bounds
      note("anchor in clip \(f), clip \(clip), flipped \(sv.contentView.isFlipped)")
      // Scrolls like a wheel over the inspector (an event built here and handed to this window only).
      let over = window.convertPoint(toScreen: sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil))
      if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(clip.maxY - f.maxY - 4), wheel2: 0, wheel3: 0) {
        cg.location = CGPoint(x: over.x, y: (NSScreen.screens.first?.frame.height ?? 0) - over.y)
        if let e = NSEvent(cgEvent: cg) { sv.scrollWheel(with: e) }
      }
      await wait(800)
      let g = a.convert(a.bounds, to: sv.contentView), now = sv.contentView.bounds
      note("anchor now \(g), clip \(now)")
      check("New group starts at the bottom edge", g.maxY <= now.maxY && g.maxY > now.maxY - 40)
    } else {
      note("no scroll view around the groups")
    }
    check("New group clicked with a long caption", await click(.newGroup))
    await wait(800)
    check("form opened", model.groupForm != nil)
    if let a = anchor(in: host), let sv = a.enclosingScrollView {
      let g = a.convert(a.bounds, to: sv.contentView), now = sv.contentView.bounds
      note("with the form: anchor \(g), clip \(now)")
      check("all of the form is on screen", g.maxY <= now.maxY + 1 && g.minY >= now.minY - 1)
    } else {
      check("all of the form is on screen", false)
    }
    await shot("long-caption-form")
    await press("\u{1b}", code: 53)
    model.flushAndWait()

    // 8. The same database, as Settings sees it — then delete with the app's confirm, and Undo.
    let app = AppModel(store: store)
    app.refreshNow()
    check("Settings' model has the group", app.hashtagSets.contains { $0.id == made?.id })
    SettingsUIState.shared.reset()
    let settings = AnyView(ScrollView { CaptionsSettings(model: app).padding(DS.space.xl) }.background(DS.color.background))
    try? await DSGallerySnapshot.render(settings, size: CGSize(width: 760, height: 620), name: "group-settings-captions", to: out)
    SettingsUIState.shared.scrollTarget = NewClipDefaultsSettings.captionAnchor
    let defaults = AnyView(NewClipDefaultsSettings(model: app, ui: SettingsUIState.shared).padding(DS.space.xl).background(DS.color.background))
    try? await DSGallerySnapshot.render(defaults, size: CGSize(width: 760, height: 900), name: "group-settings-new-clip-defaults", to: out)
    SettingsUIState.shared.reset()
    if let made {
      // This clip now has a scheduled post and follows the template with the group on.
      model.resetVersion(["caption", "platformCaptions", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
      model.setGroup(made.id, on: true)
      model.flushAndWait()
      _ = try? store.db.run("""
        INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
        VALUES('script-post',?,'x',1,1,'regular',0,'planned','manual',0,0)
        """, [video])
      await wait(600)
      let scheduled = model.mainCaption
      app.confirmDeleteGroup(made, undoHint: "Undo on the message that follows brings it back.")
      note("confirm says: \(app.pendingConfirm?.message ?? "nothing")")
      check("delete asks first, with the count", groups().count == 1
            && app.pendingConfirm?.message.contains("1 clip with scheduled or posted posts keeps these tags") == true)
      let confirm = app.pendingConfirm?.action
      app.pendingConfirm = nil
      confirm?()
      await wait(1500)
      check("delete removes it from the store", groups().isEmpty)
      check("the editor's chips follow (ChangeSignal)", model.sets.isEmpty)
      check("the scheduled clip's caption is byte-identical", model.mainCaption == scheduled && scheduled.hasSuffix("#amapiano #piano #yanos"))
      check("its tags are frozen into the extra hashtags", model.resolved.hashtagSetIds.isEmpty
            && model.resolved.extraHashtags == ["#amapiano", "#piano", "#yanos"])
      await shot("deleted-keeps-tags")
      if let b = app.undoHistory.top?.batchId {
        app.undo(batch: b)
        await wait(2000)
      }
      check("Undo brings it back, chips too", groups().count == 1 && model.sets.count == 1)
      check("Undo puts the group back on the clip", model.resolved.hashtagSetIds == [made.id] && model.mainCaption == scheduled)

      // Re-review R1: an edit from the editor with the app's session open. Nothing in the clip was edited, so closing the
      // session journals nothing, the edit has its Undo, and the scheduled caption doesn't move.
      app.editorSession = try? app.bulk.begin("editor", ids: [video])
      model.appHooks.beforeGroupWrite = { app.splitEditorSession() }
      model.appHooks.afterGroupEdit = { app.groupEdited($0, message: $1) }
      if let g = groups().first {
        model.openGroupForm(g)
        check("edit form counts this clip", model.groupForm?.impact?.kept == 1)
        check("edit saves", model.saveGroup(name: g.name, tags: "#amapiano #changed"))
      }
      await wait(800)
      check("the scheduled caption didn't move", model.mainCaption == scheduled)
      check("the edit is in the app's history", app.undoHistory.top?.label.contains("saved") == true)
      if let s = app.editorSession {
        check("closing the session journals no “Edits to …”", (try? app.bulk.commit(s))?.batchId == nil)
      }
      app.editorSession = nil
      model.appHooks.beforeGroupWrite = nil
      model.appHooks.afterGroupEdit = nil

      // Re-review R2: unsaved changes on the clip while something else freezes it (`djq` from another process).
      let other = HashtagGroups.make(name: "Other", tags: ["#other"], existing: groups())
      _ = try? HashtagGroups.create(other, store: store, bulk: BulkActions(store: store))
      ChangeSignal.post()  // as `djq` does after a write
      await wait(800)
      model.setGroup(other.id, on: true)
      model.flushAndWait()
      let frozenCaption = model.mainCaption
      model.setText("Unsaved words")
      check("the change is unsaved", model.saving)
      _ = try? HashtagGroups.delete(other, store: store, bulk: BulkActions(store: store))
      ChangeSignal.post()
      await wait(1500)
      model.flushAndWait()
      let stored = (try? store.versions(videoId: video))?.first
      check("the freeze survives the editor's save", stored?.hashtagSetIds == [] && stored?.extraHashtags?.contains("#other") == true)
      check("Eric's unsaved change survives too", stored?.text == "Unsaved words")
      let tagsBefore = Captions.tags(in: frozenCaption), tagsAfter = Captions.tags(in: model.mainCaption)
      note("tags before the freeze \(tagsBefore), after \(tagsAfter)")
      check("the caption keeps the same tags in the same order", tagsBefore == tagsAfter && tagsAfter.contains("#other"))
    }
    return finish()

    func finish() -> Int32 {
      note(failed == 0 ? "all passed" : "\(failed) failed")
      try? log.joined(separator: "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
      model.flushAndWait()
      return failed == 0 ? 0 : 1
    }
  }

  static func fields(in v: NSView) -> [NSTextField] {
    var out: [NSTextField] = []
    if let t = v as? NSTextField { out.append(t) }
    for s in v.subviews { out += fields(in: s) }
    return out
  }

  private static func anchor(in v: NSView) -> EditorGroupsAnchorView? {
    if let a = v as? EditorGroupsAnchorView { return a }
    for s in v.subviews { if let a = anchor(in: s) { return a } }
    return nil
  }
}
