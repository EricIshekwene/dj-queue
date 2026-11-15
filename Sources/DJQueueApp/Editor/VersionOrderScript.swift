import AppKit
import DJQCore
import SwiftUI

/// `DJQ_VERSION_ORDER_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 35 end to end on a throwaway
/// copy of the database, in backstage windows only.
///
/// 1. The editor's version list, in its own window first (the real one is a native popover macOS would pull onto a
///    display: a stand-in, said so in the log), on a Queue clip with three versions: every row says when it posts in one
///    line ("Planned to post …", no platform list) and its place in the order. Real clicks on the ↑ / ↓ arrows change
///    the order; the store's order, the clip's days (which version each carries) and every row follow.
/// 2. The Queue card for the clip: the date chip carries the version the new order puts first.
/// 3. Library › All: a clip removed from videos.json and excluded reads "Removed", not "File missing", and isn't
///    counted under Missing.
/// Exits 1 on a FAIL.
@MainActor
enum VersionOrderScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    try? script.log.joined(separator: "\n").write(to: out.appendingPathComponent("version-order-checks-\(appearance).txt"),
                                                  atomically: true, encoding: .utf8)
    print("version-order: \(script.failed) failed, \(script.passed) passed")
    return script.failed == 0 ? 0 : 1
  }

  @MainActor
  private final class Runner {
    let store: Store, out: URL, appearance: String
    var log: [String] = []
    var failed = 0, passed = 0, step = 0

    init(store: Store, out: URL, appearance: String) { self.store = store; self.out = out; self.appearance = appearance }

    func note(_ s: String) { print("version-order: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if ok { passed += 1 } else { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Window

    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }

    func anchors(_ v: NSView, prefix: String, into out: inout [String]) {
      if let id = v.identifier?.rawValue, id.hasPrefix(ScriptAnchor.prefix + prefix) { out.append(String(id.dropFirst(ScriptAnchor.prefix.count))) }
      for c in v.subviews { anchors(c, prefix: prefix, into: &out) }
    }

    func marks(_ w: NSWindow, _ prefix: String) -> [String] {
      var found: [String] = []
      if let root = w.contentView { anchors(root, prefix: prefix, into: &found) }
      return found
    }

    func mouse(_ w: NSWindow, _ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        w.sendEvent(e)
      }
    }

    /// A real click (events sent to that window) on the control marked `label`.
    @discardableResult func click(_ w: NSWindow, _ label: String) async -> Bool {
      guard let root = w.contentView, let a = anchor(root, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      let f = a.convert(a.bounds, to: nil)
      let p = NSPoint(x: f.midX, y: f.midY)
      mouse(w, .leftMouseDown, p)
      await wait(40)
      mouse(w, .leftMouseUp, p)
      await wait(1500)
      return true
    }

    var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

    func capture(_ w: NSWindow) async -> Data? {
      if screenLocked, let host = w.contentView {
        note("screen locked: capture is the view tree")
        w.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
      }
      for _ in 0..<10 {
        Backstage.front(w)
        await wait(250)
        if let data = WindowCapture.png(w), let img = NSBitmapImageRep(data: data)?.cgImage, !Self.isBlank(img) { return data }
        note("blank capture, trying again")
        await wait(1000)
      }
      return nil
    }

    func shot(_ name: String, _ w: NSWindow) async {
      await wait(600)
      step += 1
      let file = out.appendingPathComponent(String(format: "version-order-%02d-%@-%@.png", step, name, appearance))
      guard let data = await capture(w), (try? data.write(to: file)) != nil else { check("captured \(name)", false); return }
      note("shot \(file.lastPathComponent)")
    }

    static func isBlank(_ img: CGImage) -> Bool {
      let w = 48, h = 30
      var px = [UInt8](repeating: 0, count: w * h * 4)
      guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
      let first = Array(px.prefix(3))
      return stride(from: 0, to: px.count, by: 4).allSatisfy { i in (0..<3).allSatisfy { abs(Int(px[i + $0]) - Int(first[$0])) < 6 } }
    }

    // MARK: Store

    func settings() -> AppSettings { (try? store.settings()) ?? AppSettings() }
    func slots(_ id: String) -> [PlanSlot] {
      ((try? store.planSlots(where: "video_id=?", [id])) ?? []).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
    }
    func order(_ id: String) -> [Int] { (try? store.versionOrder(videoId: id)) ?? [] }
    /// Live regular posts of the clip per platform and version post: each must be one.
    func livePairs(_ id: String) -> [String: Int] {
      ((try? store.posts(where: "video_id=? AND kind='regular'", [id])) ?? []).filter { !$0.state.isTerminal || $0.state == .posted }
        .reduce(into: [String: Int]()) { $0["\($1.platform.rawValue) \($1.unit)", default: 0] += 1 }
    }

    // MARK: The run

    func main() async {
      let a = AppModel(store: store)
      _ = try? Planner(store: store).autoSchedule()
      a.refreshNow()
      a.loaded = true
      let dm = DayMath(settings: settings())
      let today = a.todayKey
      // In the newest backups every day for the next weeks has a first post, and a repeat looks only a week ahead, so a
      // clip's later versions may have no day yet. The engine's pass as of a week on gives them days (this copy only).
      note("seeding: the engine's pass as of \(dm.addDays(today, 8)) 08:00 (this copy only), so later versions get days")
      _ = try? Planner(store: store).autoSchedule(now: dm.at(dm.addDays(today, 8), minutes: 8 * 60))
      a.refreshNow()
      // A Queue clip with three versions (the most days first), else two.
      func versionCount(_ v: Video) -> Int { ((try? store.versions(videoId: v.id)) ?? []).filter { $0.number > 1 }.count + 1 }
      // Its first day must still be free to change (after today, nothing in Postiz): a day going out today keeps its version.
      func freeFirstDay(_ v: Video) -> Bool {
        guard let s = slots(v.id).first, s.date > today else { return false }
        let posts = (try? store.posts(where: "plan_slot_id=?", [s.id])) ?? []
        return posts.allSatisfy { ((try? store.postizJobs(postId: $0.id)) ?? []).isEmpty }
      }
      var candidates = a.queueList.filter { $0.type == .short && !$0.isPhoto && !$0.missing && versionCount($0) >= 2 && freeFirstDay($0) }
      if candidates.isEmpty {
        // This copy's Queue has none: send Edit clips with versions to the Queue here (this copy only), as Eric did.
        let edits = a.editList.filter { $0.type == .short && !$0.isPhoto && !$0.missing && versionCount($0) >= 2 }
        note("seeding: sending \(edits.count) Edit clip(s) with versions to the Queue (this copy only)")
        let sent = try? BulkActions(store: store).sendToQueue(edits.map(\.id))
        note("sent: \(sent?.summary ?? "nothing")")
        _ = try? Planner(store: store).autoSchedule()
        _ = try? Planner(store: store).autoSchedule(now: dm.at(dm.addDays(today, 8), minutes: 8 * 60))
        a.refreshNow()
        candidates = a.queueList.filter { $0.type == .short && !$0.isPhoto && !$0.missing && versionCount($0) >= 2 && freeFirstDay($0) }
      }
      guard let clip = candidates.max(by: { (min(versionCount($0), 3), slots($0.id).count) < (min(versionCount($1), 3), slots($1.id).count) }) else {
        check("a Queue clip with versions", false); return
      }
      let id = clip.id
      let n = versionCount(clip)
      note("clip \(id.prefix(8)) “\(a.displayName(clip))”, \(n) versions, days: \(slots(id).map { "\($0.date) \($0.unit)" }.joined(separator: ", "))")
      check("it starts in number order", order(id) == Array(1...n).filter { v in ((try? store.versions(videoId: id)) ?? []).contains { $0.number == v } || v == 1 })

      // 1. The version list on its own (stand-in for the popover).
      let e = EditorModel(store: store, videoId: id)
      for _ in 0..<40 where e.video == nil { await wait(150) }
      let list = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 380, height: 120 + 64 * CGFloat(n)), [.titled, .fullSizeContentView])
      list.titlebarAppearsTransparent = true
      list.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      list.isReleasedWhenClosed = false
      let hc = NSHostingController(rootView: EditorVersionList(model: e) { _ in })
      hc.sceneBridgingOptions = []
      list.contentViewController = hc
      list.setContentSize(NSSize(width: 380, height: 150 + 64 * CGFloat(n)))
      Backstage.show(list)
      defer { list.orderOut(nil); list.close() }
      note("stand-in: the version list in its own backstage window (the real one is a native popover)")
      await wait(1800)
      let numbers = e.orderedVersionNumbers
      check("the list shows every version (\(numbers))", numbers.count == n && marks(list, "Version plan v").count == n)
      for v in numbers {
        let line = e.planLine(of: v)
        note("v\(v): \(line)")
        check("v\(v)'s line names no platform", !Platform.allCases.contains { line.contains($0.displayName) })
        if slots(id).contains(where: { $0.versionNo == v && $0.date >= today }) {
          check("v\(v) has a day → “Planned to post …”", line.hasPrefix("Planned to post "))
        }
      }
      check("each row shows its place (1st…)", marks(list, "Version order v").count == n)
      await shot("version-list-number-order", list)

      // Real clicks: v2 ↑ → v2 posts first.
      let firstDay = slots(id).first { $0.date >= today }
      note("first day before: \(firstDay.map { "\($0.date) \($0.unit)" } ?? "none")")
      await click(list, "Version earlier v2")
      for _ in 0..<20 where order(id).first != 2 { await wait(250) }
      let want = [2, 1] + (n >= 3 ? Array(3...n) : [])
      check("click ↑ on v2 → the store's order is \(VersionOrder.text(want))", order(id) == want)
      let afterDay = slots(id).first { $0.id == firstDay?.id }
      check("the clip's first day (\(firstDay?.date ?? "?")) now carries v2 · 1 (same day, same place)",
            firstDay == nil || (afterDay?.unit == PostUnit(version: 2, post: 1) && afterDay?.date == firstDay?.date))
      if let s = afterDay {
        check("…and its posts were made again for v2", ((try? store.posts(where: "plan_slot_id=?", [s.id])) ?? []).allSatisfy { $0.versionNo == 2 })
      }
      for _ in 0..<20 where e.orderedVersionNumbers.first != 2 { await wait(250) }
      check("the list now starts with v2", e.orderedVersionNumbers == want)
      check("v2's line is its new day", firstDay == nil || e.planLine(of: 2).hasPrefix("Planned to post"))
      await shot("version-list-v2-first", list)
      if n >= 3 {
        await click(list, "Version later v1")
        for _ in 0..<20 where order(id) == want { await wait(250) }
        check("click ↓ on v1 → v2, then v3, then v1", order(id).prefix(3) == [2, 3, 1])
        await shot("version-list-v1-later", list)
        await click(list, "Version earlier v1")
        for _ in 0..<20 where order(id).prefix(3) != [2, 1, 3] { await wait(250) }
        check("click ↑ on v1 → back to v2, then v1, then v3", order(id) == want)
      }
      check("no live version post is doubled on a platform (\(livePairs(id)))", livePairs(id).allSatisfy { $0.value == 1 })
      e.flushAndWait()

      // 2. The Queue card's date chip carries v2 now.
      a.refreshNow()
      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = list.appearance
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }
      a.screen = .queue
      ListPrefs.shared.setSearch(.queue, a.displayName(clip))
      await wait(2500)
      let card = a.dsClip(clip, for: .queue)
      note("Queue card: \(card.dateText ?? "-") · \(card.dateUnit ?? "-") · \(card.units.map(\.text).joined(separator: ", "))")
      check("Queue card: the next version post is v2", firstDay == nil || (card.dateUnit ?? "").hasPrefix("v2"))
      await shot("queue-v2-first", w)
      ListPrefs.shared.reset()

      // 3. Library › All: removed on purpose reads "Removed".
      let discarded = a.libraryAll.filter(\.isDiscarded)
      note("removed on purpose in this copy: \(discarded.map { a.displayName($0) }.joined(separator: ", "))")
      if discarded.isEmpty {
        note("this copy has no clip removed from videos.json and excluded; the Library part is skipped")
      } else {
        check("none of them reads File missing", discarded.allSatisfy { !a.libraryShowsMissing($0) })
        check("each one's chip is Removed", discarded.allSatisfy { a.libraryStateChip($0).text == "Removed" })
        check("Missing doesn't count them", discarded.allSatisfy { !a.libraryShowsMissing($0) && !a.libraryIsRemoved($0) })
        // Library › All with the set's name: the removed quiz clips aren't among the tiles (look at the shot).
        a.screen = .library
        ListPrefs.shared.reset()
        ListPrefs.shared.setSearch(.library, "Mix Session")
        await wait(2500)
        await shot("library-all-mix-session", w)
        a.screen = .library
        ListPrefs.shared.setStatus(.library, LibraryFilter.excluded.rawValue)
        ListPrefs.shared.setSearch(.library, "quiz")
        await wait(2500)
        await shot("library-removed", w)
        ListPrefs.shared.reset()
      }
    }
  }
}
