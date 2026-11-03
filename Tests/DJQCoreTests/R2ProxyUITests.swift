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

  @Test func engineTickOnlyEnqueuesProxies() throws {
    let f = try Fixture.engine(5, ready: 2)
    let e = Engine(store: f.store, renderer: nil, publisher: nil, notifier: LogNotifier())
    #expect(e.proxyService == nil && e.tick(reason: "t").steps["proxies"] == "off")  // off without the real renderer
    let ps = ProxyService(store: f.store)
    let made = Locked<[String]>([])
    let gate = DispatchSemaphore(value: 0)
    ps.make = { _, v, _ in
      gate.wait()  // a "hung" encode must not hold up the tick
      made.mutate { $0.append(v.id) }
      if v.id == "clip-2" { throw MediaError("boom") }
      return URL(fileURLWithPath: "/tmp/\(v.id).mp4")
    }
    e.proxyService = ps
    let t0 = Date()
    let r = e.tick(reason: "t")
    #expect(Date().timeIntervalSince(t0) < 5)
    #expect(r.steps["proxies"]?.hasPrefix("queued 5") == true && r.errors.isEmpty)
    for _ in 0..<5 { gate.signal() }
    // Wait for the work itself, with room for a loaded machine (the auto-update gate runs the suite in parallel).
    let deadline = Date().addingTimeInterval(30)
    while ps.pendingCount > 0 || made.value.count < 5, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    #expect(made.value.first == "clip-2" && made.value.count == 5)  // clips to score first
    #expect(try f.store.kv("proxyFail.clip-2", as: String.self) != nil)
    // Next tick: the failed clip isn't retried in the background (nothing here caches, so the others are retried).
    for _ in 0..<10 { gate.signal() }
    e.tick(reason: "t")
    let d2 = Date().addingTimeInterval(30)
    while ps.pendingCount > 0 || made.value.count < 9, Date() < d2 { Thread.sleep(forTimeInterval: 0.02) }
    #expect(made.value.filter { $0 == "clip-2" }.count == 1 && made.value.count == 9)
    // A visible request always tries.
    let done = DispatchSemaphore(value: 0)
    ps.request("clip-2", priority: .visible) { _ in done.signal() }
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(made.value.filter { $0 == "clip-2" }.count == 2)
  }

  @Test func backgroundProxiesPauseWhileRendering() throws {
    let f = try Fixture.engine(2, ready: 0)
    let ps = ProxyService(store: f.store)
    let paused = Locked(true)
    ps.shouldPause = { paused.value }
    let made = Locked<[String]>([])
    ps.make = { _, v, _ in made.mutate { $0.append(v.id) }; return URL(fileURLWithPath: "/tmp/x.mp4") }
    ps.request("clip-0", priority: .background)
    let vis = DispatchSemaphore(value: 0)
    ps.request("clip-1", priority: .visible) { _ in vis.signal() }
    #expect(vis.wait(timeout: .now() + 5) == .success)
    Thread.sleep(forTimeInterval: 0.3)
    #expect(made.value == ["clip-1"])
    paused.mutate { $0 = false }
    let d = Date().addingTimeInterval(5)
    while ps.pendingCount > 0, Date() < d { Thread.sleep(forTimeInterval: 0.05) }
    #expect(made.value == ["clip-1", "clip-0"])
    ps.stop()
  }

  @Test func proxyLockMakesASecondProcessWaitAndReuse() throws {
    let f = try Fixture()
    try f.intake()
    try f.store.setSourceSize("clip-0", width: 1920, height: 1080)
    let v = try #require(try f.store.video(id: "clip-0"))
    let url = try Media.proxyURL(store: f.store, video: v)
    try FileManager.default.createDirectory(at: f.paths.proxies, withIntermediateDirectories: true)
    // "Another process" holds the clip's proxy lock (flock is per open file, so a second open in this process blocks too).
    let fd = open(f.paths.proxies.appendingPathComponent(".clip-0-trim.lock").path, O_CREAT | O_RDWR, 0o644)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let got = Locked<URL?>(nil)
    let store = f.store
    let t = Thread { let u = try? Media.ensureProxy(store: store, video: v, timeout: 5); got.mutate { $0 = u } }
    t.start()
    Thread.sleep(forTimeInterval: 0.4)
    #expect(got.value == nil)  // waiting, not encoding
    try Data("proxy".utf8).write(to: url)  // the other process finishes…
    flock(fd, LOCK_UN); close(fd)  // …and releases
    let d = Date().addingTimeInterval(5)
    while got.value == nil, Date() < d { Thread.sleep(forTimeInterval: 0.05) }
    #expect(got.value == url)  // reused the finished file (the fake source could never have been encoded)
  }

  @Test func engineSkipsProxiesWhileRendersWait() throws {
    let f = try Fixture.engine(8)
    try Planner(store: f.store).approveWeek(f.week)
    let e = Engine(store: f.store, renderer: FakeRenderer(store: f.store), publisher: nil, notifier: LogNotifier())
    let ps = ProxyService(store: f.store)
    ps.make = { _, _, _ in throw MediaError("should not run") }
    e.proxyService = ps
    #expect(e.tick(reason: "t").steps["proxies"] == "waiting for renders")
    #expect(ps.pendingCount == 0)
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
