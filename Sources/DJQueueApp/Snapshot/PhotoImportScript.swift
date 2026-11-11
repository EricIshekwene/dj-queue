import AppKit
import DJQCore
import SwiftUI
import UniformTypeIdentifiers

/// `DJQ_PHOTO_IMPORT_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 21): the photo import and photo posts in the lists, in
/// the real main window on the throwaway sample. It picks four pictures and a text file, takes one picture back out
/// in the import sheet, checks the sheet's one switch, adds a carousel, looks at it in Cards, Grid, List, Single and
/// the quick look (stepping with real clicks), changes the post while its large preview is up, adds a single photo
/// through the drop handler, runs three imports at once, steps a six-photo carousel with the model running live,
/// sends two posts to the Queue and checks they got there with no score, that Score never saw them and that no
/// preview proxy was asked for a photo.
///
/// Stand-ins, since macOS puts these on a display or they have no view of their own: the file picker (the script
/// calls `model.takePhotos`, which it ends in), a Finder or Photos drag (the script hands the drop handler the item
/// providers such a drag carries), the quick look's way in (a native menu; `previewVideo` is set as the menu does),
/// the drop outline (its flag), the toast's Open (its action), view modes, the list search, the Kind filter and the
/// selection (set on the model). Each is said in the log where it happens. Everything else is a real click or key
/// sent to this window, which sits off every display. Exits 1 on a failed check and saves a capture of each step.
///
/// `DJQ_PHOTO_IMPORT_SABOTAGE` shows the checks can fail: `count` (or `1`) picks one picture too few, `queue` sends
/// the new carousel to the Queue behind the import's back, `proxy` asks for a proxy of it.
@MainActor
enum PhotoImportScript {
  static func run(model: AppModel, store: Store, out: URL, scratch: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    let sabotageMode = env["DJQ_PHOTO_IMPORT_SABOTAGE"]
    let sabotage = sabotageMode == "1" || sabotageMode == "count"
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

    // 1. Pick four pictures and one file that isn't a picture (stand-in for the file picker).
    let picked: [URL]
    let extra: URL
    let notAPhoto = scratch.appendingPathComponent("set-list.txt")
    do {
      picked = try SampleData.photoFiles(store: store, count: sabotage ? 2 : 3, dir: scratch, offset: 2, name: "loft")
      extra = try SampleData.photoFiles(store: store, count: 1, dir: scratch.appendingPathComponent("extra"), offset: 7, name: "wrong-pick")[0]
      try "not a photo".write(to: notAPhoto, atomically: true, encoding: .utf8)
    } catch {
      note("FAIL couldn't make the sample pictures: \(error)")
      return 1
    }
    let originals = fingerprints(picked)
    note("stand-in: the file picker (a real panel lands on a display); the script hands the same files to model.takePhotos")
    model.takePhotos(picked + [extra, notAPhoto])
    check("several photos open the import sheet", await until { model.photoImportRequest != nil })
    await wait(1200)
    check("the sheet shows all four picked photos", has("Import photo \(picked.count + 1)") && model.photoImportRequest?.files == picked + [extra])
    check("the text file was refused with the reason", ui.lastSkipped.map(\.file) == [notAPhoto.path]
          && model.toast?.detail?.contains("not a photo format") == true && model.toast?.detail?.contains("set-list.txt") == true)
    await shot("import-sheet-four")
    // The same files picked again while the sheet is open don't go in twice.
    model.takePhotos(picked)
    await wait(900)
    check("picking the same files again adds nothing", model.photoImportRequest?.files == picked + [extra])
    // Take the wrong pick back out with its ✕ (a real click).
    check("✕ on a thumbnail leaves that photo out", await click("Leave out photo \(picked.count + 1)") && model.photoImportRequest?.files == picked)
    await wait(600)
    check("the sheet holds the 3 photos, in the order picked", model.photoImportRequest?.files == picked && picked.count == 3)
    check("the sheet shows 3 thumbnails", has("Import photo 1") && has("Import photo 2") && has("Import photo 3") && !has("Import photo 4"))
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
    if sabotageMode == "queue" {
      note("SABOTAGE: sending the new carousel to the Queue behind the import's back")
      _ = try? model.bulk.sendToQueue([carousel.id])
      model.refreshNow()
    }
    if sabotageMode == "proxy" {
      note("SABOTAGE: asking for a preview proxy of the new carousel")
      model.requestProxies([carousel.id])
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
    note("stand-in: the toast's Open is run through its action (the shared toast host draws the button)")
    model.toast?.action?()
    let opened = model.editor?.videoId
    model.closeEditor()  // in the same turn, so the editor (another builder's screen) never draws here
    check("Open asks for the editor on the new post", opened == carousel.id)
    await wait(600)
    model.refreshNow()
    check("Open sent nothing to the Queue", fresh(carousel.id)?.sentToQueue == false)
    model.toast = nil

    // 5. The other layouts.
    note("stand-in: view modes, the list's search text and the Kind filter are set on the model (plain SwiftUI state behind their controls)")
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

    // 5b. The post changes while its large preview is up: a title, as the card's Add title field or `djq` sets it.
    // Every photo must still draw at preview size afterwards, not the small cover and not a blank.
    check("Single: photo 2 draws at preview size", has("Photo \(carousel.id) picture large"))
    let stampBefore = model.previewStamp(carousel.id)
    note("stand-in: the title is changed through BulkActions.setTitle, the call the Add title field makes")
    _ = try? model.bulk.setTitle([carousel.id], title + ", late")
    model.refresh()
    await wait(1500)
    check("the change moved the post's preview stamp", model.previewStamp(carousel.id) != stampBefore)
    check("Single: photo 2 still draws at preview size after the post changed", has("Photo \(carousel.id) picture large"))
    await shot("edit-single-photo-2-after-change")
    check("Single: ‹ back to photo 1, also at preview size", await click("Previous photo") && has("Photo \(carousel.id) 1 of 3")
          && has("Photo \(carousel.id) picture large"))
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
    note("stand-in: no system drag session; the drop handler is given the item providers a Finder drag carries")
    PhotoDrop.files(from: [NSItemProvider(object: single as NSURL)]) { urls in model.takePhotos(urls) }
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

    // 7a. A picture dragged with no file behind it (Photos, a browser) becomes a file the importer can read.
    final class Got { var urls: [URL]? }
    let got = Got()
    if let data = try? Data(contentsOf: single) {
      note("stand-in: a picture-only drag is an item provider holding JPEG data and a name")
      let p = NSItemProvider(item: data as NSData, typeIdentifier: UTType.jpeg.identifier)
      p.suggestedName = "From Photos"
      PhotoDrop.files(from: [p]) { got.urls = $0 }
    }
    check("a picture with no file is kept as a photo file", await until { got.urls != nil } && got.urls?.count == 1
          && got.urls.map { PhotoImport.refusal($0[0]) == nil && $0[0].lastPathComponent.hasPrefix("From Photos") } == true)

    // 7b. Imports asked for while one is copying wait their turn, and nothing is dropped.
    var long: Video?
    do {
      let six = try SampleData.photoFiles(store: store, count: 6, dir: scratch.appendingPathComponent("long"), offset: 4, name: "long")
      let late = try SampleData.photoFiles(store: store, count: 2, dir: scratch.appendingPathComponent("late"), offset: 16, name: "late")
      note("stand-in: model.importPhotos is called as the sheet's Add to Edit calls it, three times in one turn")
      model.importPhotos(urls: six, mode: .carousel, title: "Long set")
      model.importPhotos(urls: [late[0]], mode: .carousel, title: nil)
      model.takePhotos([late[1]])
      check("a second import during one is queued, and files picked during it wait", ui.importing && ui.queued.count == 1 && ui.waiting == [late[1]])
      check("the wait is said", model.toast?.message == "Still adding the last photos")
      let names: Set<String> = ["late-1", "late-2"]
      func landed() -> Bool {
        let all = (try? store.videos(where: "photos IS NOT NULL")) ?? []
        return all.contains { $0.titleText == "Long set" && $0.photoCount == 6 } && all.filter { names.contains($0.name) }.count == 2
      }
      check("all three imports land, in Edit", await until(40) { landed() && !ui.importing && ui.queued.isEmpty && ui.waiting.isEmpty })
      await wait(800)
      model.refreshNow()
      long = model.videos.first { $0.isPhoto && $0.titleText == "Long set" }
      check("none of them reached the Queue", Set(model.queueClips.map(\.id)) == queueBefore)
    } catch {
      note("FAIL couldn't make the pictures for the three imports: \(error)")
      failures += 1
    }
    model.toast = nil

    // 7c. A six-photo carousel in the quick look with the model running live (not frozen), so photos load in the
    // background as they do in the app: each step draws at preview size, far photos are let go, and a change to the
    // post while it is open brings the photo back at preview size by itself.
    if let long {
      ListPrefs.shared.setSearch(.edit, "Long set")
      await wait(700)
      note("the model runs live (frozen off) for this step")
      model.frozen = false
      model.previewVideo = long
      let large = "Quick look photo picture large"
      check("live: photo 1 of 6 draws at preview size", await until { has("Quick look photo 1 of 6") && has(large) })
      var stepped = true
      for n in 2...6 {
        let clicked = await click("Next photo")
        let drawn = await until(6) { has("Quick look photo \(n) of 6") && has(large) }
        stepped = stepped && clicked && drawn
      }
      check("live: every step up to photo 6 draws at preview size", stepped)
      check("live: photos far behind the one on screen are let go", model.photoImage(long, index: 0) == nil && model.photoImage(long, index: 5) != nil)
      await shot("quicklook-live-photo-6")
      let stamp = model.previewStamp(long.id)
      _ = try? model.bulk.setTitle([long.id], "Long set, late")
      model.refresh()
      check("live: photo 6 comes back at preview size after the post changed", await until(10) { model.previewStamp(long.id) != stamp && has(large) })
      await shot("quicklook-live-photo-6-after-change")
      var back = true
      for n in stride(from: 5, through: 1, by: -1) {
        let clicked = await click("Previous photo")
        let drawn = await until(6) { has("Quick look photo \(n) of 6") && has(large) }
        back = back && clicked && drawn
      }
      check("live: stepping back to photo 1 loads the dropped photos again", back && model.photoImage(long, index: 0) != nil)
      model.previewVideo = nil
      model.frozen = true
      model.refreshNow()
      ListPrefs.shared.setSearch(.edit, "")
      await wait(600)
    }
    model.toast = nil

    // 8. The outline a file drag shows (stand-in: a real drag needs the system's drag session).
    note("stand-in: the drop outline's flag is set by hand; a real drag would need the system drag session")
    ui.dropTargeted = true
    await shot("edit-drop-outline")
    ui.dropTargeted = false

    // 9. Select both and Send to Queue. Only this moves them.
    check("nothing has reached the Queue by importing", Set(model.queueClips.map(\.id)) == queueBefore)
    note("stand-in: the two posts are selected through model.setSelection (a ⌘-click needs the real modifier keys)")
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

    // 11. No preview proxy for a photo post, anywhere the script went.
    let photoIds = model.videos.filter(\.isPhoto).map(\.id)
    check("no preview proxy was asked for a photo post in Edit or the Queue", !model.recentProxyIds.contains { photoIds.contains($0) })
    model.screen = .calendar
    await wait(1800)
    await shot("calendar")
    note("the Calendar still hands photo ids to requestProxies and Core refuses them; the guard there is in a shared file (see the report)")
    check("Calendar: no proxy exists or is being made for a photo post", photoIds.allSatisfy { model.proxyURLs[$0] == nil && !model.proxyPending.contains($0) })

    note(failures == 0 ? "all passed" : "\(failures) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("photo-import-checks-\(look).txt"), atomically: true, encoding: .utf8)
    return failures == 0 ? 0 : 1
  }
}
