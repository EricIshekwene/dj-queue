import Foundation
import Testing
@testable import DJQCore

/// Round 21, the two halves together: a photo post (no score, never YouTube) takes a set time, renders one file per
/// photo and shows in the week JSON.
@Suite struct R21IntegrationTests {
  /// Two days after the fixture's Monday 9:00, 3:15 PM New York.
  func wednesdayAfternoon(_ f: Fixture) throws -> Date {
    try Planner.parseExact("2026-11-04 15:15", settings: try f.store.settings())
  }

  @Test func anUnscoredPhotoPostInEditTakesASetTimeOnFivePlatforms() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("flyer", count: 3, title: "Friday at the Loft")
    #expect(post.score == nil && ClipStage.of(post) == .edit && !post.sentToQueue)
    let before = try ExactRig.others(f, except: post.id)
    let at = try wednesdayAfternoon(f)

    let preview = try BulkActions(store: f.store).postAtPreview(post.id, at: at)
    #expect(preview.blocker == nil)
    #expect(Set(preview.platforms.map(\.platform)) == Set(Platform.allCases.filter(\.supportsPhotos)))
    #expect(try f.store.video(id: post.id)?.sentToQueue == false)  // a preview sends nothing

    let r = try BulkActions(store: f.store).postAt([post.id], at: at)
    #expect(r.changed == [post.id])
    let after = try #require(try f.store.video(id: post.id))
    #expect(after.sentToQueue && after.score == nil && ClipStage.of(after) == .scheduled)
    let slot = try #require(try Planner(store: f.store).exactSlot(videoId: post.id))
    #expect(slot.exactAt == at && slot.pinned && slot.position >= PlanSlot.exactBase)
    let posts = try f.store.posts(where: "video_id=?", [post.id])
    #expect(Set(posts.map(\.platform)) == [.tiktok, .instagram, .facebook, .threads, .x])
    #expect(posts.allSatisfy { $0.scheduledAt == at && $0.planSlotId == slot.id && $0.kind == .regular })
    #expect(try ExactRig.others(f, except: post.id) == before)
    #expect(try ExactRig.twice(f).isEmpty && ExactRig.cardless(f).isEmpty)

    // The scheduler leaves it alone, and never gives it a regular day or a YouTube post.
    for _ in 0..<3 { try Planner(store: f.store).autoSchedule() }
    #expect(try f.store.planSlots(where: "video_id=?", [post.id]).map(\.id) == [slot.id])
    #expect(try f.store.posts(where: "video_id=? AND platform='youtube'", [post.id]).isEmpty)

    // One undo takes back the time and the send.
    try BulkActions(store: f.store).undo(try #require(r.batchId))
    let undone = try #require(try f.store.video(id: post.id))
    #expect(!undone.sentToQueue && ClipStage.of(undone) == .edit)
    #expect(try f.store.planSlots(where: "video_id=?", [post.id]).isEmpty)
    #expect(try f.store.posts(where: "video_id=?", [post.id]).isEmpty)
  }

  @Test func aSetTimePhotoPostRendersOneFilePerPhotoAndShowsInTheWeekJSON() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("set", count: 3)
    let at = try wednesdayAfternoon(f)
    try BulkActions(store: f.store).postAt([post.id], at: at)

    let render = try Renderer(store: f.store).ensureRender(videoId: post.id, versionNo: 1, platform: .instagram)
    #expect(render.status == .done && render.allPaths.count == 3)
    #expect(render.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) && f.paths.owns(URL(fileURLWithPath: $0)) })

