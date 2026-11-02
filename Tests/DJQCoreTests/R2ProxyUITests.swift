import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// Round 2 #12 proxies (tiny lavfi media) and #4/#8 platform geometry data.
@Suite struct R2ProxyTests {
  func realClip() throws -> Fixture {
    let f = try Fixture(clips: [("yayo x johnny", 4.0)], longform: false)
    let clip = f.sessionDir.appendingPathComponent("Clips/2026-10-23 – Afroween Jazz Piano – yayo x johnny.mp4")
    try FileManager.default.removeItem(at: clip)
    try FileManager.default.copyItem(at: TestMedia.clip, to: clip)
    try f.intake()
    return f
  }

  @Test(.enabled(if: Tools.ffmpeg != nil)) func proxyIs540x960CachedAndKeyedByCropAndTrim() throws {
    let f = try realClip()
    var v = try #require(try f.store.video(id: "clip-0"))
    let url = try Media.ensureProxy(store: f.store, video: v)
    let info = try Media.probe(url)
    #expect(info.width == 540 && info.height == 960 && info.videoCodec == "h264" && info.hasAudio)
    #expect(abs(info.duration - 4.0) < 0.15)  // the 4 s fixture's markers cross (3 s in from each end) → whole file
    #expect(url.path.hasPrefix(f.paths.proxies.path))
    v = try #require(try f.store.video(id: "clip-0"))
    #expect(v.sourceWidth == 1920 && v.sourceHeight == 1080)
    let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    #expect(try Media.ensureProxy(store: f.store, video: v) == url)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtime)
    // A confirmed crop → a new proxy; the old one is removed.
    var e = Edit()
    e.crop = CropRect(x: 0, y: 0, w: 607.5, h: 1080)
    try f.store.save(e, videoId: "clip-0")
    let url2 = try Media.ensureProxy(store: f.store, video: v)
    #expect(url2 != url && !FileManager.default.fileExists(atPath: url.path))
    // Whole-file range.
    let whole = try Media.ensureProxy(store: f.store, video: v, range: .wholeFile)
    #expect(abs(try Media.probe(whole).duration - 4.0) < 0.15)
    #expect(Media.cachedProxy(store: f.store, video: v) == url2)
  }

  @Test func proxyServiceRunsVisibleFirstAndDedupes() throws {
    let f = try Fixture.engine(4, ready: 0)
    let svc = ProxyService(store: f.store)
    let order = Locked<[String]>([])
    let gate = DispatchSemaphore(value: 0)
    svc.make = { _, v, _ in
      if v.id == "clip-0" { gate.wait() }  // hold the worker so the queue builds up
      order.mutate { $0.append(v.id) }
      return URL(fileURLWithPath: "/tmp/\(v.id).mp4")
    }
    let done = DispatchGroup()
    for id in ["clip-0", "clip-1", "clip-2", "clip-3"] {
      done.enter()
      svc.request(id, priority: id == "clip-0" ? .visible : .background) { _ in done.leave() }
    }
    done.enter()
    svc.request("clip-1", priority: .background) { _ in done.leave() }  // deduped, completion still called
    Thread.sleep(forTimeInterval: 0.1)
    svc.setVisible(["clip-3"])
    gate.signal()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(order.value.first == "clip-0" && order.value[1] == "clip-3")
    #expect(order.value.count == 4 && svc.pendingCount == 0)
  }

