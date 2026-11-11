import Foundation
import Testing
@testable import DJQCore

/// Round 21 (P2, D4, D7, D8, D17, D18): a photo post goes Edit → Queue → Scheduled without a score, validates by its
/// own rules, sorts ahead of scored clips while it has no score, and never reaches YouTube.
@Suite struct R21PhotoStageTests {
  @Test func aPhotoPostIsInEditWithoutAScoreAndNeverInScore() throws {
    let f = try Fixture()
    try f.intake()
    let v = try f.photoPost()
    let queue = Queue(store: f.store)
    #expect(ClipStage.of(v) == .edit)
    #expect(try !queue.toScore().contains { $0.id == v.id })
    #expect(try queue.toScore().count == 4, "the four clips still wait for a score")
    #expect(try queue.needsEdit().map(\.id) == [v.id])
    let bulk = BulkActions(store: f.store)
    #expect(try bulk.ids(filter: "unscored").contains(v.id) == false)
    #expect(try bulk.ids(filter: "needs-edit") == [v.id])
    // Back from Edit doesn't apply: there is no Score stage to go to.
    #expect(try bulk.blocker(v, .back) == "Photos have no Score stage")
    #expect(StageWording.blocker(v, .back) == PhotoRules.noScoreStage && StageWording.backTitle(v) == "Back")
    #expect(StageWording.backHelp(v) == PhotoRules.noScoreStage && StageWording.forwardTitle(v) == "Send to Queue")
    let back = try bulk.back([v.id])
    #expect(back.changed.isEmpty && back.skipped[v.id] == PhotoRules.noScoreStage)
    #expect(try bulk.blocker(v, .forward) == nil)
    // A clip is as it was.
    let clip = try #require(try f.store.video(id: "clip-0"))
    #expect(ClipStage.of(clip) == .score && StageWording.backTitle(clip) == "Back")
  }