    let dm = DayMath(settings: try f.store.settings())
    let week = try AgentAPI.week(dm.weekStart(of: at), store: f.store)
    let slots = week.days.flatMap(\.slots)
    let mine = try #require(slots.first { $0.video_id == post.id })
    #expect(mine.exact_at == at && mine.position >= PlanSlot.exactBase && mine.pinned)
    #expect(slots.filter { $0.video_id != post.id }.allSatisfy { $0.exact_at == nil })
    // A regular slot's JSON has no `exact_at` key at all, so existing readers see what they saw.
    let json = String(decoding: try JSONCoding.encoder.encode(slots.filter { $0.video_id != post.id }), as: UTF8.self)
    #expect(!json.contains("exact_at"))
  }

  /// D20 with a set time: a 9:16 photo post that goes to Instagram isn't ready, so it stays in Edit and says why.
  @Test func aNineBySixteenPhotoPostForInstagramStaysInEdit() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("tall", count: 1)
    var e = try f.store.edit(videoId: post.id)
    e.aspectOverride = .r9x16
    try f.store.save(e, videoId: post.id)
    let r = try BulkActions(store: f.store).postAt([post.id], at: try wednesdayAfternoon(f))
    #expect(r.changed.isEmpty && r.skipped[post.id]?.contains("Instagram") == true)
    #expect(try f.store.video(id: post.id)?.sentToQueue == false)
    #expect(try f.store.planSlots(where: "video_id=?", [post.id]).isEmpty)
  }
}

/// A scripted run keeps its photos outside the shared dev footage folder (`DJQ_PHOTOS`).
@Suite struct R21PhotosFolderTests {
  @Test func aPhotosFolderOutsideTheRootIsOwnedAndUsed() throws {
    let f = try Fixture()
    var paths = f.paths
    let scratch = f.dir.appendingPathComponent("scratch-photos")
    #expect(!paths.owns(scratch.appendingPathComponent("Ready to Post/Shortform/a.jpg")))
    paths.photosOverride = scratch
    #expect(paths.photos == scratch)
    #expect(paths.owns(scratch.appendingPathComponent("Ready to Post/Shortform/a.jpg")))
    #expect(paths.owns(paths.sessions.appendingPathComponent("S/Ready to Post/Shortform/a.mp4")))
    #expect(!paths.owns(f.dir.appendingPathComponent("elsewhere/a.jpg")))

    let store = try Store(memoryWith: paths, clock: f.clock)
    let files = f.pictures(["one.jpg", "two.jpg"])
    let post = try requireValue(try PhotoImport(store: store).add(files: files).posts.first)
    #expect(try store.photoURLs(post).allSatisfy { $0.path.hasPrefix(scratch.path) && FileManager.default.fileExists(atPath: $0.path) })
    let render = try Renderer(store: store).ensureRender(videoId: post.id, versionNo: 1, platform: nil)
    #expect(render.allPaths.count == 2 && render.allPaths.allSatisfy { $0.hasPrefix(scratch.path) })
    #expect(!FileManager.default.fileExists(atPath: f.paths.root.appendingPathComponent("Photos").path))
  }
}

/// A text on a photo post stays with its photos when one is removed (`PhotoTextRanges`).
@Suite struct R21PhotoTextRangeTests {
  func window(_ w: (start: Double?, end: Double?, moved: Bool)?) -> String {
    guard let w else { return "same" }
    return "\(w.start.map { String(Int($0)) } ?? "-")…\(w.end.map { String(Int($0)) } ?? "-")\(w.moved ? " moved" : "")"
  }

  @Test func theRuleForOneRemovedPhoto() {
    typealias R = PhotoTextRanges
    // Photos 2–3 of 4 are the window 1…3.
    #expect(window(R.removing(index: 0, start: 1, end: 3, count: 4)) == "0…2")       // a photo before it: same pictures, one place down
    #expect(window(R.removing(index: 1, start: 1, end: 3, count: 4)) == "1…2")       // one of its photos: the other stays
    #expect(window(R.removing(index: 2, start: 1, end: 3, count: 4)) == "1…2")
    #expect(window(R.removing(index: 3, start: 1, end: 3, count: 4)) == "same")      // a photo after it
    #expect(window(R.removing(index: 3, start: 3, end: 4, count: 4)) == "2…3 moved") // its only photo, the last: the new last
    #expect(window(R.removing(index: 0, start: 0, end: 1, count: 4)) == "0…1 moved") // its only photo, the first: the new first
    #expect(window(R.removing(index: 1, start: 1, end: 2, count: 2)) == "0…1 moved")
    #expect(window(R.removing(index: 1, start: nil, end: nil, count: 4)) == "same")  // every photo
    #expect(window(R.removing(index: 0, start: nil, end: 2, count: 4)) == "-…1")     // "from the start" stays written that way
    #expect(window(R.removing(index: 3, start: 2, end: nil, count: 4)) == "same")    // "to the end" still ends at the end
    #expect(window(R.removing(index: 0, start: 2, end: nil, count: 4)) == "1…-")
    #expect(window(R.removing(index: 2, start: 3, end: 1, count: 4)) == "same")      // inverted = the whole post
    #expect(window(R.removing(index: 0, start: 0, end: 1, count: 1)) == "same")      // the last photo never goes
  }

