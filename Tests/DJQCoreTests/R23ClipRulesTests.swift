import Foundation
import Testing
@testable import DJQCore

/// Round 23 (A3, A4, A6, D6, D7, D10): a video made from a photo is a clip everywhere, with four differences: no score,
/// no text by default (and no `{set}`/`{tag}`), its own mark, and a title before YouTube.
///
/// Each rule is run for both fits (D12): "Fill the frame", where the crop is Eric's, and "Whole photo", where the crop
/// is the whole frame. The fit changes the picture, never the rules.
@Suite(.enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R23ClipRulesTests {
  @Test(arguments: StillSource.Fit.allCases) func itIsInEditWithoutAScoreAndSortsAheadOfScoredClips(fit: StillSource.Fit) throws {
    let f = try Fixture.engine(3, scores: [80, 20, 50])
    try f.writeManifest(clips: [("song0 x mix0", 20), ("song1 x mix1", 21), ("song2 x mix2", 22), ("unscored", 23)], longform: true,
                        sessionName: f.sessionDir.lastPathComponent)
    try f.intake()
    let older = try f.still("older", title: "Older", fit: fit)
    f.clock.advance(60)
    let photo = try f.singlePhoto("photo", title: "Photo")
    f.clock.advance(60)
    let newer = try f.still("newer", title: "Newer", fit: fit)
    let queue = Queue(store: f.store), bulk = BulkActions(store: f.store)
    // Edit, never Score; the unscored clip still waits for its score.
    #expect(ClipStage.of(older) == .edit && older.score == nil)
    #expect(try queue.toScore().map(\.id) == ["clip-3"])
    #expect(try queue.needsEdit().map(\.id) == [older.id, photo.id, newer.id], "oldest import first, photos and made videos together")
    #expect(try bulk.ids(filter: "unscored") == ["clip-3"])
    #expect(try Set(bulk.ids(filter: "needs-edit")) == [older.id, photo.id, newer.id])
    // Back from Edit doesn't apply, in its own words; the photo post keeps its words.
    #expect(try bulk.blocker(older, .back) == "A photo with audio has no Score stage")
    #expect(StageWording.backTitle(older) == "Back" && StageWording.backHelp(older) == StillVideo.noScoreStage)
    #expect(StageWording.forwardTitle(older) == "Send to Queue" && StageWording.blocker(photo, .back) == PhotoRules.noScoreStage)
    let back = try bulk.back([older.id])
    #expect(back.changed.isEmpty && back.skipped[older.id] == StillVideo.noScoreStage)
    // Send to Queue needs no score and confirms the centred crop, whatever the anchor in Settings.
    try f.updateSettings { $0.defaults.cropAnchor = .leftThird }
    for v in [newer, older, photo] { #expect(try f.send(v.id).changed == [v.id]) }
    let sent = try #require(try f.store.video(id: older.id))
    #expect(sent.state == .ready && sent.sentToQueue && ClipStage.of(sent) == .queue && Store.wasInQueue(sent))
    let crop = try #require(try f.store.edit(videoId: older.id).crop)
    if fit == .fill {
      #expect(crop == CropRect(x: 116, y: 0, w: 168, h: 300), "9:16 of 400×300, centred: \(crop)")
    } else {
      #expect(crop == CropRect(x: 0, y: 0, w: 396, h: 704), "the whole frame, as it was made: \(crop)")
    }
    #expect(try f.store.lastCropCentre() == nil, "a made video's crop isn't the next clip's starting point")
    // Queue order: the three without a score first, oldest first, then the clips by score.
    #expect(try queue.ordered().map(\.id) == [older.id, photo.id, newer.id, "clip-1", "clip-2", "clip-0"])
    try f.updateSettings { $0.sort = .bestFirst }
    #expect(try queue.ordered().map(\.id) == [older.id, photo.id, newer.id, "clip-0", "clip-2", "clip-1"])
    // YouTube's own list takes the made videos and never the photo post.
    #expect(try queue.ordered(platform: .youtube).map(\.id) == [older.id, newer.id, "clip-0", "clip-2", "clip-1"])
    // Clearing a score it never had doesn't unsend it; a score sorts it like a clip.
    try f.store.setScore(older.id, nil)
    #expect(try f.store.video(id: older.id)?.sentToQueue == true)
    try f.store.setScore(newer.id, 60)
    #expect(try queue.ordered().map(\.id) == [older.id, photo.id, "clip-0", newer.id, "clip-2", "clip-1"])
    // Two made videos are never "overlapping cuts" of one recording.
    #expect(!Queue.overlaps(older, newer))
    // Back to Edit from the Queue works as for a clip.
    let held = try bulk.back([older.id])
    #expect(held.changed == [older.id])
    #expect(try f.store.video(id: older.id)?.heldInEdit == true)
  }

  @Test(arguments: StillSource.Fit.allCases) func itStartsWithNoTextAndItsCaptionLeavesTheSetAndTheFileNameOut(fit: StillSource.Fit) throws {
    let f = try Fixture(clips: [], longform: false)
    try f.updateSettings { $0.defaults.textSource = .rawTag; $0.defaults.textTiming = .firstSeconds }
    let v = try f.still("IMG_0042", title: "Loft nights", fit: fit)
    let s = try f.store.settings()
    // No text unless a version sets it, whatever the default text source says.
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r.noText && !r.hasText && r.isDefault("text") && r.textStart == nil && r.textEnd == nil)
    #expect(try !Validation.issues(video: v, store: f.store).contains { $0.kind == .noText })
    // A text Eric adds shows for the whole clip until timed (not "first 3 seconds").
    var one = Version(number: 1)
    one.text = "Doors at ten"
    try f.store.save(one, videoId: v.id)
    let typed = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(typed.hasText && typed.textStart == nil && typed.textEnd == nil)
    one.textStart = 1
    one.textEnd = 2
    try f.store.save(one, videoId: v.id)
    #expect(try f.store.resolvedVersion(videoId: v.id, number: 1)?.textStart == 1)
    // A clip still follows the defaults.
    let clipDefault = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s,
                                              video: Video(id: "c", sessionId: "s", name: "Night – tag", tags: ["tag"], type: .short, contentType: "dj vid",
                                                           kind: .djVid, file: "c.mp4", fingerprint: nil, fileSize: nil, duration: 20, markedStart: nil,
                                                           markedEnd: nil, start: nil, end: nil, grace: nil, audio: nil, part: nil, score: nil,
                                                           state: .needsEdit, excluded: false, missing: false, inManifest: true, notes: "",
                                                           alreadyPostedOn: [], longformURL: nil, createdAt: f.clock.now, updatedAt: f.clock.now))
    #expect(clipDefault.text == "tag" && clipDefault.textStart == 0 && clipDefault.textEnd == 3)
    // {set} and {tag} are empty; {text} falls back to the Title, never to the file name.
    #expect(Captions.tagValue(v) == "" && Captions.setValue("2026-10-23 – Photos", video: v) == "")
    let blank = VersionResolver.resolve([Version(number: 1)], number: 1, settings: s, video: v)
    #expect(Captions.textValue(blank, video: v) == "Loft nights")
    var untitled = v
    untitled.title = nil
    #expect(Captions.textValue(blank, video: untitled) == "")
    #expect(!AgentPrompts.needsTitleHelp(untitled, suggestions: []) && !AgentPrompts.needsTitleHelp(v, suggestions: []))
    // Its mark, where a clip says its kind.
    #expect(v.markLabel == "Photo + audio" && v.kindLabel == "Photo + audio" && StillVideo.label == "Photo + audio")
    #expect(v.photoLabel == nil, "the photo label stays a photo post's: screens read it as \"this is a photo post\"")
    #expect(v.photoCount == 0 && !v.isCarousel && !v.isPhoto)
  }

  @Test(arguments: StillSource.Fit.allCases) func aYouTubePostNeedsSomethingToBeNamedAfter(fit: StillSource.Fit) throws {
    let f = try Fixture.engine(1)
    let v = try f.still("IMG_7", title: nil, fit: fit)
    func issue(_ video: Video? = nil) throws -> ValidationIssue? {
      try Validation.issues(video: try #require(try video ?? f.store.video(id: v.id)), store: f.store).first { $0.kind == .noTitle }
    }
    let i = try #require(try issue())
    #expect(i.platform == .youtube && i.message == "Add a title: YouTube needs a name for this video")
    #expect(i.kind.editorSection == .title && i.kind.chipLabel == "No title" && !i.kind.isBlock)
    // It keeps the item out of the Queue, and says so.
    let sent = try f.send(v.id)
    if fit == .fill {  // Send to Queue confirmed its crop, and says what is left
      #expect(sent.remainingIssues[v.id]?.contains { $0.kind == .noTitle } == true, "\(sent.remainingIssues)")
    } else {  // nothing for it to confirm: it says why it stays
      #expect(sent.changed.isEmpty && sent.skipped[v.id] == "Still in Edit: Add a title: YouTube needs a name for this video", "\(sent.skipped)")
    }
    #expect(try f.store.video(id: v.id)?.state == .needsEdit && f.store.video(id: v.id)?.sentToQueue == false)
    #expect(try AgentAPI.summary(try #require(try f.store.video(id: v.id)), store: f.store).reasons == ["No title"])
    // Any of Eric's own words fixes it: a Title, a typed YouTube title, or text on the video.
    try f.store.setTitle(v.id, "Loft nights")
    #expect(try issue() == nil)
    try f.store.setTitle(v.id, nil)
    #expect(try issue() != nil)
    var one = Version(number: 1)
    one.youtubeTitle = "Saturday at the Loft"
    try f.store.save(one, videoId: v.id)
    #expect(try issue() == nil)
    one.youtubeTitle = nil
    one.text = "Doors at ten"
    try f.store.save(one, videoId: v.id)
    #expect(try issue() == nil)
    one.text = nil
    try f.store.save(one, videoId: v.id)
    #expect(try issue() != nil)
    // With YouTube off for it, there is nothing to name.
    _ = try BulkActions(store: f.store).setPlatform([v.id], .youtube, skipped: true)
    #expect(try issue() == nil)
    #expect(try f.send(v.id).changed == [v.id])
    #expect(try f.store.video(id: v.id)?.state == .ready)
    // A clip without a title has its tag, and a photo post never goes to YouTube: neither gets the issue.
    #expect(try issue(try f.store.video(id: "clip-0")) == nil)
    #expect(try issue(try f.singlePhoto("p")) == nil)
  }

  @Test(arguments: StillSource.Fit.allCases) func theSchedulerGivesItAYouTubePostAndAPhotoPostStillGetsFive(fit: StillSource.Fit) throws {
    let f = try Fixture.engine(1)
    let made = try f.still(title: "Flyer", fit: fit)
    f.clock.advance(60)
    let photo = try f.singlePhoto("photo", title: "Photo")
    try f.send(made.id)
    try f.send(photo.id)
    let planner = Planner(store: f.store)
    #expect(try planner.usable(made.id, on: .youtube))
    #expect(try !planner.usable(photo.id, on: .youtube))
    let report = try planner.autoSchedule()
    #expect(report.scheduled == 3 && Array(report.clips.map(\.videoId).prefix(2)) == [made.id, photo.id])
    let posts = try f.store.posts(where: "video_id=?", [made.id])
    #expect(posts.count == 6 && Set(posts.map(\.platform)) == Set(Platform.allCases), "six platforms, YouTube included")
    #expect(try f.store.posts(where: "video_id=?", [photo.id]).count == 5)
    #expect(try f.store.posts(where: "video_id=? AND platform='youtube'", [photo.id]).isEmpty)
    #expect(try f.store.video(id: made.id)?.state == .planned && f.doublePosts().isEmpty)
    // Too long for a platform is a clip's issue, with a clip's fix (the trim).
    let long = try f.still("long", title: "Long", seconds: 95, fit: fit)
    let issues = try Validation.issues(video: long, store: f.store)
    #expect(issues.contains { $0.kind == .tooLong && $0.platform == .facebook } && !issues.contains { $0.kind == .tooLong && $0.platform == .tiktok })
    var e = try f.store.edit(videoId: long.id)
    e.trimOut = 60
    try f.store.save(e, videoId: long.id)
    #expect(try !Validation.issues(video: try #require(try f.store.video(id: long.id)), store: f.store).contains { $0.kind == .tooLong })
  }

  @Test(arguments: StillSource.Fit.allCases) func theVideoRendererRendersItAndPostizGetsTheVideoPayload(fit: StillSource.Fit) throws {
    let f = try Fixture(clips: [], longform: false)
    try f.updateSettings { s in
      for p in Platform.allCases {
        s.publishing.publishers[p] = .postiz
        s.publishing.channels[p] = "ch-\(p.rawValue)"
      }
    }
    let v = try f.still(title: "Saturday flyer", seconds: 4, fit: fit)
    var e = try f.store.edit(videoId: v.id)
    e.trimIn = 0.5
    e.trimOut = 3
    try f.store.save(e, videoId: v.id)
    var one = Version(number: 1)
    one.text = "Doors at ten"
    one.textStart = 0.5
    one.textEnd = 1.5
    one.caption = "Come through"
    try f.store.save(one, videoId: v.id)
    try f.send(v.id)
    try Planner(store: f.store).autoSchedule()
    let renderer = Renderer(store: f.store)
    // The video renderer, not the photo one: an mp4 with sound at the output size, as long as the trim, with a cover.
    #expect(try renderer.photoPost(v.id) == nil)
    let r = try renderer.ensureRender(videoId: v.id, versionNo: 1, platform: nil)
    let out = try #require(r.outputPath)
    #expect(out.hasSuffix("/flyer-1 – v1.mp4") && out.hasPrefix(f.paths.photos.appendingPathComponent("Ready to Post/Shortform").path))
    #expect(r.status == .done && r.morePaths == nil && r.allPaths == [out] && r.coverPath?.hasSuffix(".jpg") == true && r.loudness != nil)
    let info = try Media.probe(URL(fileURLWithPath: out))
    #expect(info.width == 1080 && info.height == 1920 && info.videoCodec == "h264" && info.hasAudio && abs(info.duration - 2.5) <= 0.1)
    #expect(try renderer.currentRender(videoId: v.id, versionNo: 1, platform: .youtube)?.id == r.id)
    // The picture in the render is the photo's own (the left half red, the right half blue), text aside.
    let frame = try #require(Tone.frame(URL(fileURLWithPath: out), at: 2.2, in: f.dir))
    let source = try #require(PhotoImages.bitmap(f.inbox.appendingPathComponent("flyer-1.jpg")))
    // Fill: Eric's crop, edge to edge. Whole: the photo across the middle (and its darkened copy above and below).
    let (left, right) = fit == .fill ? ((300, 300), (800, 1700)) : ((270, 960), (810, 960))
    #expect(frame[left.0, left.1].near(source[150, 40], 16) && frame[right.0, right.1].near(source[250, 260], 16),
            "\(frame[left.0, left.1]) \(frame[right.0, right.1])")
    if fit == .whole {
      let above = frame[270, 200], red = source[150, 40]
      #expect(above.near(.init(r: red.r * 65 / 100, g: red.g * 65 / 100, b: red.b * 65 / 100), 20), "above the photo: its darkened copy, \(above)")
    }
    // Postiz: the video payload on every platform, YouTube included; nothing of a photo post's.
    let s = try f.store.settings()
    for p in Platform.allCases {
      var post = try #require(try f.store.posts(where: "video_id=? AND platform=?", [v.id, p.rawValue]).first)
      post.renderId = r.id
      let spec = try PostizPayload.spec(store: f.store, post: post, settings: s, integrationId: "ch-\(p.rawValue)")
      #expect(!spec.isPhotoPost && spec.photoPaths.isEmpty && spec.renderPath == out && spec.renderId == r.id, "\(p)")
    }
    var yt = try #require(try f.store.posts(where: "video_id=? AND platform='youtube'", [v.id]).first)
    yt.renderId = r.id
    let body = try PostizPayload.spec(store: f.store, post: yt, settings: s, integrationId: "ch-youtube")
      .body(date: f.clock.now, media: [PostizMedia(id: "m", path: "https://uploads.example/m.mp4")], cover: nil)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let item = try #require((json["posts"] as? [[String: Any]])?.first)
    let ytSettings = try #require(item["settings"] as? [String: Any])
    #expect(ytSettings["__type"] as? String == "youtube" && (ytSettings["title"] as? String)?.contains("Doors at ten") == true, "\(ytSettings)")
    // A proxy is made for it like any clip (a photo post has none), from its picture and its sound.
    let proxy = try Media.ensureProxy(store: f.store, video: try #require(try f.store.video(id: v.id)))
    let pinfo = try Media.probe(proxy)
    #expect(pinfo.width == 540 && pinfo.height == 960 && pinfo.hasAudio && abs(pinfo.duration - 2.5) <= 0.1, "\(pinfo)")
    let pframe = try #require(Tone.frame(proxy, at: 1.9, in: f.dir))
    #expect(pframe[left.0 / 2, left.1 / 2].near(source[150, 40], 20) && pframe[right.0 / 2, right.1 / 2].near(source[250, 260], 20),
            "\(pframe[left.0 / 2, left.1 / 2]) \(pframe[right.0 / 2, right.1 / 2])")
    #expect(Media.sourceSize(store: f.store, video: v) == (fit == .fill ? CGSize(width: 400, height: 300) : CGSize(width: 396, height: 704)))
    #expect(Media.thumbnail(store: f.store, video: try #require(try f.store.video(id: v.id))) != nil)
  }

  @Test(arguments: StillSource.Fit.allCases) func bulkCropLeavesItAloneAndTheOtherBulkEditsReachIt(fit: StillSource.Fit) throws {
    let f = try Fixture.engine(1)
    let v = try f.still(title: nil, fit: fit)
    let bulk = BulkActions(store: f.store)
    let crop = try bulk.setCropOffset([v.id, "clip-0"], CropChange(offset: 0.1))
    #expect(crop.skipped[v.id] == "a photo with audio is cropped in the editor" && !crop.changed.contains(v.id))
    #expect(try bulk.previewCrop([v.id], CropChange(offset: 0.1)).first?.skipped == StillVideo.bulkCropReason)
    #expect(try f.store.edit(videoId: v.id).crop == (fit == .fill ? nil : CropRect(x: 0, y: 0, w: 396, h: 704)))
    #expect(try bulk.setTitle([v.id], "Saturday").changed == [v.id])
    #expect(try bulk.setCaptionTemplate([v.id], "short").changed == [v.id])
    // YouTube can be turned off and on again, as for a clip (a photo post can't turn it on).
    #expect(try bulk.setPlatform([v.id], .youtube, skipped: true).changed == [v.id])
    #expect(try bulk.setPlatform([v.id], .youtube, skipped: false).changed == [v.id])
    #expect(try !f.store.resolvedEdit(videoId: v.id).isSkipped(.youtube))
    // Search finds it by its mark, its audio's name and its title; it has no night and no kind to show.
    let now = try #require(try f.store.video(id: v.id))
    let item = SearchCorpus.clip(now, rank: 0, session: try f.store.session(id: Session.photosId), text: nil)
    let fields = Dictionary(grouping: item.fields, by: \.label).mapValues { $0.map(\.text) }
    #expect(item.title == "Saturday" && fields["Type"] == ["Photo + audio"] && fields["Audio"] == ["flyer.wav"] && fields["Stage"] == ["Edit"])
    #expect(fields["Kind"] == nil && fields["Session"] == nil && fields["File"]?.first?.hasPrefix("01-") == true)
  }

  @Test(arguments: StillSource.Fit.allCases) func intakeLeavesItAloneAndAMissingVideoFileIsSaidAndComesBack(fit: StillSource.Fit) throws {
    let f = try Fixture()
    try f.intake()
    let v = try f.still(title: "Flyer", fit: fit)
    let file = try #require(try f.store.fileURL(for: v))
    let stored = try f.stored(v.id)
    // Intake: not new, not updated, not missing, not "removed from videos.json", not an untracked clip.
    let report = try f.intake()
    #expect(report.missing.isEmpty && report.removedFromManifest.isEmpty && report.untracked.isEmpty && report.newVideos.isEmpty)
    #expect(try f.stored(v.id) == stored)
    let doctor = Doctor(store: f.store)
    #expect(try doctor.missingPhotos().isEmpty && doctor.missingFiles().isEmpty)
    #expect(!doctor.run().findings.contains { $0.id == "files.untracked" || $0.id == "photos.missing" || $0.id == "files.missing" })
    // The video file goes: missing, in Edit with "File missing", in Doctor under the Photos folder's finding.
    let away = f.dir.appendingPathComponent("away.mp4")
    try FileManager.default.moveItem(at: file, to: away)
    #expect(try f.intake().missing == ["flyer-1"])
    let gone = try #require(try f.store.video(id: v.id))
    #expect(gone.missing && gone.state == .missingFile && ClipStage.of(gone) == .edit)
    #expect(try Validation.issues(video: gone, store: f.store).contains { $0.kind == .missingFile })
    let finding = try #require(try doctor.missingPhotos().first)
    #expect(finding.id == "photos.missing" && finding.where_.count == 1 && finding.where_[0].hasSuffix(file.path))
    #expect(try doctor.missingFiles().isEmpty, "not the clips' finding, whose fix is about videos.json")
    #expect(try f.intake().missing.isEmpty, "said once")
    // Back in place: it comes back by itself.
    try FileManager.default.moveItem(at: away, to: file)
    try f.intake()
    let back = try #require(try f.store.video(id: v.id))
    #expect(!back.missing && back.state == .needsEdit)
    #expect(try doctor.missingPhotos().isEmpty)
    // The audio copy and the photo's copy aren't what posts: without them it still isn't missing.
    try FileManager.default.removeItem(at: f.paths.photos.appendingPathComponent(try #require(v.still?.audio)))
    try f.intake()
    #expect(try f.store.video(id: v.id)?.missing == false)
  }
}

/// Round 23: the JSON agents read, the CLI, and the schema step.
@Suite(.serialized, .enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R23PhotoAudioCLITests {
  typealias Env = R6PostizCLITests.Env

  @Test func theSummaryCarriesStillAndKeepsEveryOtherKey() throws {
    let f = try Fixture.engine(1)
    let v = try f.still(title: "Flyer", seconds: 2)
    let s = try AgentAPI.summary(v, store: f.store)
    #expect(s.media == "video" && s.photos.isEmpty && s.stage == "edit" && s.duration == v.duration && s.needs_title_help == false)
    #expect(s.still?.audio_name == "flyer.wav" && s.still?.audio_seconds == v.duration && s.still?.photo.width == 400 && s.still?.fit == "fill")
    #expect(s.still?.photo.file.hasPrefix("01-") == true && s.file?.hasSuffix("Stills/\(v.id)/video.mp4") == true)
    func keys(_ id: String) throws -> Set<String> {
      let data = try AgentAPI.encoder.encode(try AgentAPI.summary(try #require(try f.store.video(id: id)), store: f.store))
      return Set(try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
    }
    // A clip's and a photo post's summaries have exactly the keys they had: `still` is there only for a made video.
    let photo = try f.singlePhoto("p")
    let clip = try keys("clip-0")
    #expect(!clip.contains("still"))
    #expect(try !keys(photo.id).contains("still"))
    // (Keys with no value are left out, as always: a clip has no title here, a made video no part or markers.)
    let made = try keys(v.id)
    #expect(made.subtracting(clip) == ["still", "title", "title_source"], "\(made.subtracting(clip))")
    #expect(clip.subtracting(made).isSubset(of: ["score", "part", "marked_start", "marked_end", "audio"]), "\(clip.subtracting(made))")
    let detail = try AgentAPI.video(v.id, store: f.store)
    #expect(detail.youtube_title != nil && detail.captions["youtube"] != nil && detail.captions.count == 6)
  }

  @Test(.enabled(if: R6PostizCLITests.binary != nil)) func photoAddWithAudioAndPhotoAudioThroughTheBinary() throws {
    let env = try Env(clips: 1)
    let files = env.f.pictures(["a.jpg", "b.png"])
    let tone = env.f.tone("Set.wav", seconds: 2), other = env.f.tone("Other.wav", seconds: 1.5)
    // A video per photo.
    let out = try env.json("photo", "add", files[0].path, files[1].path, "--audio", tone.path, "--title", "Saturday")
    let posts = try #require(out["posts"] as? [[String: Any]])
    #expect(posts.count == 2 && (out["skipped"] as? [Any])?.isEmpty == true)
    #expect(posts.allSatisfy { $0["media"] as? String == "video" && $0["stage"] as? String == "edit" && $0["title"] as? String == "Saturday" })
    #expect(posts.allSatisfy { ($0["still"] as? [String: Any])?["audio_name"] as? String == "Set.wav" && ($0["photos"] as? [Any])?.isEmpty == true })
    #expect(posts.allSatisfy { $0["title_source"] as? String == "agent" && $0["sent_to_queue"] as? Bool == false && $0["score"] == nil })
    #expect(try env.store.planSlots().isEmpty && env.store.posts().isEmpty)
    // Audio on a photo post: add, then change, then remove; each says how to undo.
    let add = try env.json("photo", "add", files[0].path)
    let id = try #require((add["posts"] as? [[String: Any]])?.first?["id"] as? String)
    let added = try env.json("photo", "audio", id, tone.path)
    #expect(added["change"] as? String == "added" && added["batchId"] is String)
    #expect(((added["video"] as? [String: Any])?["still"] as? [String: Any])?["audio_name"] as? String == "Set.wav")
    let changed = try env.json("photo", "audio", String(id.prefix(8)), other.path)
    #expect(changed["change"] as? String == "changed")
    #expect(((changed["video"] as? [String: Any])?["still"] as? [String: Any])?["audio_name"] as? String == "Other.wav")
    #expect(try env.store.video(id: id)?.file.hasSuffix("video-2.mp4") == true)
    let words = try env.djq("photo", "audio", id, "--remove")
    #expect(words.status == 0 && words.out.contains("audio removed: a photo post again") && words.out.contains("undo: djq bulk undo"), "\(words.out)\(words.err)")
    #expect(try env.store.video(id: id)?.isPhoto == true)
    // The list of videos carries `still`; the photo list doesn't hold made videos.
    let all = try env.djq("videos", "--json")
    #expect(all.out.contains("\"audio_name\" : \"Set.wav\""))
    let list = try env.djq("photo", "list")
    #expect(list.out.contains("1 photo post(s)"), "\(list.out)")
    // Refusals read as sentences and change nothing.
    let carousel = try env.json("photo", "add", files[0].path, files[1].path)
    let cid = try #require((carousel["posts"] as? [[String: Any]])?.first?["id"] as? String)
    let no = try env.djq("photo", "audio", cid, tone.path)
    #expect(no.status != 0 && (no.out + no.err).contains("Audio goes on a post with one photo"), "\(no.out)\(no.err)")
    let bad = try env.djq("photo", "add", files[0].path, "--audio", files[1].path)
    #expect(bad.status != 0 && (bad.out + bad.err).contains("not an audio format DJ Queue takes"), "\(bad.out)\(bad.err)")
    #expect(try env.djq("photo", "help").out.contains("photo audio <id> --remove"))
  }

  @Test func schema9DatabaseGainsTheColumnAndKeepsEveryRow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r23-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let file = paths.appSupport.appendingPathComponent("queue.sqlite")
    /// Every row of every table, every column but the new one.
    func dump(_ db: SQLite) throws -> [String: [String]] {
      var out: [String: [String]] = [:]
      for t in try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").compactMap({ $0.string("name") }) {
        let cols = try db.query("PRAGMA table_info(\(t))").compactMap { $0.string("name") }.filter { !(t == "videos" && $0 == "still") }
        out[t] = try db.query("SELECT \(cols.map { "\"\($0)\"" }.joined(separator: ",")) FROM \(t) ORDER BY rowid").map { r in
          cols.map { r.string($0) ?? r.double($0).map { String($0) } ?? "-" }.joined(separator: "|")
        }
      }
      return out
    }
    var before: [String: [String]] = [:]
    do {
      let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
      try s.save(Session(id: "s", folder: "/tmp/none", name: "S", date: nil, discoveredAt: Date(), missing: false))
      try s.save(Session(id: Session.photosId, folder: paths.photos.path, name: "Photos", date: nil, discoveredAt: Date(), missing: false))
      func video(_ id: String, score: Int?) -> Video {
        Video(id: id, sessionId: "s", name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid, file: "\(id).mp4",
              fingerprint: nil, fileSize: nil, duration: 30, markedStart: 3, markedEnd: 27, start: 0, end: 30, grace: 3, audio: nil,
              part: 1, score: score, state: .needsEdit, excluded: false, missing: false, inManifest: true, notes: "n-\(id)",
              alreadyPostedOn: [], longformURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
              updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "T-\(id)")
      }
      try s.save(video("a", score: 40))
      try s.save(video("b", score: nil))
      var photo = video("p", score: nil)
      photo.sessionId = Session.photosId
      photo.photos = [PhotoItem(id: "p1", file: "Originals/p/01-p1.jpg", width: 4000, height: 3000)]
      try s.save(photo)
      var e = Edit()
      e.crop = CropRect(x: 0, y: 0, w: 1215, h: 2160)
      try s.save(e, videoId: "a")
      var one = Version(number: 1)
      one.text = "Hello"
      try s.save(one, videoId: "a")
      try s.save(PlanSlot(id: "slot", date: "2026-11-05", position: 0, videoId: "a", pinned: true, weekStart: "2026-11-02"))
      try s.save(Render(id: "r", videoId: "a", versionNo: 1, editHash: "h", scope: "all", outputPath: "/tmp/a.mp4", coverPath: nil,
                        loudness: nil, duration: 24, size: 10, status: .done, error: nil, createdAt: Date(), deletedAt: nil))
      _ = try BulkActions(store: s).setTitle(["a"], "Journaled")
      // Back to a schema 9 database: no `still` column.
      try s.db.exec("ALTER TABLE videos DROP COLUMN still; PRAGMA user_version = 9;")
      before = try dump(s.db)
    }
    let s = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    #expect(try s.db.one("PRAGMA user_version")?.int("user_version") == 10 && Store.schemaVersion == 10)
    #expect(try s.db.query("PRAGMA table_info(videos)").contains { $0.string("name") == "still" })
    let after = try dump(s.db)
    #expect(after == before, "every table's rows are what they were")
    #expect(before.keys.contains("videos") && before["videos"]?.count == 3 && before["batches"]?.count == 1 && before.count >= 15)
    #expect(try s.videos().allSatisfy { $0.still == nil && !$0.isStill })
    #expect(try s.video(id: "p")?.isPhoto == true && s.video(id: "a")?.needsNoScore == false)
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(backups.filter { $0.hasPrefix("queue-before-schema10-") }.count == 1)
    // The journal written before the column still undoes.
    let batch = try #require(try BulkActions(store: s).batches().first)
    #expect(try BulkActions(store: s).undo(batch.id).changed == ["a"])
    #expect(try s.video(id: "a")?.title == "T-a")
    // Opening it again changes nothing and takes no second backup.
    _ = try Store(paths: paths, clock: FixedClock(Fixture.monday9am), path: file.path)
    let again = try FileManager.default.contentsOfDirectory(atPath: paths.appSupport.appendingPathComponent("backups").path)
    #expect(again.filter { $0.hasPrefix("queue-before-schema10-") }.count == 1)
    // And the new field round-trips.
    var made = try #require(try s.video(id: "p"))
    made.photos = nil
    made.still = StillSource(photo: PhotoItem(id: "p1", file: "Originals/p/01-p1.jpg", width: 4000, height: 3000),
                             audio: "Stills/p/audio.mp3", audioName: "Friday mix.mp3", audioDuration: 181.5)
    try s.save(made)
    #expect(try s.video(id: "p")?.still == made.still && s.video(id: "p")?.isStill == true && s.video(id: "p")?.isPhoto == false)
  }
}
