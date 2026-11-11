import AppKit
import DJQCore
import SwiftUI

/// `DJQ_PHOTO_AUDIO_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 23): photo with audio, in the real main window on the
/// throwaway sample. The sample's single photo "Saturday flyer" gets a 12-second tone and becomes a video while its
/// editor is open; the editor carries on as the clip editor (a player, the Audio row). It shows the whole photo with
/// nothing to fix (D12); Fill the frame asks for the crop, and Whole photo takes it back. It is trimmed, gets a timed
/// text, goes to the Queue with no score and is rendered by the video renderer (the whole photo over its blurred
/// copy). A second photo gets audio and ⌘Z brings the photo post back with its crop; with the editor open, Undo on the
/// toast does the same and the photo editor is back; then Change audio and Remove audio; then the import sheet makes
/// two videos from two photos and one audio file, and a photo picked while videos are being made is added next.
///
/// Stand-ins, since macOS puts these on a display: the audio file picker (the script hands the tone to
/// `model.addAudio`, `changeAudio` and `setImportAudio`, the functions a pick ends in, after a real click on the
/// button that opens the picker), the photo file picker (`model.takePhotos`), the ⋯ menu (its items are built from
/// `model.audioBlocker`, which is what is checked), the trim handle and text-bar drags (the editor functions they
/// call; `text-layers` drives the real drags), the progress overlay's picture (drawn once at 40 %: the real one
/// is up for under a second), the toast's Undo button (its action) and the Queue's search field. Each is said in the
/// log where it happens. Everything else is a real click or key sent
/// to this window, which sits off every display, and the audio is a sine tone written here. Players are silent.
///
/// `DJQ_PHOTO_AUDIO_SABOTAGE` shows the checks can fail: `queue` sends the made video to the Queue behind the add's
/// back (the "still in Edit, not sent" checks fail), `silent` hands over a file with no sound in it (no video is made:
/// every check from the add on fails), `photo` skips the add (the item stays a photo post), `fit` leaves out the click
/// on Fill the frame (the "Confirm the crop" checks fail), `crop` leaves out the click on the Crop field's Reset (the
/// "whole frame again" checks fail).
@MainActor
enum PhotoAudioScript {
  static func run(model: AppModel, store: Store, out: URL, scratch: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    let sabotage = env["DJQ_PHOTO_AUDIO_SABOTAGE"]
    var failures = 0
    func note(_ s: String) { print("photo-audio-script: \(s)") }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func until(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
      for _ in 0..<Int(seconds * 10) where !done() { await wait(100) }
      return done()
    }
    func fresh(_ id: String) -> Video? { try? store.video(id: id) }
    let ui = PhotoAudioUI.shared, importUI = PhotoImportUI.shared

    // The audio: sine tones made here (never a third-party track).
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let tone12 = tone(scratch.appendingPathComponent("Friday mix.wav"), seconds: 12)
    let tone5 = tone(scratch.appendingPathComponent("Intro.wav"), seconds: 5, frequency: 330)
    let tone8 = tone(scratch.appendingPathComponent("Second take.wav"), seconds: 8, frequency: 550)
    let tonePrints = [tone12, tone5, tone8].map(PhotoImport.fingerprint)

    model.refreshNow()
    guard let flyer = model.videos.first(where: { $0.isPhoto && $0.titleText == "Saturday flyer" }),
          let carousel = model.videos.first(where: { $0.isCarousel && ClipStage.of($0) == .edit }) else {
      note("FAIL the sample has no single photo “Saturday flyer” and carousel in Edit")
      return 1
    }
    let queueBefore = Set(model.queueClips.map(\.id))
    let scoreBefore = model.sidebarCount(.score)
    note("starts with “\(model.displayName(flyer))” (\(flyer.photoLabel ?? "?")) and “\(model.displayName(carousel))” (\(carousel.photoLabel ?? "?")) in Edit")

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

    // The window as the window server has it (the player's picture included); on a locked Mac there is no screen to
    // read, so it says so and draws the view tree, where the player is black.
    var lockedNoted = false
    var locked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
    func viewTree() -> Data? {
      window.displayIfNeeded()
      guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep.representation(using: .png, properties: [:])
    }
    func capture() async -> Data? {
      if locked {
        if !lockedNoted { lockedNoted = true; note("screen locked: captures are the view tree, with the player black") }
        return viewTree()
      }
      for _ in 0..<6 {
        Backstage.front(window)
        await wait(250)
        if let img = WindowCapture.image(window), img.width > 10, !isBlank(img) {
          return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        }
        await wait(700)
      }
      note("blank capture: the view tree instead")
      return viewTree()
    }
    var step = 0
    func shot(_ name: String) async {
      await wait(900)
      step += 1
      let file = String(format: "audio-%02d-%@-%@.png", step, name, look)
      try? (await capture())?.write(to: out.appendingPathComponent(file))
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
    /// A real click in the middle of the control (or `at`, 0…1 across it: a segment of a segmented control).
    func click(_ label: String, at x: CGFloat = 0.5) async -> Bool {
      guard let f = anchor(label) else { note("no control “\(label)”"); return false }
      let p = NSPoint(x: f.minX + f.width * x, y: f.midY)
      mouse(.leftMouseDown, p)
      await wait(40)
      mouse(.leftMouseUp, p)
      await wait(700)
      return true
    }
    /// The editor on screen, once it has read `id` (and, for a video, has its player).
    func editor(_ id: String, photo: Bool) async -> EditorModel? {
      _ = await until(12) {
        guard let e = EditorModel.live, e.videoId == id, !e.loading, e.video != nil, e.isPhoto == photo else { return false }
        return photo || locked || e.playback.ready
      }
      await wait(600)
      guard let e = EditorModel.live, e.videoId == id, e.video != nil else { return nil }
      return e
    }
    func closeEditor() async {
      model.closeEditor()
      await wait(1200)
      model.refreshNow()
    }
    func issues(_ id: String) -> [ValidationIssue.Kind] {
      EditorModel.flushLiveAndWait()
      return fresh(id).flatMap { try? Validation.issues(video: $0, store: store) }?.map(\.kind) ?? [.corrupt]
    }

    // 1. Edit, with the two photo posts: audio goes on the single photo, not on the carousel (D3).
    await shot("edit-photo-posts")
    check("“Saturday flyer” is a single photo in Edit", flyer.photoCount == 1 && model.editList.contains { $0.id == flyer.id })
    note("stand-in: the ⋯ menu is a native menu; its Add audio… item is on or off by model.audioBlocker")
    check("the single photo can take audio", model.audioBlocker(flyer) == nil)
    check("the carousel can't, and says why", model.audioBlocker(carousel) == "Audio goes on a post with one photo")
    model.openEditor(carousel.id, in: [carousel.id, flyer.id])
    if let e = await editor(carousel.id, photo: true) {
      e.scrollTarget = .title
      await wait(600)
      check("the carousel's editor has the Audio row with Add audio… off, with the reason",
            has("Audio row None") && has("Add audio off: \(StillVideo.carouselReason)") && !has("Add audio"))
      await shot("carousel-audio-off")
    } else {
      check("the carousel opens in the photo editor", false)
    }
    await closeEditor()

    // 2. The single photo in the photo editor: the Audio row, then the add (the editor stays open on it).
    model.openEditor(flyer.id, in: [flyer.id])
    guard let photoEditor = await editor(flyer.id, photo: true) else {
      check("the single photo opens in the photo editor", false)
      return 1
    }
    photoEditor.scrollTarget = .title
    await wait(600)
    check("the photo editor has no player and shows Audio: None with Add audio…", photoEditor.playback.player == nil && has("Audio row None") && has("Add audio"))
    check("its YouTube is off, as for every photo post", !photoEditor.postingPlatforms.contains(.youtube))
    await shot("photo-editor-audio-none")
    ui.asked = nil
    check("a real click on Add audio… asks for the file", await click("Add audio") && ui.asked == flyer.id)
    note("stand-in: the audio file picker (a real panel lands on a display); the script hands the 12-second tone to model.addAudio")
    ui.said = []
    if sabotage == "silent" {
      note("SABOTAGE: the file handed over has a name ending in .wav and no sound in it")
      let empty = scratch.appendingPathComponent("Silence.wav")
      try? Data("not audio".utf8).write(to: empty)
      model.addAudio(to: flyer.id, audio: empty)
    } else if sabotage == "photo" {
      note("SABOTAGE: the add is skipped")
    } else {
      model.addAudio(to: flyer.id, audio: tone12)
    }
    check("the video is being made, and says how far along it is", ui.busy == flyer.id && ui.said.first == "Making the video… 0 %")
    check("the add finishes", await until(40) { ui.busy == nil && ui.lastVideo == flyer.id })
    if sabotage == "queue" {
      note("SABOTAGE: the made video is sent to the Queue behind the add's back")
      _ = try? BulkActions(store: store).sendToQueue([flyer.id])
    }
    model.refreshNow()
    let percents = ui.said.compactMap { Int($0.dropFirst("Making the video… ".count).dropLast(2)) }
    check("its progress counted up (\(ui.said.count) lines, to \(percents.max() ?? -1) %)", percents.count >= 2 && percents == percents.sorted() && (percents.max() ?? 0) >= 80)
    let made = fresh(flyer.id)
    check("the same item is now a video with that audio", made?.isStill == true && made?.isPhoto == false && made?.still?.audioName == "Friday mix.wav"
          && abs((made?.duration ?? 0) - 12) < 0.06)
    check("it is still in Edit: not sent, not in the Queue, no day, no post", made.map { ClipStage.of($0) == .edit && !$0.sentToQueue } == true
          && Set(model.queueClips.map(\.id)) == queueBefore && ((try? store.planSlots(where: "video_id=?", [flyer.id]))?.isEmpty ?? false)
          && ((try? store.posts(where: "video_id=?", [flyer.id]))?.isEmpty ?? false))
    check("Score never saw it", model.sidebarCount(.score) == scoreBefore && !model.toScore.contains { $0.id == flyer.id } && made?.score == nil)
    check("the toast says so, with Undo", model.toast?.message == "Now a video with audio" && model.toast?.actionTitle == "Undo"
          && model.toast?.detail == "Friday mix.wav · 0:12")
    check("the picked audio is untouched", [tone12, tone5, tone8].map(PhotoImport.fingerprint) == tonePrints)

    // 3. The editor is still open on it, now as the clip editor.
    guard let clipEditor = await editor(flyer.id, photo: false) else {
      check("the editor carries on as the clip editor", false)
      await shot("no-clip-editor")
      return 1
    }
    clipEditor.scrollTarget = .title
    await wait(900)
    check("the editor carried on as the clip editor, on the same item", model.editor?.videoId == flyer.id && clipEditor.video?.isStill == true && !clipEditor.isPhoto)
    check("it has a player (silent in a check) and the clip's sections", (clipEditor.playback.player != nil) && clipEditor.playback.player?.volume == 0
          && EditorSection.inspector(photo: clipEditor.isPhoto).contains(.cover))
    check("its length is the audio's, 12 s", abs(clipEditor.duration - 12) < 0.06 && abs(clipEditor.trim.duration - 12) < 0.06)
    check("the Audio row names the file and its length, with Change audio… and Remove audio",
          has("Audio row Friday mix.wav · 0:12") && has("Change audio") && has("Remove audio"))
    check("it says Photo + audio where a clip has its Kind switch", has("Kind Photo + audio") && !has("Kind switch"))
    let active = model.settings.activePlatforms
    check("it posts on every platform, YouTube included (\(clipEditor.postingPlatforms.count) of \(active.count))",
          Set(clipEditor.postingPlatforms) == Set(active) && clipEditor.postingPlatforms.contains(.youtube) && active.count == 6)
    // D12: the whole photo by default. Its crop is the whole frame, so there is nothing to confirm.
    let frame = made.flatMap { v in v.sourceWidth.flatMap { w in v.sourceHeight.map { CropRect(x: 0, y: 0, w: Double(w), h: Double($0)) } } }
    check("it shows the whole photo: a 9:16 video whose crop is the whole frame", made?.still?.fit == .whole
          && made.map { ($0.sourceWidth ?? 0) * 16 == ($0.sourceHeight ?? 0) * 9 } == true && clipEditor.edit.crop == frame && frame != nil)
    check("it starts with no text and nothing to fix", clipEditor.resolved.noText && issues(flyer.id).isEmpty && has("Fit whole"))
    await shot("clip-editor-with-audio")
    note("stand-in: the progress overlay as it is drawn at 40 % (the real one was up for under a second)")
    ui.busy = flyer.id
    ui.progress = 0.4
    await wait(500)
    check("the overlay over the editor says Making the video", has("Making the video") && has("Audio row busy"))
    check("the header's Done, Undo, Redo and stage control are off meanwhile, with that reason", has("Done off") && !has("Done")
          && model.stageBlocker(made ?? flyer, .forward) == PhotoAudioUI.busyReason)
    await shot("making-the-video-overlay")
    ui.busy = nil
    await wait(400)

    // 3b. D12: Fill the frame, and back to Whole photo, with real clicks on the control.
    model.toast = nil
    if sabotage == "fit" {
      note("SABOTAGE: the click on Fill the frame is left out")
    } else {
      check("a real click on Fill the frame", await click("Fit whole", at: 0.75))
    }
    check("the video is made again, filling the frame", await until(30) { ui.busy == nil && fresh(flyer.id)?.still?.fit == .fill })
    if let e = await editor(flyer.id, photo: false) {
      e.scrollTarget = .title
      await wait(900)
      let now = fresh(flyer.id)
      check("Fill the frame: the video has the photo's own shape, and the item says Confirm the crop",
            now.map { ($0.sourceWidth ?? 0) > ($0.sourceHeight ?? 0) } == true && issues(flyer.id) == [.noCrop] && e.edit.crop == nil && has("Fit fill"))
      check("the same audio, from DJ Queue's own copy, with Undo on the toast", now?.still?.audioName == "Friday mix.wav" && now?.still?.audio == made?.still?.audio
            && model.toast?.message == "Fills the frame · confirm the crop" && model.toast?.actionTitle == "Undo")
      await shot("fill-the-frame-confirm-the-crop")
      model.toast = nil
      check("a real click on Whole photo", await click("Fit fill", at: 0.25))
      check("the video is made again, showing the whole photo", await until(30) { ui.busy == nil && fresh(flyer.id)?.still?.fit == .whole })
    } else {
      check("the editor is open after the fit change", false)
    }
    guard let clipEditor = await editor(flyer.id, photo: false) else {
      check("the editor is open on the whole-photo video", false)
      return 1
    }
    clipEditor.scrollTarget = .title
    await wait(900)
    check("Whole photo: nothing to fix again, and the toast says so", issues(flyer.id).isEmpty && has("Fit whole") && clipEditor.edit.crop == frame
          && model.toast?.message == "Shows the whole photo")
    await shot("whole-photo-nothing-to-fix")

    // 3c. Review round 2 (S4): the Crop field on a whole-photo video. The whole frame is how it was made, so there is
    // no Reset to press until Eric zooms in, and Reset never brings "Confirm the crop" back.
    clipEditor.scrollTarget = .frame
    await wait(900)
    let reset = EditorFrameSection.wholeResetHelp
    check("the header says Nothing to fix, and the whole frame has no Reset", has("Nothing to fix") && !has("To fix") && !has(reset) && !clipEditor.cropIsCustom)
    note("stand-in: the Zoom slider's drag; the script calls the editor function it calls")
    clipEditor.setZoom(1.5)
    await wait(700)
    check("zoomed in: the crop is Eric's own, and the field offers Reset", clipEditor.cropIsCustom && has(reset) && clipEditor.edit.crop != nil
          && clipEditor.edit.crop != frame && has("Nothing to fix"))
    await shot("whole-photo-zoomed-crop-with-reset")
    if sabotage == "crop" {
      note("SABOTAGE: the click on the Crop field's Reset is left out")
    } else {
      check("a real click on the Crop field's Reset", await click(reset))
    }
    await wait(700)
    EditorModel.flushLiveAndWait()
    let afterReset = try? store.edit(videoId: flyer.id)
    check("Reset: no crop is stored, and the crop is the whole frame again", afterReset != nil && afterReset?.crop == nil && clipEditor.edit.crop == nil
          && frame.map { abs(clipEditor.crop.w - $0.w) < 1 && abs(clipEditor.crop.h - $0.h) < 1 && clipEditor.crop.x == 0 && clipEditor.crop.y == 0 } == true)
    check("it never says Confirm the crop: the header still says Nothing to fix, in the editor and in Core",
          has("Nothing to fix") && !has("To fix") && !has("Use this crop") && clipEditor.cropIsSet && !clipEditor.liveIssues.contains { $0.kind == .noCrop }
          && issues(flyer.id).isEmpty && ((try? store.resolvedEdit(videoId: flyer.id))?.cropConfirmed ?? false))
    await shot("crop-reset-still-nothing-to-fix")

    // 4. Trim to 6 s and a timed text, as on any clip.
    note("stand-in: the trim handle and the text bar's drags; the script calls the editor functions they call (the text-layers check drives the real drags)")
    clipEditor.setTrimOut(6)
    clipEditor.commitTrim()
    clipEditor.setNoText(false)
    clipEditor.setText("Doors at ten")
    clipEditor.setTextTime(TextLayer.firstId, start: 1, end: 4)
    clipEditor.playback.seek(2, exact: true)
    await wait(900)
    EditorModel.flushLiveAndWait()
    let trimmed = try? store.resolvedEdit(videoId: flyer.id)
    let timed = try? store.resolvedVersion(videoId: flyer.id, number: 1)
    check("the trim is 0 to 6 s and the whole-frame crop needs no confirming", trimmed.map { $0.trimIn == 0 && abs($0.trimOut - 6) < 0.01 && $0.cropConfirmed } == true)
    check("the text shows from 1 s to 4 s", timed.map { $0.text == "Doors at ten" && !$0.noText && $0.textStart == 1 && $0.textEnd == 4 } == true)
    check("nothing is left to fix", ((try? Validation.issues(video: fresh(flyer.id) ?? flyer, store: store)) ?? [.init(kind: .corrupt, platform: nil, message: "")]).isEmpty)
    await shot("trimmed-with-timed-text")
    await closeEditor()

    // 5. Its card in Edit, then Send to Queue with no score.
    model.screen = .edit
    await wait(900)
    if let v = model.video(flyer.id) {
      let card = model.dsClip(v, for: .edit)
      check("its card says Photo + audio with its length, and is a clip's card", card.subtitle == "Photo + audio" && card.durationText != nil && card.photos == nil
            && card.meta.contains("Photo + audio"))
      check("the lists treat it as a clip: it plays, and the Photo filter leaves it out",
            model.playableIds([v.id]) == [v.id] && !model.listFilterMatches(v, ListFilterKey.kind, ListFilterKey.photoKind)
            && model.listFilterMatches(v, ListFilterKey.kind, ListFilterKey.stillKind) && !model.listFilterMatches(v, ListFilterKey.kind, Kind.djVid.rawValue)
            && !model.libraryIsRemoved(v))
      check("audio can still be changed while it is in Edit", model.audioBlocker(v) == nil)
    } else {
      check("the made video is in the model", false)
    }
    await shot("edit-card-photo-plus-audio")
    model.stageForward([flyer.id])
    check("Send to Queue takes it, with no score", await until(8) { fresh(flyer.id)?.state == .ready })
    model.refreshNow()
    check("it is in the Queue with no score", model.queueClips.contains { $0.id == flyer.id } && fresh(flyer.id)?.score == nil && fresh(flyer.id)?.sentToQueue == true)
    check("in the Queue its audio can't change: Send it back to Edit first", model.video(flyer.id).map { model.audioBlocker($0) } == StillVideo.lockedReason)
    model.toast = nil
    model.setViewMode(.wide, for: .queue)
    model.screen = .queue
    note("stand-in: the Queue's search field, set on the model, so its card is on screen among \(model.queueClips.count)")
    ListPrefs.shared.setSearch(.queue, "Saturday flyer")
    await wait(600)
    if let v = model.video(flyer.id) {
      let card = model.dsClip(v, for: .queue)
      check("its Queue card says Photo + audio, with no score and no day yet", card.subtitle == "Photo + audio" && card.score == nil && card.noScoreHelp != nil)
    }
    await shot("in-the-queue")
    ListPrefs.shared.setSearch(.queue, "")

    // 6. The video renderer makes its post file.
    let renderer = Renderer(store: store)
    let rendered = await Task.detached(priority: .userInitiated) { () -> (Render?, ProbeInfo?, String?) in
      do {
        let r = try renderer.ensureRender(videoId: flyer.id, versionNo: 1, platform: nil)
        return (r, try r.outputPath.map { try Media.probe(URL(fileURLWithPath: $0)) }, nil)
      } catch { return (nil, nil, "\(error)") }
    }.value
    if let why = rendered.2 { note("render: \(why)") }
    check("Renderer.ensureRender makes an mp4 for it", rendered.0?.status == .done && rendered.0?.outputPath?.hasSuffix(".mp4") == true && rendered.0?.morePaths == nil)
    check("1080×1920 H.264 with an audio stream, 6 s long", rendered.1.map { $0.width == 1080 && $0.height == 1920 && $0.videoCodec == "h264" && $0.hasAudio
          && abs($0.duration - 6) < 0.15 } == true)
    if let path = rendered.0?.outputPath, let frame = Media.frame(URL(fileURLWithPath: path), at: 2, maxSize: CGSize(width: 1080, height: 1920)) {
      try? Media.writePNG(frame, to: out.appendingPathComponent("render-frame-whole-at-2s-\(look).png"))
      note("shot render-frame-whole-at-2s-\(look).png (a frame of the rendered post: the whole photo over its blurred copy, with the timed text)")
      // The photo is a landscape frame, so it sits across the middle; above and below it is its blurred, darkened copy.
      // The average colour of a 24 px square of the frame around a spot (fractions from the top left).
      func pixel(_ fx: Double, _ fy: Double) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let box = 24.0, w = Double(frame.width), h = Double(frame.height)
        px.withUnsafeMutableBytes { b in
          if let ctx = CGContext(data: b.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: CGRect(x: -(fx * w - box / 2) / box, y: -((1 - fy) * h - box / 2) / box, width: w / box, height: h / box))
          }
        }
        return (Int(px[0]), Int(px[1]), Int(px[2]))
      }
      // What should be there: the same photo enlarged to cover the frame, blurred and darkened to 65 % (`StillVideo`).
      // Worked out here from the photo's own pixels and compared, so black bars, a grey fill or the photo at full
      // brightness all fail.
      let spots = [(0.5, 0.06), (0.2, 0.1), (0.5, 0.94), (0.8, 0.9)]
      let got = spots.map { pixel($0.0, $0.1) }
      let still = fresh(flyer.id)
      let want: [(Int, Int, Int)] = still.flatMap { v in
        guard let photo = v.still?.photo, let url = try? store.photoURL(photo, of: v), let w = v.sourceWidth, let h = v.sourceHeight else { return nil }
        return Self.blurredCopy(of: url, frame: (w, h), at: spots)
      } ?? []
      func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) <= 26 && abs(a.1 - b.1) <= 26 && abs(a.2 - b.2) <= 26 }
      check("above and below the photo the render shows its blurred, darkened copy: \(got) for \(want)",
            want.count == got.count && zip(got, want).allSatisfy { close($0, $1) } && want.contains { $0.0 + $0.1 + $0.2 > 60 })
      // And the photo itself across the middle, at its own brightness (a spot well clear of the text).
      let spot = (0.1, 0.56)
      let middle = pixel(spot.0, spot.1)
      let own: (Int, Int, Int)? = still.flatMap { v in
        guard let photo = v.still?.photo, let url = try? store.photoURL(photo, of: v), let h = v.sourceHeight else { return nil }
        let l = StillVideo.layout(width: photo.width, height: photo.height, fit: .whole)
        let top = Double(l.offset.y) / Double(h), tall = Double(l.photo.height) / Double(h)
        return Self.photoColour(of: url, at: (spot.0, (spot.1 - top) / tall))
      }
      check("the photo itself is across the middle at its own brightness: \(middle) for \(own.map { "\($0)" } ?? "-")", own.map { close(middle, $0) } == true)
    }

    // 7. A second photo: audio, then ⌘Z brings the photo post back with its crop.
    note("stand-in: the photo file picker; one photo handed to model.takePhotos is added straight away, as a photo post")
    model.screen = .edit
    let second: Video
    do {
      let file = try SampleData.photoFiles(store: store, count: 1, dir: scratch.appendingPathComponent("second"), offset: 3, name: "sunday")[0]
      importUI.lastPosts = []
      model.takePhotos([file])
      _ = await until(15) { !importUI.importing && !importUI.lastPosts.isEmpty }
      model.refreshNow()
      guard let v = importUI.lastPosts.first.flatMap(fresh) else { throw EditorlessError("no post") }
      second = v
    } catch {
      check("a second photo is added", false)
      return 1
    }
    check("one photo from Add photos is a photo post in Edit, with no audio asked for", second.isPhoto && second.photoCount == 1 && ClipStage.of(second) == .edit
          && model.photoImportRequest == nil)
    if let p = second.photos?.first {
      var e = (try? store.edit(videoId: second.id)) ?? Edit()
      e.aspectOverride = .r1x1
      var crop = PhotoRules.centredCrop(p, aspect: .r1x1)
      crop.x = max(0, crop.x - 40)
      e.photoCrops[p.id] = crop
      try? store.save(e, videoId: second.id)
      var one = Version(number: 1)
      one.text = "Sunday"
      try? store.save(one, videoId: second.id)
    }
    model.refreshNow()
    func stored(_ id: String) -> [String] {
      let edit = (try? store.db.one("SELECT json FROM edits WHERE video_id=?", [id]))??.string("json") ?? "-"
      let versions = ((try? store.db.query("SELECT json FROM versions WHERE video_id=? ORDER BY number", [id])) ?? []).map { $0.string("json") ?? "" }
      let row = (try? store.db.one("SELECT photos, file, duration, fingerprint FROM videos WHERE id=?", [id])) ?? nil
      return [edit, row?.string("photos") ?? "-", row?.string("file") ?? "-", "\(row?.double("duration") ?? -1)", row?.string("fingerprint") ?? "-"] + versions
    }
    let before = stored(second.id)
    model.toast = nil
    model.addAudio(to: second.id, audio: tone5)
    check("audio added from the list", await until(40) { ui.busy == nil && fresh(second.id)?.isStill == true })
    model.refreshNow()
    check("its own crop and shape went with the photo post", ((try? store.edit(videoId: second.id)).map { $0.photoCrops.isEmpty && $0.aspectOverride == nil }) == true)
    await shot("second-photo-now-a-video")
    check("the newest undo is Add audio", model.undoHistory.top?.label == "Add audio")
    let z = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                             isARepeat: false, keyCode: 6)
    if let z, window.performKeyEquivalent(with: z) {
      note("⌘Z sent to the window")
    } else {
      note("stand-in: ⌘Z didn't reach the window's shortcut, so the script calls what it calls (model.undoLast)")
      model.undoLast()
    }
    check("⌘Z brings the photo post back", await until(10) { fresh(second.id)?.isPhoto == true })
    await wait(600)
    model.refreshNow()
    check("exactly as it was: its photo, crop, shape and text", stored(second.id) == before)
    check("with YouTube off again", ((try? store.edit(videoId: second.id))?.skippedPlatforms.contains(.youtube)) == true)
    check("and the toast says what was undone", model.toast?.message == "Undone: Add audio")
    await shot("undone-a-photo-post-again")

    // 8. With the editor open: add audio, then Undo on the toast. The photo editor is back, on a photo post.
    model.toast = nil
    model.openEditor(second.id, in: [second.id])
    if await editor(second.id, photo: true) != nil {
      model.addAudio(to: second.id, audio: tone5)
      check("audio added with the editor open", await until(40) { ui.busy == nil && fresh(second.id)?.isStill == true })
      check("the editor carried on as the clip editor", await editor(second.id, photo: false)?.video?.isStill == true)
      check("the toast offers Undo", model.toast?.message == "Now a video with audio" && model.toast?.actionTitle == "Undo")
      note("stand-in: the toast's Undo button; the script runs its action")
      model.toast?.action?()
      check("Undo brings the photo post back", await until(10) { fresh(second.id)?.isPhoto == true })
      if let photo = await editor(second.id, photo: true) {
        photo.scrollTarget = .title
        await wait(900)
        check("the open editor is the photo editor again, showing a photo post", photo.isPhoto && photo.video?.isPhoto == true && photo.playback.player == nil
              && model.editor?.videoId == second.id && has("Audio row None") && has("Add audio") && !has("Change audio"))
        check("and the post is exactly as it was", stored(second.id) == before)
        await shot("undo-from-the-toast-photo-editor-back")
      } else {
        check("the open editor is the photo editor again", false)
      }
    } else {
      check("the second photo opens in the photo editor", false)
    }

    // 8b. Change audio and Remove audio, in the editor.
    model.toast = nil
    model.addAudio(to: second.id, audio: tone5)
    _ = await until(40) { ui.busy == nil && fresh(second.id)?.isStill == true }
    model.refreshNow()
    if let e = await editor(second.id, photo: false) {
      e.scrollTarget = .title
      await wait(700)
      check("the second one opens in the clip editor with its audio", has("Audio row Intro.wav · 0:05") && abs(e.duration - 5) < 0.06)
      ui.asked = nil
      check("a real click on Change audio… asks for the file", await click("Change audio") && ui.asked == second.id)
      note("stand-in: the audio file picker; the script hands the 8-second tone to model.changeAudio")
      model.changeAudio(videoId: second.id, audio: tone8)
      check("the change finishes", await until(40) { ui.busy == nil && fresh(second.id)?.still?.audioName == "Second take.wav" })
      if let after = await editor(second.id, photo: false) {
        after.scrollTarget = .title
        await wait(900)
        check("the editor shows the new audio and its length", has("Audio row Second take.wav · 0:08") && abs(after.duration - 8) < 0.06)
        check("the toast says Audio changed, with Undo", model.toast?.message == "Audio changed" && model.toast?.actionTitle == "Undo")
        await shot("audio-changed")
        check("a real click on Remove audio takes it off", await click("Remove audio"))
        check("it is a photo post again", await until(10) { fresh(second.id)?.isPhoto == true })
        if let photo = await editor(second.id, photo: true) {
          photo.scrollTarget = .title
          await wait(900)
          check("and the editor carries on as the photo editor, with Audio: None", photo.playback.player == nil && has("Audio row None") && has("Add audio"))
          check("the toast says so, with Undo", model.toast?.message == "Audio removed · a photo post again" && model.toast?.actionTitle == "Undo")
          await shot("audio-removed-photo-editor")
        } else {
          check("the editor carries on as the photo editor", false)
        }
      } else {
        check("the editor is still open after the change", false)
      }
    } else {
      check("the second made video opens in the clip editor", false)
    }
    await closeEditor()

    // 9. The import sheet: two photos and one audio file make two videos.
    model.screen = .edit
    model.toast = nil
    let stillsBefore = Set(model.videos.filter(\.isStill).map(\.id))
    let pair: [URL]
    do {
      pair = try SampleData.photoFiles(store: store, count: 2, dir: scratch.appendingPathComponent("pair"), offset: 6, name: "poster")
    } catch {
      check("two sample photos", false)
      return 1
    }
    let pairPrints = pair.map(PhotoImport.fingerprint)
    note("stand-in: the photo file picker; two photos handed to model.takePhotos open the import sheet")
    model.takePhotos(pair)
    check("two photos open the import sheet", await until { model.photoImportRequest?.files == pair })
    await wait(1200)
    check("its Audio row says None, with Choose audio…", has("Import audio None") && has("Choose audio") && has("A post per photo"))
    await shot("import-sheet-audio-none")
    ui.asked = nil
    check("a real click on Choose audio… asks for the file", await click("Choose audio") && ui.asked == "import")
    note("stand-in: the audio file picker; the script hands the 5-second tone to model.setImportAudio")
    model.setImportAudio(tone5)
    check("the audio is on the sheet", await until { model.photoImportRequest?.audio == tone5 })
    await wait(900)
    check("the row shows the file, and the sheet says what will be made", has("Import audio Intro.wav") && has("Clear import audio")
          && has("Import plan: 2 videos, each with this audio"))
    check("A post per photo is on and locked", has("A post per photo locked") && !has("A post per photo"))
    // D12: the same choice in the sheet, Whole photo to start with.
    check("the sheet has Whole photo | Fill the frame, on Whole photo", has("Import fit whole") && model.photoImportRequest?.fit == .whole)
    check("a real click on Fill the frame, and back", await click("Import fit whole", at: 0.75) && model.photoImportRequest?.fit == .fill && has("Import fit fill"))
    check("and Whole photo again", await click("Import fit fill", at: 0.25) && model.photoImportRequest?.fit == .whole)
    await shot("import-sheet-with-audio")
    check("Add to Edit is there to click", await click("Add to Edit"))
    check("the videos are made and the sheet closes", await until(60) { !importUI.importing && ui.busy == nil && model.photoImportRequest == nil && importUI.lastPosts.count == 2 })
    await wait(800)
    model.refreshNow()
    let pairMade = model.videos.filter { $0.isStill && !stillsBefore.contains($0.id) }
    check("two new videos, one per photo, each with that audio, showing the whole photo", pairMade.count == 2 && Set(pairMade.map(\.id)) == Set(importUI.lastPosts)
          && pairMade.allSatisfy { $0.still?.audioName == "Intro.wav" && abs($0.duration - 5) < 0.06 && $0.still?.fit == .whole })
    check("both are in Edit; nothing was sent to the Queue", pairMade.allSatisfy { ClipStage.of($0) == .edit && !$0.sentToQueue }
          && Set(model.queueClips.map(\.id)) == queueBefore.union([flyer.id]))
    check("the toast says 2 videos were added, with Open", model.toast?.message == "Added 2 videos to Edit" && model.toast?.actionTitle == "Open")
    check("the picked photos and audio are untouched", pair.map(PhotoImport.fingerprint) == pairPrints && [tone12, tone5, tone8].map(PhotoImport.fingerprint) == tonePrints)
    await shot("two-videos-in-edit")

    // 10. A photo picked while videos are being made is added next (not left waiting for some later import).
    do {
      let one = try SampleData.photoFiles(store: store, count: 1, dir: scratch.appendingPathComponent("one-more"), offset: 9, name: "encore")
      let late = try SampleData.photoFiles(store: store, count: 1, dir: scratch.appendingPathComponent("late"), offset: 11, name: "late")
      note("stand-in: the import sheet's Add to Edit with audio chosen (model.importPhotos), then the photo picker during it (model.takePhotos)")
      model.toast = nil
      model.importPhotos(urls: one, audio: tone5, title: "Encore")
      check("videos are being made", importUI.importing)
      model.takePhotos(late)
      check("a photo picked meanwhile is told it is next", importUI.waiting == late && model.toast?.message == "Still adding the last photos")
      check("and it is added when the videos are done", await until(60) {
        !importUI.importing && ui.busy == nil && importUI.waiting.isEmpty
          && ((try? store.videos(where: "photos IS NOT NULL"))?.contains { $0.name.hasPrefix("late") } ?? false)
      })
      model.refreshNow()
      check("both are in Edit: the video and the photo post", model.videos.contains { $0.isStill && $0.titleText == "Encore" && ClipStage.of($0) == .edit }
            && model.videos.contains { $0.isPhoto && $0.name.hasPrefix("late") && ClipStage.of($0) == .edit })
    } catch {
      check("sample photos for the last step", false)
    }

    note(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
  }

  /// A mono 16-bit sine tone as a WAV file.
  @discardableResult
  static func tone(_ url: URL, seconds: Double, frequency: Double = 440) -> URL {
    let rate = 44_100, n = Int(seconds * Double(rate))
    var d = Data(capacity: 44 + n * 2)
    func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
    d.append(contentsOf: Array("data".utf8)); le(UInt32(n * 2))
    let step = 2 * Double.pi * frequency / Double(rate)
    for i in 0..<n { le(Int16((sin(Double(i) * step) * 0.3 * 32767).rounded())) }
    try? d.write(to: url)
    return url
  }

  /// One colour all over: the window server had nothing drawn yet.
  /// The photo as a small sRGB bitmap (upright), for working out what a frame should show.
  private static func small(_ url: URL, width: Int = 320) -> (px: [UInt8], w: Int, h: Int)? {
    guard let img = PhotoRenderer.load(url, maxPixel: 1200) else { return nil }
    let w = width, h = max(1, Int((Double(img.height) / Double(img.width) * Double(width)).rounded()))
    var px = [UInt8](repeating: 255, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { b -> Bool in
      guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return ok ? (px, w, h) : nil
  }

  /// What a whole-photo video shows behind the photo at `spots` (fractions of the frame, from the top left): the
  /// photo enlarged to cover the `frame`, blurred (a Gaussian, sigma 40 px in a 2160-wide frame) and darkened to 65 %.
  static func blurredCopy(of photo: URL, frame: (Int, Int), at spots: [(Double, Double)]) -> [(Int, Int, Int)]? {
    guard let s = small(photo) else { return nil }
    let fw = Double(frame.0), fh = Double(frame.1)
    let cover = max(fw / Double(s.w), fh / Double(s.h))  // frame pixels per pixel of the small photo
    let sigma = max(0.5, 40 * fw / 2160 / cover)  // in pixels of the small photo
    let reach = Int((sigma * 3).rounded(.up))
    return spots.map { fx, fy in
      let cx = Double(s.w) / 2 + (fx - 0.5) * fw / cover, cy = Double(s.h) / 2 + (fy - 0.5) * fh / cover
      var sum = (0.0, 0.0, 0.0), weight = 0.0
      for dy in -reach...reach {
        for dx in -reach...reach {
          // The blur reads past the picture's edge as the edge itself.
          let x = min(s.w - 1, max(0, Int(cx.rounded()) + dx)), y = min(s.h - 1, max(0, Int(cy.rounded()) + dy))
          let k = exp(-Double(dx * dx + dy * dy) / (2 * sigma * sigma)), i = (y * s.w + x) * 4
          sum.0 += k * Double(s.px[i]); sum.1 += k * Double(s.px[i + 1]); sum.2 += k * Double(s.px[i + 2])
          weight += k
        }
      }
      return (Int(sum.0 / weight * 0.65), Int(sum.1 / weight * 0.65), Int(sum.2 / weight * 0.65))
    }
  }

  /// The photo's own colour around `spot` (fractions of the photo, from the top left).
  static func photoColour(of photo: URL, at spot: (Double, Double)) -> (Int, Int, Int)? {
    guard let s = small(photo) else { return nil }
    let cx = min(s.w - 4, max(3, Int(spot.0 * Double(s.w)))), cy = min(s.h - 4, max(3, Int(spot.1 * Double(s.h))))
    var sum = (0, 0, 0)
    for y in (cy - 3)...(cy + 3) {
      for x in (cx - 3)...(cx + 3) {
        let i = (y * s.w + x) * 4
        sum.0 += Int(s.px[i]); sum.1 += Int(s.px[i + 1]); sum.2 += Int(s.px[i + 2])
      }
    }
    return (sum.0 / 49, sum.1 / 49, sum.2 / 49)
  }

  static func isBlank(_ img: CGImage) -> Bool {
    let w = 64, h = 40
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = data.withUnsafeMutableBytes { b in
      guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok else { return true }
    return stride(from: 0, to: data.count, by: 4).allSatisfy { i in (0..<3).allSatisfy { abs(Int(data[i + $0]) - Int(data[$0])) < 6 } }
  }
}
