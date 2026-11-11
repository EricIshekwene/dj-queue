import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import DJQCore

/// Round 21 (P1, D1–D3): importing photos makes photo posts from copies; the originals are never touched.
@Suite struct R21PhotoImportTests {
  func sha(_ url: URL) throws -> String { try #require(PhotoImport.fingerprint(url)) }

  @Test func carouselIsOnePostFromEveryFileInOrder() throws {
    let f = try Fixture()
    let files = f.pictures(["a.jpg", "b.png", "c.jpg"])
    let before = try files.map(sha)
    let r = try PhotoImport(store: f.store).add(files: files, title: "  Saturday at Elsewhere ")
    #expect(r.skipped.isEmpty && r.posts.count == 1)
    let v = try #require(r.posts.first)
    let photos = try #require(v.photos)
    #expect(v.isPhoto && photos.count == 3 && v.isCarousel && v.photoLabel == "Carousel · 3")
    #expect(v.type == .short && v.duration == 0 && v.sessionId == Session.photosId && !v.inManifest && v.contentType == "photo")
    #expect(v.score == nil && v.state == .needsEdit && !v.sentToQueue && !v.missing && !v.excluded)
    #expect(v.kind == (try f.store.settings().defaults.kind))
    #expect(v.title == "Saturday at Elsewhere" && v.titleSource == "app")
    #expect(v.name == "a" && v.tags == ["a"] && v.file == photos[0].file)
    #expect(v.fingerprint != nil && (v.fileSize ?? 0) > 0)
    #expect(v.sourceWidth == 400 && v.sourceHeight == 300)
    // The copies: Originals/<post id>/NN-<photo id>.<ext>, in the order given, byte for byte.
    for (i, p) in photos.enumerated() {
      let ext = i == 1 ? "png" : "jpg"
      #expect(p.file == "Originals/\(v.id)/\(String(format: "%02d", i + 1))-\(p.id).\(ext)")
      #expect(p.width == 400 && p.height == 300)
      let copy = f.paths.photos.appendingPathComponent(p.file)
      #expect(try sha(copy) == before[i] && p.fingerprint == before[i])
      #expect(try f.store.photoURL(p, of: v) == copy)
    }
    #expect(Set(photos.map(\.id)).count == 3)
    // The originals are still where they were, unchanged.
    #expect(try files.map(sha) == before)
    // The Photos session exists once, and YouTube is off in the stored edit (D8).
    let s = try #require(try f.store.session(id: Session.photosId))
    #expect(s.name == "Photos" && s.folder == f.paths.photos.path && !s.missing && s.isPhotos)
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube])
    let stored = try #require(try f.store.db.one("SELECT json FROM edits WHERE video_id=?", [v.id])?.string("json"))
    #expect(stored.contains("youtube"))
    #expect(try f.store.events(videoId: v.id).contains { $0.kind == "photo" })
  }

  @Test func separateMakesAPostPerFileAndASinglePhotoIsAPhoto() throws {
    let f = try Fixture()
    let files = f.pictures(["one.jpg", "two.jpg"])
    let r = try PhotoImport(store: f.store).add(files: files, mode: .separate)
    #expect(r.posts.count == 2 && r.posts.map(\.name) == ["one", "two"])
    #expect(r.posts.allSatisfy { $0.photoCount == 1 && !$0.isCarousel && $0.photoLabel == "Photo" && $0.title == nil })
    #expect(Set(r.posts.map(\.id)).count == 2)
    #expect(try f.store.sessions().filter(\.isPhotos).count == 1)
    // A second import of a file with the same name gets its own name, so its renders never share a file.
    let again = try PhotoImport(store: f.store).add(files: [files[0]])
    #expect(again.posts.first?.name == "one 2" && again.posts.first?.tags == ["one"])
  }

  @Test func filesThatCantBePhotosAreSkippedWithTheReason() throws {
    let f = try Fixture()
    let good = f.pictures(["ok.jpg"])[0]
    let text = f.inbox.appendingPathComponent("notes.txt"), broken = f.inbox.appendingPathComponent("broken.jpg")
    try Data("hello".utf8).write(to: text)
    try Data("not a jpeg at all".utf8).write(to: broken)
    let gone = f.inbox.appendingPathComponent("gone.jpg"), folder = f.inbox.appendingPathComponent("folder.jpg")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let r = try PhotoImport(store: f.store).add(files: [text, good, broken, gone, folder])
    #expect(r.posts.count == 1 && r.posts[0].photoCount == 1 && r.posts[0].name == "ok")
    let why = Dictionary(uniqueKeysWithValues: r.skipped.map { (URL(fileURLWithPath: $0.file).lastPathComponent, $0.reason) })
    #expect(why["notes.txt"]?.contains("not a photo format") == true)
    #expect(why["broken.jpg"] == "it can't be read as a photo")
    #expect(why["gone.jpg"] == "the file isn't there")
    #expect(why["folder.jpg"] == "it's a folder")
    // Nothing usable: no post, no session row needed, nothing left behind.
    let none = try PhotoImport(store: f.store).add(files: [text, broken])
    #expect(none.posts.isEmpty && none.skipped.count == 2)
    #expect(try f.store.videos(where: "photos IS NOT NULL").count == 1)
    let dirs = try FileManager.default.contentsOfDirectory(atPath: f.paths.photos.appendingPathComponent("Originals").path)
    #expect(dirs == [r.posts[0].id])
  }

  @Test func uprightSizeFollowsTheExifOrientation() throws {
    let f = try Fixture()
    let turned = f.inbox.appendingPathComponent("turned.jpg")
    PhotoImages.write(turned, width: 400, height: 300, orientation: 6)
    #expect(PhotoRenderer.pixelSize(of: turned).map { [$0.width, $0.height] } == [300, 400])
    let v = try #require(try PhotoImport(store: f.store).add(files: [turned]).posts.first)
    #expect(v.photos?.first?.width == 300 && v.photos?.first?.height == 400)
    // Read upright: the stored left half (red) is the top of the picture, the right half (blue) the bottom.
    let img = try #require(PhotoRenderer.load(try f.store.photoURLs(v)[0]))
    #expect(img.width == 300 && img.height == 400)
    let b = PhotoImages.bitmap(img)
    #expect(b[150, 40].near(.red) && b[150, 360].near(.blue), "top \(b[150, 40]) bottom \(b[150, 360])")
  }

  @Test func heicTiffAndWebpExtensionsAreTaken() throws {
    let f = try Fixture()
    let tiff = f.inbox.appendingPathComponent("scan.TIFF")
    #expect(PhotoImages.write(tiff, type: .tiff))
    var files = [tiff]
    let heic = f.inbox.appendingPathComponent("phone.heic")
    let hasHEIC = PhotoImages.write(heic, type: .heic)  // no HEIC encoder on some Macs: then only TIFF is checked
    if hasHEIC { files.append(heic) }
    let v = try #require(try PhotoImport(store: f.store).add(files: files).posts.first)
    #expect(v.photoCount == files.count)
    #expect(v.photos?[0].file.hasSuffix(".tiff") == true)
    if hasHEIC { #expect(v.photos?[1].file.hasSuffix(".heic") == true && v.photos?[1].width == 400) }
    // Both decode and render to JPEG.
    let r = try Renderer(store: f.store).ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    #expect(r.allPaths.count == files.count && r.allPaths.allSatisfy { $0.hasSuffix(".jpg") && PhotoImages.bitmap(URL(fileURLWithPath: $0))?.width == 1080 })
    let first = try #require(PhotoImages.bitmap(URL(fileURLWithPath: r.allPaths[0])))
    #expect(first[200, 700].near(.red) && first[880, 700].near(.blue))
    #expect(PhotoRules.extensions.isSuperset(of: ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]))
    // WebP: this Mac can read it but not write it, so the picture is a one-pixel file spelled out here.
    let webp = f.inbox.appendingPathComponent("tiny.webp")
    try #require(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")).write(to: webp)
    let w = try #require(try PhotoImport(store: f.store).add(files: [webp]).posts.first)
    #expect(w.photos?.first?.file.hasSuffix(".webp") == true && w.photos?.first?.width == 1 && w.photos?.first?.height == 1)
    #expect(PhotoRenderer.load(try f.store.photoURLs(w)[0]) != nil)
  }

  @Test func aPostHoldsAtMostThePhotosTheLargestPlatformTakes() throws {
    let f = try Fixture()
    #expect(PhotoRules.maxPerPost == 35)
    let one = f.pictures(["p.jpg"], width: 40, height: 30)[0]
    let files = Array(repeating: one, count: 37)
    let r = try PhotoImport(store: f.store).add(files: files)
    #expect(r.posts.first?.photoCount == 35 && r.skipped.count == 2)
    #expect(r.skipped.allSatisfy { $0.reason == "a post holds at most 35 photos" })
    let more = try PhotoImport(store: f.store).append(files: [one], to: r.posts[0].id)
    #expect(more.video.photoCount == 35 && more.skipped.count == 1 && more.batchId == nil)
  }

  @Test func appendRemoveAndReorderKeepTheFirstPhotoAsTheFileAndUndo() throws {
    let f = try Fixture()
    let v = try f.photoPost(count: 2)
    let importer = PhotoImport(store: f.store), bulk = BulkActions(store: f.store)
    let ids0 = try #require(v.photos).map(\.id)
    // A crop on each photo, to see stale ones go.
    var e = try f.store.edit(videoId: v.id)
    for p in v.photos ?? [] { e.photoCrops[p.id] = PhotoRules.centredCrop(p, aspect: .r4x5) }
    try f.store.save(e, videoId: v.id)

    // Append: at the end, numbered on from the last file, one journal entry.
    let extra = f.pictures(["extra.jpg"])[0]
    let added = try importer.append(files: [extra], to: v.id)
    let ids1 = try #require(added.video.photos).map(\.id)
    #expect(ids1.count == 3 && Array(ids1.prefix(2)) == ids0 && added.skipped.isEmpty)
    #expect(added.video.photos?[2].file.contains("/03-") == true)
    #expect(added.video.fingerprint != v.fingerprint && (added.video.fileSize ?? 0) > (v.fileSize ?? 0))
    let addBatch = try #require(added.batchId)
    #expect(try bulk.batch(id: addBatch)?.action == "photo-add")

    // Reorder: the new first photo is the post's file and picture size; crops stay with their photos.
    let order = [ids1[2], ids1[0], ids1[1]]
    let moved = try importer.reorder(videoId: v.id, ids: order)
    #expect(moved.video.photos?.map(\.id) == order && moved.video.file == moved.video.photos?[0].file)
    #expect(try f.store.edit(videoId: v.id).photoCrops.keys.sorted() == ids0.sorted())
    #expect(try importer.reorder(videoId: v.id, ids: order).batchId == nil, "the same order changes nothing")
    #expect(throws: (any Error).self) { try importer.reorder(videoId: v.id, ids: [ids1[0]]) }
    #expect(throws: (any Error).self) { try importer.reorder(videoId: v.id, ids: order + ["nope"]) }

    // Remove: its crop goes, its copy stays on disk, and the last photo can't go.
    let gone = try importer.remove(photoId: ids0[0], from: v.id)
    #expect(gone.video.photos?.map(\.id) == [ids1[2], ids1[1]])
    #expect(try f.store.edit(videoId: v.id).photoCrops.keys.sorted() == [ids0[1]])
    let removedFile = try #require(v.photos?[0]).file
    #expect(FileManager.default.fileExists(atPath: f.paths.photos.appendingPathComponent(removedFile).path))
    _ = try importer.remove(photoId: ids1[2], from: v.id)
    #expect(throws: (any Error).self) { try importer.remove(photoId: ids1[1], from: v.id) }
    #expect(throws: (any Error).self) { try importer.remove(photoId: "nope", from: v.id) }
    #expect(try f.store.video(id: v.id)?.photoCount == 1)

    // Undo, newest first, puts back the photos, the order, the file and the crops.
    for b in try bulk.batches().filter({ $0.action.hasPrefix("photo-") }) { try bulk.undo(b.id) }
    let back = try #require(try f.store.video(id: v.id))
    #expect(back.photos == v.photos && back.file == v.file && back.fingerprint == v.fingerprint && back.fileSize == v.fileSize)
    #expect(try f.store.edit(videoId: v.id).photoCrops.keys.sorted() == ids0.sorted())
    // A clip isn't a photo post.
    try f.intake()
    #expect(throws: (any Error).self) { try importer.append(files: [extra], to: "clip-0") }
  }

  @Test func anEditorSessionJournalsPhotoChangesWithTheRest() throws {
    let f = try Fixture()
    let v = try f.photoPost(count: 3)
    let bulk = BulkActions(store: f.store), importer = PhotoImport(store: f.store)
    let ids = try #require(v.photos).map(\.id)
    let open = try bulk.begin("edit", ids: [v.id])
    _ = try importer.reorder(videoId: v.id, ids: ids.reversed(), journal: false)
    _ = try importer.remove(photoId: ids[1], from: v.id, journal: false)
    #expect(try bulk.batches().isEmpty)
    let r = try bulk.commit(open)
    #expect(r.changed == [v.id])
    try bulk.undo(try #require(r.batchId))
    #expect(try f.store.video(id: v.id)?.photos == v.photos)
  }

  @Test func intakeLeavesPhotoPostsAloneAndMarksAMissingPhotoFile() throws {
    let f = try Fixture()
    let v = try f.photoPost(count: 2)
    let report = try f.intake()
    #expect(report.removedFromManifest.isEmpty && report.missing.isEmpty && report.untracked.isEmpty)
    var now = try #require(try f.store.video(id: v.id))
    #expect(!now.missing && !now.inManifest && now.photos == v.photos && now.state == .needsEdit)
    #expect(try f.store.session(id: Session.photosId)?.missing == false)
    #expect(ClipStage.of(now) == .edit)
    // A photo file goes: the post is missing, like a clip; nothing else about it changes.
    let second = f.paths.photos.appendingPathComponent(try #require(v.photos?[1]).file)
    let parked = f.dir.appendingPathComponent("parked.jpg")
    try FileManager.default.moveItem(at: second, to: parked)
    #expect(try f.intake().missing == [v.name])
    now = try #require(try f.store.video(id: v.id))
    #expect(now.missing && now.state == .missingFile && ClipStage.of(now) == .edit && now.photos == v.photos)
    #expect(try Validation.issues(video: now, store: f.store).map(\.kind) == [.missingFile])
    #expect(try f.intake().missing.isEmpty, "said once")
    #expect(try f.store.session(id: Session.photosId)?.missing == false)
    // Doctor says which file, and nothing false about the photo post.
    let doctor = Doctor(store: f.store)
    doctor.probeDurations = false
    let findings = doctor.run().findings
    let missing = try #require(findings.first { $0.id == "photos.missing" })
    #expect(missing.where_.count == 1 && missing.where_[0].contains(second.path))
    #expect(!findings.contains { ["files.missing", "files.untracked", "manifest.parse", "files.duration"].contains($0.id) })
    // The file comes back: so does the post.
    try FileManager.default.moveItem(at: parked, to: second)
    try f.intake()
    now = try #require(try f.store.video(id: v.id))
    #expect(!now.missing && now.state == .needsEdit)
    #expect(!doctor.run().findings.contains { $0.id == "photos.missing" })
  }

  @Test func aSentPhotoPostWhoseFileGoesLeavesTheQueue() throws {
    let f = try Fixture()
    let v = try f.photoPost(count: 1)
    try f.send(v.id)
    #expect(try f.store.video(id: v.id)?.state == .ready)
    try FileManager.default.removeItem(at: try f.store.photoURLs(v)[0])
    try f.intake()
    let now = try #require(try f.store.video(id: v.id))
    #expect(now.missing && now.state == .missingFile && !now.sentToQueue)
  }
}
