import AppKit
import DJQCore
import SwiftUI

/// `DJQ_SNAPSHOT_EDITOR=1 DJQ_PHOTO_EDITOR_SCRIPT=<dir> DJQueueApp --snapshot <dir>` (round 21): the photo editor end to
/// end in the REAL main window with the REAL `AppModel`, on a throwaway copy of the database that holds the sample photo
/// posts (`SampleData.addPhotoPosts`). Clicks, drags and keys are events sent to this window only; every check reads the
/// store. It renders the post through `Renderer` and compares a posted JPEG with the canvas.
///
/// The window is off every display (`Backstage`). What events can't reach is a stand-in and says so in the log: a
/// native menu (the caption template), the file picker and a drop (`addPhotos`, the call both end in). Exits 1 on a FAIL.
/// `DJQ_PHOTO_EDITOR_SABOTAGE=1` breaks one step on purpose (the shape click is skipped), to prove a FAIL is seen.
@MainActor
enum PhotoEditorScript {
  /// Mean difference (0…255) under a text's solid pixels below which that text counts as showing.
  private static let shownBelow = 30.0
  /// Mean difference (0…255) over the middle of the frame below which the canvas and the posted JPEG are the same
  /// picture: the capture goes through the display's colour profile and the JPEG through its compression.
  private static let samePictureBelow = 9.0

  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    try? script.log.joined(separator: "\n").write(to: out.appendingPathComponent("photo-editor-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    print("photo-editor-script: \(script.failed) failed, \(script.passed) passed")
    return script.failed == 0 ? 0 : 1
  }

  @MainActor
  private final class Runner {
    let store: Store, out: URL, appearance: String
    var log: [String] = []
    var failed = 0, passed = 0, step = 0
    var app: AppModel!
    var window: NSWindow!
    var post = ""
    var lockedNoted = false
    let sabotage = ProcessInfo.processInfo.environment["DJQ_PHOTO_EDITOR_SABOTAGE"] != nil

    init(store: Store, out: URL, appearance: String) { self.store = store; self.out = out; self.appearance = appearance }

    func note(_ s: String) { print("photo-editor-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if ok { passed += 1 } else { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Window

    var host: NSView { window.contentView! }
    var editor: EditorModel? { EditorModel.live }

    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }

    func has(_ label: String) -> Bool { anchor(host, ScriptAnchor.prefix + label) != nil }

    /// A control by name, scrolled into view.
    func control(_ label: String) async -> NSRect? {
      guard let a = anchor(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return nil }
      a.scrollToVisible(a.bounds)
      await wait(250)
      return a.convert(a.bounds, to: nil)
    }

    /// `ProbeFrames` are SwiftUI global coordinates (top-left); events want window coordinates (bottom-left).
    func probe(_ key: String) -> NSRect? {
      guard let f = ProbeFrames.frames[key] else { note("no frame “\(key)”"); return nil }
      return NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(e)
      }
    }

    func clickAt(_ p: NSPoint) async {
      mouse(.leftMouseDown, p)
      await wait(40)
      mouse(.leftMouseUp, p)
      await wait(350)
    }

    @discardableResult func click(_ label: String) async -> Bool {
      guard let f = await control(label) else { return false }
      await clickAt(NSPoint(x: f.midX, y: f.midY))
      return true
    }

    /// Segment `i` of `n` in a full-width segmented control.
    @discardableResult func clickSegment(_ label: String, _ i: Int, of n: Int) async -> Bool {
      guard let f = await control(label) else { return false }
      await clickAt(NSPoint(x: f.minX + f.width * (CGFloat(i) + 0.5) / CGFloat(n), y: f.midY))
      return true
    }

    func drag(from a: NSPoint, to b: NSPoint) async {
      mouse(.leftMouseDown, a)
      await wait(40)
      for i in 1...10 {
        let t = CGFloat(i) / 10
        mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        await wait(25)
      }
      mouse(.leftMouseUp, b)
      await wait(500)
    }

    func type(_ text: String) async {
      for ch in text {
        let s = String(ch)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                    isARepeat: false, keyCode: 0) {
          window.sendEvent(e)
        }
        await wait(15)
      }
      await wait(500)
    }

    /// A key through the app's event path, where the editor's key monitor listens.
    func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
      window.makeFirstResponder(nil)
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code) else { return }
      NSApp.sendEvent(e)
      await wait(500)
    }

    func right() async { await press("\u{F703}", code: EditorKeys.right) }
    func left() async { await press("\u{F702}", code: EditorKeys.left) }
    func commandZ() async { await press("z", code: 6, flags: .command); await wait(400) }

    /// True while the Mac is locked or its display is off: the window server draws no window then.
    var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

    func viewTreePNG() -> Data? {
      window.displayIfNeeded()
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
      host.cacheDisplay(in: host.bounds, to: rep)
      return rep.representation(using: .png, properties: [:])
    }

    /// The window as the window server has it. A capture of one colour is tried again rather than trusted. On a locked
    /// Mac there's no screen to read, so it says so and uses the view tree.
    func frontCapture() async -> Data? {
      if screenLocked {
        if !lockedNoted { lockedNoted = true; note("screen locked: captures are the view tree") }
        await wait(250)
        return viewTreePNG()
      }
      for _ in 0..<12 {
        Backstage.front(window)
        await wait(250)
        if let data = WindowCapture.png(window), let img = NSBitmapImageRep(data: data)?.cgImage, !Self.isBlank(img) { return data }
        note("blank capture, trying again")
        await wait(1000)
      }
      return nil
    }

    func shot(_ name: String) async {
      await wait(450)
      step += 1
      let file = out.appendingPathComponent(String(format: "photo-%02d-%@-%@.png", step, name, appearance))
      guard let data = await frontCapture(), (try? data.write(to: file)) != nil else { check("captured \(name)", false); return }
      note("shot \(file.lastPathComponent)")
    }

    /// The part of the window `key`'s frame covers, as captured.
    func captured(_ key: String) async -> CGImage? {
      guard let f = probe(key), let full = await frontCapture().flatMap({ NSBitmapImageRep(data: $0)?.cgImage }) else { return nil }
      let scale = CGFloat(full.width) / host.bounds.width
      let flipped = CGRect(x: f.minX * scale, y: (host.bounds.height - f.maxY) * scale, width: f.width * scale, height: f.height * scale)
      return full.cropping(to: flipped.integral)
    }

    // MARK: Store

    func video(_ id: String? = nil) -> Video? { (try? store.video(id: id ?? post)).flatMap { $0 } }
    func photos(_ id: String? = nil) -> [PhotoItem] { video(id)?.photos ?? [] }

    func savedEdit(_ id: String? = nil) -> Edit {
      EditorModel.flushLiveAndWait()
      return (try? store.edit(videoId: id ?? post)) ?? Edit()
    }

    func saved(_ id: String? = nil) -> ResolvedVersion? {
      EditorModel.flushLiveAndWait()
      guard let settings = try? store.settings() else { return nil }
      return (try? store.resolvedVersion(videoId: id ?? post, number: 1, settings: settings)) ?? nil
    }

    func raw(_ id: String? = nil) -> Version? {
      EditorModel.flushLiveAndWait()
      return (try? store.versions(videoId: id ?? post))?.first { $0.number == 1 }
    }

    func issues(_ id: String? = nil) -> [ValidationIssue] {
      EditorModel.flushLiveAndWait()
      guard let v = video(id) else { return [] }
      return (try? Validation.issues(video: v, store: store)) ?? []
    }

    /// The first text's mean difference from its own drawing, on the canvas as captured. Small = it's there.
    func textScore(_ e: EditorModel) async -> Double {
      guard let layer = saved()?.layers.first, let canvas = await captured("canvas-output") else { return 255 }
      let w = 432, h = Int((Double(w) / e.aspect.ratio).rounded())
      guard let mask = TextOverlay.image(for: layer, aspect: e.aspect).flatMap({ Self.pixels($0, w, h) }), let shown = Self.pixels(canvas, w, h) else { return 255 }
      return Self.scoreUnder(mask, shown)
    }

    // MARK: The run

    func main() async {
      // Instagram on (D20 needs it) and YouTube on in Settings (its row must be off because of the photo, not Settings).
      if var st = try? store.settings() {
        st.enabledPlatforms.formUnion([.instagram, .youtube, .tiktok])
        st.defaults.platforms.formUnion([.instagram, .youtube, .tiktok])
        try? store.save(st)
      }
      let a = AppModel(store: store)
      app = a
      a.refreshNow()
      a.loaded = true
      a.screen = .edit
      let posts = (try? store.videos(where: "photos IS NOT NULL")) ?? []
      guard let carousel = posts.first(where: { $0.photoCount == 4 && $0.state == .needsEdit }),
            let single = posts.first(where: { $0.photoCount == 1 && $0.state == .needsEdit }) else {
        check("the sample carousel and single photo are in Edit", false)
        return
      }
      post = carousel.id
      note("carousel \(carousel.id.prefix(8)) “\(a.displayName(carousel))”, single \(single.id.prefix(8)) “\(a.displayName(single))”")
      EditorDisclosures.shared.closeAll()

      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      window = w
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }

      a.openEditor(post, in: [post, single.id])
      await wait(3000)
      guard let e = editor, e.videoId == post else { check("the real editor is open on the carousel", false); return }
      e.zonePlatforms = []
      e.canvasMode = .zones
      await wait(1200)

      let original = photos()
      await opening(e, carousel)
      await stepping(e)
      await shape(e)
      await frameAndCrop(e, original)
      await text(e)
      await styleAndColour(e)
      await reorderRemoveUndo(e, original)
      await adding(e)
      await captionAndPlatforms(e)
      await instagramShape(e)
      await export(e)
      let now = video()
      check("nothing was sent to the Queue: the post is still in Edit, not sent", now?.sentToQueue == false && now.map { ClipStage.of($0) } == .edit)
      await missingFile(e)
      await singlePhoto(e, single)
      await brokenPost(e, single)
    }

    func opening(_ e: EditorModel, _ v: Video) async {
      check("it opened as a photo post with its 4 photos", e.isPhoto && e.photoCount == 4 && e.photoIndex == 0)
      check("no player exists", e.playback.player == nil && Self.find(host, { $0 as? EditorPlayerSurface.SurfaceView }) == nil)
      check("the photo is on the canvas (decoded off the main thread)", e.playback.still != nil && e.playback.ready)
      check("no load error and nothing probed as a video", e.loadError == nil && !e.fileMissing)
      check("the strip has a picture for every photo", e.photoImages.thumbs.count == 4)
      check("the canvas picture is the composed one (PhotoRenderer.compose)", e.photoImages.composed?.key == e.photoCanvasKey)
      if let c = await captured("canvas-output") { check("the canvas is not blank", !Self.isBlank(c)) } else { check("canvas captured", false) }
      check("a new photo post has no text", e.photoHasNoTextYet && e.textImages.isEmpty && saved()?.noText == true)
      check("the header says what it is, with no version picker and no kind switch", v.photoLabel == "Carousel · 4" && !has("Versions"))
      check("YouTube is off for it", !e.posting(.youtube))
      check("nothing to fix yet", e.liveIssues.isEmpty)
      await shot("open-carousel")
    }

    func stepping(_ e: EditorModel) async {
      await right()
      await right()
      check("→ twice shows photo 3", e.photoIndex == 2 && e.currentPhoto?.id == photos()[2].id)
      await wait(600)
      check("photo 3 is on the canvas", e.playback.ready && e.photoImages.composed?.key == e.photoCanvasKey)
      await press(" ", code: EditorKeys.space)
      check("Space does nothing", !e.playback.isPlaying && e.photoIndex == 2)
      await left()
      check("← goes back one", e.photoIndex == 1)
      await right()
      await shot("photo-3")
    }

    func shape(_ e: EditorModel) async {
      check("Frame opens with a click", await click("Frame") && EditorDisclosures.shared.isOpen(.frame))
      check("the post starts in 4:5", e.aspect == .r4x5 && savedEdit().aspectOverride == nil)
      if !sabotage { await clickSegment("Shape", 1, of: 4) }
      check("a click on 1:1 saves the shape", savedEdit().aspectOverride == .r1x1 && e.aspect == .r1x1)
      await wait(500)
      check("the canvas follows the shape", e.photoImages.composed?.key == e.photoCanvasKey && e.photoImages.composed.map { $0.image.width == $0.image.height } == true)
      await shot("shape-1x1")
      await clickSegment("Shape", 0, of: 4)
      check("and 4:5 puts it back to the default", savedEdit().aspectOverride == nil && e.aspect == .r4x5)
    }

    func frameAndCrop(_ e: EditorModel, _ original: [PhotoItem]) async {
      guard let photo = e.currentPhoto else { return }
      await clickSegment("Canvas mode", 0, of: 3)
      if e.canvasMode != .frame { note("stand-in: the Frame segment (its width isn't a third)"); e.canvasMode = .frame }
      await wait(600)
      check("Frame view shows the whole photo", e.canvasMode == .frame && probe("frame-source") != nil)
      check("no photo has its own crop yet", savedEdit().photoCrops.isEmpty && !e.cropIsSet)
      let centred = PhotoRules.centredCrop(photo, aspect: .r4x5)
      if let f = probe("frame-source") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX + 90, y: f.midY))
      }
      var crops = savedEdit().photoCrops
      check("dragging the crop saved photo 3's own crop, moved right (\(crops[photo.id]?.x ?? -1) from \(centred.x))",
            (crops[photo.id]?.x ?? 0) > centred.x + 20 && crops[photo.id]?.w == centred.w)
      check("for that photo only", Set(crops.keys) == [photo.id])
      let before = crops[photo.id]
      check("Zoom in is there", await click("Zoom in"))
      await click("Zoom in")
      crops = savedEdit().photoCrops
      check("zooming in made its crop smaller (\(Int(before?.w ?? 0)) → \(Int(crops[photo.id]?.w ?? 0)))", (crops[photo.id]?.w ?? 9999) < (before?.w ?? 0) - 50)
      check("still that photo only, and it fits the shape",
            Set(crops.keys) == [photo.id] && crops[photo.id].map { Media.cropProblem($0, aspect: .r4x5, sourceWidth: photo.width, sourceHeight: photo.height) == nil } == true)
      check("the other photos keep the centred crop", original.filter { $0.id != photo.id }.allSatisfy { PhotoRules.crop(for: $0, edit: savedEdit(), aspect: .r4x5) == PhotoRules.centredCrop($0, aspect: .r4x5) })
      await shot("frame-crop-zoom")
      let kept = crops[photo.id]
      check("the same framing can go on every photo", await click("Framing for every photo"))
      crops = savedEdit().photoCrops
      check("every photo has that zoom now (\(crops.count) crops)", crops.count == 4 && original.allSatisfy { p in
        crops[p.id].map { abs($0.w - (kept?.w ?? 0)) <= 2 && Media.cropProblem($0, aspect: .r4x5, sourceWidth: p.width, sourceHeight: p.height) == nil } == true
      })
      await commandZ()
      check("⌘Z takes it back in one step", savedEdit().photoCrops == [photo.id: kept ?? CropRect(x: 0, y: 0, w: 0, h: 0)])
      await click("Reset crop")
      check("Reset crop goes back to the centred crop", savedEdit().photoCrops.isEmpty)
      await commandZ()
      check("⌘Z brings the crop back", savedEdit().photoCrops[photo.id] == kept)
      await clickSegment("Canvas mode", 1, of: 3)
      if e.canvasMode != .zones { e.canvasMode = .zones }
      await wait(600)
    }

    func text(_ e: EditorModel) async {
      await click("Index Text")
      check("the Text section offers Add text and nothing else", has("Add text") && !has("No text") && !has("Advanced"))
      await click("Add text")
      check("Add text made a text for photo 3 only", raw()?.textStart == 2 && raw()?.textEnd == 3 && e.textRange(TextLayer.firstId) == 3...3)
      check("the field has the keyboard", window.firstResponder is NSTextView)
      await type("Loft nights")
      let r = saved()
      check("typing went into the text (“\(r?.text ?? "")”)", r?.text == "Loft nights" && r?.noText == false)
      window.makeFirstResponder(nil)
      await wait(700)
      check("it draws on the canvas", e.textImages.count == 1 && e.textImages[0].shows(at: e.playback.time))
      var score = await textScore(e)
      check(String(format: "the canvas has the text's pixels (%.0f)", score), score < PhotoEditorScript.shownBelow)
      await shot("text-on-photo-3")

      check("the range has a control", await click("Shows first earlier"))
      check("it reads Photos 2–3", e.textRangeLabel(TextLayer.firstId) == "Photos 2–3" && raw()?.textStart == 1 && raw()?.textEnd == 3)
      await shot("shows-on-2-3")
      // Photo by photo: it shows on 2 and 3, by the model, on the canvas and by the renderer's own rule.
      await left(); await left()
      for i in 0..<4 {
        if i > 0 { await right() }
        await wait(500)
        let want = (1...2).contains(i)
        score = await textScore(e)
        let drawn = PhotoRules.layers(saved(), onPhoto: i, of: 4).count == 1
        check(String(format: "photo %d: the text %@ (canvas %.0f)", i + 1, want ? "shows" : "is hidden", score),
              e.photoIndex == i && (score < PhotoEditorScript.shownBelow) == want && drawn == want
                && (e.textImages.first?.shows(at: e.playback.time) ?? false) == want)
      }
      await shot("photo-4-no-text")
      // The bar: its end grip from photo 3 back to photo 2, then ⌘Z.
      if let f = probe("text-end-1"), let t2 = probe("photo-tile-2") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: t2.maxX - 3, y: f.midY))
      }
      check("dragging the bar's end grip left makes it Photo 2 (\(e.textRangeLabel(TextLayer.firstId)))", e.textRange(TextLayer.firstId) == 2...2 && raw()?.textEnd == 2)
      await commandZ()
      check("⌘Z puts Photos 2–3 back", e.textRange(TextLayer.firstId) == 2...3 && raw()?.textEnd == 3)
      // The whole bar one photo right, and back with the button.
      if let f = probe("text-bar-1"), let t3 = probe("photo-tile-3"), let t2 = probe("photo-tile-2") {
        await drag(from: NSPoint(x: f.midX, y: f.midY), to: NSPoint(x: f.midX + (t3.minX - t2.minX), y: f.midY))
      }
      check("dragging the bar moves it to Photos 3–4", e.textRange(TextLayer.firstId) == 3...4)
      await click("Every photo")
      check("Every photo stores no window", raw()?.textStart == nil && raw()?.textEnd == nil && e.textRangeLabel(TextLayer.firstId) == "Every photo")
      await commandZ()
      await commandZ()
      check("⌘Z twice is back at Photos 2–3", e.textRange(TextLayer.firstId) == 2...3)
      await left(); await left()
      check("back on photo 2", e.photoIndex == 1)
    }

    func styleAndColour(_ e: EditorModel) async {
      check("a style tile is there", await click("Style Outline"))
      check("the style saved", saved()?.style == .outline)
      check("Advanced opens with a click", await click("Advanced") && EditorDisclosures.shared.isOpen(.advanced))
      check("Advanced has no seconds for a photo", !has("Show from") && has("Add text"))
      check("a swatch click is there", await click("swatch text colour Red"))
      check("the colour saved", saved()?.textLook?.color == "#FF3B30")
      window.makeFirstResponder(nil)
      await wait(700)
      let score = await textScore(e)
      check(String(format: "the canvas draws the new look (%.0f)", score), score < PhotoEditorScript.shownBelow)
      await shot("style-and-colour")
      await click("Advanced")
    }

    func reorderRemoveUndo(_ e: EditorModel, _ original: [PhotoItem]) async {
      let third = original[2]
      let crop = savedEdit().photoCrops[third.id]
      check("photo 3 has the crop from before", crop != nil)
      if let from = probe("photo-tile-3"), let to = probe("photo-tile-1") {
        await drag(from: NSPoint(x: from.midX, y: from.midY), to: NSPoint(x: to.midX - 4, y: from.midY))
      }
      var now = photos()
      check("dragging photo 3 to the front made it the first photo", now.map(\.id) == [third.id, original[0].id, original[1].id, original[3].id])
      check("so the cover changed", video()?.file == third.file && video()?.file != original[0].file)
      check("it is the photo on the canvas, with its crop", e.photoIndex == 0 && e.currentPhoto?.id == third.id && savedEdit().photoCrops[third.id] == crop)
      check("the text stays on photos 2–3", e.textRange(TextLayer.firstId) == 2...3)
      await wait(500)
      await shot("reordered-new-cover")

      check("the selected tile has a remove button", await click("Remove photo 1"))
      now = photos()
      check("the photo is out of the post", now.map(\.id) == [original[0].id, original[1].id, original[3].id])
      check("its crop went with it, and its file stays for undo",
            savedEdit().photoCrops[third.id] == nil && FileManager.default.fileExists(atPath: store.paths.photos.appendingPathComponent(third.file).path))
      await wait(500)
      await shot("photo-removed")

      await commandZ()
      now = photos()
      check("⌘Z brings the photo back in its place (the same picture)", now.count == 4 && now.first?.fingerprint == third.fingerprint
            && Array(now.dropFirst().map(\.id)) == [original[0].id, original[1].id, original[3].id])
      check("with its crop", now.first.map { savedEdit().photoCrops[$0.id] == crop } == true)
      await commandZ()
      now = photos()
      check("⌘Z again undoes the reorder: the first cover is back", now.map(\.fingerprint) == original.map(\.fingerprint) && video()?.file == now.first?.file)
      check("photo 3 still has its crop", savedEdit().photoCrops[now[2].id] == crop && e.photos.map(\.id) == now.map(\.id))
      e.redo()
      await wait(600)
      check("Redo reorders again", photos().first?.fingerprint == third.fingerprint)
      await commandZ()
      check("and ⌘Z takes it back", photos().map(\.fingerprint) == original.map(\.fingerprint))
      await shot("undone")
    }

    /// The Add tile opens a file picker, which macOS would put on a display: the check calls what the picker and a drop
    /// both end in.
    func adding(_ e: EditorModel) async {
      note("stand-in: EditorModel.addPhotos, the call the Add tile's picker and a drop on the strip end in")
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-photo-editor-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: dir) }
      guard let files = try? SampleData.photoFiles(store: store, count: 2, dir: dir, offset: 21, name: "added") else { check("sample photos to add", false); return }
      let notAPhoto = dir.appendingPathComponent("notes.txt")
      try? "not a photo".write(to: notAPhoto, atomically: true, encoding: .utf8)
      let before = photos().map(\.id)
      e.addPhotos(files + [notAPhoto])
      var waited = 0
      while e.photoBusy, waited < 40 { await wait(250); waited += 1 }
      await wait(600)
      let now = photos()
      check("two photos were added at the end", now.count == 6 && Array(now.prefix(4).map(\.id)) == before)
      check("the file that isn't a photo was left out, and the editor said why", e.toast?.contains("notes.txt") == true)
      check("the first added photo is on the canvas", e.photoIndex == 4 && e.photoImages.thumbs.count == 6)
      await wait(500)
      await shot("photos-added")
      // D9: six photos are more than X sends; its row says so, and it isn't an issue.
      check("X's row says it gets the first 4 of 6", PhotoRules.platformNote(count: e.photoCount, aspect: e.aspect, platform: .x) == "X gets the first 4 of 6 photos"
            && e.posting(.x) && e.liveIssues.isEmpty)
      await click("Index Platforms")
      await shot("platform-note-first-4-of-6")
      await click("Index Text")
      await commandZ()
      check("⌘Z takes the added photos out again", photos().map(\.id) == before && e.photoCount == 4)
    }

    func captionAndPlatforms(_ e: EditorModel) async {
      await click("Index Caption")
      check("no YouTube title row for a photo post", !has("YouTube title template"))
      // A template is picked in a native menu, which would hold this script in its tracking loop: the item's own call.
      if let t = e.templates.first(where: { $0.id != e.defaults.captionTemplateId }) {
        note("stand-in: EditorModel.setCaptionTemplate, the template menu item's own call")
        e.setCaptionTemplate(t.id)
        await wait(400)
        check("the caption template saved (\(t.name))", raw()?.captionTemplateId == t.id)
      } else {
        check("a second caption template to pick", false)
      }
      if e.sets.isEmpty {
        try? store.save(HashtagSet(id: "photo-check", name: "Loft", category: "My groups", tags: ["#loft", "#friday"], sort: 0))
        e.reloadGroups()
        await wait(800)
      }
      if let g = e.sets.first(where: { !e.resolved.hashtagSetIds.contains($0.id) && !$0.tags.isEmpty }) ?? e.sets.first(where: { !$0.tags.isEmpty }) {
        let wasOn = e.resolved.hashtagSetIds.contains(g.id)
        check("a hashtag group chip is there", await click("Group \(g.id)"))
        let r = saved()
        check("the click turned the group \(wasOn ? "off" : "on") (\(g.name))", r?.hashtagSetIds.contains(g.id) == !wasOn)
        if !wasOn, let tag = g.tags.first { check("its hashtags are in the caption that posts", e.caption(for: .instagram).contains(tag)) }
      } else {
        check("a hashtag group to pick", false)
      }
      check("caption warnings never name YouTube", !e.captionWarnings.contains { $0.platform == .youtube })
      await shot("caption-template-and-group")

      await click("Index Platforms")
      check("the YouTube row is there", await click("Post to YouTube Shorts"))
      check("and stays off: a click changes nothing", !e.posting(.youtube) && savedEdit().skippedPlatforms.contains(.youtube))
      check("with the reason", PhotoRules.platformNote(count: e.photoCount, aspect: e.aspect, platform: .youtube) == PhotoRules.youtubeReason)
      check("the other rows have nothing to say about 4 photos in 4:5", e.postingPlatforms.allSatisfy { PhotoRules.platformNote(count: e.photoCount, aspect: e.aspect, platform: $0) == nil })
      await shot("platforms-youtube-off")
    }

    func instagramShape(_ e: EditorModel) async {
      check("Instagram is posting", e.posting(.instagram))
      await click("Index Frame")
      await clickSegment("Shape", 2, of: 4)
      check("9:16 saved", savedEdit().aspectOverride == .r9x16)
      let live = e.liveIssues.first { $0.kind == .photoShape }
      check("the Instagram issue appears at once (“\(live?.message ?? "")”)", live?.platform == .instagram && EditorModel.section(for: .photoShape) == .frame)
      check("and in the store's own validation", issues().contains { $0.kind == .photoShape && $0.platform == .instagram })
      check("the header chip counts it", has("To fix"))
      await wait(400)
      await shot("instagram-9x16-issue")
      check("the one-click fix is there", await click("Use 4:5"))
      check("Use 4:5 fixed it", savedEdit().aspectOverride == nil && !e.liveIssues.contains { $0.kind == .photoShape } && !issues().contains { $0.kind == .photoShape })
      await clickSegment("Shape", 2, of: 4)
      check("the other fix is there", await click("Turn Instagram off"))
      check("turning Instagram off for this post fixes it too, keeping 9:16",
            savedEdit().aspectOverride == .r9x16 && !e.posting(.instagram) && !issues().contains { $0.kind == .photoShape })
      await shot("instagram-off-9x16")
      await commandZ()
      await commandZ()
      check("⌘Z twice: 4:5 with Instagram on", savedEdit().aspectOverride == nil && e.posting(.instagram))
      await click("Frame")
    }

    /// The canvas against the files `Renderer` writes for the post: preview == export.
    func export(_ e: EditorModel) async {
      await click("Index Title")
      // Photo 3: it has its own crop and the text shows on it.
      await left(); await left(); await left()
      await right(); await right()
      check("on photo 3 for the export", e.photoIndex == 2)
      e.plainCanvasForScript = true
      defer { e.plainCanvasForScript = false }
      await wait(900)
      await shot("canvas-before-export")
      guard let canvas = await captured("canvas-output") else { check("canvas captured for the export", false); return }
      e.flushAndWait()
      let root = out.appendingPathComponent("render-\(appearance)")
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let storeRef = store, id = post
      let render: Render? = await Task.detached(priority: .userInitiated) {
        do { return try Renderer(store: storeRef, outputRoot: root).ensureRender(videoId: id, versionNo: 1, platform: nil) } catch {
          print("photo-editor-script: render failed: \(error)")
          return nil
        }
      }.value
      check("the saved post rendered through Renderer", render != nil)
      guard let render else { return }
      let files = render.allPaths
      check("one JPEG per photo (\(files.count))", files.count == 4 && files.allSatisfy { $0.hasSuffix(".jpg") && FileManager.default.fileExists(atPath: $0) })
      guard files.count > 2, let jpeg = NSImage(contentsOfFile: files[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { check("the third JPEG opens", false); return }
      check("it is 1080 × 1350 (4:5)", jpeg.width == 1080 && jpeg.height == 1350)
      let w = 432, h = 540
      guard let exported = Self.pixels(jpeg, w, h), let shown = Self.pixels(canvas, w, h) else { check("pixels read", false); return }
      let diff = Self.meanDifference(shown, exported, w: w, h: h, inset: 0.2)
      check(String(format: "the canvas and the posted JPEG are the same picture in the middle 60%% (mean difference %.1f of 255, tolerance %.0f)", diff, PhotoEditorScript.samePictureBelow),
            diff < PhotoEditorScript.samePictureBelow)
      if let layer = saved()?.layers.first, let mask = TextOverlay.image(for: layer, aspect: e.aspect).flatMap({ Self.pixels($0, w, h) }) {
        let inCanvas = Self.scoreUnder(mask, shown), inExport = Self.scoreUnder(mask, exported)
        check(String(format: "the text is in both (canvas %.0f, export %.0f)", inCanvas, inExport), inCanvas < PhotoEditorScript.shownBelow && inExport < PhotoEditorScript.shownBelow)
      }
      // The check can tell two pictures apart: another photo of the post is not "the same picture".
      if let other = NSImage(contentsOfFile: files[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap({ Self.pixels($0, w, h) }) {
        let apart = Self.meanDifference(shown, other, w: w, h: h, inset: 0.2)
        check(String(format: "and photo 1's JPEG is not (%.1f)", apart), apart > PhotoEditorScript.samePictureBelow * 1.5)
      }
      Self.sideBySide(canvas: canvas, export: exported, w: w, h: h, to: out.appendingPathComponent("compare-canvas-export-\(appearance).png"))
      note("compare-canvas-export-\(appearance).png: canvas left, posted JPEG right")
    }

    /// A photo file that's gone: the post is missing (as a clip would be), the strip still works, and taking that photo
    /// out makes the post whole again.
    func missingFile(_ e: EditorModel) async {
      e.flushAndWait()
      let list = photos()
      guard list.count == 4 else { check("four photos before the missing-file step", false); return }
      let gone = list[3]
      let file = store.paths.photos.appendingPathComponent(gone.file)
      let parked = file.deletingLastPathComponent().appendingPathComponent("parked.jpg")
      note("stand-in: a photo file moved away in the scratch Photos folder, then Core's own file check")
      try? FileManager.default.moveItem(at: file, to: parked)
      _ = try? PhotoImport(store: store).checkFiles()
      e.load(post)
      await wait(2000)
      check("the post opens as missing a file, on the photo that's gone", e.fileMissing && video()?.missing == true && e.photoCount == 4
            && e.missingPhotos == [gone.id] && e.photoIndex == 3 && e.currentPhotoMissing)
      await shot("photo-file-missing")
      await left()
      check("the photos that are there still show (←)", e.photoIndex == 2 && !e.currentPhotoMissing && e.playback.ready)
      await right()
      check("the strip still works: the missing photo can be removed", await click("Remove photo 4"))
      await wait(900)
      check("without it the post is whole again", !e.fileMissing && e.missingPhotos.isEmpty && e.photoCount == 3 && video()?.missing == false && e.playback.ready)
      await shot("missing-photo-removed")
      try? FileManager.default.moveItem(at: parked, to: file)
    }

    func singlePhoto(_ e: EditorModel, _ single: Video) async {
      window.makeFirstResponder(nil)
      await press("\u{F701}", code: EditorKeys.down)
      await wait(2500)
      post = single.id
      check("↓ opened the single photo", e.videoId == single.id && e.isPhoto && e.photoCount == 1)
      check("no player, and its photo is on the canvas", e.playback.player == nil && e.playback.ready)
      check("its one photo can't be removed, and says why", e.removePhotoOffReason?.contains("at least one photo") == true)
      await click("Index Text")
      await click("Add text")
      await type("Doors 9")
      window.makeFirstResponder(nil)
      await wait(700)
      check("a single photo's text has no window", raw()?.text == "Doors 9" && raw()?.textStart == nil && raw()?.textEnd == nil)
      check("and no Shows on row", !has("Every photo"))
      let score = await textScore(e)
      check(String(format: "it draws on the canvas (%.0f)", score), score < PhotoEditorScript.shownBelow)
      await shot("single-photo")
      e.canvasMode = .preview
      await wait(900)
      check("the phone preview leaves YouTube out", !e.previewOrder.contains(.youtube) && e.previewPlatform != .youtube)
      await shot("single-photo-preview")
      e.canvasMode = .zones
      await wait(400)
    }

    /// A post row with an empty photo list can't be made through the app; a broken one is made here to see that the
    /// editor opens it, says "Add a photo", and that the to-fix chip points at the strip.
    func brokenPost(_ e: EditorModel, _ single: Video) async {
      e.flushAndWait()
      note("stand-in: a photo post with no photos, written straight into the scratch database")
      _ = try? store.db.run("UPDATE videos SET photos='[]' WHERE id=?", [single.id])
      e.load(single.id)
      await wait(2000)
      check("the editor opens a post with no photos", e.isPhoto && e.photoCount == 0 && e.loadError == nil)
      check("it has the one issue, which belongs to the strip", e.liveIssues.contains { $0.kind == .noPhotos } && EditorModel.section(for: .noPhotos) == .photos)
      let before = e.flashPhotos
      check("the to-fix chip is there", await click("To fix"))
      check("and it flashes the photos strip", e.flashPhotos == before + 1)
      await shot("no-photos-strip-flash")
    }

    // MARK: Pixels

    static func find<T>(_ v: NSView, _ match: (NSView) -> T?) -> T? {
      if let hit = match(v) { return hit }
      for c in v.subviews { if let hit = find(c, match) { return hit } }
      return nil
    }

    static func isBlank(_ img: CGImage) -> Bool {
      guard let p = pixels(img, 64, 40) else { return true }
      let first = Array(p.prefix(3))
      return stride(from: 0, to: p.count, by: 4).allSatisfy { i in (0..<3).allSatisfy { abs(Int(p[i + $0]) - Int(first[$0])) < 6 } }
    }

    /// RGBA, top row first, scaled to w × h.
    static func pixels(_ image: CGImage?, _ w: Int, _ h: Int) -> [UInt8]? {
      guard let image else { return nil }
      var data = [UInt8](repeating: 0, count: w * h * 4)
      let ok: Bool = data.withUnsafeMutableBytes { b in
        guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      return ok ? data : nil
    }

    /// Mean difference between `frame` and a text's own image, under the text's solid pixels. Small = the text is there.
    static func scoreUnder(_ mask: [UInt8], _ frame: [UInt8]) -> Double {
      var sum = 0.0, n = 0.0
      var i = 0
      while i + 3 < mask.count {
        if mask[i + 3] > 245 {
          for c in 0..<3 { sum += abs(Double(mask[i + c]) - Double(frame[i + c])) }
          n += 3
        }
        i += 4
      }
      return n > 0 ? sum / n : 255
    }

    /// Mean difference of two pictures over their middle (`inset` of each side left out: rounded corners and edges).
    static func meanDifference(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int, inset: Double) -> Double {
      var sum = 0.0, n = 0.0
      for y in Int(Double(h) * inset)..<Int(Double(h) * (1 - inset)) {
        for x in Int(Double(w) * inset)..<Int(Double(w) * (1 - inset)) {
          let i = (y * w + x) * 4
          for c in 0..<3 { sum += abs(Double(a[i + c]) - Double(b[i + c])) }
          n += 3
        }
      }
      return n > 0 ? sum / n : 255
    }

    static func sideBySide(canvas: CGImage, export: [UInt8], w: Int, h: Int, to url: URL) {
      guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2 + 20, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
      ctx.draw(canvas, in: CGRect(x: 0, y: 0, width: w, height: h))
      var e = export
      e.withUnsafeMutableBytes { b in
        if let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let img = c.makeImage() {
          ctx.draw(img, in: CGRect(x: w + 20, y: 0, width: w, height: h))
        }
      }
      try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
  }
}
