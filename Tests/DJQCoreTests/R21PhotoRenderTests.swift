import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DJQCore

/// Round 21 (P3, D5–D7): a photo post renders to one JPEG per photo, cropped, scaled and with its texts drawn in, by
/// the same code the editor previews with. No ffmpeg anywhere.
@Suite struct R21PhotoRenderTests {
  typealias RGB = PhotoImages.RGB

  func fixture() throws -> Fixture { try Fixture(clips: [], longform: false) }

  func ready(_ f: Fixture) -> URL { f.paths.photos.appendingPathComponent("Ready to Post/Shortform") }

  func setAspect(_ f: Fixture, _ id: String, _ a: Aspect?) throws {
    var e = try f.store.edit(videoId: id)
    e.aspectOverride = a
    try f.store.save(e, videoId: id)
  }

  @Test func oneJPEGPerPhotoNamedAndSizedForTheAspect() throws {
    let f = try fixture()
    let v = try f.photoPost("set", count: 3)
    let renderer = Renderer(store: f.store)
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil) == nil)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: .instagram)
    let dir = ready(f)
    #expect(r.status == .done && r.scope == "all" && r.coverPath == nil && r.loudness == nil && (r.duration ?? 0) == 0)
    #expect(r.allPaths == (1...3).map { dir.appendingPathComponent("set-1 – v1 – 0\($0).jpg").path })
    #expect(r.outputPath == r.allPaths[0] && r.morePaths == Array(r.allPaths.dropFirst()))
    #expect(Renderer.photoOutputName(video: v, versionNo: 1, index: 11) == "set-1 – v1 – 12.jpg")
    // Stored as plain paths (no "\/"), so a dev copy's path rewrite reaches them like `output_path`.
    let raw = try #require(try f.store.db.one("SELECT more_paths FROM renders WHERE id=?", [r.id])?.string("more_paths"))
    #expect(raw.contains(r.allPaths[1]) && raw.contains(r.allPaths[2]) && !raw.contains("\\/"))
    var total: Int64 = 0
    for path in r.allPaths {
      let b = try #require(PhotoImages.bitmap(URL(fileURLWithPath: path)))
      #expect(b.width == 1080 && b.height == 1350, "4:5 at 1080 wide")
      total += Intake.size(URL(fileURLWithPath: path))
    }
    #expect(r.size == total && total > 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
    // The same render for every platform, and again on the next ask (nothing re-rendered).
    for p in Platform.allCases {
      #expect(try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: p).id == r.id)
      #expect(try renderer.scope(videoId: v.id, platform: p) == "all")
    }
    #expect(try f.store.renders().count == 1)
    // Each of the other shapes, 1080 wide.
    for (aspect, height) in [(Aspect.r1x1, 1080), (.r9x16, 1920), (.r16x9, 608)] {
      try setAspect(f, v.id, aspect)
      let again = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
      #expect(again.id != r.id && again.allPaths == r.allPaths, "the files are replaced in place")
      for path in again.allPaths {
        let b = try #require(PhotoImages.bitmap(URL(fileURLWithPath: path)))
        #expect(b.width == 1080 && b.height == height, "\(aspect.rawValue)")
      }
    }
    #expect(try f.store.renders().count == 1, "older renders are retired")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
    // The originals weren't written to.
    #expect(try f.store.photoURLs(v).map { PhotoImport.fingerprint($0) } == v.photos?.map(\.fingerprint))
  }

  @Test func cropOrientationAndNoMetadata() throws {
    let f = try fixture()
    // Photo 1: stored 400×300, red left / blue right. Photo 2: the same pixels turned by EXIF, with a location.
    let plain = f.inbox.appendingPathComponent("plain.jpg"), turned = f.inbox.appendingPathComponent("turned.jpg")
    PhotoImages.write(plain)
    PhotoImages.write(turned, orientation: 6, gps: true)
    #expect(PhotoImages.properties(turned)[kCGImagePropertyGPSDictionary] != nil, "the test picture carries a location")
    let v = try #require(try PhotoImport(store: f.store).add(files: [plain, turned]).posts.first)
    let renderer = Renderer(store: f.store)
    var r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    // The centred 4:5 crop of photo 1 is x 80…320: red on the left half of the output, blue on the right.
    var one = try #require(PhotoImages.bitmap(URL(fileURLWithPath: r.allPaths[0])))
    #expect(one[200, 700].near(.red) && one[880, 700].near(.blue), "\(one[200, 700]) \(one[880, 700])")
    // Photo 2 upright is 300×400 with red on top: the output is red above, blue below.
    let two = try #require(PhotoImages.bitmap(URL(fileURLWithPath: r.allPaths[1])))
    #expect(two.width == 1080 && two.height == 1350)
    #expect(two[540, 150].near(.red) && two[540, 1200].near(.blue), "\(two[540, 150]) \(two[540, 1200])")
    // Nothing but the picture: no location, no turn left to apply, sRGB.
    for path in r.allPaths {
      let props = PhotoImages.properties(URL(fileURLWithPath: path))
      #expect(props[kCGImagePropertyGPSDictionary] == nil && props[kCGImagePropertyExifDictionary].map { "\($0)".contains("GPS") } != true)
      #expect(((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1)
      #expect((props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelRGB as String))
      #expect((props[kCGImagePropertyProfileName] as? String)?.contains("sRGB") != false)
    }
    // Eric's own crop on photo 1, hard left (x 0…240): red reaches most of the way across.
    var e = try f.store.edit(videoId: v.id)
    e.photoCrops[v.photos![0].id] = CropRect(x: 0, y: 0, w: 240, h: 300)
    try f.store.save(e, videoId: v.id)
    r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    one = try #require(PhotoImages.bitmap(URL(fileURLWithPath: r.allPaths[0])))
    #expect(one[200, 700].near(.red) && one[820, 700].near(.red) && one[1000, 700].near(.blue), "\(one[820, 700]) \(one[1000, 700])")
  }

  @Test func textIsDrawnOnlyOnThePhotosInItsWindow() throws {
    let f = try fixture()
    let v = try f.photoPost("txt", count: 3)
    let renderer = Renderer(store: f.store)
    let plain = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let without = try plain.allPaths.map { try #require(PhotoImages.bitmap(URL(fileURLWithPath: $0))) }
    // "Photos 2–2": the first text on the second photo only.
    var ver = Version(number: 1)
    ver.text = "SATURDAY"
    (ver.textStart, ver.textEnd) = { let w = PhotoRules.window(fromPhoto: 2, toPhoto: 2); return (w.start, w.end) }()
    try f.store.save(ver, videoId: v.id)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(r.id != plain.id)
    let with = try r.allPaths.map { try #require(PhotoImages.bitmap(URL(fileURLWithPath: $0))) }
    #expect(with[0].difference(without[0]) == 0 && with[2].difference(without[2]) == 0, "photos 1 and 3 have no text")
    #expect(with[1].difference(without[1]) > 2000, "photo 2 has the text")
    // The text sits where the editor puts it (centre by default), not at the top.
    #expect(with[1].difference(without[1], in: 0..<300) == 0 && with[1].difference(without[1], in: 500..<850) > 2000)
    // No window: every photo. A second text on the last photo only stacks on top of it.
    ver.textStart = nil
    ver.textEnd = nil
    ver.moreText = [TextLayer(text: "LAST ONE", posY: 0.15, start: 2, end: 3)]
    try f.store.save(ver, videoId: v.id)
    let all = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let every = try all.allPaths.map { try #require(PhotoImages.bitmap(URL(fileURLWithPath: $0))) }
    #expect(every.indices.allSatisfy { every[$0].difference(without[$0], in: 500..<850) > 2000 })
    #expect(every[0].difference(without[0], in: 0..<350) == 0 && every[1].difference(without[1], in: 0..<350) == 0)
    #expect(every[2].difference(without[2], in: 0..<350) > 1000)
    // "No text" takes them all off again: the first render's pixels, and its hash.
    ver.noText = true
    try f.store.save(ver, videoId: v.id)
    #expect(try renderer.editHash(videoId: v.id, versionNo: 1, platform: nil) == plain.editHash)
  }

  @Test func theHashFollowsWhatIsInTheFilesAndNothingElse() throws {
    let f = try fixture()
    let v = try f.photoPost("hash", count: 3)
    let renderer = Renderer(store: f.store), importer = PhotoImport(store: f.store)
    func hash(_ p: Platform? = nil) throws -> String { try renderer.editHash(videoId: v.id, versionNo: 1, platform: p) }
    let h0 = try hash()
    #expect(try hash() == h0 && hash(.x) == h0 && hash(.tiktok) == h0)
    #expect(Renderer.pipelineVersion == "render-3" && PhotoRenderer.pipelineVersion == "photo-1")
    // Things that aren't in the pictures: the title, the caption, platforms, a per-platform trim, the score.
    try f.store.setTitle(v.id, "Saturday")
    var ver = Version(number: 1)
    ver.caption = "A caption"
    try f.store.save(ver, videoId: v.id)
    var e = try f.store.edit(videoId: v.id)
    e.skippedPlatforms.insert(.x)
    e.platformTrims[.tiktok] = TrimRange(start: 0, end: 1)
    try f.store.save(e, videoId: v.id)
    try f.store.setScore(v.id, 55)
    #expect(try hash() == h0 && hash(.tiktok) == h0)
    // Confirming the centred crop writes it down without moving a pixel.
    _ = try BulkActions(store: f.store).confirmDefaultCrop(try #require(try f.store.video(id: v.id)), try f.store.settings())
    #expect(try f.store.resolvedEdit(videoId: v.id).cropConfirmed && hash() == h0)
    // Things that are: the order, a crop, the aspect, the text, where the text shows, the set of photos.
    var seen: Set<String> = [h0]
    let ids = try #require(v.photos).map(\.id)
    _ = try importer.reorder(videoId: v.id, ids: [ids[1], ids[0], ids[2]])
    #expect(seen.insert(try hash()).inserted, "order")
    e = try f.store.edit(videoId: v.id)
    e.photoCrops[ids[0]] = CropRect(x: 0, y: 0, w: 240, h: 300)
    try f.store.save(e, videoId: v.id)
    #expect(seen.insert(try hash()).inserted, "crop")
    e.aspectOverride = .r1x1
    try f.store.save(e, videoId: v.id)
    #expect(seen.insert(try hash()).inserted, "aspect")
    ver.text = "Hello"
    try f.store.save(ver, videoId: v.id)
    #expect(seen.insert(try hash()).inserted, "text")
    ver.textEnd = 1
    ver.textStart = 0
    try f.store.save(ver, videoId: v.id)
    #expect(seen.insert(try hash()).inserted, "text window")
    ver.textLook = TextLook(color: "#FF3B30")
    try f.store.save(ver, videoId: v.id)
    #expect(seen.insert(try hash()).inserted, "look")
    _ = try importer.remove(photoId: ids[2], from: v.id)
    #expect(seen.insert(try hash()).inserted, "a photo removed")
    _ = try importer.append(files: f.pictures(["more.jpg"]), to: v.id)
    #expect(seen.insert(try hash()).inserted, "a photo added")
    // New-photo defaults move a post that follows them, not one with its own aspect.
    let before = try hash()
    try f.updateSettings { $0.defaults.photoAspect = .r9x16 }
    #expect(try hash() == before)
    e.aspectOverride = nil
    try f.store.save(e, videoId: v.id)
    let follows = try hash()
    try f.updateSettings { $0.defaults.photoAspect = .r1x1 }
    #expect(try hash() != follows)
  }

  @Test func aRenderWithAFileGoneIsMadeAgainAndASmallerCarouselLeavesNoFileBehind() throws {
    let f = try fixture()
    let v = try f.photoPost("gone", count: 3)
    let renderer = Renderer(store: f.store)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    try FileManager.default.removeItem(atPath: r.allPaths[1])
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil) == nil)
    let again = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(again.id != r.id && again.allPaths == r.allPaths && again.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    #expect(try f.store.renders().map(\.id) == [again.id])
    // One photo fewer: two files, and the third is gone from Ready to Post.
    _ = try PhotoImport(store: f.store).remove(photoId: v.photos![2].id, from: v.id)
    let two = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(two.allPaths == Array(r.allPaths.prefix(2)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: ready(f).path).sorted() == two.allPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
    // A photo that can't be read fails the render with the reason and leaves the good files alone.
    try Data("broken".utf8).write(to: try f.store.photoURLs(try #require(try f.store.video(id: v.id)))[0])
    var e = try f.store.edit(videoId: v.id)
    e.aspectOverride = .r1x1
    try f.store.save(e, videoId: v.id)
    #expect(throws: RenderError.self) { try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil) }
    #expect(try f.store.renders(where: "status='failed' AND deleted_at IS NULL").first?.error?.contains("Photo 1") == true)
    #expect(two.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
  }

  @Test func deleteRendersRemovesEveryFileOfAPhotoRenderAndOnlyAppMadeOnes() throws {
    let f = try fixture()
    let v = try f.photoPost("del", count: 2)
    let renderer = Renderer(store: f.store)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    // A path that isn't the app's output (a copy in Originals) must never be deleted, whatever a row says.
    let original = try f.store.photoURLs(v)[0]
    try f.store.setRenderMorePaths(id: r.id, (r.morePaths ?? []) + [original.path])
    try renderer.deleteRenders(except: [r.id])
    #expect(r.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    try renderer.deleteRenders(except: [])
    #expect(r.allPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(try f.store.renders().isEmpty)
    #expect(renderer.isAppOutput(URL(fileURLWithPath: r.allPaths[1])) && !renderer.isAppOutput(original))
  }

  @Test func theEngineRendersAheadAndMovesEveryFileToPosted() throws {
    let f = try fixture()
    let v = try f.photoPost("eng", count: 3)
    try f.send(v.id)
    let renderer = Renderer(store: f.store)
    let notifier = LogNotifier()
    let engine = Engine(store: f.store, renderer: renderer, publisher: ManualPublisher(store: f.store, renderer: renderer), notifier: notifier)
    let report = engine.tick(reason: "test")
    #expect(report.errors.isEmpty, "\(report.errors)")
    #expect(report.steps["render"]?.hasPrefix("rendered 1 · attached 4") == true, "\(report.steps["render"] ?? "")")
    let posts = try f.store.posts(where: "video_id=?", [v.id])
    let rid = try #require(posts.first?.renderId)
    #expect(posts.count == 5 && posts.allSatisfy { $0.renderId == rid && $0.state == .rendered })
    let r = try #require(try f.store.render(id: rid))
    #expect(r.allPaths.count == 3 && r.allPaths.allSatisfy { $0.contains("/Photos/Ready to Post/Shortform/") })
    // A second tick renders nothing new and keeps the render.
    let second = engine.tick(reason: "test")
    #expect(second.steps["render"]?.hasPrefix("rendered 0 · attached 0") == true)
    #expect(second.steps["proxies"]?.hasPrefix("queued 0") == true, "a photo post gets no preview video: \(second.steps["proxies"] ?? "")")
    #expect(try f.store.renders().map(\.id) == [rid])
    // Posted everywhere: every file moves to Posted/Shortform and the render follows them.
    try f.postAll(on: f.dm.key(f.clock.now))
    #expect(engine.tick(reason: "test").steps["move"]?.hasPrefix("moved 1") == true)
    let moved = try #require(try f.store.render(id: rid))
    let movedRaw = try #require(try f.store.db.one("SELECT more_paths FROM renders WHERE id=?", [rid])?.string("more_paths"))
    #expect(movedRaw.contains(moved.allPaths[1]) && !movedRaw.contains("\\/"))
    #expect(moved.allPaths.count == 3 && moved.allPaths.allSatisfy { $0.contains("/Photos/Posted/Shortform/") && FileManager.default.fileExists(atPath: $0) })
    #expect(moved.allPaths.map { URL(fileURLWithPath: $0).lastPathComponent } == r.allPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
    #expect(try FileManager.default.contentsOfDirectory(atPath: ready(f).path).isEmpty)
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: nil)?.id == rid, "still the post's render")
    #expect(try f.store.video(id: v.id)?.state == .posted)
    // Cleanup after N days deletes every posted file.
    try f.updateSettings { $0.cleanup = .deleteAfter(days: 2) }
    f.clock.advance(3 * 86400)
    _ = engine.tick(reason: "test")
    #expect(moved.allPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(try f.store.render(id: rid)?.deletedAt != nil)
  }

  @Test func previewsAndThumbnailsAreTheRenderAtAnotherSize() throws {
    let f = try fixture()
    let v = try f.photoPost("pre", count: 2)
    var ver = Version(number: 1)
    ver.text = "ONLY THE FIRST"
    ver.textStart = 0
    ver.textEnd = 1
    try f.store.save(ver, videoId: v.id)
    // The preview at the output size is the rendered file (up to JPEG noise).
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let rendered = try r.allPaths.map { try #require(PhotoImages.bitmap(URL(fileURLWithPath: $0))) }
    for i in 0..<2 {
      let img = try #require(PhotoRenderer.preview(store: f.store, video: v, index: i))
      #expect(img.width == 1080 && img.height == 1350)
      let d = PhotoImages.bitmap(img).difference(rendered[i])
      #expect(d < 15000, "photo \(i + 1) differs from its render in \(d) pixels")
    }
    let bare = PhotoImages.bitmap(try #require(PhotoRenderer.preview(store: f.store, video: v, index: 0, withText: false)))
    #expect(bare.difference(rendered[0]) > 25000, "the render has the text")
    // Smaller, with and without the text; only the first photo has any.
    let size = CGSize(width: 216, height: 270)
    let a = PhotoImages.bitmap(try #require(PhotoRenderer.preview(store: f.store, video: v, index: 0, size: size)))
    let b = PhotoImages.bitmap(try #require(PhotoRenderer.preview(store: f.store, video: v, index: 0, size: size, withText: false)))
    #expect(a.width == 216 && a.height == 270 && a.difference(b) > 100)
    let c = PhotoImages.bitmap(try #require(PhotoRenderer.preview(store: f.store, video: v, index: 1, size: size)))
    let d = PhotoImages.bitmap(try #require(PhotoRenderer.preview(store: f.store, video: v, index: 1, size: size, withText: false)))
    #expect(c.difference(d) == 0)
    #expect(PhotoRenderer.preview(store: f.store, video: v, index: 5) == nil)
    // The pure form the editor calls with unsaved values gives the same picture.
    let photo = try #require(v.photos?[0])
    let src = try #require(PhotoRenderer.load(try f.store.photoURLs(v)[0]))
    let rv = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    let pure = try #require(PhotoRenderer.image(src, photo: photo, index: 0, count: 2, edit: try f.store.edit(videoId: v.id), version: rv,
                                                defaults: try f.store.settings().defaults, size: size))
    #expect(PhotoImages.bitmap(pure).difference(a) < 1500)
    // Thumbnails: cached per photo, the first one in the cover's slot, redone when the crop changes.
    let t0 = try #require(Media.thumbnail(store: f.store, video: v))
    #expect(Media.thumbnail(store: f.store, video: v) == t0 && t0.lastPathComponent.hasPrefix("\(v.id)-c1h320-"))
    let tb = try #require(PhotoImages.bitmap(t0))
    #expect(tb.width == 256 && tb.height == 320)
    let t1 = try #require(Media.thumbnail(store: f.store, video: v, photo: 1))
    #expect(t1 != t0 && Media.thumbnail(store: f.store, video: v, photo: 2) == nil)
    var e = try f.store.edit(videoId: v.id)
    e.photoCrops[photo.id] = CropRect(x: 0, y: 0, w: 240, h: 300)
    try f.store.save(e, videoId: v.id)
    let t2 = try #require(Media.thumbnail(store: f.store, video: v))
    #expect(t2 != t0 && !FileManager.default.fileExists(atPath: t0.path) && FileManager.default.fileExists(atPath: t1.path))
  }

  @Test func aPhotoPostIsNeverProbedOrProxied() throws {
    let f = try fixture()
    let v = try f.photoPost("np", count: 2, width: 640, height: 480)
    // The size comes from the row, even when nothing is cached on it.
    var bare = v
    bare.sourceWidth = nil
    bare.sourceHeight = nil
    #expect(Media.sourceSize(store: f.store, video: bare) == CGSize(width: 640, height: 480))
    #expect(Media.cachedProxy(store: f.store, video: v) == nil)
    #expect(throws: MediaError.self) { try Media.ensureProxy(store: f.store, video: v) }
    // The proxy queue answers without encoding and without recording a failure against the post.
    let ps = ProxyService(store: f.store)
    let made = Counter()
    ps.make = { _, _, _ in made.bump(); return URL(fileURLWithPath: "/dev/null") }
    let done = DispatchSemaphore(value: 0)
    let failed = Counter()
    ps.request(v.id, priority: .background) { result in
      if case .failure = result { failed.bump() }
      done.signal()
    }
    #expect(done.wait(timeout: .now() + 10) == .success)
    #expect(made.value == 0 && failed.value == 1)
    #expect(try f.store.kv(ProxyService.failKey(v.id), as: String.self) == nil)
    // Bulk actions that need a clip's size don't probe either.
    #expect(try BulkActions(store: f.store).cachedOrProbedSize(bare) == CGSize(width: 640, height: 480))
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
  }
}