  @Test func validationHasNoCropTextOrLengthRuleAndNeverChecksYouTube() throws {
    let f = try Fixture()
    let v = try f.photoPost()
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    let s = try f.store.settings()
    // Text that no version sets is "No text" (D7), and the default aspect is 4:5 (D5).
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r.noText && !r.hasDrawnText && r.isDefault("noText"))
    let re = try f.store.resolvedEdit(videoId: v.id)
    #expect(re.aspect == .r4x5 && s.defaults.photoAspect == .r4x5 && re.isDefault(.aspect))
    #expect(re.trimIn == 0 && re.trimOut == 3 && re.coverTime == 0 && !re.cropConfirmed && re.crop != nil)
    #expect(re.isSkipped(.youtube) && re.skippedPlatforms == [.youtube] && re.isDefault(.platforms))
    // An extra text on a photo post still draws, though nothing set the first one.
    var ver = Version(number: 1)
    ver.moreText = [TextLayer(text: "Saturday", start: 0, end: 1)]
    try f.store.save(ver, videoId: v.id)
    let withMore = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(!withMore.noText && withMore.hasDrawnText && withMore.layers.map(\.text) == ["Saturday"])
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    // "No text" turned off with nothing typed blocks a clip; a photo with no text is fine.
    ver.moreText = nil
    ver.noText = false
    try f.store.save(ver, videoId: v.id)
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    // A title far over YouTube's limit: YouTube isn't a posting platform here, so nothing is said.
    ver.youtubeTitle = String(repeating: "y", count: 300)
    try f.store.save(ver, videoId: v.id)
    #expect(try Validation.issues(video: v, store: f.store).isEmpty)
    // The caption rules are the clip's: a missing template, and a caption over a platform's limit.
    ver.youtubeTitle = nil
    ver.captionTemplateId = "nope"
    try f.store.save(ver, videoId: v.id)
    #expect(try Validation.issues(video: v, store: f.store).map(\.kind) == [.noCaption])
    ver.captionTemplateId = nil
    ver.caption = String(repeating: "x", count: 600)
    try f.store.save(ver, videoId: v.id)
    let long = try Validation.issues(video: v, store: f.store)
    #expect(long.map(\.kind) == [.captionTooLong, .captionTooLong] && Set(long.compactMap(\.platform)) == [.threads, .x])
    // No photos at all is a broken row, said in the photos section.
    var broken = v
    broken.photos = []
    #expect(try Validation.issues(video: broken, store: f.store).contains { $0.kind == .noPhotos })
    #expect(ValidationIssue.Kind.noPhotos.editorSection == .photos && ValidationIssue.Kind.noPhotos.chipLabel == "No photos")
    #expect(Validation.platformIssues(video: v, resolved: re, settings: s).isEmpty)
  }

  @Test func oldSettingsDecodeWithThePhotoAspectDefault() throws {
    var d = NewClipDefaults()
    #expect(d.photoAspect == .r4x5)
    let old = try #require(try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(d)) as? [String: Any])
    var without = old
    without.removeValue(forKey: "photoAspect")
    let back = try JSONCoding.decoder.decode(NewClipDefaults.self, from: JSONSerialization.data(withJSONObject: without))
    #expect(back == d)
    d.photoAspect = .r1x1
    #expect(try JSONCoding.decoder.decode(NewClipDefaults.self, from: JSONCoding.encoder.encode(d)).photoAspect == .r1x1)
    #expect(PhotoRules.aspects == [.r4x5, .r1x1, .r9x16, .r16x9])
  }

  @Test func sendToQueueNeedsNoScoreAndConfirmsEveryPhotosCrop() throws {
    let f = try Fixture()
    let v = try f.photoPost(count: 3)
    let bulk = BulkActions(store: f.store)
    // One photo already has Eric's own crop: it stays.
    let own = CropRect(x: 0, y: 0, w: 240, h: 300)
    var e = try f.store.edit(videoId: v.id)
    e.photoCrops[try #require(v.photos?[1]).id] = own
    try f.store.save(e, videoId: v.id)
    let r = try bulk.forward([v.id])
    #expect(r.changed == [v.id] && r.moves?[v.id] == StageMove(from: .edit, to: .queue, note: StageWording.sentToQueue))
    let sent = try #require(try f.store.video(id: v.id))
    #expect(sent.state == .ready && sent.sentToQueue && sent.score == nil && ClipStage.of(sent) == .queue)
    let crops = try f.store.edit(videoId: v.id).photoCrops
    #expect(crops.count == 3 && crops[v.photos![1].id] == own)
    #expect(crops[v.photos![0].id] == CropRect(x: 80, y: 0, w: 240, h: 300), "the centred 4:5 crop of a 400×300 photo")
    #expect(try f.store.resolvedEdit(videoId: v.id).cropConfirmed)
    #expect(try Queue(store: f.store).ordered().map(\.id) == [v.id])
    // Back to Edit holds it; Send to Queue (the bulk door) sends it again; undo of that takes it back.
    #expect(try bulk.back([v.id]).moves?[v.id]?.to == .edit)
    #expect(try f.store.video(id: v.id)?.heldInEdit == true)
    let again = try bulk.sendToQueue([v.id])
    #expect(again.changed == [v.id] && again.skipped.isEmpty)
    #expect(try f.store.video(id: v.id)?.state == .ready)
    try bulk.undo(try #require(again.batchId))
    #expect(try f.store.video(id: v.id)?.state == .needsEdit)
    // Make ready with defaults counts it as going to the Queue, not as needing a score.
    let made = try bulk.makeReadyWithDefaults([v.id])
    #expect(made.outlook?.ready == [v.id] && made.outlook?.needScore.isEmpty == true)
    // Clearing a score a photo was given doesn't take it out of the Queue.
    try f.store.setScore(v.id, 70)
    try f.store.setScore(v.id, nil)
    try f.store.refreshState(videoId: v.id)
    #expect(try f.store.video(id: v.id)?.state == .ready)
    // Remove from queue works without a score too.
    #expect(try bulk.removeFromQueue([v.id]).changed == [v.id])
  }

  @Test func aCropMadeForAnotherAspectIsIgnored() throws {
    let photo = PhotoItem(id: "p", file: "x.jpg", width: 400, height: 300)
    var e = Edit()
    e.photoCrops["p"] = CropRect(x: 80, y: 0, w: 240, h: 300)
    #expect(PhotoRules.crop(for: photo, edit: e, aspect: .r4x5) == e.photoCrops["p"])
    #expect(!PhotoRules.hasOwnCrop(photo, edit: e, aspect: .r1x1))
    #expect(PhotoRules.crop(for: photo, edit: e, aspect: .r1x1) == CropRect(x: 50, y: 0, w: 300, h: 300))
    let wide = PhotoRules.crop(for: photo, edit: e, aspect: .r16x9)
    #expect(wide.x == 0 && wide.w == 400 && abs(wide.h - 225) <= 1 && abs(wide.y - 37.5) <= 1)
    e.aspectOverride = .r1x1
    #expect(PhotoRules.aspect(e, defaults: NewClipDefaults()) == .r1x1)
  }

  @Test func unscoredPhotosGoFirstOldestFirstAndAScoredPhotoSortsLikeAClip() throws {
    let f = try Fixture.engine(3, scores: [80, 20, 50])
    let older = try f.photoPost("older", count: 1)
    f.clock.advance(60)
    let newer = try f.photoPost("newer", count: 2)
    f.clock.advance(60)
    let scored = try f.photoPost("scored", count: 1)
    try f.store.setScore(scored.id, 40)
    for v in [newer, scored, older] { try f.send(v.id) }
    let queue = Queue(store: f.store)
    // Worst first (the default): photos without a score, oldest import first, then by score.
    #expect(try queue.ordered().map(\.id) == [older.id, newer.id, "clip-1", scored.id, "clip-2", "clip-0"])
    try f.updateSettings { $0.sort = .bestFirst }
    #expect(try queue.ordered().map(\.id) == [older.id, newer.id, "clip-0", "clip-2", scored.id, "clip-1"])
    // YouTube's own list never has a photo; every other platform's does.
    #expect(try queue.ordered(platform: .youtube).map(\.id) == ["clip-0", "clip-2", "clip-1"])
    #expect(try queue.ordered(platform: .x).count == 6)
    #expect(Store.wasInQueue(try #require(try f.store.video(id: older.id))))
  }

  @Test func theSchedulerNeverPlansAPhotoPostOnYouTube() throws {
    let f = try Fixture.engine(2)
    let v = try f.photoPost(count: 2)
    try f.send(v.id)
    let planner = Planner(store: f.store)
    let report = try planner.autoSchedule()
    // The photo takes the next open day, ahead of the scored clips.
    #expect(report.clips.first?.videoId == v.id && report.scheduled == 3)
    let posts = try f.store.posts(where: "video_id=?", [v.id])
    #expect(posts.count == 5 && Set(posts.map(\.platform)) == Set(Platform.allCases).subtracting([.youtube]))
    let slot = try #require(try f.store.planSlots(where: "video_id=?", [v.id]).first)
    // Its day's YouTube slot stays empty: no other clip is pulled onto it.
    #expect(try f.store.slotPosts(slot.id).allSatisfy { $0.videoId == v.id })
    #expect(try f.store.posts(where: "platform='youtube'").allSatisfy { $0.videoId != v.id })
    #expect(try f.store.posts(where: "platform='youtube'").count == 2, "the two clips still go to YouTube on their own days")
    #expect(try f.store.video(id: v.id)?.state == .planned)
    #expect(try !planner.usable(v.id, on: .youtube))
    // With YouTube on its own order, it follows that order and still never takes the photo.
    try f.updateSettings { $0.sortOverrides[.youtube] = .bestFirst }
    try planner.autoSchedule()
    #expect(try f.store.posts(where: "platform='youtube' AND video_id=?", [v.id]).isEmpty)
    #expect(try f.doublePosts().isEmpty)
  }

  @Test func nothingCanTurnYouTubeBackOn() throws {
    let f = try Fixture()
    let v = try f.photoPost()
    let bulk = BulkActions(store: f.store)
    // Saving an edit that says otherwise.
    var e = Edit()
    e.includedPlatforms = [.youtube]
    try f.store.save(e, videoId: v.id)
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube])
    #expect(try f.store.edit(videoId: v.id).includedPlatforms.isEmpty)
    // The bulk platform switch says why, and skipping it is nothing new.
    let on = try bulk.setPlatform([v.id], .youtube, skipped: false)
    #expect(on.changed.isEmpty && on.skipped[v.id] == PhotoRules.youtubeReason)
    #expect(try bulk.setPlatform([v.id], .youtube, skipped: true).changed.isEmpty)
    // Another platform still switches.
    #expect(try bulk.setPlatform([v.id], .x, skipped: true).changed == [v.id])
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube, .x])
    // Apply defaults clears Eric's skips, not YouTube's.
    #expect(try bulk.applyDefaults([v.id], sections: [.platforms]).changed == [v.id])
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube])
    // A row written behind the store's back (an old journal, a hand edit) still reads with YouTube off.
    try f.store.db.run("UPDATE edits SET json=? WHERE video_id=?", [JSONCoding.string(Edit()), v.id])
    #expect(try f.store.edit(videoId: v.id).isSkipped(.youtube, defaults: f.store.settings().defaults))
    try f.store.db.run("DELETE FROM edits WHERE video_id=?", [v.id])
    #expect(try f.store.edit(videoId: v.id).skippedPlatforms == [.youtube])
    #expect(try f.store.resolvedEdit(videoId: v.id).isSkipped(.youtube))
    #expect(try !Planner(store: f.store).usable(v.id, on: .youtube))
    // A clip's edit is untouched by any of this.
    try f.intake()
    #expect(try f.store.edit(videoId: "clip-0") == Edit())
    try f.store.save(Edit(), videoId: "clip-0")
    #expect(try f.store.db.one("SELECT json FROM edits WHERE video_id='clip-0'")?.string("json") == JSONCoding.string(Edit()))
  }

  @Test func bulkCropSkipsPhotosAndBulkCaptionTitleAndPlatformsWork() throws {
    let f = try Fixture()
    let v = try f.photoPost()
    let bulk = BulkActions(store: f.store)
    let crop = try bulk.setCropOffset([v.id], CropChange(offset: 0.1))
    #expect(crop.changed.isEmpty && crop.skipped[v.id] == "photos are cropped in the editor")
    #expect(try bulk.previewCrop([v.id], CropChange(offset: 0.1)).first?.skipped == PhotoRules.bulkCropReason)
    #expect(try bulk.setTitle([v.id], "Saturday").changed == [v.id])
    #expect(try bulk.setCaptionTemplate([v.id], "short").changed == [v.id])
    #expect(try f.store.video(id: v.id)?.title == "Saturday")
  }

  @Test func captionsLeaveTheSetAndTheFileNameOut() throws {
    let f = try Fixture()
    let v = try f.photoPost("IMG_0042", count: 1)
    let s = try f.store.settings()
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    func caption(_ template: String, _ video: Video) -> String {
      Captions.caption(for: .instagram, version: r, video: video, sessionName: "Photos", sets: [],
                       templates: [CaptionTemplate(id: s.defaults.captionTemplateId, name: "t", template: template, sort: 0)], settings: s)
    }
    // {set} is empty (D18); with no title, {text} and {tag} are empty too: never "IMG_0042-1".
    #expect(caption("{text} — live at {set}\n{tag}\nlink", v) == "— live at\n\nlink")
    var titled = v
    titled.title = "Saturday at Elsewhere"
    #expect(caption("{text} | {title} | {set}|{tag}|", titled) == "Saturday at Elsewhere | Saturday at Elsewhere | ||")
    #expect(Captions.setValue("2026-10-23 – Afroween", video: v).isEmpty && Captions.tagValue(v).isEmpty)
    // A clip keeps its set and tag.
    try f.intake()
    let clip = try #require(try f.store.video(id: "clip-0"))
    #expect(Captions.setValue("2026-10-23 – Afroween", video: clip) == "Afroween" && Captions.tagValue(clip) == "yayo x johnny")
    #expect(try !AgentPrompts.needsTitleHelp(v, store: f.store), "there is no song to look up on a photo")
  }

  @Test func textShowsOnARangeOfPhotos() throws {
    // Photo i (0-based) is [i, i + 1); a text shows where its window overlaps.
    #expect(PhotoRules.shows(0...3, onPhoto: 0) && PhotoRules.shows(0...3, onPhoto: 2) && !PhotoRules.shows(0...3, onPhoto: 3))
    #expect(!PhotoRules.shows(1...2, onPhoto: 0) && PhotoRules.shows(1...2, onPhoto: 1) && !PhotoRules.shows(1...2, onPhoto: 2))
    let w = PhotoRules.window(fromPhoto: 2, toPhoto: 4)
    #expect(w.start == 1 && w.end == 4)
    #expect(PhotoRules.photoRange(1...4, count: 7) == 2...4 && PhotoRules.photoRange(0...8, count: 7) == 1...7)
    #expect(PhotoRules.rangeLabel(2...4, count: 7) == "Photos 2–4" && PhotoRules.rangeLabel(3...3, count: 7) == "Photo 3")
    #expect(PhotoRules.rangeLabel(1...7, count: 7) == "Every photo" && PhotoRules.rangeLabel(nil, count: 7) == "No photo")
    let f = try Fixture()
    let v = try f.photoPost(count: 4)
    var ver = Version(number: 1)
    ver.text = "Everywhere"
    ver.moreText = [TextLayer(id: "two", text: "Second and third", start: 1, end: 3), TextLayer(id: "late", text: "Past the end", start: 9, end: 12)]
    try f.store.save(ver, videoId: v.id)
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect((0..<4).map { PhotoRules.layers(r, onPhoto: $0, of: 4).map(\.text) }
            == [["Everywhere"], ["Everywhere", "Second and third"], ["Everywhere", "Second and third"], ["Everywhere"]])
    #expect(PhotoRules.photoRange(of: "two", in: r, count: 4) == 2...3 && PhotoRules.photoRange(of: "late", in: r, count: 4) == nil)
    #expect(PhotoRules.photoRange(of: TextLayer.firstId, in: r, count: 4) == 1...4)
  }

  @Test func howManyPhotosEachPlatformGets() {
    #expect(PhotoRules.sent(count: 7, platform: .x) == (4, 3) && PhotoRules.sent(count: 7, platform: .instagram) == (7, 0))
    #expect(PhotoRules.sent(count: 7, platform: .youtube) == (0, 7) && PhotoRules.sent(count: 40, platform: .tiktok) == (35, 5))
    #expect(PhotoRules.notice(count: 7, platform: .x) == "X gets the first 4 of 7 photos")
    #expect(PhotoRules.notice(count: 12, platform: .facebook) == "Facebook gets the first 10 of 12 photos")
    #expect(PhotoRules.notice(count: 4, platform: .x) == nil && PhotoRules.notice(count: 7, platform: .youtube) == nil)
    #expect(PhotoRules.platformNote(count: 1, platform: .youtube) == PhotoRules.youtubeReason)
    #expect(PhotoRules.platformNote(count: 21, platform: .threads) == "Threads gets the first 20 of 21 photos")
  }

  @Test func photoPostsAreFoundBySearch() throws {
    let f = try Fixture()
    let v = try f.photoPost("rooftop", count: 2, title: "Saturday at Elsewhere")
    let session = try f.store.session(id: Session.photosId)
    let item = SearchCorpus.clip(v, rank: 0, session: session, text: nil)
    #expect(item.title == "Saturday at Elsewhere")
    let fields = Dictionary(grouping: item.fields, by: \.label).mapValues { $0.map(\.text) }
    #expect(fields["Type"] == ["Carousel · 2"] && fields["Tag"] == ["rooftop-1"] && fields["Stage"] == ["Edit"])
    #expect(fields["File"]?.count == 2 && fields["Session"] == nil && fields["Kind"] == nil)
  }
}
