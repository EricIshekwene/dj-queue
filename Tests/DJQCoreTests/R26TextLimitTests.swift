import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

// Round 26: 32 texts on a clip (quiz versions need ~20) and a countdown that takes one slot.

private func resolve(_ v: Version) -> ResolvedVersion {
  VersionResolver.resolve([v], number: v.number, settings: Settings(), video: nil)
}

@Suite struct R26CountdownTests {
  @Test func stepsSplitTheWindowEvenlyFromTheHighNumberDown() {
    let l = TextLayer(id: "c", text: "", start: 7, end: 10, countdown: 3)
    let s = l.steps(in: 7...10, trimDuration: 20)
    #expect(s.map(\.layer.text) == ["3", "2", "1"])
    #expect(s.allSatisfy { $0.layer.id == "c" && $0.layer.countdown == nil })
    #expect(abs(s[0].window.lowerBound - 7) < 1e-9 && abs(s[0].window.upperBound - (8 - TextLayer.stepGap)) < 1e-9)
    #expect(abs(s[1].window.lowerBound - 8) < 1e-9 && abs(s[2].window.lowerBound - 9) < 1e-9)
    #expect(s[2].window.upperBound == 10)
    // No two numbers share an instant: each ends before the next begins.
    for k in 0..<2 { #expect(s[k].window.upperBound < s[k + 1].window.lowerBound) }
    // A plain text is itself.
    let plain = TextLayer(id: "p", text: "Hi")
    #expect(plain.steps(in: 1...2, trimDuration: 5).map(\.layer) == [plain])
  }

  /// Inner boundaries sit on the millisecond, so the renderer's times are exact; a number ends `stepGap` before the next
  /// (printed with six decimals), so no frame shows two numbers or none.
  @Test func stepBoundariesAreFrameExactInTheFilterGraph() {
    let s = TextLayer(id: "c", text: "", countdown: 3).steps(in: 0...2, trimDuration: 5)
    #expect(s.map(\.window.lowerBound) == [0, 0.667, 1.333])
    let g = Renderer.overlayGraph(s.map(\.window))
    #expect(g.contains("between(t,0.000,0.666990)") && g.contains("between(t,0.667,1.332990)") && g.contains("between(t,1.333,2.000)"))
    // Frames at 30 fps land in exactly one step each.
    for k in 0..<60 {
      let t = Double(k) / 30
      #expect(s.filter { $0.window.contains(t) }.count == 1, "frame \(k)")
    }
    // A plain text's window prints as before.
    #expect(Renderer.time(1.5) == "1.500" && Renderer.time(86400) == "86400.000")
  }

  @Test func theNumberGoesWhereNIsElseAlone() {
    var l = TextLayer(text: "Next song in {n}…", countdown: 3)
    #expect(l.countdownText(2) == "Next song in 2…")
    l.text = "Ready?"
    #expect(l.countdownText(2) == "2")
    l.text = ""
    #expect(l.countdownText(5) == "5" && !l.isBlank)  // a countdown always draws
    #expect(TextLayers.countdownLabel(l, from: 3) == "3 · 2 · 1")
    #expect(TextLayers.countdownLabel(l, from: 10) == "10 … 1")
  }

  @Test func layerWindowsExpandACountdownAndTheAPISeesOneText() {
    var v = Version(number: 1)
    v.text = "Header"
    v.moreText = [TextLayer(id: "q", text: "Q1", start: 0, end: 5), TextLayer(id: "c", text: "", start: 5, end: 8, countdown: 3)]
    let r = resolve(v)
    let w = PreviewKeys.layerWindows(r, trimDuration: 10)
    #expect(w.map(\.layer.text) == ["Header", "Q1", "3", "2", "1"])
    let api = AgentAPI.overlays(r, trimDuration: 10)
    #expect(api.count == 3 && api[2].countdown == 3 && api[2].shows_from == 5 && api[2].shows_to == 8)
    // A countdown past the trim isn't drawn; one cut by the trim counts down over what's left of it.
    #expect(PreviewKeys.layerWindows(r, trimDuration: 4).map(\.layer.text) == ["Header", "Q1"])
    let cut = PreviewKeys.layerWindows(r, trimDuration: 6.5).filter { $0.layer.id == "c" }
    #expect(cut.count == 3 && cut.last!.window.lowerBound == 6)
  }

  @Test func storedJSONAndHashesOnlyChangeWhenACountdownIsUsed() throws {
    let plain = TextLayer(id: "a", text: "T", start: 1, end: 2)
    #expect(!JSONCoding.string(plain).contains("countdown"))
    let counting = TextLayer(id: "a", text: "T", start: 1, end: 2, countdown: 3)
    let back = try JSONCoding.decoder.decode(TextLayer.self, from: JSONCoding.encoder.encode(counting))
    #expect(back.countdown == 3)
    // Out of range in stored JSON is clamped, never unreadable.
    let wild = try JSONCoding.decoder.decode(TextLayer.self, from: Data(#"{"id":"x","text":"","countdown":99}"#.utf8))
    #expect(wild.countdown == TextLayer.countdownRange.upperBound)
    #expect(PreviewKeys.layerKey(plain, aspect: .r9x16) != PreviewKeys.layerKey(counting, aspect: .r9x16))
  }

  @Test func aCountdownIsNeverPromotedToTheFirstText() {
    var v = Version(number: 1)
    v.text = "First"
    v.moreText = [TextLayer(id: "c", text: "", countdown: 3), TextLayer(id: "b", text: "Second")]
    let r = resolve(v)
    let out = TextLayers.removing(TextLayer.firstId, from: v, resolved: r)
    #expect(out?.text == "Second" && out?.moreText?.map(\.id) == ["c"])
    v.moreText = [TextLayer(id: "c", text: "", countdown: 3)]
    #expect(TextLayers.removing(TextLayer.firstId, from: v, resolved: resolve(v)) == nil)
    // A new text never inherits a countdown from the text it looks like.
    #expect(TextLayers.new(text: "x", like: TextLayer(text: "", countdown: 3)).countdown == nil)
  }

  @Test func countdownWindowEndsWhereTheTextEnds() {
    #expect(TextLayers.countdownWindow(3, span: (2, 10), trimDuration: 20) == (7, 10))
    #expect(TextLayers.countdownWindow(3, span: (0, 2), trimDuration: 20) == (0, 3))  // no room before: from its start
    #expect(TextLayers.countdownWindow(5, span: (0, 2), trimDuration: 3) == (0, 3))  // never past the trim
  }
}

/// Flat grey picture (as in R16RenderTests), so a solid colour in a frame can only be a text box.
private enum Grey {
  static let clip: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-grey26-\(ProcessInfo.processInfo.processIdentifier)")
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

/// Real ffmpeg renders of a 3 s trim (0.5–3.5 s of the grey file).
private final class Quiz {
  let f: Fixture
  let renderer: Renderer
  let id = "clip-0"
  var store: Store { f.store }

  init() throws {
    f = try Fixture(clips: [("quiz x clip", 4.0)], longform: false)
    let clip = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – quiz x clip.mp4")
    try FileManager.default.removeItem(at: clip)
    try FileManager.default.copyItem(at: Grey.clip, to: clip)
    try f.intake()
    renderer = Renderer(store: f.store)
    var e = Edit()
    e.crop = CropRect(x: 657, y: 0, w: 607.5, h: 1080)
    e.trimIn = 0.5; e.trimOut = 3.5
    try store.save(e, videoId: id)
  }

  func save(_ change: (inout Version) -> Void) throws {
    var v = Version(number: 1)
    v.caption = "caption"
    change(&v)
    try store.save(v, videoId: id)
  }

  var resolved: ResolvedVersion { get throws { try #require(try store.resolvedVersion(videoId: id, number: 1)) } }
  func render() throws -> URL { URL(fileURLWithPath: try #require(try renderer.ensureRender(videoId: id, versionNo: 1, platform: nil).outputPath)) }
  func frame(_ out: URL, at t: Double) throws -> Pixels { Pixels(try #require(Media.frame(out, at: t, maxSize: .zero))) }

  /// Is `layer`'s solid box colour in this picture? Sampled inside the box, left of the glyphs.
  func shows(_ layer: TextLayer, in px: Pixels) throws -> Bool {
    let b = try #require(TextOverlay.textBounds(for: layer, aspect: .r9x16))
    let (r, g, bl) = try #require(TextLook.rgb(layer.look?.accent))
    let p = px.at(Int(b.minX) + 6, Int(b.midY))
    let d = abs(Double(p.0) / 255 - r) + abs(Double(p.1) / 255 - g) + abs(Double(p.2) / 255 - bl)
    return d < 0.25
  }
}

@Suite(.serialized) struct R26RenderTests {
  /// S1-R3: 24 short timed texts in one render. Each sits in its own cell of a grid and shows for 1/8 s in turn, so
  /// the frame in the middle of text j's window shows text j and not the one after it.
  @Test func rendersAVersionWithTwentyFourShortTimedTexts() throws {
    let q = try Quiz()
    let green = TextLook(accent: "#00FF00")
    func cell(_ j: Int) -> (x: Double, y: Double) { ([0.25, 0.75][j % 2], 0.06 + Double(j / 2) * 0.077) }
    try q.save { v in
      v.text = "H"; v.size = 48; v.posX = cell(0).x; v.posY = cell(0).y; v.textStart = 0; v.textEnd = 0.125; v.textLook = green
      v.moreText = (1..<24).map { j in
        TextLayer(id: "t\(j)", text: "H", size: 48, posX: cell(j).x, posY: cell(j).y, start: Double(j) * 0.125,
                  end: Double(j + 1) * 0.125, look: green)
      }
    }
    let r = try q.resolved
    #expect(r.allLayers.count == 24 && PreviewKeys.layerWindows(r, trimDuration: 3).count == 24)
    let out = try q.render()
    for j in [0, 5, 11, 17, 22] {
      let px = try q.frame(out, at: Double(j) * 0.125 + 0.0625)
      #expect(try q.shows(r.allLayers[j], in: px), "text \(j + 1) should show")
      #expect(try !q.shows(r.allLayers[j + 1], in: px), "text \(j + 2) shouldn't show yet")
    }
    // The last one, at the end of the 24.
    #expect(try q.shows(r.allLayers[23], in: q.frame(out, at: 23 * 0.125 + 0.0625)))
    let left = try FileManager.default.contentsOfDirectory(atPath: q.store.paths.work.path).filter { $0.hasSuffix(".png") }
    #expect(left.isEmpty)
  }

  /// S2-R1: a countdown renders exactly like three plain texts at its steps, one number at a time.
  @Test func aCountdownRendersLikeItsNumbersOneAtATime() throws {
    let q = try Quiz()
    let look = TextLook(accent: "#00FF00")
    try q.save { v in
      v.text = "Guess"; v.posY = 0.15; v.textStart = 0; v.textEnd = 3
      v.moreText = [TextLayer(id: "c", text: "", size: 160, posY: 0.5, start: 0, end: 3, look: look, countdown: 3)]
    }
    let counted = try q.render()
    let a = try q.frame(counted, at: 0.5), b = try q.frame(counted, at: 1.5), c = try q.frame(counted, at: 2.5)
    let hashCountdown = try q.renderer.editHash(videoId: q.id, versionNo: 1, platform: nil)

    try q.save { v in
      v.text = "Guess"; v.posY = 0.15; v.textStart = 0; v.textEnd = 3
      v.moreText = [TextLayer(id: "3", text: "3", size: 160, posY: 0.5, start: 0, end: 0.999, look: look),
                    TextLayer(id: "2", text: "2", size: 160, posY: 0.5, start: 1, end: 1.999, look: look),
                    TextLayer(id: "1", text: "1", size: 160, posY: 0.5, start: 2, end: 3, look: look)]
    }
    #expect(try q.renderer.editHash(videoId: q.id, versionNo: 1, platform: nil) != hashCountdown)
    let plain = try q.render()
    func same(_ x: Pixels, _ y: Pixels) -> Bool {
      var off = 0
      for i in stride(from: 0, to: x.data.count, by: 4 * 97) where abs(Int(x.data[i]) - Int(y.data[i])) > 24 { off += 1 }
      return off < 20
    }
    #expect(try same(a, q.frame(plain, at: 0.5)) && same(b, q.frame(plain, at: 1.5)) && same(c, q.frame(plain, at: 2.5)))
    #expect(!same(a, b) && !same(b, c))  // the number changes each second
  }
}

/// `djq overlay add|set --countdown` end to end.
@Suite(.serialized) struct R26OverlayCLITests {
  typealias Env = R6PostizCLITests.Env

  func list(_ env: Env) throws -> [[String: Any]] {
    let r = try env.djq("overlay", "list", "clip-0", "--json")
    return try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]], "\(r.out)\(r.err)")
  }

  @Test func addsACountdownInOneSlotEndingAtEnd() throws {
    let env = try Env(clips: 1)
    var r = try env.djq("overlay", "add", "clip-0", "--countdown", "3", "--end", "10")
    #expect(r.status == 0, "\(r.err)")
    var l = try list(env)
    #expect(l.count == 2 && l[1]["countdown"] as? Int == 3 && l[1]["start"] as? Double == 7 && l[1]["end"] as? Double == 10)
    #expect(l[1]["drawn"] as? Bool == true && l[1]["shows_from"] as? Double == 7 && l[1]["shows_to"] as? Double == 10)
    #expect(r.out.contains("countdown from 3"))

    // Words around the number, a different count, then off (its window stays).
    let id = try #require(l[1]["id"] as? String)
    r = try env.djq("overlay", "set", "clip-0", id, "Next in {n}", "--countdown", "5")  // a new count keeps the window
    #expect(r.status == 0, "\(r.err)")
    l = try list(env)
    #expect(l[1]["countdown"] as? Int == 5 && l[1]["text"] as? String == "Next in {n}" && l[1]["start"] as? Double == 7)
    r = try env.djq("overlay", "set", "clip-0", id, "--countdown", "5", "--end", "12")  // with --end: the last 5 s before it
    l = try list(env)
    #expect(r.status == 0 && l[1]["start"] as? Double == 7 && l[1]["end"] as? Double == 12)
    r = try env.djq("overlay", "set", "clip-0", id, "--countdown", "off")
    #expect(r.status == 0, "\(r.err)")
    l = try list(env)
    #expect(l[1]["countdown"] == nil && l[1]["start"] as? Double == 7 && l[1]["end"] as? Double == 12)

    // From --start with no --end: one second a number from there.
    r = try env.djq("overlay", "add", "clip-0", "--countdown", "3", "--start", "2")
    l = try list(env)
    #expect(r.status == 0 && l[2]["start"] as? Double == 2 && l[2]["end"] as? Double == 5)

    // Refusals: the first text, an out-of-range count, plain text with no words.
    r = try env.djq("overlay", "set", "clip-0", "1", "--countdown", "3")
    #expect(r.status != 0 && r.err.contains("text 1 can't count down"))
    r = try env.djq("overlay", "add", "clip-0", "--countdown", "11")
    #expect(r.status != 0 && r.err.contains("--countdown"))
    r = try env.djq("overlay", "add", "clip-0", "   ")
    #expect(r.status != 0 && r.err.contains("write the text"))
    // Text 1 with only countdowns after it can't be removed, and says why.
    try env.djq("overlay", "remove", "clip-0", id)
    r = try env.djq("overlay", "remove", "clip-0", "1")
    #expect(r.status != 0 && r.err.contains("a countdown can't be text 1"), "\(r.err)")
  }

  /// The quiz layout from the request: header, three questions of six texts (question, 3-2-1, wrong, right) and a
  /// closing text is 20 texts; with a one-slot countdown it's 14. Both fit, and the 33rd text is refused.
  @Test func aThreeQuestionQuizFitsAndThe33rdIsRefused() throws {
    let env = try Env(clips: 1)
    func add(_ a: String...) throws {
      let r = try env.djq(args: ["overlay", "add", "clip-0"] + a)
      #expect(r.status == 0, "\(a): \(r.err)")
    }
    for q in 0..<3 {
      let s = Double(q) * 6
      try add("Q\(q + 1): A, B or C?", "--start", "\(s)", "--end", "\(s + 3)")
      for (k, n) in ["3", "2", "1"].enumerated() { try add(n, "--start", "\(s + Double(k))", "--end", "\(s + Double(k) + 1)") }
      try add("A  B", "--start", "\(s + 3)", "--end", "\(s + 6)", "--color", "#FF3B30")
      try add("C", "--start", "\(s + 3)", "--end", "\(s + 6)", "--color", "#34C759")
    }
    try add("Comment your score", "--start", "18")
    #expect(try list(env).count == 20)
    for i in 21...32 { try add("T\(i)") }
    let r = try env.djq("overlay", "add", "clip-0", "Thirty-three")
    #expect(r.status != 0 && r.err.contains("already has 32 texts"))
    #expect(try list(env).count == 32)
  }
}

/// A photo with audio is a video, so it can count down; taking the audio off makes it a photo post again, where a
/// countdown has no time: it becomes a plain text with its first number.
@Suite(.enabled(if: Tone.haveTools, "ffmpeg and ffprobe aren't installed")) struct R26PhotoAudioCountdownTests {
  @Test func removeAudioTurnsACountdownIntoItsFirstNumber() throws {
    let f = try Fixture(clips: [], longform: false)
    let made = try f.still(seconds: 3)
    var one = Version(number: 1)
    one.text = "Loft nights"
    one.moreText = [TextLayer(id: "c", text: "Next in {n}", start: 0, end: 3, countdown: 3), TextLayer(id: "p", text: "Plain")]
    try f.store.save(one, videoId: made.id)
    let v = try StillVideo(store: f.store).removeAudio(videoId: made.id).video
    #expect(v.isPhoto)
    let r = try #require(try f.store.resolvedVersion(videoId: v.id, number: 1))
    #expect(r.moreText.map(\.text) == ["Next in 3", "Plain"] && r.moreText.allSatisfy { $0.countdown == nil && $0.start == nil })
    #expect(PhotoRules.layers(r, onPhoto: 0, of: 1).map(\.text) == ["Loft nights", "Next in 3", "Plain"])
  }
}
