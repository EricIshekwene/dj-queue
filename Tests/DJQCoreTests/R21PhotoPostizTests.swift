import Foundation
import Testing
@testable import DJQCore

/// Round 21 (P4, D8–D11, D19): a photo post through Manual and Postiz. Everything runs against `FakePostiz`; nothing
/// reaches the network.
@Suite struct R21PhotoPostizTests {
  /// A photo post with a real render, every platform on Postiz, and the engine around it.
  final class Rig {
    let f: Fixture
    let fake = FakePostiz()
    let keys = MemoryPostizKeyStore(key: "test-key-123")
    let renderer: Renderer
    let service: PostizService
    let engine: Engine
    let video: Video

    init(photos: Int, title: String? = "Saturday at Elsewhere", postiz: Bool = true, budget: Int = 1000,
         change: ((inout Settings) -> Void)? = nil) throws {
      f = try Fixture(clips: [], longform: false)
      renderer = Renderer(store: f.store)
      service = PostizService(store: f.store, transport: fake, keyStore: keys)
      engine = Engine(store: f.store, renderer: renderer, publisher: ManualPublisher(store: f.store, renderer: renderer),
                      notifier: LogNotifier(), postiz: service)
      try f.updateSettings { s in
        for p in Platform.allCases where postiz {
          s.publishing.publishers[p] = .postiz
          s.publishing.channels[p] = "ch-\(p.rawValue)"
        }
        s.publishing.hourlyBudget = budget
        change?(&s)
      }
      video = try f.photoPost("drop", count: photos, title: title, width: 80, height: 60)
      var v = Version(number: 1)
      v.caption = "Last night was loud"
      try f.store.save(v, videoId: video.id)
    }

    var store: Store { f.store }

    /// Sent to the Queue, scheduled and rendered, with nothing published yet.
    func scheduleAndRender() throws -> Render {
      try f.send(video.id)
      try Planner(store: store).autoSchedule()
      return try renderer.ensureRender(videoId: video.id, versionNo: 1, platform: nil)
    }

    func post(_ p: Platform) throws -> PlatformPost? { try store.posts(where: "video_id=? AND platform=?", [video.id, p.rawValue]).first }

    /// The request body Postiz got for a platform, as parsed JSON.
    func item(_ p: Platform) throws -> [String: Any] {
      let live = try requireValue(fake.livePosts.first { $0.integrationId == "ch-\(p.rawValue)" })
      return try requireValue((live.body["posts"] as? [[String: Any]])?.first)
    }

    func images(_ p: Platform) throws -> [[String: Any]] {
      try requireValue(((try item(p)["value"] as? [[String: Any]])?.first?["image"]) as? [[String: Any]])
    }
  }