  @Test func aJournaledRemovalKeepsEachTextOnItsPhotosAndUndoPutsItBack() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("set", count: 4)
    var v = Version(number: 1)
    v.text = "Loft nights"
    v.noText = false
    v.textStart = 1
    v.textEnd = 3  // photos 2–3
    v.moreText = [TextLayer(id: "two", text: "Last one", start: 3, end: 4)]  // photo 4
    try f.store.save(v, videoId: post.id)
    let photos = try #require(try f.store.video(id: post.id)?.photos)
    let importer = PhotoImport(store: f.store)

    // Photo 1 goes: both texts are on the same pictures, one place down.
    let first = try importer.remove(photoId: photos[0].id, from: post.id)
    var now = try #require(try f.store.versions(videoId: post.id).first)
    #expect(now.textStart == 0 && now.textEnd == 2 && now.moreText?.first?.start == 2 && now.moreText?.first?.end == 3)
    let rv = try #require(try f.store.resolvedVersion(videoId: post.id, number: 1))
    #expect((0..<3).map { PhotoRules.layers(rv, onPhoto: $0, of: 3).count } == [1, 1, 1])

    // The photo "Last one" was on goes: it moves to the new last photo.
    let second = try importer.remove(photoId: photos[3].id, from: post.id)
    now = try #require(try f.store.versions(videoId: post.id).first)
    #expect(now.moreText?.first?.start == 1 && now.moreText?.first?.end == 2)

    // Undo the second removal, then the first: the photos, their order and both texts are as they were.
    try BulkActions(store: f.store).undo(try #require(second.batchId))
    try BulkActions(store: f.store).undo(try #require(first.batchId))
    #expect(try f.store.video(id: post.id)?.photos == photos)
    #expect(try f.store.versions(videoId: post.id).first == v)
  }

  @Test func setPhotosRestoresAListAndRefusesAMissingFile() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("list", count: 3)
    let photos = try #require(post.photos)
    let importer = PhotoImport(store: f.store)
    try importer.remove(photoId: photos[1].id, from: post.id, journal: false)
    let back = try importer.setPhotos(photos, videoId: post.id)
    #expect(back.photos == photos && back.file == photos[0].file)
    let reordered = try importer.setPhotos([photos[2], photos[0]], videoId: post.id)
    #expect(reordered.file == photos[2].file && reordered.photoCount == 2)
    #expect(ExactRig.message { _ = try importer.setPhotos([], videoId: post.id) } != nil)
    try FileManager.default.removeItem(at: try f.store.photoURL(photos[1], of: post))
    #expect(ExactRig.message { _ = try importer.setPhotos(photos, videoId: post.id) }?.contains("isn't on disk") == true)
    #expect(try f.store.video(id: post.id)?.photoCount == 2)
  }

  /// A photo file that is there but can't be read counts as missing: the post waits in Edit instead of failing at render.
  @Test func anUnreadablePhotoFileCountsAsMissing() throws {
    let f = try Fixture()
    try f.intake()
    let post = try f.photoPost("broken", count: 2)
    let url = try f.store.photoURL(try #require(post.photos?[1]), of: post)
    let good = try Data(contentsOf: url)
    try Data("not a picture".utf8).write(to: url)
    #expect(try PhotoImport(store: f.store).checkFiles() == [post.name])
    let missing = try #require(try f.store.video(id: post.id))
    let issues = try Validation.issues(video: missing, store: f.store)
    #expect(missing.missing && issues.contains { $0.kind == .missingFile })
    #expect(try BulkActions(store: f.store).sendToQueue([post.id]).changed.isEmpty)
    try good.write(to: url)
    #expect(try PhotoImport(store: f.store).checkFiles().isEmpty)
    #expect(try f.store.video(id: post.id)?.missing == false)
  }
}
