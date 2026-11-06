import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Flat grey picture, so a solid colour in a frame can only be a text box.
private enum GreyMedia {
  static let clip: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-grey-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("grey.mp4")
    if !FileManager.default.fileExists(atPath: url.path) {
      let r = try! Proc.run(Tools.ffmpeg!, [
        "-hide_banner", "-v", "error", "-y",
        "-f", "lavfi", "-i", "color=c=gray:size=1920x1080:rate=30:duration=4",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
        "-filter_complex", "[1:a]volume=0.07,aformat=channel_layouts=stereo[a]", "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        url.path,
      ])
      precondition(r.status == 0, r.stderr)
    }
    return url
  }()
}

/// A real render of a 3 s trim (0.5–3.5 s of the file) with three coloured boxes:
/// the first text 0–1 s, the second 1.5–2.5 s (sequential) and the third 0.5–2 s (overlapping both).
private final class Layered {
  let f: Fixture
  let renderer: Renderer
  let id = "clip-0"
  var store: Store { f.store }

  static let red = TextLook(accent: "#FF0000"), green = TextLook(accent: "#00FF00"), blue = TextLook(accent: "#0000FF")

  init() throws {
    f = try Fixture(clips: [("yayo x johnny", 4.0)], longform: false)
    let clip = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – yayo x johnny.mp4")
    try FileManager.default.removeItem(at: clip)
    try FileManager.default.copyItem(at: GreyMedia.clip, to: clip)
    try f.intake()
    renderer = Renderer(store: f.store)
    var e = Edit()
    e.crop = CropRect(x: 657, y: 0, w: 607.5, h: 1080)
    e.trimIn = 0.5; e.trimOut = 3.5
    try store.save(e, videoId: id)
    var v = Version(number: 1)
    v.text = "HHHH"; v.caption = "caption"; v.size = 120; v.posY = 0.2
    v.textStart = 0; v.textEnd = 1; v.textLook = Self.red
    v.moreText = [TextLayer(id: "b", text: "HHHH", size: 120, posY: 0.5, start: 1.5, end: 2.5, look: Self.green),
                  TextLayer(id: "c", text: "HHHH", size: 120, posY: 0.8, start: 0.5, end: 2, look: Self.blue)]
    try store.save(v, videoId: id)
  }

  func version(_ change: (inout Version) -> Void) throws {
    var v = try store.versions(videoId: id).first { $0.number == 1 }!
    change(&v)
    try store.save(v, videoId: id)
  }

  func edit(_ change: (inout Edit) -> Void) throws {
    var e = try store.edit(videoId: id)
    change(&e)
    try store.save(e, videoId: id)
  }

