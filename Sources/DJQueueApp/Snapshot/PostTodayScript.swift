import AppKit
import DJQCore
import SwiftUI

/// `DJQ_POST_TODAY_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 33): Post today on an evening when today has no slot left
/// to give, in the real main window on the throwaway sample. The live case (Sat 14 Nov): every slot of the day had gone
/// out, Post today refused, and the sheet hid why. Now the item goes out now on its own and the sheet says, per
/// platform, when; YouTube waits only for Postiz's shared upload quota, and the sheet says why. A clip whose post
/// already went out today is the one refusal left, and its reason sits in the sheet in plain view.
///
/// Today's slots are pinned here (the sample's posts are in the future, so they can't be marked posted): a pinned slot
/// holds its position exactly like a posted one. The clock is 10:30 PM, inside YouTube's quiet window. The Queue card's
/// Post today shows while the pointer rests on it; nothing moves Eric's pointer, so the script calls the function the
/// button calls (`postTodayAsking`), labelled a stand-in. Return confirms through the sheet's real default button.
/// `DJQ_POST_TODAY_SABOTAGE=1` adds a post a day, leaving today a free position, so the "on its own" checks must fail.
@MainActor
enum PostTodayScript {
  static func run(model: AppModel, store: Store, clock: FixedClock, out: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    let sabotage = env["DJQ_POST_TODAY_SABOTAGE"] != nil
    var failures = 0
    var log: [String] = []
    func note(_ s: String) { print("post-today-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }
    defer { try? log.joined(separator: "\n").write(to: out.appendingPathComponent("post-today-checks-\(look).txt"), atomically: true, encoding: .utf8) }

    let planner = Planner(store: store)
    let dm = model.dm
    let today = dm.key(clock.now)
    // 10:30 PM: Postiz's YouTube quota window (19:00–24:00 Pacific) has started.
    let evening = dm.at(today, minutes: 22 * 60 + 30)
    clock.set(evening)
    model.now = evening
    // Today's slots fill every position and can't move.
    let todays = ((try? store.planSlots(where: "date=? AND exact_at IS NULL", [today])) ?? [])
    if sabotage {
      // One more post a day leaves today a free position, so Post today takes it and the "on its own" checks must fail.
      if var s = try? store.settings() { s.postsPerDay += 1; try? store.save(s) }
    } else {
      for s in todays where !s.pinned { try? planner.pin(videoId: s.videoId, date: today) }
    }
    model.refreshNow()
    let perDay = max(1, model.settings.postsPerDay)
    note("today \(today): \(todays.count)/\(perDay) slots\(sabotage ? " (sabotage: one more a day)" : ", all pinned")")
    let held = Set(todays.map(\.videoId))
    guard let clip = model.queueList.first(where: { !held.contains($0.id) && !$0.isPhoto && model.setTime($0.id) == nil }) else {
      note("FAIL no Queue clip without a day today")
      return 1
    }
    note("clip “\(model.displayName(clip))”")
    func plan(except id: String) -> [String] {
      ((try? store.planSlots()) ?? []).filter { $0.videoId != id }.map { "\($0.date)#\($0.position) \($0.videoId) \($0.pinned)" }.sorted()
    }
    let before = plan(except: clip.id)

    SnapshotContext.resetUI(model)
    model.screen = .queue
    let window = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
    window.setContentSize(NSSize(width: Shot.standard.width, height: Shot.standard.height))
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    guard let host = window.contentView else { return 1 }
    await wait(1800)

    var step = 0
    func shot(_ name: String) async {
      await wait(700)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "post-today-%02d-%@-%@.png", step, name, look))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }
    func has(_ label: String) -> Bool { anchor(host, ScriptAnchor.prefix + label) != nil }
    func key(_ chars: String, code: UInt16) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code) else { return }
      if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
      await wait(600)
    }
    func preview() async -> BulkResult? {
      for _ in 0..<60 where model.pendingBulk != nil && model.pendingBulk?.preview == nil && model.pendingBulk?.error == nil { await wait(100) }
      await wait(500)
      return model.pendingBulk?.preview
    }

    // 1. The sheet: it goes out now on its own; YouTube waits for Postiz's quota and says so.
    note("stand-in: the Queue card's Post today shows on hover; calling postTodayAsking, the function the button calls")
    model.postTodayAsking([clip.id])
    let p = await preview()
    check("the sheet opened and its dry run landed", p != nil && model.pendingBulk?.request.verb == "Post today")
    check("it will change (not refused)", p?.changed == [clip.id] && p?.skipped.isEmpty == true)
    check("it goes out now on its own", p?.onItsOwn == [clip.id])
    let goes = p?.goesOut?[clip.id] ?? []
    let yt = goes.first { $0.platform == .youtube }
    check("YouTube waits until 00:30 Pacific and says why", yt.map { !$0.now && ($0.wait ?? "").contains("midnight Pacific") } ?? false)
    check("every other platform goes right away", !goes.isEmpty && goes.filter { $0.platform != .youtube }.allSatisfy(\.now))
    check("the sheet shows the Goes out list", has("Post today goes out"))
    check("the dry run wrote nothing", plan(except: clip.id) == before && ((try? store.planSlots(where: "video_id=? AND exact_at IS NOT NULL", [clip.id])) ?? []).isEmpty)
    await shot("sheet-on-its-own")

    // 2. Return confirms through the real default button.
    await key("\r", code: 36)
    for _ in 0..<40 where model.pendingBulk != nil { await wait(100) }
    await wait(800)
    let exact = ((try? store.planSlots(where: "video_id=? AND exact_at IS NOT NULL", [clip.id])) ?? []).first
    check("Return posted it: a set time at the next minute", model.pendingBulk == nil && exact?.exactAt == dm.at(today, minutes: 22 * 60 + 31))
    check("nothing else on the Calendar moved", plan(except: clip.id) == before)
    check("the toast says it's posting now and YouTube waits",
          (model.toast?.message ?? "").hasPrefix("Posting now") && (model.toast?.detail ?? "").contains("YouTube"))
    await shot("posted")

    // 2b. A drag onto a full today (review H4): it isn't refused, it asks Post today and goes out now on its own.
    model.toast = nil
    model.refreshNow()
    if let later = ((try? store.planSlots(where: "date>? AND exact_at IS NULL", [today])) ?? []).sorted(by: { $0.date < $1.date }).first {
      note("stand-in: a drag between days is a system drag session, so the drop's own function runs (CalendarDrop.accept)")
      let accepted = CalendarDrop.accept(["slot:\(later.id)"], on: today, model: model)
      let d = await preview()
      check("a drag onto a full today asks Post today instead of refusing", accepted && model.pendingBulk?.request.verb == "Post today")
      check("and it would go out now on its own", d?.changed == [later.videoId] && d?.onItsOwn == [later.videoId])
      await shot("drag-onto-full-today")
      model.cancelPendingBulk()
      await wait(400)
    } else {
      note("FAIL no later regular slot to drag onto today")
      failures += 1
    }

    // 3. The one refusal left (its post already went out today) reads in the sheet, not behind "Why skipped".
    if let first = todays.first, let gone = ((try? store.posts(where: "plan_slot_id=?", [first.id])) ?? []).filter({ $0.scheduledAt < evening && !$0.state.isTerminal }).first {
      try? PostActions(store: store).markPosted(postId: gone.id, url: "https://example.com/p")
      model.refreshNow()
      model.toast = nil
      model.postTodayAsking([first.videoId])
      let r = await preview()
      check("a clip already going out today is refused with the reason", r?.changed.isEmpty == true && (r?.skipped[first.videoId] ?? "").contains("already going out today"))
      check("the reason is in the sheet in plain view", has("Bulk refusal"))
      await shot("refusal-in-view")
      model.cancelPendingBulk()
    } else {
      note("FAIL no post of today's first slot before 10:30 PM to mark posted")
      failures += 1
    }

    note(failures == 0 ? "post-today: all checks passed" : "post-today: \(failures) failed")
    return failures == 0 ? 0 : 1
  }
}
