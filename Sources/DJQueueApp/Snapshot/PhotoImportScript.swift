import AppKit
import DJQCore
import SwiftUI

/// `DJQ_PHOTO_IMPORT_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 21): the photo import and photo posts in the lists, in
/// the real main window on the throwaway sample. It picks three pictures and a text file, checks the import sheet and
/// its one switch, adds a carousel, looks at it in Cards, Grid, List, Single and the quick look (stepping to the
/// second photo with a real click), adds a single photo, sends both to the Queue and checks they got there with no
/// score, and that Score never saw them.
///
/// Stand-ins, since macOS puts these on a display: the file picker and a Finder drag (the script calls
/// `model.takePhotos`, which both end in), the quick look's way in (a native menu; the script sets `previewVideo` as
/// the menu does) and the drop outline (its flag). Everything else is a real click or key sent to this window, which
/// sits off every display. Exits 1 on a failed check and saves a capture of each step.
/// `DJQ_PHOTO_IMPORT_SABOTAGE=1` picks two pictures instead of three, to show the checks can fail.
@MainActor
enum PhotoImportScript {
  static func run(model: AppModel, store: Store, out: URL, scratch: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    let sabotage = env["DJQ_PHOTO_IMPORT_SABOTAGE"] != nil
    var failures = 0
    var log: [String] = []
    func note(_ s: String) { print("photo-import-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }
    /// Polls up to `seconds` for `done`.
    func until(_ seconds: Double = 8, _ done: () -> Bool) async -> Bool {
      for _ in 0..<Int(seconds * 10) where !done() { await wait(100) }
      return done()
    }

    model.refreshNow()
    let ui = PhotoImportUI.shared
    let photosBefore = Set(model.videos.filter(\.isPhoto).map(\.id))
    let queueBefore = Set(model.queueClips.map(\.id))
    let scoreBefore = model.sidebarCount(.score)
    note("starts with \(photosBefore.count) photo posts, \(model.editList.count) in Edit, \(queueBefore.count) in the Queue")

    SnapshotContext.resetUI(model)
    model.setViewMode(.wide, for: .edit)
    model.screen = .edit
    let window = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
    window.setContentSize(NSSize(width: Shot.standard.width, height: Shot.standard.height))
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    await wait(1500)

    var step = 0
    func shot(_ name: String) async {
      await wait(900)
      window.displayIfNeeded()
      guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
      view.cacheDisplay(in: view.bounds, to: rep)
      step += 1
      let file = String(format: "photo-%02d-%@-%@.png", step, name, look)
      try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(file))
      note("shot \(file)")
    }
    func find(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = find(c, name) { return hit } }
      return nil
    }
    func anchor(_ label: String) -> NSRect? {
      guard let root = window.contentView, let a = find(root, ScriptAnchor.prefix + label), a.window != nil else { return nil }
      return a.convert(a.bounds, to: nil)
    }
    func has(_ label: String) -> Bool { anchor(label) != nil }
    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                    pressure: type == .leftMouseUp ? 0 : 1) {
        window.sendEvent(e)
      }
    }
    /// A real click in the middle of the control (or `at`, 0…1 across it).
    func click(_ label: String, at x: CGFloat = 0.5) async -> Bool {
      guard let f = anchor(label) else { note("no control “\(label)”"); return false }
      let p = NSPoint(x: f.minX + f.width * x, y: f.midY)
      if env["DJQ_PHOTO_IMPORT_DEBUG"] != nil { note("click “\(label)” at \(Int(p.x)),\(Int(p.y)) in \(f)") }
      mouse(.leftMouseDown, p)
      await wait(40)  // a tap gesture needs a moment between down and up
      mouse(.leftMouseUp, p)
      await wait(700)
      return true
    }
    func key(_ chars: String, code: UInt16) async {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
        if type == .keyDown, window.performKeyEquivalent(with: e) { continue }
        window.sendEvent(e)
      }
      await wait(60)
    }
    func fingerprints(_ files: [URL]) -> [String?] { files.map(PhotoImport.fingerprint) }
    func fresh(_ id: String) -> Video? { try? store.video(id: id) }

    await shot("edit-before")
    check("starts on Edit with the Add photos button", model.screen == .edit && has("Add photos"))

    // 1. Pick three pictures and one file that isn't a picture (stand-in for the file picker and a Finder drag).
    let picked: [URL]
    let notAPhoto = scratch.appendingPathComponent("set-list.txt")
    do {
      picked = try SampleData.photoFiles(store: store, count: sabotage ? 2 : 3, dir: scratch, offset: 2, name: "loft")
      try "not a photo".write(to: notAPhoto, atomically: true, encoding: .utf8)
    } catch {
      note("FAIL couldn't make the sample pictures: \(error)")
      return 1
    }
    let originals = fingerprints(picked)
    note("stand-in: the file picker (a real panel lands on a display); the script hands the same files to model.takePhotos")
    model.takePhotos(picked + [notAPhoto])
    check("several photos open the import sheet", await until { model.photoImportRequest != nil })
    await wait(1200)
    check("the sheet holds the 3 photos, in the order picked", model.photoImportRequest?.files == picked && picked.count == 3)
    check("the sheet shows 3 thumbnails", has("Import photo 1") && has("Import photo 2") && has("Import photo 3") && !has("Import photo 4"))
    check("the text file was refused with the reason", ui.lastSkipped.map(\.file) == [notAPhoto.path]
          && model.toast?.detail?.contains("not a photo format") == true && model.toast?.detail?.contains("set-list.txt") == true)
    check("it says one carousel of 3 photos", has("Import plan: One carousel of 3 photos"))
    check("nothing is imported yet", Set(model.videos.filter(\.isPhoto).map(\.id)) == photosBefore
          && ((try? store.videos(where: "photos IS NOT NULL"))?.count ?? -1) == photosBefore.count)
    await shot("import-sheet")
    model.toast = nil

    // 2. The one switch, on and back off, with real clicks.
    check("A post per photo switches on", await click("A post per photo") && has("Import plan: 3 posts, one photo each"))
    await shot("import-sheet-post-per-photo")
    check("and back to one carousel", await click("A post per photo") && has("Import plan: One carousel of 3 photos"))

    // 3. A title, typed into the field.
    let title = "Loft set"
    if await click("Import title") {
      for c in title { await key(String(c), code: 0) }
      await wait(400)
    }
    await shot("import-sheet-title")

    // 4. Add to Edit.
    check("Add to Edit is there to click", await click("Add to Edit"))
    check("the import finishes and the sheet closes", await until(20) { !ui.importing && model.photoImportRequest == nil && !ui.lastPosts.isEmpty })
    await wait(800)
    model.refreshNow()
    let made = model.videos.filter { $0.isPhoto && !photosBefore.contains($0.id) }
    check("one new post", made.count == 1 && ui.lastPosts == made.map(\.id))
    guard let carousel = made.first else {
      note("FAIL no carousel to go on with")
      await shot("no-carousel")
      return 1
    }
    check("it is a carousel of 3 photos", carousel.photoCount == 3 && carousel.photoLabel == "Carousel · 3")
    check("it has the typed title", carousel.titleText == title)
    check("it is in Edit", model.editList.contains { $0.id == carousel.id } && fresh(carousel.id)?.state == .needsEdit)
    check("it is not in the Queue", !model.queueClips.contains { $0.id == carousel.id } && fresh(carousel.id)?.sentToQueue == false)
    check("it is not on Score", !model.scoreList.contains { $0.id == carousel.id } && model.sidebarCount(.score) == scoreBefore)
    check("it has no score and nothing to fix", carousel.score == nil && (model.issuesByVideo[carousel.id] ?? []).isEmpty)
    check("the picked files are untouched", fingerprints(picked) == originals && picked.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    check("DJ Queue has its own copies", ((try? store.photoURLs(carousel)) ?? []).count == 3
          && ((try? store.photoURLs(carousel)) ?? []).allSatisfy { FileManager.default.fileExists(atPath: $0.path) && !picked.contains($0) })
    check("the toast says what was added, with Open", model.toast?.message == "Added 1 carousel to Edit" && model.toast?.actionTitle == "Open")
    let mark = "Photo mark \(carousel.id) Carousel · 3"
    check("Cards: the card has the Carousel · 3 mark", has(mark))
    await shot("edit-cards-added")
    model.toast = nil

    // 5. The other layouts.
    model.setViewMode(.grid, for: .edit)
    await wait(900)
    check("Grid: the tile has the Carousel · 3 mark", has(mark))
    await shot("edit-grid")
    model.setViewMode(.list, for: .edit)
    await wait(900)
    check("List: the row has the Carousel · 3 mark", has(mark))
    await shot("edit-list")
    ListPrefs.shared.setSearch(.edit, title)
    model.setViewMode(.single, for: .edit)
    await wait(1200)
    check("Single: the carousel starts on photo 1 of 3", has("Photo \(carousel.id) 1 of 3"))
    check("Single: › steps to photo 2", await click("Next photo") && has("Photo \(carousel.id) 2 of 3"))
    await shot("edit-single-photo-2")
    ListPrefs.shared.setSearch(.edit, "")
    model.setViewMode(.wide, for: .edit)
    await wait(600)

    // 6. Quick look, stepping to the second photo.
    note("stand-in: the quick look's way in is a native menu; the script sets previewVideo as that menu item does")
    model.previewVideo = carousel
    await wait(1500)
    check("quick look opens on photo 1 of 3", has("Quick look photo 1 of 3"))
    await shot("quicklook-photo-1")
    check("› steps to photo 2", await click("Next photo") && has("Quick look photo 2 of 3"))
    await shot("quicklook-photo-2")
    check("‹ goes back to photo 1", await click("Previous photo") && has("Quick look photo 1 of 3"))
    model.previewVideo = nil
    await wait(500)
    check("no preview proxy was ever asked for a photo post",
          !model.recentProxyIds.contains { model.video($0)?.isPhoto == true } && model.proxyURLs[carousel.id] == nil && !model.proxyPending.contains(carousel.id))

    // 7. One photo imports straight away, with no sheet.
    let single: URL
    do {
      single = try SampleData.photoFiles(store: store, count: 1, dir: scratch.appendingPathComponent("one"), offset: 11, name: "flyer")[0]
    } catch {
      note("FAIL couldn't make the single picture: \(error)")
      return 1
    }
    ui.lastPosts = []
    model.takePhotos([single])
    check("one photo is added without the sheet", await until(20) { !ui.importing && !ui.lastPosts.isEmpty } && model.photoImportRequest == nil)
    await wait(800)
    model.refreshNow()
    let solo = model.videos.first { $0.isPhoto && !photosBefore.contains($0.id) && $0.id != carousel.id }
    check("it is a single photo post in Edit", solo?.photoCount == 1 && solo?.photoLabel == "Photo" && model.editList.contains { $0.id == solo?.id })
    check("its toast says one photo", model.toast?.message == "Added 1 photo to Edit")
    guard let solo else {
      note("FAIL no single photo post to go on with")
      return 1
    }
    check("its card has the Photo mark", has("Photo mark \(solo.id) Photo"))
    await shot("edit-single-photo-added")
    model.toast = nil

    // 8. The outline a file drag shows (stand-in: a real drag needs the system's drag session).
    note("stand-in: the drop outline's flag is set by hand; a real drag would need the system drag session")
    ui.dropTargeted = true
    await shot("edit-drop-outline")
    ui.dropTargeted = false

    // 9. Select both and Send to Queue. Only this moves them.
    check("nothing has reached the Queue by importing", Set(model.queueClips.map(\.id)) == queueBefore)
    model.setSelection([carousel.id, solo.id], screen: .edit)
    await wait(900)
    await shot("edit-both-selected")
    check("the bar's Send to Queue asks first", await click("Send selected to Queue") && model.pendingBulk != nil)
    check("the dry run says both will go", await until { model.pendingBulk?.preview != nil } && model.pendingBulk?.preview?.changed.count == 2)
    await shot("send-confirm")
    await key("\r", code: 36)
    if model.pendingBulk != nil {
      note("stand-in: ↩ didn't reach the dialog; confirming through the model")
      model.confirmPendingBulk()
    }
    check("both are sent", await until(15) { fresh(carousel.id)?.sentToQueue == true && fresh(solo.id)?.sentToQueue == true })
    await wait(1000)
    model.refreshNow()
    let inQueue = Set(model.queueClips.map(\.id))
    check("both are in the Queue", inQueue.contains(carousel.id) && inQueue.contains(solo.id))
    check("and nothing else moved there", inQueue.subtracting(queueBefore) == [carousel.id, solo.id])
    check("neither has a score", fresh(carousel.id)?.score == nil && fresh(solo.id)?.score == nil)
    check("both left Edit", !model.editList.contains { [carousel.id, solo.id].contains($0.id) })
    check("Score still doesn't list them", !model.scoreList.contains { $0.isPhoto } && model.sidebarCount(.score) == scoreBefore)
    model.toast = nil

    // 10. The Queue, narrowed to photo posts with the new Kind filter.
    model.clearSelection(.edit)
    ListPrefs.shared.setFilter(.queue, ListFilterKey.kind, ListFilterKey.photoKind)
    model.setViewMode(.wide, for: .queue)
    model.screen = .queue
    await wait(1500)
    let shownPhotos = model.listScope(.queue, model.queueClips)
    check("Kind: Photo shows only photo posts", !shownPhotos.isEmpty && shownPhotos.allSatisfy(\.isPhoto) && shownPhotos.count < model.queueClips.count)
    check("Queue cards carry the marks", has(mark) && has("Photo mark \(solo.id) Photo"))
    await shot("queue-cards")
    model.setViewMode(.grid, for: .queue)
    await wait(900)
    await shot("queue-grid")
    ListPrefs.shared.setFilter(.queue, ListFilterKey.kind, nil)
    model.setViewMode(.wide, for: .queue)
    await wait(900)
    await shot("queue-all")

    note(failures == 0 ? "all passed" : "\(failures) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("photo-import-checks-\(look).txt"), atomically: true, encoding: .utf8)
    return failures == 0 ? 0 : 1
  }
}