  @Test func engineMakesProxiesOnlyWhenIdle() throws {
    let f = try Fixture.engine(5, ready: 2)
    let made = Locked<[String]>([])
    let e = Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier())
    #expect(e.proxyMaker == nil)  // off without the real renderer
    #expect(e.tick(reason: "t").steps["proxies"] == "off")
    e.proxyMaker = { _, v in
      made.mutate { $0.append(v.id) }
      if v.id == "clip-2" { throw MediaError("boom") }
      let u = try Media.proxyURL(store: f.store, video: v)
      try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("p".utf8).write(to: u)
      return u
    }
    let r = e.tick(reason: "t")
    #expect(r.steps["proxies"]?.hasPrefix("made") == true)
    #expect(made.value == ["clip-2", "clip-3"])  // unscored first, 2 per tick
    #expect(r.errors.isEmpty)
    e.tick(reason: "t")
    #expect(made.value == ["clip-2", "clip-3", "clip-4", "clip-0"])  // clip-2's failure isn't retried
    e.tick(reason: "t")
    #expect(made.value.count == 5 && made.value.last == "clip-1")
    #expect(e.tick(reason: "t").steps["proxies"] == "up to date")
  }

  @Test func engineSkipsProxiesWhileRendersWait() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let e = Engine(store: f.store, renderer: FakeRenderer(store: f.store), publisher: nil, notifier: LogNotifier())
    e.proxyMaker = { _, _ in throw MediaError("should not run") }
    #expect(e.tick(reason: "t").steps["proxies"] == "waiting for renders")
  }
}

final class Locked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var v: T
  init(_ v: T) { self.v = v }
  var value: T { lock.withLock { v } }
  func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

@Suite struct R2PlatformUITests {
  @Test func everyPlatformHasDataAndHandles() {
    for p in Platform.allCases {
      let s = PlatformUI.spec(p)
      #expect(!s.elements.isEmpty && s.captionLines > 0)
      for e in s.elements { #expect(e.screen.minX >= 0 && e.screen.maxX <= 1.0001 && e.screen.maxY <= 1.0001) }
    }
    #expect(PlatformUI.handle(.tiktok) == "@dj.lovd" && PlatformUI.handle(.instagram) == "@dj.lovd")
    #expect(PlatformUI.handle(.x) == "@djlovdreal" && PlatformUI.handle(.youtube) == "@dj.lovdreal")
    #expect(PlatformUI.spec(.threads).layout == .postCard && PlatformUI.spec(.x).layout == .postCard)
    #expect(PlatformUI.spec(.youtube).showsTitle)
  }

  @Test func overlaysFollowDesignTableAndAspect() {
    let tt = PlatformUI.overlays(.tiktok, aspect: .r9x16)
    let rail = tt.first { $0.kind == .rightRail }!.frame!
    #expect(abs(rail.minX - 0.828) < 1e-9 && abs(rail.minY - 0.494) < 1e-9 && abs(rail.maxY - 0.983) < 1e-9)
    #expect(!tt.contains { $0.kind == .bottomNav })  // not over the video
    for e in PlatformUI.overlays(.instagram, aspect: .r4x5) {
      let r = e.frame!
      #expect(r.minY >= 0 && r.maxY <= 1.0001)
    }
    #expect(PlatformUI.overlays(.x, aspect: .r9x16).isEmpty && PlatformUI.overlays(.tiktok, aspect: .r16x9).isEmpty)
    #expect(Set(PlatformUI.unsafeRects([.tiktok, .youtube], aspect: .r9x16).keys) == [.tiktok, .youtube])
  }

  @Test func cardMediaFrames() throws {
    let x = try #require(PlatformUI.cardMediaFrame(.x, aspect: .r9x16))  // portrait cropped to 4:5
    #expect(abs(Double(x.width * 9) / Double(x.height * 19.5) - 0.8) < 0.01)
    let th = try #require(PlatformUI.cardMediaFrame(.threads, aspect: .r9x16))
    #expect(abs(Double(th.width * 9) / Double(th.height * 19.5) - 9.0 / 16) < 0.01)
    #expect(PlatformUI.cardMediaFrame(.tiktok, aspect: .r9x16) == nil)
  }

  @Test func previewCaptionTruncates() {
    let long = String(repeating: "word ", count: 60)
    let ig = PlatformUI.previewCaption(long, for: .instagram)
    #expect(ig.truncated && ig.text.hasSuffix("…") && ig.text.count <= 44)
    let tt = PlatformUI.previewCaption("Yayo x Johnny\n\n#dj", for: .tiktok)
    #expect(!tt.truncated && tt.text == "Yayo x Johnny  #dj")
    let x = PlatformUI.previewCaption("a\nb\nc\nd\ne\nf", for: .x)
    #expect(x.truncated && x.text.hasSuffix(" Show more"))
  }
}
