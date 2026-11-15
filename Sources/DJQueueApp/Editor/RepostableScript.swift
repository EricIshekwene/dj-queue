import AppKit
import DJQCore
import SwiftUI

/// `DJQ_REPOSTABLE_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 37's one repost control end to end
/// in the REAL main window with the REAL `AppModel`, on a throwaway copy of the database. The editor has only Posts (no
/// "Ready to repost", no Repost switch); a real click on Posts + makes a version post twice; the bulk Mark repostable /
/// not repostable asks first (its sheet drawn in the window), changes the plan, and Undo brings it back; Filters › Reposts
/// and ⌘K "repostable" find the clips. Native menus can't run off screen, so the menu item's call is the stand-in (said so
/// in the log). Exits 1 on a FAIL.
@MainActor
enum RepostableScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    try? script.log.joined(separator: "\n").write(to: out.appendingPathComponent("repostable-checks-\(appearance).txt"),
                                                  atomically: true, encoding: .utf8)
    print("repostable-script: \(script.failed) failed, \(script.passed) passed")
    return script.failed == 0 ? 0 : 1
  }

  /// What marking a version must leave alone.
  struct Baseline: Equatable {
    var state: VideoState
    var sent: Bool
    var stage: ClipStage?
    var slots: Int
    var posts: Int
  }

  @MainActor
  private final class Runner {
    let store: Store, out: URL, appearance: String
    var log: [String] = []
    var failed = 0, passed = 0, step = 0
    var app: AppModel!
    var window: NSWindow!
    var clip = ""
    var baseline: Baseline?

    init(store: Store, out: URL, appearance: String) { self.store = store; self.out = out; self.appearance = appearance }

    func note(_ s: String) { print("repostable-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if ok { passed += 1 } else { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }
    var editor: EditorModel? { EditorModel.live }

    // MARK: Window

    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in w: NSWindow) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        w.sendEvent(e)
      }
    }

    /// Clicks the control marked `label` in `w` (the main window by default), scrolled into view first.
    @discardableResult func click(_ label: String, in w: NSWindow? = nil) async -> Bool {
      let w = w ?? window!
      guard let root = w.contentView, let a = anchor(root, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      a.scrollToVisible(a.bounds)
      await wait(250)
      let f = a.convert(a.bounds, to: nil)
      let p = NSPoint(x: f.midX, y: f.midY)
      mouse(.leftMouseDown, p, in: w)
      await wait(40)
      mouse(.leftMouseUp, p, in: w)
      await wait(700)
      return true
    }

    func has(_ label: String) -> Bool { window.contentView.flatMap { anchor($0, ScriptAnchor.prefix + label) } != nil }

    func commandZ() async {
      guard let k = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                     isARepeat: false, keyCode: 6), let e = editor else { return }
      check("⌘Z reaches the editor's history", EditorUndoKeys.handle(k, model: e))
      await wait(800)
    }

    var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

    /// The window as the window server draws it (off every display); the view tree on a locked Mac.
    func capture(_ w: NSWindow) async -> Data? {
      if screenLocked, let host = w.contentView {
        note("screen locked: capture is the view tree")
        w.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
      }
      for _ in 0..<10 {
        Backstage.front(w)
        await wait(250)
        if let data = WindowCapture.png(w), let img = NSBitmapImageRep(data: data)?.cgImage, !Self.isBlank(img) { return data }
        note("blank capture, trying again")
        await wait(1000)
      }
      return nil
    }

    func shot(_ name: String, _ w: NSWindow? = nil) async {
      await wait(450)
      step += 1
      let file = out.appendingPathComponent(String(format: "repostable-%02d-%@-%@.png", step, name, appearance))
      guard let data = await capture(w ?? window), (try? data.write(to: file)) != nil else { check("captured \(name)", false); return }
      note("shot \(file.lastPathComponent)")
    }

    static func isBlank(_ img: CGImage) -> Bool {
      let w = 48, h = 30
      var px = [UInt8](repeating: 0, count: w * h * 4)
      guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
      let first = Array(px.prefix(3))
      return stride(from: 0, to: px.count, by: 4).allSatisfy { i in (0..<3).allSatisfy { abs(Int(px[i + $0]) - Int(first[$0])) < 6 } }
    }

    // MARK: Store


    /// The clip's preview identity over every version (what lists redraw on).
    func stamp() -> String {
      EditorModel.flushLiveAndWait()
      guard let v = (try? store.video(id: clip)) ?? nil, let t = try? store.previewStampTable() else { return "?" }
      return t.stamp(for: v, version: .max)
    }

    func now() -> Baseline? {
      guard let v = (try? store.video(id: clip)) ?? nil else { return nil }
      return Baseline(state: v.state, sent: v.sentToQueue, stage: ClipStage.of(v),
                      slots: ((try? store.planSlots(where: "video_id=?", [clip])) ?? []).count,
                      posts: ((try? store.posts(where: "video_id=?", [clip])) ?? []).count)
    }

    func stageHolds(_ when: String) {
      EditorModel.flushLiveAndWait()
      check("stage, Queue, slots and posts unchanged \(when)", baseline != nil && now() == baseline)
    }

    // MARK: The run

    func count(_ id: String, _ n: Int) -> Int { (try? store.postCount(videoId: id, version: n)) ?? -1 }
    func repostable(_ id: String) -> Bool { (try? store.isRepostable(videoId: id)) ?? false }
    func slots(_ id: String) -> [PlanSlot] { (try? store.planSlots(where: "video_id=?", [id])) ?? [] }

    /// Opens the bulk sheet through the menu item's own call, checks it, shoots it and confirms it.
    func markRepostable(_ ids: [String], _ on: Bool, _ name: String) async {
      guard let a = app else { return }
      note("stand-in: “Mark \(on ? "" : "not ")repostable” through the menu item's call (native menus can't run off screen)")
      a.markRepostable(ids, on)
      await wait(1500)
      check("the bulk sheet asks first (\(a.pendingBulk?.request.title ?? "none"))", a.pendingBulk?.request.title.contains(on ? "repostable?" : "not repostable?") == true)
      await shot(name)
      a.confirmPendingBulk()
      await wait(2500)
      EditorModel.flushLiveAndWait()
    }

    func main() async {
      let a = AppModel(store: store)
      app = a
      a.refreshNow()
      a.loaded = true
      a.screen = .edit
      let shorts = a.editList.filter { $0.type == .short && !$0.missing }
      guard let v = shorts.first, let other = shorts.first(where: { $0.id != v.id }) else { check("two Edit clips", false); return }
      clip = v.id
      note("clip \(v.id.prefix(8)) “\(a.displayName(v))”")
      check("the clip starts posting each version once", !repostable(clip) && count(clip, 1) == 1)
      EditorDisclosures.shared.closeAll()
      baseline = now()

      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      window = w
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }

      // 1. The editor: Posts is the one repost control.
      a.openEditor(clip, in: [clip, other.id])
      await wait(3500)
      guard let e = editor, e.videoId == clip else { check("the real editor is open", false); return }
      e.zonePlatforms = []
      e.canvasMode = .zones
      await wait(800)
      if e.versionNumbers.count < 2 {
        note("stand-in: New version through the model (the version list is a native popover)")
        e.newVersion(copying: 1)
        e.updateVersion(coalesce: false) { $0.text = "Repost hook v2" }
        await wait(900)
      }
      check("no Ready to repost row and no Repost switch, only Posts", !has("Repost ready") && !has("Repost switch") && has("Post count"))
      await shot("editor-posts-only")
      let stampBefore = stamp()
      // The + end of the stepper (a real click).
      if let root = w.contentView, let anchorView = anchor(root, ScriptAnchor.prefix + "Post count") {
        let f = anchorView.convert(anchorView.bounds, to: nil)
        let p = NSPoint(x: f.maxX - 12, y: f.midY)
        mouse(.leftMouseDown, p, in: w); await wait(40); mouse(.leftMouseUp, p, in: w); await wait(900)
      }
      let n = e.versionNo
      check("click + on Posts → v\(n) posts twice (its own count)", count(clip, n) == 2 && e.ownPostCount(n) == 2)
      check("…the clip now reads repostable", repostable(clip))
      check("…and how it looks didn't change (preview stamp)", stamp() == stampBefore)
      stageHolds("after Posts +")
      await shot("editor-posts-twice")
      e.setPostCount(n, nil)
      await wait(700)
      check("back to once", count(clip, n) == 1 && !repostable(clip))
      e.flushAndWait()
      a.closeEditor()
      await wait(900)

      // 2. Edit: Mark repostable on two clips (asks first), then Undo.
      a.refreshNow()
      await wait(600)
      let both = [clip, other.id]
      await markRepostable(both, true, "edit-mark-repostable-sheet")
      let times = max(1, (try? store.settings().postsPerVersion) ?? 2)
      check("both clips repostable, every version \(times) times", both.allSatisfy { repostable($0) && count($0, 1) == times })
      stageHolds("after Mark repostable (an Edit clip stays in Edit)")
      a.refreshNow()
      await wait(700)
      ListPrefs.shared.setFilter(.edit, ListFilterKey.repost, RepostFilter.ready.rawValue)
      await wait(900)
      check("Edit › Filters › Reposts: Repostable → the two clips", Set(a.listScope(.edit, a.editList).map(\.id)) == Set(both))
      await shot("edit-filter-repostable")
      ListPrefs.shared.setFilter(.edit, ListFilterKey.repost, nil)
      let hits = Set(a.searchIndex.search(SearchQuery("repostable")).filter { $0.kind == .clip }.map(\.id))
      check("⌘K “repostable” finds both", Set(both.map { SearchId.clip($0) }).isSubset(of: hits))
      a.openSearch("repostable")
      await wait(1200)
      await shot("search-repostable")
      a.closePalette()
      await wait(500)
      a.undoLast()
      await wait(2500)
      check("Undo → neither clip is repostable again", both.allSatisfy { !repostable($0) && count($0, 1) == 1 })

      // 3. Queue: Mark repostable gives the reposts days; not repostable takes them off.
      a.screen = .queue
      await wait(1200)
      let queued = a.queueClips.filter { $0.type == .short && !$0.missing }.prefix(2).map(\.id)
      if queued.count == 2 {
        _ = try? Planner(store: store).autoSchedule()
        let before = queued.map { slots($0).count }
        await markRepostable(Array(queued), true, "queue-mark-repostable-sheet")
        _ = try? Planner(store: store).autoSchedule()
        a.refreshNow()
        await wait(1200)
        let after = queued.map { slots($0).count }
        check("Queue: the reposts got days (\(before) → \(after) days)", zip(before, after).allSatisfy { $1 > $0 })
        await shot("queue-repostable")
        await markRepostable(Array(queued), false, "queue-not-repostable-sheet")
        _ = try? Planner(store: store).autoSchedule()
        a.refreshNow()
        await wait(900)
        check("Not repostable → back to one day per version (\(queued.map { slots($0).count }))",
              queued.map { slots($0).count } == before)
      } else {
        note("this copy has fewer than two Queue clips: the Queue part is skipped")
      }
      ListPrefs.shared.reset()
      a.screen = .edit
      await wait(600)
      await bulk(other.id)
    }

    /// Eric: a bulk edit applies to every version except captions, and the bulk UI says so.
    func bulk(_ other: String) async {
      guard let a = app, let s = try? store.settings() else { return }
      let ids = [clip, other]
      func raw(_ n: Int) -> Version? { ((try? store.versions(videoId: clip)) ?? []).first { $0.number == n } }
      func resolved(_ n: Int) -> ResolvedVersion? { (try? store.resolvedVersion(videoId: clip, number: n, settings: s)) ?? nil }
      // v2 gets its own text look, and takes its caption from v1.
      if var v2 = raw(2) { v2.style = .outline; v2.size = 80; try? store.save(v2, videoId: clip) }
      a.refreshNow()
      await wait(600)
      guard let before = resolved(2) else { check("v2 readable", false); return }
      let v2Text = before.text
      let face = BulkActions.CaptionFace(before)
      let shown = { (r: ResolvedVersion) -> String in
        guard let v = (try? self.store.video(id: self.clip)) ?? nil else { return "" }
        return Captions.sharedCaption(version: r, video: v, sessionName: ((try? self.store.session(id: v.sessionId)) ?? nil)?.name ?? "",
                                      sets: (try? self.store.hashtagSets()) ?? [], templates: (try? self.store.captionTemplates()) ?? [],
                                      settings: s)
      }
      let captionBefore = shown(before)
      // Round 27: v2 was made as a copy of v1 and holds its own caption from then on.
      check("v2 holds its own copy of v1's caption before the bulk edit", raw(2)?.standalone == true && before.inherited.isEmpty)

      // The Caption dialog says captions change on v1 only.
      a.screen = .edit
      a.captionDialogIds = ids
      await wait(1500)
      check("Caption dialog: the versions note shows", has("Bulk versions note"))
      await shot("bulk-caption-versions-note")
      a.captionDialogIds = nil
      await wait(500)
      let current = resolved(1)?.captionTemplateId ?? s.defaults.captionTemplateId
      guard let other = ((try? store.captionTemplates()) ?? []).first(where: { $0.id != current }) else { check("a second caption template", false); return }
      _ = try? a.bulk.setCaptionTemplate(ids, other.id)
      EditorModel.flushLiveAndWait()
      check("bulk caption template → v1 uses “\(other.name)”", resolved(1)?.captionTemplateId == other.id)
      check("…and v2's caption is exactly as it was", resolved(2).map { BulkActions.CaptionFace($0) == face && shown($0) == captionBefore } == true)
      check("…and v2 still has its own text", resolved(2)?.text == v2Text)

      // Reset to defaults (Text + Caption) asks first and says what reaches every version.
      a.pipelineBulk("Apply defaults (text, caption) to 2 clips?", verb: "Apply defaults", ids: ids,
                     changes: [.init(field: "Text", value: "Default"), .init(field: "Caption", value: "Default")], done: "Defaults applied",
                     versionScope: .of([.text, .caption]), keepsWords: true) { b, dry in
        try b.applyDefaults(ids, sections: [.text, .caption], dryRun: dry)
      }
      await wait(1800)
      check("Reset to defaults: the versions note shows in the sheet", a.pendingBulk != nil && has("Bulk versions note"))
      await shot("bulk-reset-versions-note")
      a.confirmPendingBulk()
      await wait(2000)
      EditorModel.flushLiveAndWait()
      check("reset → v2's text look is back to the default", raw(2)?.style == nil && raw(2)?.size == nil)
      check("reset → v2 keeps its words", resolved(2)?.text == v2Text)
      check("reset → v2's caption is still exactly as it was", resolved(2).map { BulkActions.CaptionFace($0) == face && shown($0) == captionBefore } == true)
      check("reset → v1's caption follows the defaults", resolved(1)?.captionTemplateId == nil)
      check("the clip is still in Edit (no bulk edit sends it to Queue)", now()?.stage == .edit && now()?.sent == false)
      await shot("after-bulk")
    }
  }
}
