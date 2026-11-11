import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DJQCore

/// Round 21, review fixes (reviews/core-photos.md M1, M2 in `R21PhotoPostizTests`, m1–m11). Each test fails on the
/// code before its fix.
@Suite struct R21PhotoReviewTests {
  typealias RGB = PhotoImages.RGB

  func fixture() throws -> Fixture { try Fixture(clips: [], longform: false) }
  func ready(_ f: Fixture) -> URL { f.paths.photos.appendingPathComponent("Ready to Post/Shortform") }
  func bitmap(_ path: String) throws -> PhotoImages.Bitmap { try #require(PhotoImages.bitmap(URL(fileURLWithPath: path))) }

  /// A picture of one colour, in its own folder (two names that differ only by case can't share one on a Mac).
  func picture(_ f: Fixture, _ folder: String, _ name: String, _ c: RGB) -> URL {
    let url = f.inbox.appendingPathComponent(folder).appendingPathComponent(name)
    PhotoImages.write(url, left: c, right: c)
    return url
  }

  // MARK: M1 — two posts never share a render file

  @Test func namesThatAreOneFileNameGetDifferentNamesAndNeverShareARender() throws {
    let f = try fixture()
    let importer = PhotoImport(store: f.store), renderer = Renderer(store: f.store)
    let a = try #require(try importer.add(files: [picture(f, "1", "Flyer.jpg", .red)]).posts.first)
    let b = try #require(try importer.add(files: [picture(f, "2", "flyer.jpg", .blue)]).posts.first)
    #expect(a.name == "Flyer" && b.name == "flyer 2", "a name that differs only by case is taken")
    // ":" and "/" are written as "-" in a render's name, so "a:b" and "a-b" are one name too.
    let c = try #require(try importer.add(files: [picture(f, "3", "a:b.jpg", .green)]).posts.first)
    let d = try #require(try importer.add(files: [picture(f, "4", "a-b.jpg", .yellow)]).posts.first)
    #expect(c.name == "a:b" && d.name == "a-b 2")
    #expect(PhotoImport.fileNameKey("A:B") == PhotoImport.fileNameKey("a-b"))
    // And whatever the names are, the post's id is in the file name: force two posts onto one name and render both.
    try f.store.db.run("UPDATE videos SET name='Flyer' WHERE id=?", [b.id])
    let ra = try renderer.ensureRender(videoId: a.id, versionNo: 1, platform: nil)
    let rb = try renderer.ensureRender(videoId: b.id, versionNo: 1, platform: nil)
    #expect(ra.outputPath?.lowercased() != rb.outputPath?.lowercased())
    #expect(try FileManager.default.contentsOfDirectory(atPath: ready(f).path).count == 2)
    #expect(try bitmap(try #require(ra.outputPath))[540, 600].near(.red), "post A's file still holds post A's photo")
    #expect(try bitmap(try #require(rb.outputPath))[540, 600].near(.blue))
    #expect(try renderer.currentRender(videoId: a.id, versionNo: 1, platform: nil)?.id == ra.id)
    #expect(try renderer.currentRender(videoId: b.id, versionNo: 1, platform: nil)?.id == rb.id)
  }

  // MARK: m1 — a render row short of files is never current

  @Test func aRowWithFewerFilesThanPhotosIsRenderedAgain() throws {
    let f = try fixture()
    let v = try f.photoPost("short", count: 3)
    let renderer = Renderer(store: f.store)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    // As a crash between two writes would have left it: done, with only the first file on the row.
    try f.store.db.run("UPDATE renders SET more_paths=NULL WHERE id=?", [r.id])
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil) == nil)
    let again = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(again.id != r.id && again.allPaths.count == 3)
    #expect(try f.store.renders().map(\.id) == [again.id])
  }

  // MARK: m2 — default text timing on a photo post is every photo

  @Test func firstSecondsTimingDoesNotBecomeFirstPhotos() throws {
    let f = try Fixture()
    try f.intake()
    try f.updateSettings { $0.defaults.textTiming = .firstSeconds; $0.defaults.textFirstSeconds = 3 }
    let v = try f.photoPost("timing", count: 6)
    var ver = Version(number: 1)
    ver.text = "Hello"
    try f.store.save(ver, videoId: v.id)
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r.textStart == nil && r.textEnd == nil)
    #expect((0..<6).map { PhotoRules.layers(r, onPhoto: $0, of: 6).count } == [1, 1, 1, 1, 1, 1])
    #expect(PhotoRules.photoRange(of: TextLayer.firstId, in: r, count: 6) == 1...6)
    // A window Eric sets is kept, and a clip still gets its first three seconds.
    ver.textStart = 0
    ver.textEnd = 2
    try f.store.save(ver, videoId: v.id)
    #expect(PhotoRules.photoRange(of: TextLayer.firstId, in: try #require(try f.store.resolvedVersion(videoId: v.id, number: 1)), count: 6) == 1...2)
    try f.store.save(ver.with { $0.textStart = nil; $0.textEnd = nil }, videoId: "clip-0")
    let clip = try #require(try f.store.resolvedVersion(videoId: "clip-0", number: 1))
    #expect(clip.textStart == 0 && clip.textEnd == 3)
  }

  // MARK: m3 — a symlink is imported as a copy of the file

  @Test func importingASymlinkCopiesTheFile() throws {
    let f = try fixture()
    let original = picture(f, "real", "original.jpg", .red)
    let link = f.inbox.appendingPathComponent("link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    let v = try #require(try PhotoImport(store: f.store).add(files: [link]).posts.first)
    let copy = try f.store.photoURLs(v)[0]
    let type = try FileManager.default.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType
    #expect(type == .typeRegular && v.name == "link")
    #expect(PhotoImport.fingerprint(copy) == PhotoImport.fingerprint(original))
    // The original moves away: DJ Queue's copy is still a photo.
    try FileManager.default.removeItem(at: original)
    try f.intake()
    #expect(try f.store.video(id: v.id)?.missing == false && PhotoRenderer.load(copy) != nil)
  }

  // MARK: m4 — the pure spec never gives a photo post a video payload

  @Test func thePureSpecThrowsForAPhotoPostOnYouTube() throws {
    let f = try fixture()
    let v = try f.photoPost("pure", count: 2)
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let s = try f.store.settings()
    let rv = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    let re = try f.store.resolvedEdit(videoId: v.id)
    func spec(_ p: Platform) throws -> PostizPostSpec {
      let post = PlatformPost(id: "p-\(p.rawValue)", videoId: v.id, platform: p, versionNo: 1, attemptNo: 1, kind: .regular, planSlotId: nil,
                              scheduledAt: f.clock.now.addingTimeInterval(3600), renderId: r.id, state: .rendered, publisher: "postiz",
                              externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil,
                              resolution: nil, metrics: nil, createdAt: f.clock.now, updatedAt: f.clock.now)
      return try PostizPayload.spec(post: post, video: v, render: r, version: rv, edit: re, settings: s, sessionName: "Photos", sets: [],
                                    templates: try f.store.captionTemplates(), integrationId: "ch")
    }
    #expect(throws: EngineError.self) { try spec(.youtube) }
    let x = try spec(.x)
    #expect(x.isPhotoPost && x.photoPaths == r.allPaths && x.thumbnailTimestampMs == nil)
  }

  // MARK: m5 — nothing outside this store's root is moved or deleted; photo paths come from Paths.photos

  @Test func aPathOutsideTheRootIsNeverDeletedOrMoved() throws {
    let f = try fixture()
    let v = try f.photoPost("root", count: 2)
    try f.send(v.id)
    let renderer = Renderer(store: f.store)
    let engine = Engine(store: f.store, renderer: renderer, publisher: ManualPublisher(store: f.store, renderer: renderer), notifier: LogNotifier())
    _ = engine.tick(reason: "t")
    let r = try #require(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil))
    // A file shaped exactly like an app output, in another DJ Video root (what a copied database could name).
    let foreign = f.dir.appendingPathComponent("elsewhere/DJ Video/Photos/Ready to Post/Shortform/someone – v1 – 02.jpg")
    try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("theirs".utf8).write(to: foreign)
    #expect(!f.paths.owns(foreign) && f.paths.owns(URL(fileURLWithPath: r.allPaths[0])))
    #expect(!renderer.isAppOutput(foreign) && renderer.isAppOutput(URL(fileURLWithPath: r.allPaths[0])))
    try f.store.setRenderMorePaths(id: r.id, (r.morePaths ?? []) + [foreign.path])
    // Posted everywhere: the post's own files move, the foreign one stays where it is.
    try f.postAll(on: f.dm.key(f.clock.now))
    _ = engine.tick(reason: "t")
    let moved = try #require(try f.store.render(id: r.id))
    #expect(moved.allPaths.prefix(2).allSatisfy { $0.contains("/Posted/Shortform/") && FileManager.default.fileExists(atPath: $0) })
    #expect(moved.allPaths.last == foreign.path && FileManager.default.fileExists(atPath: foreign.path))
    #expect(!FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("elsewhere/DJ Video/Photos/Posted").path))
    // Cleanup of old posted files leaves it too.
    try f.updateSettings { $0.cleanup = .deleteAfter(days: 1) }
    f.clock.advance(3 * 86400)
    _ = engine.tick(reason: "t")
    #expect(String(decoding: try Data(contentsOf: foreign), as: UTF8.self) == "theirs")
    #expect(moved.allPaths.prefix(2).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    // And so does the renderer when it deletes a render that names it.
    let other = try f.photoPost("root-two", count: 1)
    let r2 = try renderer.ensureRender(videoId: other.id, versionNo: 1, platform: nil)
    try f.store.setRenderMorePaths(id: r2.id, [foreign.path])
    try renderer.deleteRenders(except: [])
    #expect(!FileManager.default.fileExists(atPath: r2.allPaths[0]))
    #expect(try f.store.render(id: r2.id)?.deletedAt != nil)
    #expect(String(decoding: try Data(contentsOf: foreign), as: UTF8.self) == "theirs")
  }

  @Test func photoFilesAreFoundUnderThisRootWhateverTheSessionRowSays() throws {
    let f = try fixture()
    let v = try f.photoPost("moved", count: 2)
    // The database came from another root: the Photos session row names a folder that isn't this one.
    let elsewhere = f.dir.appendingPathComponent("elsewhere/DJ Video/Photos").path
    try f.store.db.run("UPDATE sessions SET folder=? WHERE id=?", [elsewhere, Session.photosId])
    #expect(try f.store.photoURLs(v).allSatisfy { $0.path.hasPrefix(f.paths.photos.path + "/") })
    #expect(try f.store.fileURL(for: v)?.path.hasPrefix(f.paths.photos.path + "/") == true)
    #expect(try f.intake().missing.isEmpty)
    #expect(try f.store.video(id: v.id)?.missing == false)
    #expect(try f.store.session(id: Session.photosId)?.folder == f.paths.photos.path, "intake repairs the folder")
    // Renders land under this root too.
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(r.allPaths.allSatisfy { $0.hasPrefix(ready(f).path + "/") })
    #expect(!FileManager.default.fileExists(atPath: elsewhere))
  }

  // MARK: m6 — moving a carousel to Posted finishes on a later tick

  /// A posted carousel with its render, and the engine around it.
  func postedCarousel(_ f: Fixture, _ name: String) throws -> (Engine, Render) {
    let v = try f.photoPost(name, count: 3)
    try f.send(v.id)
    let renderer = Renderer(store: f.store)
    let engine = Engine(store: f.store, renderer: renderer, publisher: ManualPublisher(store: f.store, renderer: renderer), notifier: LogNotifier())
    _ = engine.tick(reason: "t")
    let r = try #require(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil))
    try f.postAll(on: f.dm.key(f.clock.now))
    return (engine, r)
  }

  @Test func aMoveThatStoppedPartWayIsFinishedOnTheNextTick() throws {
    let f = try fixture()
    let (engine, r) = try postedCarousel(f, "half")
    // The first file moved and the row says so; the other two are still in Ready to Post.
    let posted = f.paths.photos.appendingPathComponent("Posted/Shortform")
    try FileManager.default.createDirectory(at: posted, withIntermediateDirectories: true)
    let first = posted.appendingPathComponent(URL(fileURLWithPath: r.allPaths[0]).lastPathComponent)
    try FileManager.default.moveItem(atPath: r.allPaths[0], toPath: first.path)
    try f.store.setRenderOutput(id: r.id, outputPath: first.path, coverPath: nil)
    #expect(engine.tick(reason: "t").steps["move"]?.hasPrefix("moved 1") == true)
    let after = try #require(try f.store.render(id: r.id))
    #expect(after.allPaths.count == 3 && after.allPaths.allSatisfy { $0.contains("/Posted/Shortform/") && FileManager.default.fileExists(atPath: $0) })
    #expect(try FileManager.default.contentsOfDirectory(atPath: ready(f).path).isEmpty)
    #expect(engine.tick(reason: "t").steps["move"]?.hasPrefix("moved 0") == true, "nothing left to move")
  }

  @Test func filesThatCantMoveStayOnTheRowAndMoveLater() throws {
    let f = try fixture()
    let (engine, r) = try postedCarousel(f, "locked")
    let posted = f.paths.photos.appendingPathComponent("Posted/Shortform")
    try FileManager.default.createDirectory(at: posted, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: posted.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: posted.path) }
    let stuck = engine.tick(reason: "t")
    #expect(stuck.errors.isEmpty && stuck.steps["move"]?.contains("3 files still to move") == true, "\(stuck.steps["move"] ?? "")")
    #expect(try f.store.render(id: r.id)?.allPaths == r.allPaths && r.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: posted.path)
    #expect(engine.tick(reason: "t").steps["move"]?.hasPrefix("moved 1") == true)
    #expect(try #require(try f.store.render(id: r.id)).allPaths.allSatisfy { $0.contains("/Posted/Shortform/") && FileManager.default.fileExists(atPath: $0) })
  }

  // MARK: m7 — a failure while placing retires the rows whose files were overwritten

  @Test func aPlacingFailureLeavesNoFinishedRowPointingAtAMixOfPhotos() throws {
    let f = try fixture()
    let v = try f.photoPost("mix", count: 3)
    let renderer = Renderer(store: f.store)
    let old = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    var e = try f.store.edit(videoId: v.id)
    e.aspectOverride = .r1x1
    try f.store.save(e, videoId: v.id)
    renderer.photoPlaceHook = { i in if i == 2 { throw RenderError("the disk is full") } }
    #expect(throws: RenderError.self) { try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil) }
    // Photos 1 and 2 were replaced before it failed: the old render can't be used any more, and says so.
    #expect(try f.store.render(id: old.id)?.deletedAt != nil)
    #expect(try f.store.renders(where: "deleted_at IS NULL AND status='done'").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: old.allPaths[0]) && !FileManager.default.fileExists(atPath: old.allPaths[1]))
    // Back at the old edit, nothing stale is handed out; the next render is whole.
    e.aspectOverride = nil
    try f.store.save(e, videoId: v.id)
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil) == nil)
    renderer.photoPlaceHook = nil
    let whole = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(whole.allPaths.count == 3 && whole.id != old.id)
    #expect(try whole.allPaths.allSatisfy { try bitmap($0).height == 1350 })
  }

  // MARK: m8 — clips in Edit keep their tie order

  @Test func clipsWithTheSameScorePartAndStartStayInTheOrderTheyWereRead() throws {
    let f = try fixture()
    try f.intake()
    let s = try #require(try f.store.sessions().first)
    // "z" is stored before "a": the same score, part and start, the same creation time.
    for id in ["z", "a", "m"] {
      try f.store.save(Video(id: id, sessionId: s.id, name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid,
                             file: "Clips/\(id).mp4", fingerprint: nil, fileSize: nil, duration: 30, markedStart: nil, markedEnd: nil,
                             start: 10, end: 40, grace: nil, audio: nil, part: 1, score: 50, state: .needsEdit, excluded: false,
                             missing: false, inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil,
                             createdAt: f.clock.now, updatedAt: f.clock.now))
    }
    #expect(try Queue(store: f.store).needsEdit().map(\.id) == ["z", "a", "m"])
    // Photos tie among themselves by import time, and unscored ones still lead.
    let p1 = try f.photoPost("one", count: 1)
    f.clock.advance(60)
    let p2 = try f.photoPost("two", count: 1)
    #expect(try Queue(store: f.store).needsEdit().map(\.id) == [p1.id, p2.id, "z", "a", "m"])
  }

  // MARK: m9 — the text drawing version is in the hash of a photo post with text

  @Test func theTextDrawingVersionIsInTheHashOnlyWhenTextIsDrawn() throws {
    let f = try fixture()
    let v = try f.photoPost("draw", count: 2)
    let renderer = Renderer(store: f.store)
    let plain = try renderer.photoPlan(v, versionNo: 1)
    #expect(plain.input.textDrawing == nil && !JSONCoding.string(plain.input).contains("textDrawing"))
    var ver = Version(number: 1)
    ver.text = "Hello"
    try f.store.save(ver, videoId: v.id)
    let text = try renderer.photoPlan(v, versionNo: 1)
    #expect(text.input.textDrawing == TextOverlay.drawingVersion && TextOverlay.drawingVersion == "text-1")
    var next = text.input
    next.textDrawing = "text-2"
    #expect(try Renderer.photoHash(next) != text.hash && Renderer.photoHash(text.input) == text.hash)
  }

  // MARK: m10 (D20) — a shape Instagram refuses is a readiness issue

  @Test func aNineBySixteenPhotoPostCantGoToInstagram() throws {
    let f = try fixture()
    let v = try f.photoPost("tall", count: 2)
    let bulk = BulkActions(store: f.store)
    func issues() throws -> [ValidationIssue] { try Validation.issues(video: try #require(try f.store.video(id: v.id)), store: f.store) }
    func setAspect(_ a: Aspect?) throws {
      var e = try f.store.edit(videoId: v.id)
      e.aspectOverride = a
      try f.store.save(e, videoId: v.id)
    }
    // 4:5 (the default), 1:1 and 16:9 are fine everywhere.
    for a in [nil, Aspect.r4x5, .r1x1, .r16x9] {
      try setAspect(a)
      #expect(try issues().isEmpty, "\(a?.rawValue ?? "default")")
    }
    try setAspect(.r9x16)
    let found = try issues()
    let shape = try #require(found.first, "9:16 with Instagram on is an issue")
    #expect(found.map(\.kind) == [.photoShape] && shape.platform == .instagram)
    #expect(found[0].message == "Instagram takes photos from 4:5 to 16:9 — pick another shape or turn Instagram off for this post")
    #expect(found[0].chipText == "Wrong shape for Instagram" && found[0].kind.isBlock && found[0].kind.editorSection == .frame)
    // Send to Queue says so and leaves it in Edit.
    let sent = try bulk.forward([v.id])
    #expect(try f.store.video(id: v.id)?.state == .needsEdit)
    #expect((sent.moves?[v.id]?.note ?? sent.skipped[v.id] ?? "").contains("Instagram takes photos from 4:5 to 16:9"))
    // Turning Instagram off for the post clears it, and it goes to the Queue with four platforms.
    #expect(try bulk.setPlatform([v.id], .instagram, skipped: true).changed == [v.id])
    #expect(try issues().isEmpty)
    try f.send(v.id)
    #expect(try f.store.video(id: v.id)?.state == .ready)
    try Planner(store: f.store).autoSchedule()
    #expect(try Set(f.store.posts(where: "video_id=?", [v.id]).map(\.platform)) == [.facebook, .threads, .x, .tiktok])
    // What the aspect picker and the platform rows show.
    #expect(PhotoRules.takes(.r4x5, platform: .instagram) && PhotoRules.takes(.r16x9, platform: .instagram) && PhotoRules.takes(.r1x1, platform: .instagram))
    #expect(!PhotoRules.takes(.r9x16, platform: .instagram) && PhotoRules.takes(.r9x16, platform: .tiktok) && PhotoRules.takes(.r9x16, platform: .x))
    #expect(PhotoRules.aspectNote(.r9x16) == "Instagram doesn't take 9:16 photos" && PhotoRules.aspectNote(.r4x5) == nil)
    #expect(PhotoRules.aspectNote(.r9x16, posting: [.tiktok, .x]) == nil)
    #expect(PhotoRules.refusing(.r9x16, posting: Platform.allCases) == [.instagram])
    #expect(PhotoRules.platformNote(count: 12, aspect: .r9x16, platform: .instagram) == found[0].message)
    #expect(PhotoRules.platformNote(count: 12, aspect: .r4x5, platform: .instagram) == "Instagram gets the first 10 of 12 photos")
    #expect(PhotoRules.platformNote(count: 2, aspect: .r9x16, platform: .youtube) == PhotoRules.youtubeReason)
  }

  // MARK: m11 — alpha, wide gamut, the seed path rewrite

  @Test func seeThroughPixelsComeOutWhite() throws {
    let f = try fixture()
    // Left half solid red, right half fully see-through.
    let w = 400, h = 300
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 220 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    let url = f.inbox.appendingPathComponent("cutout.png")
    try FileManager.default.createDirectory(at: f.inbox, withIntermediateDirectories: true)
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dest))
    #expect((PhotoImages.properties(url)[kCGImagePropertyHasAlpha] as? Bool) == true)
    let v = try #require(try PhotoImport(store: f.store).add(files: [url]).posts.first)
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let b = try bitmap(r.allPaths[0])
    #expect(b[200, 700].near(.red) && b[880, 700].near(.white, 6), "see-through is white, not black: \(b[880, 700])")
    #expect((PhotoImages.properties(URL(fileURLWithPath: r.allPaths[0]))[kCGImagePropertyHasAlpha] as? Bool) != true)
  }

  @Test func aWideGamutPhotoIsConvertedToSRGBNotJustRelabelled() throws {
    let f = try fixture()
    // Display P3 (0.8, 0.3, 0.3): the same colour in sRGB is about (221, 64, 71), not the raw (204, 77, 77).
    let w = 400, h = 300
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: p3,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(try #require(CGColor(colorSpace: p3, components: [0.8, 0.3, 0.3, 1])))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let url = f.inbox.appendingPathComponent("wide.jpg")
    try FileManager.default.createDirectory(at: f.inbox, withIntermediateDirectories: true)
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    #expect((PhotoImages.properties(url)[kCGImagePropertyProfileName] as? String)?.contains("P3") == true, "the source is tagged Display P3")
    let v = try #require(try PhotoImport(store: f.store).add(files: [url]).posts.first)
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let out = URL(fileURLWithPath: r.allPaths[0])
    #expect((PhotoImages.properties(out)[kCGImagePropertyProfileName] as? String) == "sRGB IEC61966-2.1")
    // Tagged sRGB, so these are the stored values: relabelled P3 numbers would read (204, 77, 77).
    let px = try bitmap(r.allPaths[0])[540, 600]
    #expect(px.near(RGB(r: 221, g: 64, b: 71), 8) && !px.near(RGB(r: 204, g: 77, b: 77), 6), "\(px)")
  }

  /// `scripts/seed-paths.sh` is what points a database copy at the dev root before a live check. Run here on a made-up
  /// database with made-up roots (no app, no real data): both forms of a stored path are rewritten, and a leftover fails.
  @Test func theSeedPathRewriteReachesPlainAndEscapedPaths() throws {
    let f = try fixture()
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = repo.appendingPathComponent("scripts/seed-paths.sh")
    let old = f.dir.appendingPathComponent("real/DJ Video").path, new = f.dir.appendingPathComponent("dev/DJ Video").path
    let dbURL = f.dir.appendingPathComponent("seed.sqlite")
    do {
      let db = try SQLite(path: dbURL.path)
      try db.exec("CREATE TABLE renders(id TEXT, output_path TEXT, more_paths TEXT, size INTEGER); CREATE TABLE kv(key TEXT, json TEXT);")
      let more = ["\(old)/Photos/Ready to Post/Shortform/x – 02.jpg", "\(old)/Photos/Ready to Post/Shortform/x – 03.jpg"]
      try db.run("INSERT INTO renders VALUES('plain', ?, ?, 1)", ["\(old)/Photos/Ready to Post/Shortform/x – 01.jpg", JSONCoding.pathList(more)])
      try db.run("INSERT INTO renders VALUES('escaped', ?, ?, 1)", ["\(old)/a.mp4", JSONCoding.string(more)])  // "\/" inside
      try db.run("INSERT INTO renders VALUES('other', '/somewhere/else.mp4', NULL, 1)")
      try db.run("INSERT INTO kv VALUES('report', ?)", [JSONCoding.string(["untracked": ["\(old)/Sessions/s/Clips/c.mp4"]])])
      #expect(try db.one("SELECT more_paths FROM renders WHERE id='escaped'")?.string("more_paths")?.contains("\\/") == true)
    }
    func run(_ args: [String]) throws -> Int32 {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = [script.path] + args
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      try p.run()
      p.waitUntilExit()
      return p.terminationStatus
    }
    #expect(try run([dbURL.path, old, new]) == 0)
    let db = try SQLite(path: dbURL.path)
    for row in try db.query("SELECT id, output_path, more_paths FROM renders WHERE id<>'other'") {
      #expect(row.string("output_path")?.hasPrefix(new + "/") == true)
      let paths: [String] = try #require(row.json("more_paths"))
      #expect(paths.count == 2 && paths.allSatisfy { $0.hasPrefix(new + "/Photos/Ready to Post/Shortform/x – 0") }, "\(row.string("id") ?? "")")
    }
    #expect(try db.one("SELECT output_path FROM renders WHERE id='other'")?.string("output_path") == "/somewhere/else.mp4")
    let all = try db.query("SELECT output_path || coalesce(more_paths, '') AS t FROM renders").compactMap { $0.string("t") }
      + db.query("SELECT json AS t FROM kv").compactMap { $0.string("t") }
    let escapedOld = old.replacingOccurrences(of: "/", with: "\\/")
    #expect(all.allSatisfy { !$0.contains(old) && !$0.contains(escapedOld) })
    // Running it again finds nothing to do and still passes.
    #expect(try run([dbURL.path, old, new]) == 0)
    #expect(try run([dbURL.path]) != 0, "it needs both roots")
  }

  // MARK: The other builder's call: `send` takes an unscored photo post

  @Test func sendLetsAnUnscoredPhotoPostThrough() throws {
    let f = try fixture()
    let v = try f.photoPost("send", count: 2)
    #expect(v.score == nil)
    let bulk = BulkActions(store: f.store)
    let outcome = try bulk.send(v, try f.store.settings())
    guard case .changed = outcome else { Issue.record("send left the photo post alone: \(outcome)"); return }
    let sent = try #require(try f.store.video(id: v.id))
    #expect(sent.sentToQueue && sent.state == .ready && sent.score == nil && ClipStage.of(sent) == .queue)
    // A clip without a score still isn't sent.
    let g = try Fixture()
    try g.intake()
    try g.store.save(Edit().with { $0.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160) }, videoId: "clip-0")
    _ = try BulkActions(store: g.store).send(try #require(try g.store.video(id: "clip-0")), try g.store.settings())
    #expect(try g.store.video(id: "clip-0")?.sentToQueue == false)
  }
}

private extension Version {
  func with(_ change: (inout Version) -> Void) -> Version { var v = self; change(&v); return v }
}

private extension Edit {
  func with(_ change: (inout Edit) -> Void) -> Edit { var e = self; change(&e); return e }
}