  var resolved: ResolvedVersion { get throws { try #require(try store.resolvedVersion(videoId: id, number: 1)) } }

  /// Is `layer`'s solid box colour in this picture? Sampled inside the box, left of the glyphs.
  func shows(_ layer: TextLayer, in px: Pixels) throws -> Bool {
    let b = try #require(TextOverlay.textBounds(for: layer, aspect: .r9x16))
    let (r, g, bl) = try #require(TextLook.rgb(layer.look?.accent))
    let p = px.at(Int(b.minX) + 10, Int(b.midY))
    let d = abs(Double(p.0) / 255 - r) + abs(Double(p.1) / 255 - g) + abs(Double(p.2) / 255 - bl)
    return d < 0.25
  }

  func frame(_ out: URL, at t: Double) throws -> Pixels { Pixels(try #require(Media.frame(out, at: t, maxSize: .zero))) }

  /// Which of the three texts (by colour name) the frame at `t` shows.
  func showing(_ out: URL, at t: Double) throws -> [String] {
    let r = try resolved, px = try frame(out, at: t)
    let a = r.firstLayer, b = r.moreText[0], c = r.moreText[1]
    return try [("first", a), ("second", b), ("third", c)].filter { try shows($0.1, in: px) }.map(\.0)
  }

  func render(_ p: Platform? = nil) throws -> Render { try renderer.ensureRender(videoId: id, versionNo: 1, platform: p) }
}

/// Real ffmpeg renders, asserted by pixel. See DECISIONS-R16.md for the run with the enable window broken on purpose.
@Suite(.serialized) struct R16RenderTests {
  @Test func eachTextShowsOnlyInsideItsOwnWindow() throws {
    let l = try Layered()
    let r = try l.render()
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    #expect(try l.showing(out, at: 0.25) == ["first"])
    #expect(try l.showing(out, at: 0.75) == ["first", "third"])  // overlap
    #expect(try l.showing(out, at: 1.25) == ["third"])  // between the sequential two
    #expect(try l.showing(out, at: 1.75) == ["second", "third"])
    #expect(try l.showing(out, at: 2.25) == ["second"])
    #expect(try l.showing(out, at: 2.75) == [])  // outside all of them

    // Every temp PNG went, however many there were.
    let left = try FileManager.default.contentsOfDirectory(atPath: l.store.paths.work.path).filter { $0.hasSuffix(".png") }
    #expect(left.isEmpty)
  }

  @Test func overlapsStackInListOrder() throws {
    let l = try Layered()
    try l.version {
      $0.posY = 0.5; $0.textStart = nil; $0.textEnd = nil
      $0.moreText = [TextLayer(id: "b", text: "HHHH", size: 120, posY: 0.5, look: Layered.green),
                     TextLayer(id: "c", text: "HHHH", size: 120, posY: 0.5, start: 1, end: 2, look: Layered.blue)]
    }
    let out = URL(fileURLWithPath: try #require(try l.render().outputPath))
    let rv = try l.resolved
    #expect(try l.shows(rv.moreText[0], in: l.frame(out, at: 0.5)))  // over the first
    #expect(try !l.shows(rv.firstLayer, in: l.frame(out, at: 0.5)))
    #expect(try l.shows(rv.moreText[1], in: l.frame(out, at: 1.5)))  // the last on top
    #expect(try !l.shows(rv.moreText[0], in: l.frame(out, at: 1.5)))
  }

  @Test func aShorterPlatformTrimDropsAnOutOfRangeText() throws {
    let l = try Layered()
    try l.edit { $0.platformTrims = [.x: TrimRange(start: 0.5, end: 1.5)] }  // 1 s: the second text starts at 1.5
    let rv = try l.resolved
    #expect(PreviewKeys.layerWindows(rv, trimDuration: 1).map(\.layer.id) == [TextLayer.firstId, "c"])
    let r = try l.render(.x)
    #expect(r.scope == Platform.x.rawValue)
    let out = URL(fileURLWithPath: try #require(r.outputPath))
    #expect(try l.showing(out, at: 0.25) == ["first"])
    #expect(try l.showing(out, at: 0.75) == ["first", "third"])
    #expect(try l.renderer.editHash(videoId: l.id, versionNo: 1, platform: .x) != l.renderer.editHash(videoId: l.id, versionNo: 1, platform: nil))
  }

  @Test func firstTextInvertedWindowStillCoversTheWholeClip() throws {
    let l = try Layered()
    try l.version { $0.textStart = 2.5; $0.textEnd = 1 }
    let out = URL(fileURLWithPath: try #require(try l.render().outputPath))
    #expect(try l.showing(out, at: 0.25) == ["first"])
    #expect(try l.showing(out, at: 2.75) == ["first"])
  }

  @Test func noTextRendersNoOverlaysAndOnlyTheExtrasWhenTheFirstIsEmpty() throws {
    let l = try Layered()
    try l.version { $0.text = nil }
    let out = URL(fileURLWithPath: try #require(try l.render().outputPath))
    #expect(try l.resolved.layers.map(\.id) == ["b", "c"])
    let rv = try l.resolved
    #expect(try l.shows(rv.moreText[1], in: l.frame(out, at: 0.75)))
    #expect(try !l.shows(TextLayer(text: "HHHH", size: 120, posY: 0.2, look: Layered.red), in: l.frame(out, at: 0.25)))

    try l.version { $0.noText = true }
    let none = URL(fileURLWithPath: try #require(try l.render().outputPath))
    #expect(try !l.shows(rv.moreText[1], in: l.frame(none, at: 0.75)))
    #expect(try !l.shows(rv.moreText[0], in: l.frame(none, at: 1.75)))
  }

  @Test func coverDrawsWhatShowsAtItsFrameElseTheFirstText() throws {
    let l = try Layered()
    let rv = try l.resolved
    func cover() throws -> Pixels {
      let r = try l.render()
      let path = try #require(r.coverPath)
      return Pixels(try #require(loadImage(URL(fileURLWithPath: path))))
    }
    try l.edit { $0.coverTime = 0.5 + 0.75; $0.coverIncludesTextOverride = true }
    let both = try cover()
    #expect(try l.shows(rv.firstLayer, in: both) && l.shows(rv.moreText[1], in: both) && !l.shows(rv.moreText[0], in: both))
    try l.edit { $0.coverTime = 0.5 + 1.25 + 0.5 }  // only the second shows
    let second = try cover()
    #expect(try l.shows(rv.moreText[0], in: second) && !l.shows(rv.firstLayer, in: second))
    try l.edit { $0.coverTime = 0.5 + 2.75 }  // nothing shows: the first text
    let first = try cover()
    #expect(try l.shows(rv.firstLayer, in: first) && !l.shows(rv.moreText[0], in: first) && !l.shows(rv.moreText[1], in: first))
    try l.edit { $0.coverIncludesTextOverride = false }
    let bare = try cover()
    #expect(try !l.shows(rv.firstLayer, in: bare))
  }
}

/// `djq overlay` end to end: the built binary against a throwaway file database.
@Suite(.serialized) struct R16OverlayCLITests {
  typealias Env = R6PostizCLITests.Env

  func list(_ env: Env, _ extra: [String] = []) throws -> [[String: Any]] {
    let r = try env.djq(args: ["overlay", "list", "clip-0", "--json"] + extra)
    return try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]], "\(r.out)\(r.err)")
  }

  @Test func addSetListRemove() throws {
    let env = try Env(clips: 1)
    var r = try env.djq("overlay", "add", "clip-0", "Second\nline", "--start", "1", "--end", "2.5", "--y", "0.8", "--color", "#ff0000",
                        "--background", "#00f", "--font", "impact", "--opacity", "0.5", "--tracking", "0.1", "--style", "outline",
                        "--size", "80", "--align", "left")
    #expect(r.status == 0, "\(r.err)")
    var l = try list(env)
    #expect(l.count == 2)
    #expect(l[0]["number"] as? Int == 1 && l[0]["id"] as? String == "first" && l[0]["text"] as? String == "Text clip-0")
    let two = l[1]
    #expect(two["number"] as? Int == 2 && two["text"] as? String == "Second\nline" && two["start"] as? Double == 1 && two["end"] as? Double == 2.5)
    #expect(two["y"] as? Double == 0.8 && two["color"] as? String == "#FF0000" && two["background"] as? String == "#0000FF")
    #expect(two["font"] as? String == "impact" && two["opacity"] as? Double == 0.5 && two["tracking"] as? Double == 0.1)
    #expect(two["style"] as? String == "outline" && two["size"] as? Double == 80 && two["align"] as? String == "left")
    #expect(two["drawn"] as? Bool == true && two["shows_from"] as? Double == 1 && two["shows_to"] as? Double == 2.5)
    let id = try #require(two["id"] as? String)

    // By number and by id; "default" clears; the first text goes to the first-text fields.
    r = try env.djq("overlay", "set", "clip-0", "2", "New words", "--color", "default", "--end", "default")
    #expect(r.status == 0, "\(r.err)")
    r = try env.djq("overlay", "set", "clip-0", id, "--x", "0.25")
    #expect(r.status == 0, "\(r.err)")
    l = try list(env)
    #expect(l[1]["text"] as? String == "New words" && l[1]["color"] == nil && l[1]["end"] == nil && l[1]["x"] as? Double == 0.25)
    r = try env.djq("overlay", "set", "clip-0", "1", "--font", "futura", "--start", "1", "--end", "2")
    #expect(r.status == 0, "\(r.err)")
    var v = try #require(try env.store.versions(videoId: "clip-0").first)
    #expect(v.textLook?.font == .futura && v.textStart == 1 && v.textEnd == 2 && v.text == "Text clip-0")

    // `djq text` is unchanged and still writes the first text.
    r = try env.djq("text", "clip-0", "From text")
    #expect(try list(env)[0]["text"] as? String == "From text" && list(env).count == 2)

    // `djq video --json` shows them, in `overlays` and in the fields as stored.
    let d = try env.json("video", "clip-0")
    #expect((d["overlays"] as? [[String: Any]])?.count == 2)
    #expect(((d["resolved_v1"] as? [String: Any])?["moreText"] as? [Any])?.count == 1)
    #expect(((d["versions"] as? [[String: Any]])?.first?["textLook"] as? [String: Any])?["font"] as? String == "futura")

    // Removing the first text promotes the second.
    r = try env.djq("overlay", "remove", "clip-0", "1")
    #expect(r.status == 0, "\(r.err)")
    l = try list(env)
    #expect(l.count == 1 && l[0]["id"] as? String == "first" && l[0]["text"] as? String == "New words")
    v = try #require(try env.store.versions(videoId: "clip-0").first)
    #expect(v.text == "New words" && v.moreText == [] && v.style == .outline)
    r = try env.djq("overlay", "remove", "clip-0", "1")
    #expect(r.status != 0 && r.err.contains("only text"))
  }

  @Test func refusesWhatItCantDo() throws {
    let env = try Env(clips: 1)
    func fails(_ args: String..., contains text: String) throws {
      let r = try env.djq(args: args)
      #expect(r.status != 0 && r.err.contains(text), "\(args): \(r.err)")
    }
    try fails("overlay", "add", "clip-0", "  ", contains: "write the text")
    try fails("overlay", "add", "clip-0", "T", "--color", "red", contains: "--color")
    try fails("overlay", "add", "clip-0", "T", "--font", "papyrus", contains: "--font")
    try fails("overlay", "add", "clip-0", "T", "--x", "2", contains: "--x")
    try fails("overlay", "add", "clip-0", "T", "--opacity", "0", contains: "--opacity")
    try fails("overlay", "add", "clip-0", "T", "--start", "3", "--end", "2", contains: "before it starts")
    try fails("overlay", "set", "clip-0", "9", "--x", "0.1", contains: "no text 9")
    try fails("overlay", "wiggle", "clip-0", contains: "unknown overlay command")
    try fails("overlay", "add", "clip-0", "T", "--version", "3", contains: "doesn't exist yet")
    #expect(try list(env).count == 1)  // nothing got through
    for i in 2...TextLayers.maxCount {
      let r = try env.djq("overlay", "add", "clip-0", "T\(i)", "--start", "\(i)")
      #expect(r.status == 0, "\(r.err)")
    }
    try fails("overlay", "add", "clip-0", "Thirteen", contains: "already has 12")
    #expect(try list(env).count == 12)
  }

  @Test func versionsAndNoText() throws {
    let env = try Env(clips: 1)
    try env.djq("overlay", "add", "clip-0", "On v1", "--start", "1")
    try env.store.save(Version(number: 2), videoId: "clip-0")
    #expect(try list(env, ["--version", "2"]).count == 2)  // inherited
    var r = try env.djq("overlay", "remove", "clip-0", "2", "--version", "2")
    #expect(r.status == 0, "\(r.err)")
    #expect(try list(env, ["--version", "2"]).count == 1 && list(env).count == 2)  // v1 keeps its own

    r = try env.djq("text", "clip-0", "--none")
    let l = try list(env)
    #expect(l.count == 2 && l.allSatisfy { $0["drawn"] as? Bool == false })  // hidden, still stored
    r = try env.djq("overlay", "list", "clip-0")
    #expect(r.out.contains("No text is on"))
    r = try env.djq("text", "clip-0", "Back")
    #expect(try list(env).allSatisfy { $0["drawn"] as? Bool == true })
  }

  /// S1-R10: overlay edits never move a clip. Only Send to Queue does that.
  @Test func overlayEditsNeverMoveAClip() throws {
    let env = try Env(clips: 2)
    // A clip in the Queue stays there, sent.
    let queued = try #require(try env.store.video(id: "clip-0"))
    #expect(queued.sentToQueue && ClipStage.of(queued) == .queue)
    // A clip in Edit that has nothing to fix stays in Edit: nothing here sends it.
    try env.store.setSentToQueue("clip-1", false)
    let held = try #require(try env.store.video(id: "clip-1"))
    #expect(ClipStage.of(held) == .edit)

    for id in ["clip-0", "clip-1"] {
      for args in [["overlay", "add", id, "Timed", "--start", "1", "--end", "2"], ["overlay", "set", id, "2", "--color", "#FF0000"],
                   ["overlay", "set", id, "1", "--background", "#00FF00"], ["overlay", "remove", id, "2"]] {
        let r = try env.djq(args: args)
        #expect(r.status == 0, "\(r.err)")
        let now = try #require(try env.store.video(id: id))
        let before = id == "clip-0" ? queued : held
        #expect(now.sentToQueue == before.sentToQueue && ClipStage.of(now) == ClipStage.of(before) && now.state == before.state, "\(args)")
      }
    }
  }
}
