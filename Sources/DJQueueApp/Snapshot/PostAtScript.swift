import AppKit
import DJQCore
import SwiftUI

/// `DJQ_POST_AT_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 21): "Post at a set time" and the Calendar, in the real main
/// window on the throwaway sample (`SampleData.addPhotoPosts` put four photo posts in it). The clock is fixed at 4:10 PM
/// today in the Settings time zone.
///
/// Clicks, typing and Esc are real events sent to this window, which sits off every display; every check reads the store
/// or what the dialog itself says (`PostAtDialogModel.live`). Two things macOS would pull onto a display are stand-ins,
/// and say so in the log: a drag between days (the drop's own function, `CalendarDrop.accept`) and the card's ⋯ menu
/// (the function its item calls, `askPostAt`). A Queue card shows its buttons while the pointer rests on it; nothing moves
/// Eric's pointer, so `SnapshotHover` stands in for that and the click on the clock is still a real one. `DJQ_POST_AT_SABOTAGE=1` types a time that is fine where the script
/// expects a refusal, to prove the run can fail. Exits 1 on a failed check and saves a capture of each step.
@MainActor
enum PostAtScript {
  static func run(model: AppModel, store: Store, clock: FixedClock, out: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    let sabotage = env["DJQ_POST_AT_SABOTAGE"] != nil
    var failures = 0
    var log: [String] = []
    func note(_ s: String) { print("post-at-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }
    defer { try? log.joined(separator: "\n").write(to: out.appendingPathComponent("post-at-checks-\(look).txt"), atomically: true, encoding: .utf8) }

    // What Eric types, and what it must read as.
    let typed: [(String, Int?)] = [("7pm", 19 * 60), ("7:30 pm", 19 * 60 + 30), ("19:00", 19 * 60), ("730p", 19 * 60 + 30), ("12am", 0),
                                   ("12:05 PM", 12 * 60 + 5), ("noon", 12 * 60), ("9", 9 * 60), ("0915", 9 * 60 + 15), ("7.45 a.m.", 7 * 60 + 45),
                                   ("25:00", nil), ("7:75pm", nil), ("13pm", nil), ("soon", nil), ("", nil)]
    check("the time field reads 7pm, 19:00, 7:30 pm… and refuses what isn't a time", typed.allSatisfy { PostAtClock.minutes($0.0) == $0.1 })

    model.refreshNow()
    let dm = model.dm
    let now = clock.now
    let today = dm.key(now)
    guard let photo = model.editList.first(where: { $0.isPhoto && !$0.isCarousel && (model.issuesByVideo[$0.id] ?? []).isEmpty && !$0.sentToQueue }) else {
      note("FAIL no ready single photo post in Edit")
      return 1
    }
    note("photo post “\(model.displayName(photo))”")

    SnapshotContext.resetUI(model)
    model.setViewMode(.wide, for: .edit)
    model.screen = .edit
    ListPrefs.shared.setSearch(.edit, model.displayName(photo))
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
      let file = out.appendingPathComponent(String(format: "post-at-%02d-%@-%@.png", step, name, look))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    /// Real controls, where they really are: `ScriptAnchor` marks them in the view tree and the click goes through the
    /// window's own hit testing.
    func anchor(_ v: NSView, _ name: String) -> NSView? {
      if v.identifier?.rawValue == name { return v }
      for c in v.subviews { if let hit = anchor(c, name) { return hit } }
      return nil
    }
    func has(_ label: String) -> Bool { anchor(host, ScriptAnchor.prefix + label) != nil }
    func click(_ label: String) async -> Bool {
      guard let a = anchor(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      let f = a.convert(a.bounds, to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: f.midX, y: f.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait(500)
      return true
    }
    func key(_ chars: String, code: UInt16) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code) else { return }
      if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
      await wait(600)
    }
    func timeField(_ v: NSView) -> NSTextField? {
      if let f = v as? NSTextField, f.placeholderString == PostAtDialog.timePlaceholder { return f }
      for c in v.subviews { if let hit = timeField(c) { return hit } }
      return nil
    }
    /// Types into the dialog's real time field, replacing what's there.
    func type(_ text: String) async -> Bool {
      guard let f = timeField(host) else { note("no time field"); return false }
      window.makeFirstResponder(f)
      await wait(200)
      guard let e = f.currentEditor() as? NSTextView else { note("the time field didn't take the keyboard"); return false }
      e.selectAll(nil)
      e.insertText(text, replacementRange: e.selectedRange())
      await wait(300)
      return true
    }
    var dialog: PostAtDialogModel? { model.postAtRequest == nil ? nil : PostAtDialogModel.live }
    /// Waits for Core's dry run of the picked time to land in the dialog.
    func preview() async -> Planner.ExactPreview? {
      for _ in 0..<60 where dialog?.landed == nil && dialog?.picked.at != nil { await wait(100) }
      return dialog?.landed?.first?.preview
    }
    func closed() async -> Bool {
      for _ in 0..<80 where model.postAtRequest != nil { await wait(100) }
      await wait(400)
      return model.postAtRequest == nil
    }
    /// A real click on a dialog button that should finish the dialog.
    func finish(_ label: String) async -> Bool {
      guard await click(label) else { return false }
      return await closed()
    }
    func video(_ id: String) -> Video? { try? store.video(id: id) }
    func stage(_ id: String) -> ClipStage? { video(id).flatMap(ClipStage.of) }
    func exact(_ id: String) -> PlanSlot? { try? Planner(store: store).exactSlot(videoId: id) }
    func slot(_ id: String) -> PlanSlot? { (try? store.planSlots(where: "id=?", [id]))?.first }
    func livePosts(_ id: String) -> [PlatformPost] { ((try? store.posts()) ?? []).filter { $0.videoId == id && !$0.state.isTerminal } }
    func others(_ ids: Set<String>) -> [String: Date] {
      Dictionary(uniqueKeysWithValues: ((try? store.posts()) ?? []).filter { !ids.contains($0.videoId) }.map { ($0.id, $0.scheduledAt) })
    }
    func minutes(_ d: Date) -> Int { Fmt.minutesOfDay(d, calendar: dm.calendar) }
    /// Every slot and post, for "the plan is back".
    func plan() -> [String] {
      let slots = (try? store.planSlots(where: "date>=?", ["0000"])) ?? []
      let posts = (try? store.posts()) ?? []
      return slots.map { "slot|\($0.date)|\($0.position)|\($0.videoId)|\($0.pinned)|\($0.exactAt?.timeIntervalSince1970 ?? 0)" }.sorted()
        + posts.map { "post|\($0.videoId)|\($0.platform.rawValue)|\($0.kind.rawValue)|\($0.scheduledAt.timeIntervalSince1970)|\($0.state.rawValue)" }.sorted()
    }
    func calendar(_ mode: CalendarViewMode, _ day: String) async {
      model.toast = nil
      model.calendarMode = mode
      model.calendarAnchor = day == today ? "" : day
      model.screen = .calendar
      model.refreshNow()
      await wait(900)
    }

    // 1. Edit: the clock on a ready photo post opens the dialog.
    await shot("edit-photo-ready")
    check("the photo post is in Edit with nothing to fix and no time", stage(photo.id) == .edit && exact(photo.id) == nil && livePosts(photo.id).isEmpty)
    check("its card has the clock, and a real click opens the dialog", await click("Post at \(photo.id)") && model.postAtRequest?.videoIds == [photo.id])
    await wait(600)
    let first = await preview()
    check("it starts on the next round hour at least an hour away (6:00 PM today)",
          dialog?.day == today && dialog?.timeText == "6:00 PM" && dialog?.primaryTitle == "Set time")
    check("opening it writes nothing", exact(photo.id) == nil && stage(photo.id) == .edit && first != nil)
    await shot("dialog-open")

    // 2. Under 10 minutes away: the reason under the field, no rows, the button off.
    check("typed a time 5 minutes away", await type(sabotage ? "6:45 PM" : "4:15 PM"))
    await wait(700)
    check("the field says why", dialog?.picked.problem == StageWording.setTimeTooSoon)
    check("the button is off with that reason", dialog?.offReason == StageWording.setTimeTooSoon)
    await shot("too-soon")
    _ = await click("Post at confirm")
    await wait(600)
    check("a click on the off button sets nothing", model.postAtRequest != nil && exact(photo.id) == nil && stage(photo.id) == .edit)
    check("typed a time that has passed", await type("9am"))
    await wait(500)
    check("the field says it has passed", dialog?.picked.problem == StageWording.setTimePassed)
    check("typed something that isn't a time", await type("later"))
    await wait(500)
    check("the field says so, and the button is off", dialog?.picked.at == nil && dialog?.offReason != nil)

    // 3. Two days out at 3:15 PM: five platform rows, none for YouTube.
    let day2 = dm.addDays(today, 2)
    check("clicked \(day2) in the month", await click("Post at day \(day2)") && dialog?.day == day2)
    check("typed 3:15pm", await type("3:15pm"))
    let at2 = dm.at(day2, minutes: 15 * 60 + 15)
    let p2 = await preview()
    check("the dialog reads it as \(model.setTimeText(at2))", dialog?.picked.at == at2 && dialog?.picked.problem == nil)
    check("five platform rows, every one at that minute", p2?.platforms.count == 5 && p2?.platforms.allSatisfy { $0.at == at2 && !$0.moved } == true)
    check("no YouTube row: a photo post never goes there", p2?.platforms.contains { $0.platform == .youtube } == false
          && p2?.skipped.contains { $0.platform == .youtube && $0.reason == .off } == true)
    check("the button is on", dialog?.offReason == nil && p2?.blocker == nil)
    await shot("two-days-out")

    // 4. Confirm: Scheduled, five posts at that minute, nothing else moved.
    let before = others([photo.id])
    check("clicked Set time, and the dialog closed", await finish("Post at confirm"))
    model.refreshNow()
    let slot2 = exact(photo.id)
    check("it is Scheduled with that set time", stage(photo.id) == .scheduled && slot2?.exactAt == at2 && slot2?.date == day2 && slot2?.pinned == true)
    let posts2 = livePosts(photo.id)
    check("five posts, each at exactly \(model.setTimeText(at2))", posts2.count == 5 && posts2.allSatisfy { $0.scheduledAt == at2 })
    check("none on YouTube", !posts2.contains { $0.platform == .youtube })
    check("every other post kept its time (\(before.count) posts)", others([photo.id]) == before)
    check("the toast says “\(StageWording.setFor(at2, settings: model.settings))” with Undo",
          model.toast?.message == StageWording.setFor(at2, settings: model.settings) && model.toast?.actionTitle == "Undo")
    check("it left Edit", !model.editList.contains { $0.id == photo.id })
    await shot("set-toast")

    // 5. The Calendar on that day, in every view.
    for (mode, name) in [(CalendarViewMode.week, "week"), (.threeDay, "3day"), (.day, "day"), (.month, "month")] {
      await calendar(mode, day2)
      let clip = model.calendarClips(day2).first { $0.video.id == photo.id }
      if mode == .day {
        let group = model.calendarDayGroups(day2).first { $0.videoId == photo.id }
        check("Day: its five rows are at 3:15 PM", group?.slot?.isExact == true && group?.posts.count == 5 && group?.posts.allSatisfy { $0.scheduledAt == at2 } == true)
      } else {
        check("\(mode.title): the card is on \(day2)", clip?.slot.isExact == true && clip?.platforms.count == 5)
      }
      check("\(mode.title): it shows the clock mark with its time", slot2.map { has("Set time mark \($0.id)") } == true
            && slot2.flatMap { model.setTimeHelp($0) } == "Set time — every platform at 3:15 PM")
      check("\(mode.title): it is marked as a photo, with no YouTube", has("Photo mark \(photo.id)") && clip?.platforms.contains(.youtube) != true)
      await shot("calendar-\(name)")
    }
    // The day's cards go by their real time: the set time is never first or last because of its position.
    await calendar(.week, day2)
    let order = model.calendarClips(day2).map { c in c.platforms.map { model.calendarTime(c, $0) }.min() ?? .distantFuture }
    check("the day's cards are in time order", order == order.sorted() && order.count >= 2)
    check("the day still counts as open for a regular clip beside it", model.calendarRegularSlots(day2).count == model.calendarClips(day2).count - 1)

    // 6. Drag it to the next day: the same clock time there.
    let day3 = dm.addDays(day2, 1)
    note("stand-in: a drag between days is a system drag session, so the drop's own function runs (CalendarDrop.accept)")
    let beforeMove = others([photo.id])
    check("dropped on \(day3)", slot2.map { CalendarDrop.accept(["slot:\($0.id)"], on: day3, model: model) } == true)
    await wait(600)
    model.refreshNow()
    let slot3 = exact(photo.id)
    check("it moved to \(day3), still 3:15 PM", slot3?.date == day3 && slot3?.exactAt.map(minutes) == 15 * 60 + 15 && slot3?.id == slot2?.id)
    check("its five posts follow, at the same minute", livePosts(photo.id).count == 5 && livePosts(photo.id).allSatisfy { $0.scheduledAt == slot3?.exactAt })
    check("the toast says “Moved to …, still 3:15 PM”", model.toast?.message.hasSuffix(", still 3:15 PM") == true && model.toast?.message.hasPrefix("Moved to ") == true)
    check("nothing else moved", others([photo.id]) == beforeMove)
    await shot("moved-next-day")
    // A day where that time has passed refuses, with Core's reason. Today's 3:15 PM is behind 4:10 PM.
    check("dropping it on today is refused", slot3.map { !CalendarDrop.accept(["slot:\($0.id)"], on: today, model: model) } == true
          && exact(photo.id)?.date == day3 && model.toast?.message == StageWording.setTimePassed)
    await shot("moved-today-refused")

    // 7. Change the time: the dialog opens on the time it has.
    note("stand-in: the card's ⋯ menu is a system menu, so the function its “Change set time…” item calls runs (askPostAt)")
    model.toast = nil
    model.askPostAt([photo.id])
    await wait(900)
    _ = await preview()
    check("the dialog opens on its time and offers Change time", dialog?.primaryTitle == "Change time" && dialog?.picked.at == slot3?.exactAt && has("Post at regular"))
    check("the time it already has changes nothing, so the button is off", dialog?.offReason == "It already has this time")
    await shot("change-open")
    check("clicked the Tomorrow 12:00 PM chip", await click("Post at chip tomorrow"))
    let noon = dm.at(dm.addDays(today, 1), minutes: 12 * 60)
    let p7 = await preview()
    check("the rows move to tomorrow noon and name the time it leaves", dialog?.picked.at == noon && p7?.platforms.allSatisfy { $0.at == noon } == true
          && p7?.replaces.first?.exactAt == slot3?.exactAt)
    await shot("change-picked")
    check("clicked Change time", await finish("Post at confirm"))
    model.refreshNow()
    check("the set time is tomorrow 12:00 PM, same card", exact(photo.id)?.exactAt == noon && exact(photo.id)?.id == slot2?.id
          && livePosts(photo.id).allSatisfy { $0.scheduledAt == noon } && livePosts(photo.id).count == 5)
    check("nothing else moved", others([photo.id]) == beforeMove)
    await calendar(.threeDay, today)
    await shot("changed-calendar")

    // 8. Use the regular schedule: back in the Queue.
    model.askPostAt([photo.id])
    await wait(900)
    check("clicked Use the regular schedule", await finish("Post at regular"))
    model.refreshNow()
    check("it is back in the Queue with no set time", stage(photo.id) == .queue && exact(photo.id) == nil && livePosts(photo.id).isEmpty
          && model.queueClips.contains { $0.id == photo.id })
    check("the toast says so, with Undo", model.toast?.message == StageWording.regularSchedule && model.toast?.actionTitle == "Undo")
    check("nothing else moved", others([photo.id]) == beforeMove)
    model.toast = nil
    model.setViewMode(.wide, for: .queue)
    ListPrefs.shared.setSearch(.queue, model.displayName(photo))
    model.screen = .queue
    await shot("regular-schedule-queue")
    ListPrefs.shared.setSearch(.queue, "")

    // 9. Something left to fix: the dialog says what, in Send to Queue's words, and the button is off.
    ListPrefs.shared.setSearch(.edit, "")
    if let stuck = model.editList.first(where: { !$0.isPhoto && !$0.missing && !(model.issuesByVideo[$0.id] ?? []).isEmpty && model.postAtBlocker($0) == nil }) {
      model.screen = .edit
      ListPrefs.shared.setSearch(.edit, model.displayName(stuck))
      await wait(900)
      check("a clip with something to fix: its clock opens the dialog", await click("Post at \(stuck.id)") && model.postAtRequest?.videoIds == [stuck.id])
      let p9 = await preview()
      check("it says what is missing, in Send to Queue's words", p9?.blocker?.hasPrefix("Still in Edit: ") == true && dialog?.offReason == p9?.blocker)
      await shot("fix-first")
      _ = await click("Post at confirm")
      await wait(500)
      check("nothing is set and it stays in Edit, untouched", exact(stuck.id) == nil && stage(stuck.id) == .edit && video(stuck.id)?.sentToQueue == false)
      await key("\u{1b}", code: 53)
      check("Esc closes the dialog", await closed())
      ListPrefs.shared.setSearch(.edit, "")
    } else {
      check("a clip in Edit with something to fix", false)
    }

    // 10. A regular clip at 9:30 PM New York: inside YouTube's quiet hours (02:00–07:00 UTC), so YouTube moves to 07:30 UTC.
    let far = dm.addDays(today, 35)
    let late = dm.at(far, minutes: 21 * 60 + 30)
    func takesYouTube(_ v: Video) -> Bool {
      guard !v.isPhoto, exact(v.id) == nil, model.postAtBlocker(v) == nil, let p = try? model.bulk.postAtPreview(v.id, at: late) else { return false }
      return p.blocker == nil && p.platforms.contains { $0.platform == .youtube && $0.moved }
    }
    guard let clip = model.queueClips.first(where: { ClipStage.of($0) == .queue && takesYouTube($0) }) ?? model.queueClips.first(where: takesYouTube) else {
      check("a regular clip in the Queue that posts to YouTube", false)
      return 1
    }
    note("clip “\(model.displayName(clip))”, \(ClipStage.of(clip)?.displayName ?? "?")")
    let planBefore = plan()
    let through = model.scheduledText
    model.setViewMode(.wide, for: .queue)
    model.screen = .queue
    ListPrefs.shared.setSearch(.queue, model.displayName(clip))
    note("stand-in: a Queue card shows its buttons while the pointer rests on it; SnapshotHover puts them up, the click is real")
    SnapshotHover.id = clip.id
    model.refreshNow()
    await wait(900)
    await shot("queue-clip")
    check("the Queue card has the clock, and a real click opens the dialog", await click("Post at \(clip.id)") && model.postAtRequest?.videoIds == [clip.id])
    SnapshotHover.id = nil
    await wait(500)
    for _ in 0..<3 where dialog.map({ !far.hasPrefix(String(($0.month.isEmpty ? today : $0.month).prefix(7))) }) == true { _ = await click("Post at month next") }
    check("stepped to its month and clicked \(far)", await click("Post at day \(far)") && dialog?.day == far)
    check("typed 9:30 pm", await type("9:30 pm"))
    let p10 = await preview()
    let yt = p10?.platforms.first { $0.platform == .youtube }
    func utcSecond(_ d: Date) -> Int { Int(d.timeIntervalSince1970) % 86400 }
    check("the YouTube row is moved to 07:30 UTC", yt?.moved == true && yt.map { utcSecond($0.at) } == 7 * 3600 + 1800 && yt.map { $0.at > late } == true)
    check("the dialog says so before anything is set", p10?.notes.contains { $0.hasPrefix("YouTube moves to ") && $0.hasSuffix("(07:30 UTC)") } == true)
    check("every other platform is at 9:30 PM", p10?.platforms.filter { $0.platform != .youtube }.allSatisfy { $0.at == late && !$0.moved } == true
          && (p10?.platforms.count ?? 0) >= 2)
    await shot("youtube-quiet-hours")
    check("clicked Set time", await finish("Post at confirm"))
    model.refreshNow()
    let ytPost = livePosts(clip.id).first { $0.platform == .youtube }
    check("the stored YouTube post is outside 02:00–07:00 UTC, at 07:30", ytPost.map { !(2 * 3600..<7 * 3600).contains(utcSecond($0.scheduledAt)) && utcSecond($0.scheduledAt) == 27000 } == true)
    check("the others are stored at 9:30 PM", livePosts(clip.id).filter { $0.platform != .youtube }.allSatisfy { $0.scheduledAt == late } && exact(clip.id)?.exactAt == late)
    check("“\(through)” didn't change: a set time is outside the cadence", model.scheduledText == through)
    ListPrefs.shared.setSearch(.queue, "")
    await calendar(.week, far)
    let farSlot = exact(clip.id)
    check("Week: the card names YouTube's own time on hover", farSlot.flatMap { model.setTimeHelp($0) }?.contains("YouTube moves to ") == true)
    check("Week: YouTube shows on the next day, the rest on the card", model.calendarClips(far).first { $0.video.id == clip.id }?.platforms.contains(.youtube) == false
          && model.calendarExtras(dm.addDays(far, 1)).contains { $0.videoId == clip.id && $0.platform == .youtube })
    check("the day is still open for a regular clip", model.calendarDayCanFill(far) && model.calendarRegularSlots(far).isEmpty)
    await shot("youtube-calendar-week")

    // 11. A regular clip dropped on a day that only has a set-time item lands beside it (review m7).
    if let regular = model.upcomingSlots.filter({ !$0.isExact && $0.date > today && model.calendarMoveBlocker($0, posts: model.slotPosts($0.id)) == nil }).last {
      note("stand-in: the drop's own function again (CalendarDrop.accept)")
      model.toast = nil
      check("a regular clip dropped on that day is taken", CalendarDrop.accept(["slot:\(regular.id)"], on: far, model: model))
      await wait(600)
      model.refreshNow()
      let landed = slot(regular.id)
      check("it has the day's first regular place, with no swap", landed?.date == far && landed?.position == 0 && model.toast?.message.contains("swapped") == false)
      check("the set-time item beside it didn't move", exact(clip.id)?.exactAt == late && exact(clip.id)?.id == farSlot?.id)
      await calendar(.week, far)
      await shot("regular-clip-beside-set-time")
      model.undoLast()
      for _ in 0..<50 where slot(regular.id)?.date == far { await wait(100) }
      await wait(500)
    } else {
      check("a regular scheduled clip to drop", false)
    }

    // 12. Undo: the plan is back.
    model.refreshNow()
    check("the undo history's newest entry is the set time", model.undoHistory.top?.label == StageWording.setFor(late, settings: model.settings))
    model.undoLast()
    for _ in 0..<60 where plan() != planBefore { await wait(100) }
    await wait(600)
    model.refreshNow()
    check("Undo puts the whole plan back", plan() == planBefore && exact(clip.id) == nil)
    await calendar(.week, today)
    await shot("undone")

    note(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
  }
}
