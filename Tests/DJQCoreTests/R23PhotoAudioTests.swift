import Foundation
import Testing
@testable import DJQCore

/// Round 23 (A1, A2, A5, D2, D3, D9): audio on a photo post turns the same item into a video; change and remove; undo
/// for each; and the times it is refused.
@Suite(.enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R23PhotoAudioTests {
  /// A photo post with everything a photo post can carry: a title, a caption and groups, two texts with looks and
  /// "shows on" ranges, a second version, its own shape and crop, and X turned off.
  func dressed(_ f: Fixture) throws -> Video {
    let v = try f.singlePhoto("flyer", title: "Saturday flyer")
    let photo = try #require(v.photos?.first)
    try f.store.save(HashtagSet(id: "house", name: "House", category: "DJ", tags: ["#house", "#dj"], sort: 0))
    var one = Version(number: 1)
    one.text = "Loft nights"
    one.style = .outline
    one.size = 72
    one.posY = 0.3
    one.textLook = TextLook(color: "#FF3B30")
    one.textStart = 0
    one.textEnd = 1
    one.moreText = [TextLayer(id: "second", text: "Doors at ten", posY: 0.8, start: 0, end: 1, look: TextLook(color: "#FFFFFF"))]
    one.caption = "Come through"
    one.hashtagSetIds = ["house"]
    one.extraHashtags = ["#brooklyn"]
    one.youtubeTitle = "Saturday at the Loft"
    one.platformCaptions = [.x: "Short one"]
    try f.store.save(one, videoId: v.id)
    var two = Version(number: 2)
    two.text = "Again next week"
    two.textStart = 0
    two.textEnd = 1
    try f.store.save(two, videoId: v.id)
    var e = try f.store.edit(videoId: v.id)
    e.aspectOverride = .r1x1
    e.photoCrops[photo.id] = PhotoRules.centredCrop(photo, aspect: .r1x1)
    e.skippedPlatforms.insert(.x)
    try f.store.save(e, videoId: v.id)
    return try #require(try f.store.video(id: v.id))
  }

  @Test func addAudioKeepsTheItemAndDropsOnlyWhatWasPhotoOnly() throws {
    let f = try Fixture(clips: [], longform: false)
    let before = try dressed(f)
    let photo = try #require(before.photos?.first)
    let audio = f.tone("Friday mix.wav", seconds: 4)
    let prints = [try #require(PhotoImport.fingerprint(audio)), try #require(PhotoImport.fingerprint(f.inbox.appendingPathComponent("flyer-1.jpg")))]
    let versionsBefore = try f.store.versions(videoId: before.id)
    let change = try StillVideo(store: f.store).addAudio(to: before.id, audio: audio)
    let v = change.video
    // The same item, now a video of that photo with that audio.
    #expect(v.id == before.id && v.isStill && !v.isPhoto && v.photos == nil && v.needsNoScore)
    #expect(v.still?.photo == photo && v.still?.audioName == "Friday mix.wav" && v.still?.audio == "Stills/\(v.id)/audio.wav")
    #expect(abs((v.still?.audioDuration ?? 0) - 4) <= 0.05 && v.duration == v.still?.audioDuration)
    #expect(v.file == "Stills/\(v.id)/video.mp4" && v.start == 0 && v.end == v.duration)
    #expect(v.fingerprint != nil && (v.fileSize ?? 0) > 0 && v.sourceWidth == 400 && v.sourceHeight == 300)
    #expect(try f.store.fileURL(for: v)?.path == f.paths.photos.appendingPathComponent("Stills/\(v.id)/video.mp4").path)
    #expect(f.stillFiles(v.id) == ["audio.wav", "video.mp4"] && f.stillLeftovers.isEmpty)
    // Kept: title, name, kind, session, score, and it is still in Edit, not sent anywhere.
    #expect(v.title == "Saturday flyer" && v.titleSource == before.titleSource && v.name == before.name && v.tags == before.tags)
    #expect(v.kind == before.kind && v.sessionId == Session.photosId && !v.inManifest && v.type == .short && v.createdAt == before.createdAt)
    #expect(v.score == nil && v.state == .needsEdit && !v.sentToQueue && !v.missing && ClipStage.of(v) == .edit)
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    // The edit: no photo crops, no photo shape, no confirmed crop, YouTube no longer forced off; Eric's own skip stays.
    let e = try f.store.edit(videoId: v.id)
    #expect(e.photoCrops.isEmpty && e.aspectOverride == nil && e.crop == nil && e.skippedPlatforms == [.x] && e.includedPlatforms.isEmpty)
    let re = try f.store.resolvedEdit(videoId: v.id)
    #expect(re.aspect == .r9x16 && !re.cropConfirmed && !re.isSkipped(.youtube) && re.isSkipped(.x))
    #expect(re.trimIn == 0 && abs(re.trimOut - v.duration) < 0.001)
    // The versions: every word, look, place and caption field as it was; only the "shows on" ranges are gone.
    let versions = try f.store.versions(videoId: v.id)
    #expect(versions.count == 2)
    var expected = versionsBefore
    for i in expected.indices {
      expected[i].textStart = nil
      expected[i].textEnd = nil
      expected[i].moreText = expected[i].moreText?.map { var l = $0; l.start = nil; l.end = nil; return l }
    }
    #expect(versions == expected)
    let r1 = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r1.text == "Loft nights" && r1.textLook == TextLook(color: "#FF3B30") && r1.textStart == nil && r1.textEnd == nil)
    #expect(r1.caption == "Come through" && r1.hashtagSetIds == ["house"] && r1.youtubeTitle == "Saturday at the Loft")
    let shown = PreviewKeys.layerWindows(r1, trimDuration: v.duration)
    #expect(shown.count == 2 && shown.allSatisfy { $0.window.lowerBound == 0 && $0.window.upperBound >= v.duration }, "each text shows for the whole clip")
    // One journal entry, and the picked files are as they were.
    let batchId = try #require(change.batchId)
    let batch = try #require(try BulkActions(store: f.store).batch(id: batchId))
    #expect(batch.action == "photo-audio-add" && batch.videoIds == [v.id])
    #expect([try #require(PhotoImport.fingerprint(audio)), try #require(PhotoImport.fingerprint(f.inbox.appendingPathComponent("flyer-1.jpg")))] == prints)
    // The photo's own copy is still in Originals: Remove audio needs it.
    #expect(FileManager.default.fileExists(atPath: f.paths.photos.appendingPathComponent(photo.file).path))
  }

  @Test func undoBringsThePhotoPostBackExactly() throws {
    let f = try Fixture(clips: [], longform: false)
    let before = try dressed(f)
    let stored = try f.stored(before.id)
    let issues = try Validation.issues(video: before, store: f.store)
    let bulk = BulkActions(store: f.store)
    let change = try StillVideo(store: f.store).addAudio(to: before.id, audio: f.tone(seconds: 2))
    #expect(try f.stored(before.id) != stored)
    let undo = try bulk.undo(try #require(change.batchId))
    #expect(undo.changed == [before.id] && undo.skipped.isEmpty)
    // Row, edit and versions are byte for byte what they were (photos, crops, shape, windows, the YouTube skip).
    #expect(try f.stored(before.id) == stored)
    let v = try #require(try f.store.video(id: before.id))
    #expect(v.isPhoto && !v.isStill && v.photos == before.photos && v.duration == 0 && v.start == nil && v.end == nil && v.file == before.file)
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube, .x])
    #expect(try f.store.resolvedEdit(videoId: v.id).aspect == .r1x1)
    #expect(try Validation.issues(video: v, store: f.store) == issues)
    #expect(try f.store.fileURL(for: v).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    // The batch is closed; the made files are still there and nothing points at them.
    #expect(try bulk.batch(id: try #require(change.batchId))?.undoneAt != nil)
    #expect(f.stillFiles(v.id) == ["audio.wav", "video.mp4"])
    // Adding again takes new names, so the first entry's files are never written over.
    let again = try StillVideo(store: f.store).addAudio(to: v.id, audio: f.tone("b.wav", seconds: 2)).video
    #expect(again.file == "Stills/\(v.id)/video-2.mp4" && again.still?.audio == "Stills/\(v.id)/audio-2.wav")
  }

  @Test func anUndoNeverOverwritesLaterWorkAndIsRefusedOnceItIsScheduled() throws {
    let f = try Fixture(clips: [], longform: false)
    let bulk = BulkActions(store: f.store)
    let v = try f.singlePhoto(title: "Flyer")
    let batch = try #require(try StillVideo(store: f.store).addAudio(to: v.id, audio: f.tone(seconds: 2)).batchId)
    // Eric cropped it since: the undo leaves it alone unless forced.
    var e = try f.store.edit(videoId: v.id)
    e.crop = CropRect(x: 0, y: 0, w: 168, h: 300)
    try f.store.save(e, videoId: v.id)
    let soft = try bulk.undo(batch)
    #expect(soft.changed.isEmpty && soft.skipped[v.id] == "changed again since the batch (use force to overwrite)")
    #expect(try f.store.video(id: v.id)?.isStill == true)
    // In the Queue with a day and posts: refused, force or not (D9).
    try f.send(v.id)
    try Planner(store: f.store).autoSchedule()
    #expect(try !f.store.posts(where: "video_id=?", [v.id]).isEmpty)
    let hard = try bulk.undo(batch, force: true)
    #expect(hard.changed.isEmpty && hard.skipped[v.id] == "It's scheduled or posted now: send it back to Edit first")
    #expect(try f.store.video(id: v.id)?.isStill == true && f.store.video(id: v.id)?.state == .planned)
  }

  @Test func changeAudioMakesTheVideoAgainAndClearsTrimsThatNoLongerFit() throws {
    let f = try Fixture(clips: [], longform: false)
    let made = try f.still(seconds: 6)
    var e = try f.store.edit(videoId: made.id)
    e.crop = CropRect(x: 116, y: 0, w: 168, h: 300)
    e.trimIn = 1
    e.trimOut = 5.5
    e.platformTrims = [.x: TrimRange(start: 0, end: 5), .tiktok: TrimRange(start: 0.5, end: 2)]
    e.coverTime = 5.8
    try f.store.save(e, videoId: made.id)
    let stored = try f.stored(made.id)
    let maker = StillVideo(store: f.store)
    let change = try maker.changeAudio(videoId: made.id, audio: f.tone("Shorter.wav", seconds: 3))
    let v = change.video
    #expect(v.isStill && v.still?.photo == made.still?.photo && v.still?.audioName == "Shorter.wav" && abs(v.duration - 3) <= 0.05)
    #expect(v.file == "Stills/\(v.id)/video-2.mp4" && v.still?.audio == "Stills/\(v.id)/audio-2.wav" && v.end == v.duration)
    #expect(v.fingerprint != made.fingerprint && f.stillFiles(v.id) == ["audio-2.wav", "audio.wav", "video-2.mp4", "video.mp4"])
    let after = try f.store.edit(videoId: v.id)
    #expect(after.crop == e.crop, "the crop stays")
    #expect(after.trimIn == nil && after.trimOut == nil && after.coverTime == nil)
    #expect(after.platformTrims == [.tiktok: TrimRange(start: 0.5, end: 2)], "the trim that still fits stays")
    #expect(try BulkActions(store: f.store).batch(id: try #require(change.batchId))?.action == "photo-audio-change")
    #expect(ClipStage.of(v) == .edit && !v.sentToQueue)
    // A longer audio keeps every trim.
    var keep = after
    keep.trimIn = 0.5
    keep.trimOut = 2.5
    try f.store.save(keep, videoId: v.id)
    let longer = try maker.changeAudio(videoId: v.id, audio: f.tone("Longer.wav", seconds: 5)).video
    #expect(try f.store.edit(videoId: v.id) == keep && abs(longer.duration - 5) <= 0.05 && longer.file.hasSuffix("video-3.mp4"))
    // Undo of the first change (forced past the second): the first video and its edit again.
    _ = try BulkActions(store: f.store).undo(try #require(change.batchId), force: true)
    #expect(try f.stored(made.id) == stored)
    let back = try #require(try f.store.video(id: made.id))
    #expect(back.file == "Stills/\(made.id)/video.mp4" && back.still == made.still && abs(back.duration - 6) <= 0.05)
    #expect(try f.store.fileURL(for: back).map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  @Test func removeAudioGivesThePhotoPostBackAndUndoGivesTheVideoBack() throws {
    let f = try Fixture(clips: [], longform: false)
    let made = try f.still(seconds: 3)
    var e = try f.store.edit(videoId: made.id)
    e.crop = CropRect(x: 116, y: 0, w: 168, h: 300)
    e.trimOut = 2
    e.platformTrims = [.x: TrimRange(start: 0, end: 1)]
    try f.store.save(e, videoId: made.id)
    var one = Version(number: 1)
    one.text = "Loft nights"
    one.textStart = 0.5
    one.textEnd = 2
    try f.store.save(one, videoId: made.id)
    let stored = try f.stored(made.id)
    let change = try StillVideo(store: f.store).removeAudio(videoId: made.id)
    let v = change.video
    let photo = try #require(made.still?.photo)
    // A photo post with its one photo, the default shape, YouTube off again, in Edit.
    #expect(v.id == made.id && v.isPhoto && !v.isStill && v.photos == [photo] && v.photoLabel == "Photo")
    #expect(v.duration == 0 && v.start == nil && v.end == nil && v.file == photo.file && v.sourceWidth == 400)
    #expect(v.title == "Saturday flyer" && ClipStage.of(v) == .edit && !v.sentToQueue)
    let after = try f.store.edit(videoId: v.id)
    #expect(after.crop == nil && after.trimOut == nil && after.platformTrims.isEmpty && after.photoCrops.isEmpty && after.skippedPlatforms == [.youtube])
    let re = try f.store.resolvedEdit(videoId: v.id)
    #expect(re.aspect == .r4x5 && re.isSkipped(.youtube))
    // Its text is on the photo (a window in seconds means nothing there).
    let r1 = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r1.text == "Loft nights" && r1.textStart == nil && r1.textEnd == nil)
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    #expect(try BulkActions(store: f.store).batch(id: try #require(change.batchId))?.action == "photo-audio-remove")
    // The made files stay, so undo only points the row back.
    #expect(f.stillFiles(v.id) == ["audio.wav", "video.mp4"])
    let undo = try BulkActions(store: f.store).undo(try #require(change.batchId))
    #expect(undo.changed == [v.id])
    #expect(try f.stored(made.id) == stored)
    let back = try #require(try f.store.video(id: made.id))
    #expect(back.isStill && back.still == made.still && back.file == made.file && back.duration == made.duration && back.photos == nil)
    #expect(try !f.store.resolvedEdit(videoId: back.id).isSkipped(.youtube))
  }

  @Test func onePhotoOnlyAndOnlyWhileItIsInEditWithNoDayAndNoPost() throws {
    let f = try Fixture.engine(1)
    let maker = StillVideo(store: f.store)
    let tone = f.tone()
    func refused(_ body: () throws -> Void) -> String {
      do { try body(); return "done" } catch { return "\(error)" }
    }
    // A carousel (D3), a clip, an id that isn't there.
    let carousel = try f.photoPost("night", count: 2)
    #expect(refused { try maker.addAudio(to: carousel.id, audio: tone) } == "Audio goes on a post with one photo")
    #expect(try maker.blocker(carousel) == StillVideo.carouselReason)
    #expect(refused { try maker.addAudio(to: "clip-0", audio: tone) }.hasSuffix("isn't a photo post"))
    #expect(refused { try maker.addAudio(to: "nope", audio: tone) } == "No post nope")
    #expect(refused { try maker.changeAudio(videoId: carousel.id, audio: tone) }.hasSuffix("has no audio to change"))
    #expect(refused { try maker.removeAudio(videoId: "clip-0") }.hasSuffix("has no audio to remove"))
    // A photo post in the Queue (D9).
    let queued = try f.singlePhoto("queued", title: "Queued")
    try f.send(queued.id)
    #expect(try f.store.video(id: queued.id)?.state == .ready)
    #expect(refused { try maker.addAudio(to: queued.id, audio: tone) } == "Send it back to Edit first")
    // With a set time.
    let timed = try f.singlePhoto("timed", title: "Timed")
    _ = try BulkActions(store: f.store).postAt([timed.id], at: f.clock.now.addingTimeInterval(3 * 86400))
    #expect(try Planner(store: f.store).exactSlot(videoId: timed.id) != nil)
    #expect(refused { try maker.addAudio(to: timed.id, audio: tone) } == StillVideo.lockedReason)
    // A made video that is scheduled, then posted: no change and no remove.
    let made = try f.still("made", title: "Made")
    #expect(try maker.blocker(made) == nil)
    #expect(refused { try maker.addAudio(to: made.id, audio: tone) }.hasSuffix("already has audio"))
    try f.send(made.id)
    #expect(refused { try maker.changeAudio(videoId: made.id, audio: tone) } == StillVideo.lockedReason, "in the Queue")
    try Planner(store: f.store).autoSchedule()
    #expect(refused { try maker.changeAudio(videoId: made.id, audio: tone) } == StillVideo.lockedReason)
    #expect(refused { try maker.removeAudio(videoId: made.id) } == StillVideo.lockedReason)
    var post = try #require(try f.store.posts(where: "video_id=?", [made.id]).first)
    post.state = .posted
    post.postedAt = f.clock.now
    try f.store.save(post)
    #expect(refused { try maker.removeAudio(videoId: made.id) } == StillVideo.lockedReason)
    #expect(try maker.blocker(try #require(try f.store.video(id: made.id))) == "Send it back to Edit first")
    // Back in Edit with nothing planned, it can change again.
    let free = try f.still("free", title: "Free")
    try f.send(free.id)
    _ = try BulkActions(store: f.store).back([free.id])
    #expect(try f.store.video(id: free.id)?.heldInEdit == true)
    #expect(refused { try maker.changeAudio(videoId: free.id, audio: tone) } == "done")
    // A photo whose file is gone; an excluded post.
    let lost = try f.singlePhoto("lost")
    try FileManager.default.removeItem(at: try f.store.photoURL(try #require(lost.photos?.first), of: lost))
    #expect(refused { try maker.addAudio(to: lost.id, audio: tone) }.hasPrefix("Its photo file is missing"))
    let out = try f.singlePhoto("out")
    try f.store.setExcluded(out.id, true)
    #expect(refused { try maker.addAudio(to: out.id, audio: tone) } == "It's excluded: include it first")
    // None of the refusals left a file or changed a row.
    for v in [carousel, queued, timed, lost, out] {
      #expect(try f.stillFiles(v.id).isEmpty && f.store.video(id: v.id)?.isPhoto == true)
    }
    #expect(f.stillLeftovers.isEmpty)
  }

  @Test func photosWithAudioInOneGoAreTheSameAsImportThenAddAudio() throws {
    let f = try Fixture(clips: [], longform: false)
    let files = f.pictures(["one.jpg", "two.png", "three.jpg"])
    let notes = f.inbox.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: notes)
    let tone = f.tone("Set.wav", seconds: 2)
    let seen = Seen()
    let r = try StillVideo(store: f.store).add(photos: [files[0], notes, files[1]], audio: tone, title: "Saturday") { seen.add($0) }
    // A video per photo, in order; the file that isn't a photo is skipped with the reason.
    #expect(r.videos.count == 2 && r.skipped.map(\.file) == [notes.path] && r.skipped[0].reason.hasPrefix("not a photo format"))
    #expect(r.videos.map(\.name) == ["one", "two"] && r.videos.allSatisfy { $0.isStill && $0.title == "Saturday" && $0.titleSource == "app" })
    #expect(r.videos.allSatisfy { ClipStage.of($0) == .edit && !$0.sentToQueue && $0.still?.audioName == "Set.wav" && abs($0.duration - 2) <= 0.05 })
    #expect(try f.store.planSlots().isEmpty && f.store.posts().isEmpty)
    #expect(seen.values.last == 1 && seen.values == seen.values.sorted())
    // Each has its own files and its own copy of the audio.
    for v in r.videos { #expect(f.stillFiles(v.id) == ["audio.wav", "video.mp4"]) }
    // The same as importing the photo and adding the audio: edit, versions, and everything on the row but its identity.
    let post = try #require(try PhotoImport(store: f.store).add(files: [files[2]], mode: .separate, title: "Saturday").posts.first)
    let control = try StillVideo(store: f.store).addAudio(to: post.id, audio: tone).video
    let own: Set<String> = ["updated_at", "created_at", "id", "name", "tags", "file", "fingerprint", "file_size", "still"]
    #expect(try f.row("videos", "id", control.id, without: own) == f.row("videos", "id", r.videos[0].id, without: own))
    #expect(try f.store.edit(videoId: control.id) == f.store.edit(videoId: r.videos[0].id))
    #expect(try f.store.versions(videoId: control.id) == f.store.versions(videoId: r.videos[0].id))
    #expect(try Validation.issues(video: control, store: f.store).map(\.id) == Validation.issues(video: r.videos[0], store: f.store).map(\.id))
    // An import isn't journaled, so there is nothing to undo; the one "Add audio" above is.
    #expect(try BulkActions(store: f.store).batches().map(\.action) == ["photo-audio-add"])
    // Audio that can't be used: nothing is imported at all.
    let count = try f.store.videos().count
    let fake = f.inbox.appendingPathComponent("fake.mp3")
    try Data("no".utf8).write(to: fake)
    #expect(throws: EngineError.self) { try StillVideo(store: f.store).add(photos: files, audio: fake) }
    #expect(try f.store.videos().count == count && f.stillLeftovers.isEmpty)
  }
}
