import Foundation
import Testing
@testable import DJQCore

/// Round 21 (P9): `djq photo add|list` and the photo fields in `djq videos --json` / `djq video --json`, through the
/// built `djq` binary against a throwaway database (the same rig as the Postiz CLI tests).
@Suite(.serialized) struct R21PhotoCLITests {
  typealias Env = R6PostizCLITests.Env

  func objects(_ out: String) throws -> [[String: Any]] {
    try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]], "\(out)")
  }

  @Test func photoAddMakesACarouselInEditAndLeavesTheOriginalsAlone() throws {
    let env = try Env(clips: 1)
    let files = env.f.pictures(["a.jpg", "b.png"])
    let before = try files.map { try #require(PhotoImport.fingerprint($0)) }
    let out = try env.json("photo", "add", files[0].path, files[1].path, "--title", "Saturday at Elsewhere")
    #expect((out["skipped"] as? [Any])?.isEmpty == true)
    let posts = try #require(out["posts"] as? [[String: Any]])
    let post = try #require(posts.first)
    #expect(posts.count == 1)
    #expect(post["media"] as? String == "photo" && post["stage"] as? String == "edit" && post["state"] as? String == "needs_edit")
    #expect(post["title"] as? String == "Saturday at Elsewhere" && post["title_source"] as? String == "agent")
    #expect(post["score"] == nil && post["sent_to_queue"] as? Bool == false && post["type"] as? String == "short-form")
    #expect(post["duration"] as? Double == 0 && (post["reasons"] as? [String])?.isEmpty == true)
    let photos = try #require(post["photos"] as? [[String: Any]])
    #expect(photos.count == 2 && photos.allSatisfy { $0["width"] as? Int == 400 && $0["height"] as? Int == 300 })
    let names = photos.compactMap { $0["file"] as? String }
    #expect(names[0].hasPrefix("01-") && names[0].hasSuffix(".jpg") && names[1].hasPrefix("02-") && names[1].hasSuffix(".png"))
    #expect(photos.allSatisfy { ($0["id"] as? String)?.count == 8 && $0.keys.sorted() == ["file", "height", "id", "width"] })
    // In the database: one photo post, in Edit, not sent anywhere; the picked files are untouched.
    let id = try #require(post["id"] as? String)
    let v = try #require(try env.store.video(id: id))
    #expect(v.photoCount == 2 && v.state == .needsEdit && !v.sentToQueue && v.score == nil)
    #expect(try env.store.planSlots().isEmpty && env.store.posts().isEmpty)
    #expect(try files.map { try #require(PhotoImport.fingerprint($0)) } == before)
    #expect(try env.store.photoURLs(v).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    // The words a person reads.
    let more = try env.djq("photo", "add", files[0].path)
    #expect(more.status == 0 && more.out.contains("added ") && more.out.contains("Photo") && more.out.contains("(in Edit)"), "\(more.out)\(more.err)")
  }

  @Test func separateSkipsAndAnEmptyAddFails() throws {
    let env = try Env(clips: 0)
    let files = env.f.pictures(["one.jpg", "two.jpg"])
    let notes = env.f.inbox.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: notes)
    let out = try env.json("photo", "add", "--separate", files[0].path, notes.path, files[1].path)
    #expect((out["posts"] as? [[String: Any]])?.count == 2)
    let skipped = try #require(out["skipped"] as? [[String: Any]])
    #expect(skipped.count == 1 && (skipped[0]["reason"] as? String)?.contains("not a photo format") == true)
    #expect((skipped[0]["file"] as? String) == notes.path)
    // Nothing usable: exit 1 and nothing made; no file at all: usage.
    let none = try env.djq("photo", "add", notes.path)
    #expect(none.status == 1 && none.out.contains("skipped") && none.out.contains("no post made"), "\(none.out)\(none.err)")
    #expect(try env.djq("photo", "add").status != 0)
    #expect(try env.store.videos(where: "photos IS NOT NULL").count == 2)
    // Help never needs the database.
    let help = try env.djq("photo")
    #expect(help.status == 0 && help.out.contains("photo add <file>") && help.out.contains("never posts to YouTube Shorts"))
    #expect(try env.djq("photo", "help").out.contains("photo list"))
    #expect(try env.djq("photo", "frobnicate").status != 0)
    #expect(try env.djq("help").out.contains("photo add <file>"))
  }

  @Test func listsAndVideoJSONCarryThePhotoFieldsAndKeepEveryOldKey() throws {
    let env = try Env(clips: 2)
    let files = env.f.pictures(["x.jpg", "y.jpg", "z.jpg"])
    _ = try env.djq("photo", "add", files[0].path, files[1].path, files[2].path)
    _ = try env.djq("photo", "add", files[0].path)
    // photo list: only photo posts.
    let list = try objects(try env.djq("photo", "list", "--json").out)
    #expect(list.count == 2 && list.allSatisfy { $0["media"] as? String == "photo" })
    #expect(Set(list.compactMap { ($0["photos"] as? [Any])?.count }) == [1, 3])
    let human = try env.djq("photo", "list")
    #expect(human.out.contains("Carousel · 3") && human.out.contains("Photo") && human.out.contains("2 photo post(s)"), "\(human.out)")
    // videos: clips say "video" with no photos; the keys agents already read are all still there.
    let all = try objects(try env.djq("videos", "--json").out)
    let clips = all.filter { $0["media"] as? String == "video" }
    #expect(all.count == 5 && clips.count == 3 && clips.allSatisfy { ($0["photos"] as? [Any])?.isEmpty == true })
    let old = ["id", "display_name", "raw_tag", "name", "session", "type", "kind", "state", "excluded", "missing", "duration",
               "suggestion_count", "needs_title_help", "issues", "held_in_edit", "sent_to_queue", "reasons", "text_suggestion_count",
               "repost_ready_versions"]
    #expect(all.allSatisfy { v in old.allSatisfy { v[$0] != nil } })
    #expect(try objects(try env.djq("videos", "--stage", "edit", "--json").out).count == 2, "both photo posts are in Edit")
    #expect(try objects(try env.djq("videos", "--state", "unscored", "--json").out).isEmpty)
    // video: the detail of a photo post has no YouTube caption or title.
    let id = try #require(list.first { ($0["photos"] as? [Any])?.count == 3 }?["id"] as? String)
    let detail = try env.json("video", id)
    let summary = try #require(detail["video"] as? [String: Any])
    #expect(summary["media"] as? String == "photo" && (summary["photos"] as? [Any])?.count == 3 && summary["needs_title_help"] as? Bool == false)
    let captions = try #require(detail["captions"] as? [String: Any])
    #expect(captions.count == 5 && captions["youtube"] == nil && detail["youtube_title"] == nil)
    let resolved = try #require(detail["resolved_edit"] as? [String: Any])
    #expect(resolved["aspect"] as? String == "4:5" && (resolved["skippedPlatforms"] as? [String]) == ["youtube"])
    #expect(((detail["edit"] as? [String: Any])?["skippedPlatforms"] as? [String]) == ["youtube"])
    #expect(try env.djq("video", id).status == 0)
  }

  @Test func ericsSendToQueueAndRenderWorkFromTheCommandLine() throws {
    let env = try Env(clips: 0)
    let files = env.f.pictures(["q1.jpg", "q2.jpg"])
    let added = try env.json("photo", "add", files[0].path, files[1].path)
    let id = try #require((added["posts"] as? [[String: Any]])?.first?["id"] as? String)
    // Back from Edit says why not.
    let back = try env.djq("stage", id, "back")
    #expect(back.out.contains(PhotoRules.noScoreStage) || back.err.contains(PhotoRules.noScoreStage), "\(back.out)\(back.err)")
    #expect(try env.store.video(id: id)?.state == .needsEdit)
    // Send to Queue (Eric's word) needs no score.
    let sent = try env.djq("requeue", id)
    #expect(sent.status == 0, "\(sent.out)\(sent.err)")
    let v = try #require(try env.store.video(id: id))
    #expect(v.state == .ready && v.sentToQueue && v.score == nil)
    #expect(try env.djq("queue").out.contains("q1"))
    // Render: two JPEGs in Photos/Ready to Post, no ffmpeg involved.
    let render = try env.djq("render", id)
    #expect(render.status == 0 && render.out.contains("q1 – v1 – \(id.prefix(8)) – 01.jpg"), "\(render.out)\(render.err)")
    let dir = env.f.paths.photos.appendingPathComponent("Ready to Post/Shortform")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["01", "02"].map { "q1 – v1 – \(id.prefix(8)) – \($0).jpg" })
    // The scheduler gives it a day with five posts and none on YouTube; Doctor has nothing to say about photo posts.
    #expect(try env.djq("schedule").status == 0)
    #expect(try env.store.posts(where: "video_id=?", [id]).map(\.platform).sorted() == Platform.allCases.filter(\.supportsPhotos).sorted())
    let doctor = try env.djq("doctor", "--json")
    let findings = try #require((try JSONSerialization.jsonObject(with: Data(doctor.out.utf8)) as? [String: Any])?["findings"] as? [[String: Any]])
    let ids = Set(findings.compactMap { $0["id"] as? String })
    #expect(ids.isDisjoint(with: ["photos.missing", "files.missing", "files.untracked", "files.duration", "plan.notReady", "renders.failed", "manifest.parse"]), "\(ids)")
  }

  @Test func textAndTimedTextsWorkOnAPhotoPostFromTheCommandLine() throws {
    let env = try Env(clips: 0)
    let files = env.f.pictures(["t1.jpg", "t2.jpg", "t3.jpg"])
    let added = try env.json("photo", "add", files[0].path, files[1].path, files[2].path)
    let id = try #require((added["posts"] as? [[String: Any]])?.first?["id"] as? String)
    // The first text on every photo; a second on photos 2–3 (photo N is the unit N-1…N).
    #expect(try env.djq("text", id, "Everywhere").status == 0)
    let second = try env.djq("overlay", "add", id, "Two and three", "--start", "1", "--end", "3")
    #expect(second.status == 0, "\(second.out)\(second.err)")
    let list = try objects(try env.djq("overlay", "list", id, "--json").out)
    #expect(list.count == 2 && list.allSatisfy { $0["drawn"] as? Bool == true })
    #expect(list[1]["shows_from"] as? Double == 1 && list[1]["shows_to"] as? Double == 3)
    let r = try #require(try env.store.resolvedVersion(videoId: id, number: 1))
    #expect((0..<3).map { PhotoRules.layers(r, onPhoto: $0, of: 3).count } == [1, 2, 2])
    #expect(try env.djq("caption", id, "Out now").status == 0)
    #expect(try env.djq("render", id).status == 0)
    #expect(try env.store.video(id: id)?.state == .needsEdit, "editing never sends it to the Queue")
  }

  @Test func agentAPIInProcess() throws {
    let f = try Fixture()
    try f.intake()
    let v = try f.photoPost("api", count: 2, title: "Rooftop")
    let s = try AgentAPI.summary(v, store: f.store)
    #expect(s.media == "photo" && s.photos.map(\.id) == v.photos?.map(\.id) && s.stage == "edit" && s.duration == 0)
    #expect(s.photos[0].file == URL(fileURLWithPath: v.photos![0].file).lastPathComponent && !s.photos[0].file.contains("/"))
    let clip = try AgentAPI.summary(try #require(try f.store.video(id: "clip-0")), store: f.store)
    #expect(clip.media == "video" && clip.photos.isEmpty)
    let d = try AgentAPI.video(v.id, store: f.store)
    #expect(d.youtube_title == nil && d.captions["youtube"] == nil && d.captions.count == 5 && d.issues.isEmpty)
    #expect(try AgentAPI.video("clip-0", store: f.store).captions["youtube"] != nil)
    // Round trip: the JSON decodes back with the new fields.
    let back = try JSONDecoder().decode(AgentAPI.VideoSummary.self, from: AgentAPI.encoder.encode(s))
    #expect(back.media == "photo" && back.photos.count == 2)
  }
}
