import AppKit
import DJQCore
import SwiftUI

/// `DJQ_VERSION_POSTS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 31 "every version posts its
/// count" end to end in the REAL main window with the REAL `AppModel`, on a throwaway copy of the database. Clicks are
/// events sent to that window only (it stays off every display); every check reads the store.
///
/// 1. Settings › Schedule: + and − on Posts per version (real clicks) change `Settings.postsPerVersion` and back.
/// 2. The editor on a Queue clip with two versions: + on v2's Posts row (real click) gives v2 a count of its own, Use
///    default takes it away, + again sets it, and nothing about how the clip looks changed.
/// 3. The plan picks it up (the engine's pass, run here), then the Queue shows each card's next version post on its date
///    chip and the others as tags, and the Calendar week shows every card's version post, each matching the store.
/// Picking v2 goes through the model (the version list is a native popover; a stand-in, said so in the log). Exits 1 on a FAIL.
@MainActor
enum VersionPostsScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let script = Runner(store: store, out: out, appearance: appearance)
    await script.main()
    try? script.log.joined(separator: "\n").write(to: out.appendingPathComponent("version-posts-checks-\(appearance).txt"),
                                                  atomically: true, encoding: .utf8)
    print("version-posts: \(script.failed) failed, \(script.passed) passed")
    return script.failed == 0 ? 0 : 1
  }

  @MainActor
  private final class Runner {
    let store: Store, out: URL, appearance: String
    var log: [String] = []
    var failed = 0, passed = 0, step = 0
    var window: NSWindow!

    init(store: Store, out: URL, appearance: String) { self.store = store; self.out = out; self.appearance = appearance }

    func note(_ s: String) { print("version-posts: \(s)"); log.append(s) }
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

    /// Every script anchor in the window whose name starts with `prefix`.
    func marks(_ prefix: String) -> [String] {
      var found: [String] = []
      if let root = window.contentView { anchors(root, prefix: prefix, into: &found) }
      return found
    }

    func has(_ label: String) -> Bool { window.contentView.flatMap { anchor($0, ScriptAnchor.prefix + label) } != nil }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(e)
      }
    }

    enum Spot { case middle, leading, trailing }

    /// A real click on the control marked `label`: its middle, or the − / + end of a stepper.
    @discardableResult func click(_ label: String, at spot: Spot = .middle) async -> Bool {
      guard let root = window.contentView, let a = anchor(root, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      a.scrollToVisible(a.bounds)
      await wait(300)
      let f = a.convert(a.bounds, to: nil)
      let x: CGFloat = switch spot {
      case .middle: f.midX
      case .leading: f.minX + 14
      case .trailing: f.maxX - 14
      }
      let p = NSPoint(x: x, y: f.midY)
      mouse(.leftMouseDown, p)
      await wait(40)
      mouse(.leftMouseUp, p)
      await wait(900)
      return true
    }

    var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

    func capture() async -> Data? {
      if screenLocked, let host = window.contentView {
        note("screen locked: capture is the view tree")
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
      }
      for _ in 0..<10 {
        Backstage.front(window)
        await wait(250)
        if let data = WindowCapture.png(window), let img = NSBitmapImageRep(data: data)?.cgImage, !Self.isBlank(img) { return data }
        note("blank capture, trying again")
        await wait(1000)
      }
      return nil
    }

    func shot(_ name: String) async {
      await wait(600)
      step += 1
      let file = out.appendingPathComponent(String(format: "version-posts-%02d-%@-%@.png", step, name, appearance))
      guard let data = await capture(), (try? data.write(to: file)) != nil else { check("captured \(name)", false); return }
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

    func ownCount(_ id: String, _ n: Int) -> Int? {
      EditorModel.flushLiveAndWait()
      return ((try? store.versions(videoId: id)) ?? []).first { $0.number == n }?.postCount
    }

    func count(_ id: String, _ n: Int) -> Int { (try? store.postCount(videoId: id, version: n)) ?? -1 }

    /// How the clip looks: its preview identity over every version (a count must never move it).
    func stamp(_ id: String) -> String {
      EditorModel.flushLiveAndWait()
      guard let v = (try? store.video(id: id)) ?? nil, let t = try? store.previewStampTable() else { return "?" }
      return t.stamp(for: v, version: .max)
    }

    /// The clip's version posts as `djq video --json` reports them.
    func units(_ id: String) -> [AgentAPI.UnitOut] { (try? AgentAPI.units(id, store: store, settings: settings())) ?? [] }

    // MARK: The run

    func main() async {
      let a = AppModel(store: store)
      // The engine's pass on this copy: the round-31 migration already ran when it opened; this lays out version posts.
      _ = try? Planner(store: store).autoSchedule()
      a.refreshNow()
      a.loaded = true
      let today = a.todayKey
      let upcoming = ((try? store.planSlots(where: "date>=?", [today])) ?? []).sorted { ($0.date, $0.position) < ($1.date, $1.position) }
      // A Queue clip with two versions and a day coming, the soonest first.
      let twoVersions = a.queueList.filter { v in
        v.type == .short && !v.isPhoto && !v.missing && ((try? store.versions(videoId: v.id)) ?? []).contains { $0.number == 2 }
      }
      let firstDay = Dictionary(upcoming.map { ($0.videoId, $0.date) }, uniquingKeysWith: { a, b in min(a, b) })
      guard let clip = twoVersions.min(by: { (firstDay[$0.id] ?? "9", $0.id) < (firstDay[$1.id] ?? "9", $1.id) }) else {
        check("a Queue clip with two versions", false); return
      }
      let id = clip.id
      note("clip \(id.prefix(8)) “\(a.displayName(clip))”, first day \(firstDay[id] ?? "none")")
      note("settings: \(settings().postsPerDay) posts a day, \(settings().postsPerVersion) per version")
      check("the app's labels match the store's (djq video --json)",
            units(id).allSatisfy { u in a.unitLabel(id, PostUnit(version: u.version, post: u.post_number)) == u.label })

      let w = WindowManager.makeMainWindow(model: a, make: SnapshotWindow.make)
      window = w
      w.setContentSize(NSSize(width: 1440, height: 900))
      w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      Backstage.show(w)
      defer { w.orderOut(nil); w.close() }

      // 1. Settings › Schedule: Posts per version, a real click on + then −.
      a.screen = .queue
      a.settingsSection = .schedule
      SettingsUIState.shared.scrollTarget = SettingsAnchor.row("Posts per version")
      a.showSettings = true
      await wait(2500)
      let before = settings().postsPerVersion
      check("Settings › Schedule shows Posts per version", has("Posts per version"))
      await click("Posts per version", at: .trailing)
      check("click + → posts per version \(before) → \(before + 1) in the store", settings().postsPerVersion == before + 1)
      check("…and a v1 that has no count of its own follows it", ownCount(id, 1) != nil || count(id, 1) == before + 1)
      await shot("settings-posts-per-version")
      // The stepper counts from what the app shows: let the save land in the app first, as a person's next click would.
      for _ in 0..<20 where a.settings.postsPerVersion != before + 1 { await wait(250) }
      await click("Posts per version", at: .leading)
      check("click − → back to \(before)", settings().postsPerVersion == before)
      a.showSettings = false
      await wait(600)

      // 2. The editor on the clip, v2: its own count through the Posts row.
      a.openEditor(id, in: [id])
      await wait(3500)
      guard let e = EditorModel.live, e.videoId == id else { check("the real editor is open", false); return }
      e.zonePlatforms = []
      e.canvasMode = .zones
      note("stand-in: v2 picked through the model (the version list is a native popover)")
      e.selectVersion(2)
      await wait(900)
      check("the editor shows the Posts row for v2", e.versionNo == 2 && has("Post count"))
      let look = stamp(id)
      let v2 = count(id, 2)
      check("v2 starts at the default (\(v2))", ownCount(id, 2) == nil && v2 == e.defaultPostCount(2))
      await shot("editor-v2-default")
      await click("Post count", at: .trailing)
      check("click + → v2 posts \(v2 + 1) times, its own count, in the store", ownCount(id, 2) == v2 + 1 && count(id, 2) == v2 + 1)
      check("…v1 keeps the default", ownCount(id, 1) == nil)
      check("…and how the clip looks didn't change (preview stamp)", stamp(id) == look)
      check("Use default shows once v2 has its own", has("Post count default"))
      await shot("editor-v2-own-count")
      await click("Post count default")
      check("Use default → v2 follows the default again", ownCount(id, 2) == nil && count(id, 2) == v2)
      await click("Post count", at: .trailing)
      check("+ again → v2 posts \(v2 + 1) times", count(id, 2) == v2 + 1)
      let labels = units(id).filter { $0.version == 2 }.map(\.label)
      check("the store lists v2's posts as 1…\(v2 + 1) of \(v2 + 1)",
            labels == (1...(v2 + 1)).map { "v2 · \($0) of \(v2 + 1)" })
      check("the stage didn't move (still a Queue clip)", ((try? store.video(id: id)) ?? nil).map { ClipStage.of($0) != .edit } == true)
      e.flushAndWait()
      a.closeEditor()
      await wait(900)

      // 3. The plan picks it up, then the Queue and the Calendar say which version post each card is.
      _ = try? Planner(store: store).autoSchedule()
      a.refreshNow()
      await wait(600)
      check("the app knows v2 posts \(v2 + 1) times", a.unitBook?.count(id, version: 2) == v2 + 1)
      a.screen = .queue
      await wait(2000)
      let card = a.dsClip(clip, for: .queue)
      let next = a.nextSlotByVideo[id]
      check("Queue card: the date chip carries the next version post",
            next == nil ? card.dateUnit == nil : card.dateUnit == next.map { a.unitLabel($0) })
      let lines = a.unitLines[id] ?? []
      check("Queue card: the other version posts are tags (\(card.units.map(\.text).joined(separator: ", ")))",
            !card.units.isEmpty && lines.count == units(id).count)
      check("Queue card: v2's posts read “of \(v2 + 1)”", lines.filter { $0.unit.version == 2 }.allSatisfy { $0.label.hasSuffix("of \(v2 + 1)") })
      var tags = marks("Unit tag ")
      for _ in 0..<12 where tags.isEmpty {
        await wait(500)
        tags = marks("Unit tag ")
      }
      if tags.isEmpty && screenLocked { note("screen locked: the Queue's cards may not be drawn, so their tags can't be found") }
      check("the Queue draws version-post tags (\(tags.count))", !tags.isEmpty)
      check("the Queue draws date chips with a version post",
            a.queueList.prefix(4).contains { a.nextUnitLabel($0.id) != nil } && !marks("Date chip ").isEmpty)
      let waiting = a.queueList.filter { a.nextSlotByVideo[$0.id] == nil }.count
      note("Queue: \(a.queueList.count) clips, \(a.queueList.count - waiting) with a day, \(waiting) with none yet")
      await shot("queue-version-posts")
      // The two-version clip itself (search narrows the list; positions keep their numbers).
      ListPrefs.shared.setSearch(.queue, a.displayName(clip))
      await wait(1500)
      check("search finds the clip and its card shows its version posts", marks("Unit tag \(id)").count >= 1)
      await shot("queue-two-versions")
      ListPrefs.shared.reset()
      await wait(500)

      a.calendarMode = .week
      a.calendarAnchor = next?.date ?? ""
      a.screen = .calendar
      a.refreshNow()
      await wait(2500)
      let week = a.calendarVisible
      let slots = ((try? store.planSlots(where: "date>=? AND date<=?", [week.first, week.last])) ?? [])
      let shownMarks = Set(marks("Unit mark "))
      let cards = a.calendarDays.flatMap { a.calendarClips($0) }
      check("Calendar week: every card has its version post (\(cards.count) cards, \(shownMarks.count) marks)",
            !cards.isEmpty && cards.allSatisfy { shownMarks.contains("Unit mark \($0.video.id) \($0.slot.unit)") })
      let storeLabels = Dictionary(slots.map { s in
        ("\(s.videoId)#\(s.unit)", units(s.videoId).first { $0.version == s.versionNo && $0.post_number == s.postNo }?.label ?? "?")
      }, uniquingKeysWith: { a, _ in a })
      check("Calendar week: each card's label is the store's",
            cards.allSatisfy { storeLabels["\($0.video.id)#\($0.slot.unit)"] == a.unitLabel($0.slot) })
      check("the clip's card on \(next?.date ?? "?") says \(next.map { a.unitLabel($0) } ?? "?")",
            next == nil || cards.contains { $0.slot.id == next?.id })
      await shot("calendar-week-version-posts")
      // The first week with a repeat or a later version on it (the days already planned keep their clips, so the first
      // ones can be weeks out); the week after when there's none yet.
      let repeatDay = ((try? store.planSlots(where: "date>=?", [today])) ?? []).filter { $0.unit != .first }.map(\.date).min()
      note(repeatDay.map { "first repeat or later version on \($0)" } ?? "no repeat or later version has a day yet in this copy")
      if let repeatDay { a.calendarAnchor = repeatDay } else { a.stepCalendar(1) }
      a.refreshNow()
      await wait(2500)
      let later = a.calendarDays.flatMap { a.calendarClips($0) }
      let laterMarks = Set(marks("Unit mark "))
      check("that week: every card has its version post (\(later.count) cards)",
            later.allSatisfy { laterMarks.contains("Unit mark \($0.video.id) \($0.slot.unit)") })
      note("that week: " + later.map { a.unitLabel($0.slot) }.joined(separator: ", "))
      await shot("calendar-repeats-week")
    }
  }
}