  func json(_ d: Data) throws -> NSDictionary { try #require(try JSONSerialization.jsonObject(with: d) as? NSDictionary) }

  // MARK: Payload

  @Test func payloadPerPlatformIsExact() throws {
    let rig = try Rig(photos: 3)
    let r = try rig.scheduleAndRender()
    let s = try rig.store.settings()
    let date = Date(timeIntervalSince1970: 1_794_268_800)
    let media = (1...3).map { PostizMedia(id: "m\($0)", path: "https://uploads.example/m\($0).jpg") }
    func body(_ p: Platform, _ settings: Settings) throws -> (PostizPostSpec, NSDictionary) {
      var post = try #require(try rig.post(p))
      post.renderId = r.id
      let spec = try PostizPayload.spec(store: rig.store, post: post, settings: settings, integrationId: "ch-\(p.rawValue)")
      #expect(spec.isPhotoPost && spec.photoPaths == PhotoRules.files(r, platform: p) && spec.renderPath == r.allPaths[0])
      #expect(spec.thumbnailTimestampMs == nil && !spec.uploadsCover && spec.coverPath == nil && spec.renderId == r.id)
      return (spec, try json(spec.body(date: date, media: Array(media.prefix(spec.photoPaths.count)), cover: nil)))
    }
    let image: [[String: String]] = media.map { ["id": $0.id, "path": $0.path] }
    func expected(_ p: Platform, type: String = "schedule", settings: [String: Any]) -> NSDictionary {
      ["type": type, "date": PostizClient.isoString(date), "shortLink": false, "tags": [Any](),
       "posts": [["integration": ["id": "ch-\(p.rawValue)"],
                  "value": [["content": "Last night was loud", "image": image]],
                  "settings": settings]]] as NSDictionary
    }
    // Instagram: a feed post (a carousel with several photos), no trial reel, no thumbnail time.
    #expect(try body(.instagram, s).1 == expected(.instagram, settings: ["__type": "instagram-standalone", "post_type": "post"]))
    // TikTok: the same required keys as a video, never auto-added music, the Title, no "made with AI".
    #expect(try body(.tiktok, s).1 == expected(.tiktok, settings: [
      "__type": "tiktok-business", "content_posting_method": "DIRECT_POST", "privacy_level": "PUBLIC_TO_EVERYONE",
      "duet": true, "stitch": true, "comment": true, "autoAddMusic": "no", "brand_content_toggle": false,
      "brand_organic_toggle": false, "title": "Saturday at Elsewhere",
    ]))
    // Facebook: a post, without the title a video carries.
    #expect(try body(.facebook, s).1 == expected(.facebook, settings: ["__type": "facebook", "post_type": "post"]))
    #expect(try body(.threads, s).1 == expected(.threads, settings: ["__type": "threads"]))
    #expect(try body(.x, s).1 == expected(.x, settings: ["__type": "x", "who_can_reply_post": "everyone", "post_type": "post"]))
    // Test run (D19): drafts where the platform has them, TikTok to the inbox.
    var test = s
    test.publishing.testMode = true
    for p in [Platform.instagram, .facebook, .threads, .x] {
      let (spec, b) = try body(p, test)
      #expect(spec.type == "draft" && spec.testMode && b["type"] as? String == "draft")
    }
    let (tt, ttBody) = try body(.tiktok, test)
    let ttSettings = try #require(((ttBody["posts"] as? [[String: Any]])?.first?["settings"]) as? [String: Any])
    #expect(tt.type == "schedule" && ttSettings["content_posting_method"] as? String == "UPLOAD" && ttSettings["autoAddMusic"] as? String == "no")
    // The hash follows the render, the count sent, the caption and test mode.
    let h = try body(.x, s).0.contentHash
    #expect(try body(.x, s).0.contentHash == h && body(.x, test).0.contentHash != h && body(.threads, s).0.contentHash != h)
    // YouTube: never asked for, and it says why when it is.
    var yt = try #require(try rig.post(.x))
    yt.platform = .youtube
    #expect(throws: EngineError.self) { try PostizPayload.spec(store: rig.store, post: yt, settings: s, integrationId: "ch-youtube") }
    do {
      _ = try PostizPayload.spec(store: rig.store, post: yt, settings: s, integrationId: "ch-youtube")
    } catch {
      #expect("\(error)" == PhotoRules.youtubeReason)
    }
    // A post without a Title sends no TikTok title.
    try rig.store.setTitle(rig.video.id, nil)
    let untitled = try #require((try body(.tiktok, s).1["posts"] as? [[String: Any]])?.first?["settings"] as? [String: Any])
    #expect(untitled["title"] == nil && untitled.count == 9)
  }

  @Test func aLongCarouselSendsEachPlatformItsFirstPhotos() throws {
    let rig = try Rig(photos: 12)
    let r = try rig.scheduleAndRender()
    #expect(r.allPaths.count == 12)
    #expect(rig.engine.tick(reason: "t").errors.isEmpty)
    // Twelve uploads in all (each photo once, shared by every platform), five posts, none on YouTube.
    #expect(rig.fake.uploadCount == 12 && rig.fake.createCount == 5)
    #expect(!rig.fake.livePosts.contains { $0.integrationId == "ch-youtube" })
    let mediaIds = try (1...12).map { try #require(try rig.store.postizMedia(renderId: r.id, kind: "photo\($0)")).mediaId }
    #expect(Set(mediaIds).count == 12)
    #expect(try rig.store.postizMedia(renderId: r.id, kind: "video") == nil)
    for (p, n) in [(Platform.x, 4), (.instagram, 10), (.facebook, 10), (.threads, 12), (.tiktok, 12)] {
      let images = try rig.images(p)
      #expect(images.count == n && images.count == PhotoRules.sent(count: 12, platform: p).sent, "\(p.rawValue)")
      #expect(images.map { $0["id"] as? String } == Array(mediaIds.prefix(n)), "the first \(n), in order")
      #expect(images.allSatisfy { $0["thumbnailTimestamp"] == nil && $0.count == 2 })
      let post = try #require(try rig.post(p))
      let job = try #require(try rig.store.livePostizJob(postId: post.id))
      #expect(job.mediaId == mediaIds[0] && job.coverMediaId == nil && job.renderId == r.id, "the job carries the first photo")
      #expect(post.publisher == "postiz")
    }
    // Every upload was a JPEG.
    let uploads = rig.fake.requests.compactMap { req -> String? in
      if case .multipart(_, _, let mime, _) = req.body { return mime }  // (file, name, mime type, fields)
      return nil
    }
    #expect(uploads.count == 12 && uploads.allSatisfy { $0 == "image/jpeg" })
    // Another tick sends nothing again.
    _ = rig.engine.tick(reason: "t")
    #expect(rig.fake.uploadCount == 12 && rig.fake.createCount == 5)
  }

  @Test func uploadsAreCachedPerPhotoAndAnEditUploadsTheNewRender() throws {
    let rig = try Rig(photos: 3)
    _ = try rig.scheduleAndRender()
    _ = rig.engine.tick(reason: "t")
    #expect(rig.fake.uploadCount == 3 && rig.fake.createCount == 5)
    // Reordering makes a new render: its photos go up, the old posts are replaced once the edit settles.
    let ids = try #require(rig.video.photos).map(\.id)
    _ = try PhotoImport(store: rig.store).reorder(videoId: rig.video.id, ids: ids.reversed())
    for _ in 0..<5 {
      _ = rig.engine.tick(reason: "t")
      rig.f.clock.advance(PostizService.settleDelay + 60)
    }
    #expect(rig.fake.uploadCount == 6 && rig.fake.livePosts.count == 5 && rig.fake.violations.isEmpty)
    let r2 = try #require(try rig.renderer.currentRender(videoId: rig.video.id, versionNo: 1, platform: nil))
    let first = try #require(try rig.store.postizMedia(renderId: r2.id, kind: "photo1")).mediaId
    #expect(try rig.images(.instagram).first?["id"] as? String == first)
  }

  @Test func theBudgetCountsEveryPhotoBeforeAnythingIsSent() throws {
    let rig = try Rig(photos: 7, budget: 10)
    _ = try rig.scheduleAndRender()
    let report = rig.engine.tick(reason: "t")
    // Facebook goes first and needs 7 uploads + 1 create with room to spare for a sync: it fits. The next platform
    // needs only its create (the photos are cached), and so on until the budget is used; nothing is half sent.
    #expect(rig.fake.uploadCount == 7, "\(report.steps["publish"] ?? "")")
    #expect(rig.fake.createCount >= 1 && rig.fake.createCount < 5)
    #expect(rig.fake.violations.isEmpty)
    // With no room for the photos at all, nothing is uploaded.
    let tight = try Rig(photos: 12, budget: 10)  // Facebook alone needs 10 uploads and a create
    _ = try tight.scheduleAndRender()
    _ = tight.engine.tick(reason: "t")
    #expect(tight.fake.uploadCount == 0 && tight.fake.createCount == 0)
    #expect(try tight.store.openPostizJobs().isEmpty)
  }

  @Test func aRefusedPhotoFallsBackToTheCalendar() throws {
    let rig = try Rig(photos: 2)
    _ = try rig.scheduleAndRender()
    rig.fake.failNext["POST upload"] = [400]
    _ = rig.engine.tick(reason: "t")
    let fb = try #require(try rig.post(.facebook))  // the earliest slot: its upload was the one refused
    #expect(fb.publisher == "manual")
    #expect(try rig.store.finalPostizJob(postId: fb.id) != nil)
    #expect(rig.fake.createCount == 4 && rig.fake.violations.isEmpty)
  }

  // MARK: Manual and the Publisher interface

  @Test func manualPrepareHandsOverEveryFileThePlatformTakes() throws {
    let rig = try Rig(photos: 6, postiz: false)
    let r = try rig.scheduleAndRender()
    let manual = ManualPublisher(store: rig.store, renderer: rig.renderer)
    for (p, n) in [(Platform.x, 4), (.instagram, 6), (.tiktok, 6), (.facebook, 6), (.threads, 6)] {
      let prepared = try manual.prepare(postId: try #require(try rig.post(p)).id)
      #expect(prepared.allFileURLs.map(\.path) == Array(r.allPaths.prefix(n)), "\(p.rawValue)")
      #expect(prepared.fileURL.path == r.allPaths[0] && prepared.moreFileURLs.count == n - 1)
      #expect(prepared.coverURL == nil && prepared.title == nil && prepared.caption == "Last night was loud")
      #expect(prepared.allFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
    // A YouTube post can't exist for a photo; made by hand, it is refused with the reason.
    var yt = try #require(try rig.post(.x))
    yt.id = "yt-by-hand"
    yt.platform = .youtube
    try rig.store.save(yt)
    #expect(throws: EngineError.self) { try manual.prepare(postId: "yt-by-hand") }
    // A video's prepared post has no extra files.
    let clip = PreparedPost(postId: "p", platform: .x, fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), coverURL: nil, caption: "", title: nil,
                            uploadURL: Platform.x.uploadURL)
    #expect(clip.moreFileURLs.isEmpty && clip.allFileURLs.count == 1)
  }

  @Test func thePostizPublisherPreparesTheSameFilesItSends() throws {
    let rig = try Rig(photos: 6)
    let r = try rig.scheduleAndRender()
    _ = rig.engine.tick(reason: "t")
    let publisher = PostizPublisher(service: rig.service)
    let x = try publisher.prepare(postId: try #require(try rig.post(.x)).id)
    #expect(x.allFileURLs.map(\.path) == Array(r.allPaths.prefix(4)) && x.coverURL == nil)
    let tt = try publisher.prepare(postId: try #require(try rig.post(.tiktok)).id)
    #expect(tt.allFileURLs.count == 6 && tt.title == "Saturday at Elsewhere")
    #expect(try rig.images(.x).count == 4)
  }

  @Test func theTestRunSkipsYouTubeAndDraftsTheRest() throws {
    let rig = try Rig(photos: 5)
    _ = try rig.renderer.ensureRender(videoId: rig.video.id, versionNo: 1, platform: nil)
    // Dry run: five bodies with a placeholder per photo, YouTube left out with the reason, nothing sent.
    let dry = try rig.service.testPost(videoId: rig.video.id, draft: false)
    #expect(dry.platforms.count == 6 && rig.fake.requests.isEmpty)
    let yt = try #require(dry.platforms.first { $0.platform == .youtube })
    #expect(yt.skipped == PhotoRules.youtubeReason && yt.body.isEmpty)
    let x = try #require(dry.platforms.first { $0.platform == .x })
    #expect(x.skipped == nil && x.body.contains("<uploaded photo 4 id>") && !x.body.contains("<uploaded photo 5 id>"))
    #expect(dry.platforms.first { $0.platform == .instagram }?.body.contains("<uploaded photo 5 id>") == true)
    // Drafts: each photo goes up once, five drafts, none for YouTube.
    let drafts = try rig.service.testPost(videoId: rig.video.id, draft: true)
    #expect(rig.fake.uploadCount == 5 && rig.fake.createCount == 5)
    #expect(rig.fake.livePosts.allSatisfy { $0.type == "draft" } && !rig.fake.livePosts.contains { $0.integrationId == "ch-youtube" })
    #expect(drafts.platforms.filter { $0.postizId != nil }.count == 5)
  }
}
