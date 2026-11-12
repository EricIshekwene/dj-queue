import AppKit
import DJQCore
import SwiftUI

/// `DJQ_EDITOR_DEFAULTS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 29. Drives "Make default for new
/// clips…" in the real editor with the real `AppModel` journal on a throwaway copy of the dev database, clicking the form's own
/// controls in this window only. Saves `def-NN-<step>-<appearance>.png` and `def-checks-<appearance>.txt`.
@MainActor
enum EditorDefaultsScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("defaults-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    guard ids.count >= 3 else { note("needs three clips"); return 1 }
    let scheduled = ids.first { $0 != video } ?? ids[0], fresh = ids.last { $0 != video && $0 != scheduled } ?? ids[0]
    for g in (try? store.hashtagSets()) ?? [] { try? store.deleteHashtagSet(g.id) }
    try? store.save(HashtagSet(id: "piano", name: "Piano", category: "Mine", tags: ["#amapiano", "#piano"], sort: 0))
    try? store.save(HashtagSet(id: "house", name: "House", category: "Mine", tags: ["#afrohouse"], sort: 1))
    if var st = try? store.settings() {
      st.defaults.hashtagSetIds = []
      st.defaults.extraHashtags = []
      st.defaults.captionTemplateId = "set-link"
      st.defaults.platforms = Set(Platform.allCases)
      try? store.save(st)
    }
    for id in [video, scheduled, fresh] {
      _ = try? store.db.run("DELETE FROM versions WHERE video_id=?", [id])
      _ = try? store.db.run("DELETE FROM edits WHERE video_id=?", [id])
    }
    _ = try? store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('def-post',?,'tiktok',1,1,'regular',0,'planned','manual',0,0)
      """, [scheduled])
    func caption(_ id: String, _ p: Platform = .tiktok) -> String {
      guard let v = try? store.video(id: id), let r = try? store.resolvedVersion(videoId: id, number: 1),
            let name = try? store.session(id: v.sessionId)?.name, let sets = try? store.hashtagSets(),
            let templates = try? store.captionTemplates(), let settings = try? store.settings() else { return "?" }
      return Captions.caption(for: p, version: r, video: v, sessionName: name, sets: sets, templates: templates, settings: settings)
    }
    func posting(_ id: String) -> Set<Platform> {
      guard let d = (try? store.settings())?.defaults, let e = try? store.edit(videoId: id) else { return [] }
      return Set(Platform.allCases.filter { !e.isSkipped($0, defaults: d) })
    }
    func defaults() -> NewClipDefaults { (try? store.settings())?.defaults ?? NewClipDefaults() }

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
    Backstage.show(window)
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
      let file = out.appendingPathComponent(String(format: "def-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    /// Clicks the control marked `label`, scrolled into view first.
    @discardableResult func click(_ label: String) async -> Bool {
      guard let a = EditorKeysScript.anchors(in: host, named: label).first else { note("no control “\(label)”"); return false }
      a.scrollToVisible(a.bounds)
      await wait(300)
      let f = a.convert(a.bounds, to: nil)
      // The anchor fills its control's background; a checkbox's box sits at its leading edge.
      let p = label.hasPrefix("Default ") ? NSPoint(x: f.minX + 8, y: f.maxY - 10) : NSPoint(x: f.midX, y: f.midY)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
        await wait(40)
      }
      await wait(500)
      return true
    }

    /// Checkboxes and switches use SwiftUI tap gestures, which events sent to a backstage window don't reach (buttons do), and
    /// SwiftUI builds no accessibility tree without a client. They run the closure the control calls, scrolled into view first,
    /// and the log says so.
    func press(_ anchor: String, _ action: () -> Void) async {
      if let a = EditorKeysScript.anchors(in: host, named: anchor).first { a.scrollToVisible(a.bounds) } else { note("no control “\(anchor)”") }
      await wait(300)
      note("stand-in: “\(anchor)” runs its control's action (tap gestures don't get backstage events)")
      action()
      await wait(500)
    }

    // 1. The way in sits at the foot of the Caption section.
    check("the button is there", !EditorKeysScript.anchors(in: host, named: "Make default").isEmpty)
    await click("Make default")
    check("everything is already the default: nothing is ticked", model.defaultsForm?.picked.isEmpty == true)
    await shot("form-all-default")
    model.defaultsForm = nil
    await wait(400)

    // 2. This clip's own setup: a template, a group, an extra tag.
    model.setCaptionTemplate("short")
    model.setGroup("piano", on: true)
    model.setExtraHashtags(["#djlovd"])
    model.flushAndWait()
    await wait(800)
    let scheduledBefore = caption(scheduled), freshBefore = caption(fresh)
    let freshWhere = posting(fresh), scheduledWhere = posting(scheduled)
    await click("Make default")
    let picked = model.defaultsForm?.picked ?? []
    check("the form opens with what differs ticked", picked == [.template, .groups, .extra])
    check("the clips it would reach are counted", (model.defaultsForm?.reach.follow.count ?? 0) >= 1)
    check("the scheduled clip is counted as held", model.defaultsForm?.reach.held.contains(scheduled) == true)
    if let a = EditorKeysScript.anchors(in: host, named: "Save defaults").first { a.scrollToVisible(a.bounds) }
    await shot("form-open")
    await press("Default extra") { model.toggleDefaultPart(.extra) }
    check("a click unticks a part", model.defaultsForm?.picked.contains(.extra) == false)
    await shot("form-extra-off")
    await press("Default extra") { model.toggleDefaultPart(.extra) }
    check("and ticks it again", model.defaultsForm?.picked.contains(.extra) == true)
    await click("Save defaults")
    let d = defaults()
    check("the template is the default", d.captionTemplateId == "short")
    check("the group is the default", d.hashtagSetIds == ["piano"])
    check("the extra tag is the default", d.extraHashtags == ["#djlovd"])
    check("the form closes", model.defaultsForm == nil)
    check("the toast has Undo", app.toast?.actionTitle == "Undo")
    check("a clip you already have keeps its caption", caption(fresh) == freshBefore)
    check("the scheduled caption didn't move", caption(scheduled) == scheduledBefore)
    check("this clip's caption didn't move", model.mainCaption.contains("#piano") && model.mainCaption.contains("#djlovd"))
    check("this clip now reads Default", model.resolved.isDefault("captionTemplateId") && model.resolved.isDefault("hashtagSetIds")
      && model.resolved.isDefault("extraHashtags"))
    await shot("saved-toast")
    await click("Make default")
    check("now nothing differs", model.defaultsForm?.picked.isEmpty == true)
    await shot("form-now-default")
    model.defaultsForm = nil
    await wait(400)

    // 3. Platforms, with the switch on: clips without posts follow, the scheduled one keeps where it posts.
    model.setPosting(.x, false)
    model.setPosting(.threads, false)
    model.flushAndWait()
    await wait(600)
    await click("Make default")
    check("only the platforms are ticked", model.defaultsForm?.picked == [.platforms])
    let wouldFollow = model.defaultsForm?.reach.follow.contains(fresh) == true
    check("the fresh clip would follow", wouldFollow)
    await press("Update existing") { model.defaultsForm?.updateExisting = true }
    check("the switch turns on", model.defaultsForm?.updateExisting == true)
    await shot("form-platforms-update")
    await click("Save defaults")
    check("new clips skip X and Threads", !defaults().platforms.contains(.x) && !defaults().platforms.contains(.threads))
    check("the fresh clip follows", posting(fresh) == freshWhere.subtracting([.x, .threads]))
    check("the scheduled clip keeps where it posts", posting(scheduled) == scheduledWhere)
    check("this clip still skips X and Threads, now as the default", !model.posting(.x) && !model.posting(.threads) && model.isDefault(.platforms))
    check("the scheduled caption still didn't move", caption(scheduled) == scheduledBefore)
    await shot("saved-platforms")

    note(failed == 0 ? "all passed" : "\(failed) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("def-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    model.flushAndWait()
    return failed == 0 ? 0 : 1
  }
}
