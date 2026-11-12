import AppKit
import DJQCore
import SwiftUI

/// `DJQ_REPOST_READY_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 20 "Ready to repost" end to
/// end in the REAL main window with the REAL `AppModel`, on a throwaway copy of the database. Clicks and ⌘Z are events sent
/// to that window only; every check reads the store. It proves marking a version ready never moves, queues or schedules
/// the clip, then shows the Reposts filter and ⌘K finding it.
///
/// The version list is a native popover, which macOS would pull onto a display, so the script shows the same
/// `EditorVersionList` in a second backstage window (a stand-in, said so in the log). Events don't reach a second
/// backstage window, so its switches are pressed through their action; the real click is the inspector row's.
/// New version is made through the model for the same reason. Exits 1 on a FAIL.
@MainActor
enum RepostReadyScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    try? script.log.joined(separator: "\n").write(to: out.appendingPathComponent("repost-checks-\(appearance).txt"),
                                                  atomically: true, encoding: .utf8)
    print("repost-script: \(script.failed) failed, \(script.passed) passed")
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

    func note(_ s: String) { print("repost-script: \(s)"); log.append(s) }
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
      let file = out.appendingPathComponent(String(format: "repost-%02d-%@-%@.png", step, name, appearance))
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

    func ready() -> [Int] {
      EditorModel.flushLiveAndWait()
      return (try? store.repostReadyVersions(videoId: clip)) ?? []
    }

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

    func main() async {
      let a = AppModel(store: store)
      app = a
      a.refreshNow()
      a.loaded = true
      a.screen = .edit
      let shorts = a.editList.filter { $0.type == .short && !$0.missing }
      // A clip with one version (the seed may give some Edit clips a v2 already), and any other Edit clip.
      let single = shorts.filter { ((try? store.versions(videoId: $0.id)) ?? []).allSatisfy { $0.number == 1 } }
      if single.isEmpty, let first = shorts.first {
        // Every Edit clip in this seed has a v2 already: this scratch copy's first one goes back to v1 only.
        for n in ((try? store.versions(videoId: first.id)) ?? []).map(\.number) where n > 1 { try? store.deleteVersion(videoId: first.id, number: n) }
        note("every Edit clip had a v2: \(first.id.prefix(8))'s later versions were removed in this scratch copy")
        a.refreshNow()
      }
      let ones = a.editList.filter { $0.type == .short && !$0.missing && ((try? store.versions(videoId: $0.id)) ?? []).allSatisfy { $0.number == 1 } }
      guard let v = ones.first, let other = shorts.first(where: { $0.id != v.id }) else { check("an Edit clip with one version, and another", false); return }
      clip = v.id
      note("clip \(v.id.prefix(8)) “\(a.displayName(v))”")
      check("the clip starts with no version ready", ready().isEmpty)
      EditorDisclosures.shared.closeAll()
      baseline = now()

      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      window = w
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }

      a.openEditor(clip, in: [clip, other.id])
      await wait(3500)
      guard let e = editor, e.videoId == clip else { check("the real editor is open", false); return }
      e.zonePlatforms = []
      e.canvasMode = .zones
      await wait(800)

      // 1. One version: no row in the inspector (the version list still has the switch).
      check("one version: no Ready to repost row in the inspector", !has("Repost ready"))
      await shot("one-version")

      // 1b. Undo of a mark on a clip whose v1 was never saved clears it again (review r2).
      if ((try? store.versions(videoId: clip)) ?? []).isEmpty {
        e.setRepostReady(1, true)
        await wait(500)
        check("v1 with no saved row: marked", ready() == [1])
        await commandZ()
        check("…⌘Z clears it in the store and the editor", ready().isEmpty && !e.isRepostReady(1))
      } else {
        note("clip already has a saved v1: the never-saved-v1 undo case isn't driven on this clip")
      }

      // 2. A second version (stand-in: the model's New version; the list is a popover) shows the row, off.
      note("stand-in: New version through the model (the version list is a native popover)")
      e.newVersion(copying: 1)
      e.updateVersion(coalesce: false) { $0.text = "Repost hook v2" }
      await wait(900)
      check("two versions: the row shows for v2, off", e.versionNo == 2 && has("Repost ready") && !e.isRepostReady(2))
      await shot("v2-row-off")

      // 3. A real click turns v2 on: stored on v2 only; nothing else about the clip moves, and list previews don't redraw.
      let stampBefore = stamp()
      await click("Repost ready")
      check("click → v2 ready to repost in the store", ready() == [2])
      check("v1 isn't marked by v2's switch", !e.isRepostReady(1))
      check("the clip's preview stamp didn't move (no preview redraw)", stamp() == stampBefore)
      stageHolds("after marking v2")
      await shot("v2-ready")

      // 4. v1 too, then off again, and ⌘Z brings it back.
      e.selectVersion(1)
      await wait(700)
      await click("Repost ready")
      check("click on v1's row → v1 and v2 ready", ready() == [1, 2])
      await click("Repost ready")
      check("click again → v1 off, v2 still ready", ready() == [2])
      let stampMid = stamp()
      await commandZ()
      check("⌘Z → v1 ready again", ready() == [1, 2])
      check("…and the undo didn't re-save the versions (preview stamp unchanged)", stamp() == stampMid)
      stageHolds("after v1 on, off and undo")
      e.selectVersion(2)
      await wait(600)
      await shot("header-check-v2")

      // 5. The version list (stand-in window for the popover): each row has its own switch.
      let list = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 340, height: 300), [.titled, .fullSizeContentView])
      list.titlebarAppearsTransparent = true
      list.appearance = w.appearance
      list.isReleasedWhenClosed = false
      let hc = NSHostingController(rootView: EditorVersionList(model: e) { _ in })
      hc.sceneBridgingOptions = []
      list.contentViewController = hc
      list.setContentSize(NSSize(width: 340, height: 300))
      Backstage.show(list)
      defer { list.orderOut(nil); list.close() }
      note("stand-in: the version list in its own backstage window (the real one is a native popover)")
      await wait(1500)
      await shot("version-list-both-ready", list)
      // A second backstage window gets no events here, so the row switches are pressed through the call their button
      // makes (the same `setRepostReady` the inspector row's real click went through above).
      note("stand-in: version-list switches pressed through their action (events don't reach a second backstage window)")
      e.setRepostReady(1, false)
      await wait(700)
      check("version list: v1's switch → v1 off, the row says so", ready() == [2] && !e.isRepostReady(1))
      await shot("version-list-v1-off", list)
      e.setRepostReady(1, true)
      await wait(700)
      check("version list: v1's switch again → v1 on", ready() == [1, 2])
      stageHolds("after the version list")

      // 6. The Reposts filter and ⌘K find the clip, and nothing put it in Queue.
      e.flushAndWait()
      a.closeEditor()
      await wait(800)
      a.refreshNow()
      await wait(600)
      check("the app knows v1 and v2 are ready", a.repostReady[clip] == [1, 2])
      a.screen = .library
      ListPrefs.shared.setFilter(.library, ListFilterKey.repost, RepostFilter.ready.rawValue)
      await wait(900)
      let shown = a.listScope(.library, a.libraryAll).map(\.id)
      check("Library › Reposts: Ready to repost → only this clip", shown == [clip])
      await shot("library-filter-ready")
      ListPrefs.shared.setFilter(.library, ListFilterKey.repost, RepostFilter.none.rawValue)
      await wait(400)
      check("Reposts: No version ready → everything else", !a.listScope(.library, a.libraryAll).contains { $0.id == clip })
      ListPrefs.shared.setFilter(.library, ListFilterKey.repost, nil)
      a.screen = .edit
      ListPrefs.shared.setFilter(.edit, ListFilterKey.repost, RepostFilter.ready.rawValue)
      await wait(700)
      check("Edit › Reposts: the clip is still in Edit", a.listScope(.edit, a.editList).map(\.id) == [clip])
      await shot("edit-filter-ready")
      ListPrefs.shared.setFilter(.edit, ListFilterKey.repost, nil)
      let hits = a.searchIndex.search(SearchQuery("ready to repost")).filter { $0.kind == .clip }.map(\.id)
      check("⌘K “ready to repost” finds the clip", hits == [SearchId.clip(clip)])
      a.openSearch("ready to repost")
      await wait(1200)
      await shot("search-ready-to-repost")
      stageHolds("after filters and search")
      ListPrefs.shared.reset()
      a.closePalette()
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
      check("…and v2 still has its own text", resolved(2)?.text == "Repost hook v2")

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
      check("reset → v2 keeps its words", resolved(2)?.text == "Repost hook v2")
      check("reset → v2's caption is still exactly as it was", resolved(2).map { BulkActions.CaptionFace($0) == face && shown($0) == captionBefore } == true)
      check("reset → v1's caption follows the defaults", resolved(1)?.captionTemplateId == nil)
      check("v1 and v2 are still ready to repost", ready() == [1, 2])
      check("the clip is still in Edit (no bulk edit sends it to Queue)", now()?.stage == .edit && now()?.sent == false)
      await shot("after-bulk")
    }
  }
}
