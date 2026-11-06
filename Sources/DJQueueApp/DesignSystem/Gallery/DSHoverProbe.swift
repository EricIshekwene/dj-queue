import AppKit
import DJQCore
import SwiftUI

/// Evidence run for small previews in the REAL main window (round 14):
/// `DJQ_SNAPSHOT_GALLERY=1 DJQ_HOVER_PROBE=1 DJQueueApp --snapshot <dir>`, with the dev-root env. Writes
/// `hover-probe.log` in plain words and exits 1 when any check fails.
///
/// Same setup as DSTooltipProbe: the real model on a throwaway DB, the real window off every display (`Backstage`),
/// never activating the app. macOS doesn't let the app move the pointer and SwiftUI's hover follows the real cursor only, so
/// a probe pointer stands in for it: each move reaches `DSPlaybackHoverGuard` as the enter/exit pairs a real pointer
/// there would produce (forwarded moves). A case that gets no hover events in real use (scrolling, a drag, a menu)
/// sends none here, so only the guard can end the playback. State comes from `DSPlaybackBudget` and the player views,
/// not from pixels; captures are extra.
@MainActor
enum DSHoverProbe {
  static func run(outputDir: String) async -> Int32 {
    defer { DSTooltipProbe.cleanUp() }
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let model = try DSTooltipProbe.makeModel()
      let w = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
      w.isReleasedWhenClosed = false
      w.appearance = NSAppearance(named: .aqua)
      Backstage.show(w)
      let run = Run(model: model, window: w, out: out)
      await run.all()
      w.orderOut(nil)
      return run.finish()
    } catch {
      print("hover-probe: failed: \(error)")
      return 1
    }
  }

  private struct Page {
    let name: String
    let screen: Screen
    var mode: DSViewMode? = nil
    var calendar: CalendarViewMode? = nil
    var isCalendar: Bool { calendar != nil }
  }

  @MainActor
  private final class Run {
    let model: AppModel
    let w: NSWindow
    let out: URL
    let guardian = DSPlaybackHoverGuard.shared
    let budget = DSPlaybackBudget.shared
    var lines: [String] = []
    var failures = 0
    var blanks = 0

    init(model: AppModel, window: NSWindow, out: URL) {
      self.model = model
      w = window
      self.out = out
    }

    // MARK: Plan

    func all() async {
      guardian.simulatedPointer = DSTooltipProbe.offscreen
      guardian.simulatedAppActive = true
      model.playback = PlaybackPrefs()  // in memory only: the defaults, whatever this Mac saved
      guard await prepareProxies() else { return }
      keyWindowGate()
      let week = Page(name: "Calendar Week", screen: .calendar, calendar: .week)
      let three = Page(name: "Calendar 3 Day", screen: .calendar, calendar: .threeDay)
      let queueCards = Page(name: "Queue Cards", screen: .queue, mode: .wide)
      for page in [week, three, queueCards, Page(name: "Edit Cards", screen: .edit, mode: .wide),
                   Page(name: "Queue Grid", screen: .queue, mode: .grid)] {
        await hoverWalk(page)
      }
      await exitCases(queueCards)
      await hoverOnlyOff(week)
      stackTwoClipsOnADay()
      await exitCases(week)
      await dragEnd(week)
      await largeViews()
      await park()
    }

    /// The sample week fits the window: two posts on one day (on the throwaway DB) give it something to scroll.
    func stackTwoClipsOnADay() {
      guard var st = try? model.store.settings() else { return }
      st.postsPerDay = 2
      try? model.store.save(st)
      model.refreshNow()
      let days = model.calendarDays.filter { $0 > model.todayKey && !model.calendarClips($0).isEmpty }
      guard days.count >= 2, let c = model.calendarClips(days[1]).first else { return }
      _ = model.calendarMove(slotId: c.slot.id, to: days[0])
    }

    /// One real proxy, shown for every clip: the rule is under test, not the proxy generator.
    func prepareProxies() async -> Bool {
      let shorts = model.videoById.values.filter { $0.type == .short && !$0.missing }.map(\.id).sorted()
      guard let first = shorts.first, let url = await DSTooltipProbe.makeProxy(model, first) else {
        check(false, "a preview copy could be made for the probe")
        return false
      }
      for id in shorts { model.proxyURLs[id] = url }
      say("Every clip has a real preview copy (\(shorts.count) clips, \(url.lastPathComponent)).")
      return true
    }

    // MARK: The four steps on one page

    func hoverWalk(_ page: Page) async {
      say("\n\(page.name)")
      await open(page)
      await capture(page, "1-rest")
      let rest = state()
      check(rest.nothing, "at rest nothing plays (\(rest.words))")
      guard let (a, b) = await pickCards(page) else { return }
      let soundWord = page.isCalendar ? "muted" : "with sound"

      await move(to: a.center)
      let one = await until(2000) { [self] in state().only(in: a) && state().sound == !page.isCalendar }
      let held = await holds(400) { [self] in state().only(in: a) }
      await capture(page, "2-hover-a")
      check(one != nil && held, "hover card A: only A plays, \(soundWord) (\(state().words))")

      await move(to: b.center)
      let swap = await until(1500) { [self] in state().only(in: b) && state().sound == !page.isCalendar }
      await capture(page, "3-hover-b")
      check(swap != nil && state().count(in: a) == 0, "move straight to card B: A stopped and released, only B plays, \(soundWord) (\(state().words))")

      await move(to: restPoint)
      let gone = await until(1500) { [self] in state().nothing }
      let stays = await holds(400) { [self] in state().nothing }
      await capture(page, "4-left")
      check(gone != nil && stays, "leave: zero players, zero audible\(gone.map { " after \($0) ms" } ?? "") (\(state().words))")
    }

    // MARK: R3: exits SwiftUI doesn't report

    func exitCases(_ page: Page) async {
      say("\nExits on \(page.name)")
      await open(page)
      guard let (a, _) = await pickCards(page) else { return }

      // Scrolling under a still pointer: no pointer move, so no hover event. The pointer sits near the card's bottom
      // edge, so a short scroll takes the card out from under it.
      await fadeOut(a)
      let nearEdge = CGPoint(x: a.center.x, y: a.rect.minY + 6)
      await move(to: nearEdge)
      _ = await until(2000) { [self] in state().only(in: a) }
      if let scroller = scrollView(at: nearEdge), scrollBy(scroller, Self.scrollStep) {
        let done = await until(1500) { [self] in state().count(in: a) == 0 && !state().sound && state().live == 0 }
        check(done != nil, "scrolling under a still pointer stops it\(done.map { " after \($0) ms" } ?? "") (\(state().words))")
        _ = scrollBy(scroller, -Self.scrollStep)
        await settle(500)
      } else {
        say("  NOT DRIVEN scrolling: this page has nothing to scroll in the probe window")
      }
      await move(to: restPoint)
      _ = await until(1500) { [self] in state().nothing }

      // A menu over the card (stand-in: AppKit's notifications, see `menu`); closes with the pointer still on it, then gone.
      await hover(a)
      await menu(then: nil)
      let back = await until(1500) { [self] in state().only(in: a) }
      check(back != nil, "menu (stand-in) closed with the pointer still on the card: it plays again (\(state().words))")
      await menu(then: restPoint)
      let closed = await until(1500) { [self] in state().nothing }
      check(closed != nil, "menu (stand-in) closed with the pointer elsewhere: zero players, zero audible (\(state().words))")
      await move(to: restPoint)

      // The app goes to the background: a stand-in, because the probe never activates the app.
      await hover(a)
      guardian.simulatedAppActive = false
      let blurred = await until(1500) { [self] in state().nothing }
      check(blurred != nil, "app goes to the background (stand-in): zero players, zero audible (\(state().words))")
      guardian.simulatedAppActive = true
      let refocus = await until(1500) { [self] in state().only(in: a) }
      check(refocus != nil, "app comes back with the pointer on the card: it plays again (\(state().words))")

      // The window really leaves the screen.
      w.orderOut(nil)
      let hidden = await until(1500) { [self] in state().nothing }
      check(hidden != nil, "window hidden for real: zero players, zero audible (\(state().words))")
      let frame = w.frame
      Backstage.front(w)
      w.setFrame(frame, display: true)
      w.makeKey()
      await settle(600)
      await move(to: restPoint)
      _ = await until(1500) { [self] in state().nothing }

      // The page changes under the pointer.
      await hover(a)
      model.screen = .health
      let left = await until(1500) { [self] in state().nothing }
      check(left != nil, "page changes under the pointer: zero players, zero audible (\(state().words))")
      await move(to: restPoint)
    }

    /// A drag gives no hover events: the pointer moves silently, the drop lands, and nothing may keep playing. The
    /// probe can't run a real drag session (it would need the real mouse), so `calendarMove` makes the real drop.
    func dragEnd(_ page: Page) async {
      say("\nDrag on \(page.name)")
      await open(page)
      let future = model.calendarDays.filter { $0 > model.todayKey && !model.calendarClips($0).isEmpty }
      guard let day = future.last, let clip = model.calendarClips(day).first,
            let a = cards().max(by: { $0.rect.minX < $1.rect.minX }) else {
        say("  NOT DRIVEN drag: no future card")
        return
      }
      await hover(a)
      let other = model.calendarDays.last { $0 > model.todayKey && $0 != day } ?? model.todayKey
      guardian.simulatedPointer = CGPoint(x: a.center.x - a.rect.width * 2, y: a.center.y)
      let away = await until(1500) { [self] in state().nothing }
      check(away != nil, "drag carries the pointer off the card (stand-in, the card stays put): zero players, zero audible (\(state().words))")
      let moved = model.calendarMove(slotId: clip.slot.id, to: other)
      await settle(400)
      check(state().nothing, "drag ends on another day (stand-in, drop \(moved ? "landed" : "refused")): zero players, zero audible (\(state().words))")
      await move(to: restPoint)
    }

    /// Leaving inside an animation, as a card's hover does: the player goes at once and no other is built for the
    /// view that's fading out. Coming straight back during the fade plays again.
    func fadeOut(_ a: Card) async {
      await hover(a)
      let built = DSPlayerNSView.debugPlayersBuilt
      withAnimation(.easeOut(duration: 0.12)) { guardian.debugPointerMoved(to: restPoint, in: w) }
      await settle(350)
      check(state().nothing && DSPlayerNSView.debugPlayersBuilt == built,
            "leave during a hover fade: no player built for the fading view (\(DSPlayerNSView.debugPlayersBuilt - built) built, \(state().words))")
      await hover(a)
      withAnimation(.easeOut(duration: 0.12)) { guardian.debugPointerMoved(to: restPoint, in: w) }
      await settle(40)
      await move(to: a.center)
      let back = await until(1500) { [self] in state().only(in: a) }
      check(back != nil, "come straight back during the fade: it plays again (\(state().words))")
      await move(to: restPoint)
      _ = await until(1500) { [self] in state().nothing }
    }

    /// The key-window check reads the window's real state, and it's true throughout this run. Its false side can't
    /// be reached without activating the app: while inactive, two windows both read as key and `resignKey` changes
    /// nothing. "The app is active" stays a stand-in.
    func keyWindowGate() {
      w.makeKey()
      check(w.isKeyWindow, "the window reads as key (real): every hover check runs through it")
      say("  NOT DRIVEN the window losing key status: it needs the app active, and the probe never takes focus")
    }

    // MARK: With the switch off

    /// "Small previews: play on hover only" off (in memory): the old behaviour, and a hovered card still gets a slot.
    func hoverOnlyOff(_ page: Page) async {
      say("\nSwitch off on \(page.name)")
      model.playback.gridHoverOnly = false
      defer { model.playback.gridHoverOnly = true }
      await open(page)
      let four = await until(2500) { [self] in state().playing == 4 }
      check(four != nil, "four covers play by themselves (\(state().words))")
      guard let other = cards().first(where: { state().count(in: $0) == 0 }) else {
        say("  NOT DRIVEN switch off: every card already plays")
        return
      }
      await move(to: other.center)
      let got = await until(1500) { [self] in state().count(in: other) == 1 && state().playing <= 4 }
      check(got != nil, "hover a card with no slot: it takes one, still at most 4 (\(state().words))")
      await move(to: restPoint)
    }

    // MARK: Large previews still play by themselves

    func largeViews() async {
      say("\nLarge previews")
      await open(Page(name: "Queue Single", screen: .queue, mode: .single))
      let plays = await until(2500) { [self] in state().playing == 1 }
      check(plays != nil && !state().sound, "Queue Single plays by itself, muted (\(state().words))")
      await open(Page(name: "Score Single", screen: .score, mode: .single))
      guard await until(2500, { [self] in state().playing == 1 }) != nil, let p = state().rects.first else {
        say("  NOT DRIVEN Score Single: no clip to score in the sample")
        return
      }
      check(!state().sound, "Score Single plays by itself, muted (\(state().words))")
      await move(to: CGPoint(x: p.midX, y: p.midY))
      let on = await until(1500) { [self] in state().sound }
      check(on != nil, "Score Single: hover adds sound (\(state().words))")
      await move(to: restPoint)
      let off = await until(1500) { [self] in !state().sound && state().playing == 1 }
      check(off != nil, "Score Single: leaving mutes it and it keeps playing (\(state().words))")
      await scrubPastTheEdge(p)
    }

    /// Mouse events to this window's content only: a held mouse sends no hover, and the pointer overshoots the preview.
    func scrubPastTheEdge(_ p: CGRect) async {
      await move(to: CGPoint(x: p.midX, y: p.midY))
      _ = await until(1500) { [self] in state().sound && scrubber != nil }
      guard let bar = scrubber else {
        check(false, "Score Single: the scrubber shows on hover")
        return
      }
      let start = CGPoint(x: bar.midX, y: bar.midY)
      let end = CGPoint(x: p.maxX + 30, y: p.minY - 20)
      mouse(.leftMouseDown, start)
      for i in 1...8 {
        let t = CGFloat(i) / 8
        let at = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        guardian.simulatedPointer = at
        mouse(.leftMouseDragged, at)
        await settle(30)
      }
      await settle(400)  // well past the guard's check
      check(scrubber != nil && state().sound, "scrub past the preview's edge: the scrubber and the sound stay (\(state().words))")
      mouse(.leftMouseUp, end)
      let ended = await until(1500) { [self] in scrubber == nil && !state().sound && state().playing == 1 }
      check(ended != nil, "the scrub ends off the preview: the scrubber goes, it mutes and keeps playing (\(state().words))")
      await move(to: restPoint)
    }

    var scrubber: CGRect? {
      DSTooltipProbe.anchors(in: w).first { $0.content.label == "Drag to scrub through the preview" }?.visibleScreenRect
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
      if let e = NSEvent.mouseEvent(with: type, location: w.convertPoint(fromScreen: p), modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: 1, pressure: 1) {
        switch type {
        case .leftMouseDown: w.contentView?.mouseDown(with: e)
        case .leftMouseDragged: w.contentView?.mouseDragged(with: e)
        default: w.contentView?.mouseUp(with: e)
        }
      }
    }

    // MARK: Moves

    /// In the window's sidebar: no card under it.
    var restPoint: CGPoint { CGPoint(x: w.frame.minX + 130, y: w.frame.midY) }

    func park() async {
      guardian.simulatedPointer = nil
      guardian.simulatedAppActive = nil
    }

    func move(to p: CGPoint) async {
      guardian.debugPointerMoved(to: p, in: w)
    }

    func hover(_ c: Card) async {
      await move(to: c.center)
      if await until(2000, { [self] in state().only(in: c) }) == nil { say("  (card did not start: \(state().words))") }
    }

    func open(_ page: Page) async {
      SnapshotContext.resetUI(model)
      if let m = page.mode { model.viewModes[page.screen] = m }
      if let c = page.calendar { model.calendarMode = c }
      model.screen = page.screen
      await move(to: restPoint)
      await settle(2500)
    }

    func settle(_ ms: Int) async {
      try? await Task.sleep(for: .milliseconds(ms))
      w.displayIfNeeded()
    }

    /// Two cards that can play, top-left first. Hovers each candidate until two have started.
    func pickCards(_ page: Page) async -> (Card, Card)? {
      var found: [Card] = []
      var skipped = 0
      for c in cards().prefix(10) where found.count < 2 {
        await move(to: c.center)
        if await until(1500, { [self] in state().count(in: c) > 0 }) != nil { found.append(c) } else { skipped += 1 }
        await move(to: restPoint)
        _ = await until(1000) { [self] in state().count(in: c) == 0 }
      }
      await settle(300)
      if skipped > 0 { say("  (\(skipped) card(s) skipped: nothing to play)") }
      guard found.count == 2 else {
        check(false, "\(page.name): two cards start playing on hover (found \(found.count), \(cards().count) on screen)")
        return nil
      }
      return (found[0], found[1])
    }

    // MARK: Cards and state

    struct Card {
      let rect: CGRect
      var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
      var height: CGFloat { rect.height }
    }

    /// Clip cards on screen, at least 120 pt of each showing: the outermost hover regions.
    func cards() -> [Card] {
      var whole: [CGRect] = []
      func walk(_ v: NSView) {
        if let h = v as? DSPlaybackHoverView, let r = h.visibleScreenRect, r.height >= min(120, h.bounds.height - 1) { whole.append(r) }
        v.subviews.forEach(walk)
      }
      if let root = w.contentView { walk(root) }
      let outer = whole.filter { r in !whole.contains { $0 != r && $0.contains(r) } }
      var seen = Set<String>()
      return outer.filter { seen.insert("\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))").inserted }
        .sorted { $0.minY != $1.minY ? $0.maxY > $1.maxY : $0.minX < $1.minX }
        .map(Card.init)
    }

    struct State {
      var requests: Int, budgetAudible: Bool, live: Int, playing: Int, withSound: Int
      var rects: [CGRect]
      var sound: Bool { budgetAudible && withSound == 1 }
      var nothing: Bool { requests == 0 && !budgetAudible && live == 0 && withSound == 0 }
      func count(in c: Card) -> Int { rects.filter { c.rect.insetBy(dx: 2, dy: 2).intersects($0) }.count }
      func only(in c: Card) -> Bool { requests == 1 && live == 1 && playing == 1 && count(in: c) == 1 }
      var words: String { "\(playing) playing, \(withSound) with sound, \(live) players alive, \(requests) in the budget" }
    }

    func state() -> State {
      let views = DSTooltipProbe.playerViews(in: w)
      return State(requests: budget.activeCount, budgetAudible: budget.effectiveAudible != nil, live: DSPlayerNSView.debugLivePlayers,
                   playing: views.filter(\.isPlaying).count, withSound: views.filter(\.isPlayingWithSound).count,
                   rects: views.filter(\.isPlaying).compactMap { v in v.window.map { $0.convertToScreen(v.convert(v.bounds, to: nil)) } })
    }

    /// Milliseconds until `cond` is true, nil at the timeout.
    func until(_ timeout: Int, _ cond: () -> Bool) async -> Int? {
      let start = Date()
      while true {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if cond() { return ms }
        if ms > timeout { return nil }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    func holds(_ ms: Int, _ cond: () -> Bool) async -> Bool {
      let start = Date()
      while Date().timeIntervalSince(start) * 1000 < Double(ms) {
        if !cond() { return false }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return true
    }

    // MARK: Real AppKit stand-ins

    static let scrollStep: CGFloat = 30

    func scrollView(at p: CGPoint) -> NSScrollView? {
      var found: NSScrollView?
      func walk(_ v: NSView) {
        if let s = v as? NSScrollView, let doc = s.documentView, doc.frame.height > s.contentView.bounds.height + Self.scrollStep,
           let win = s.window, win.convertToScreen(s.convert(s.bounds, to: nil)).contains(p) { found = s }
        v.subviews.forEach(walk)
      }
      if let root = w.contentView { walk(root) }
      return found
    }

    func scrollBy(_ s: NSScrollView, _ dy: CGFloat) -> Bool {
      let c = s.contentView
      let flipped = s.documentView?.isFlipped ?? true
      var o = c.bounds.origin
      o.y += flipped ? dy : -dy
      c.scroll(to: o)
      s.reflectScrolledClipView(c)
      return true
    }

    /// A menu opening, through the notifications AppKit sends for one: reads the state while it's open, then moves the
    /// pointer first when `then` is set (a menu takes every move, so no hover event goes with it). A real menu would
    /// draw on the user's display, since macOS pulls menus back onto a screen.
    func menu(then: CGPoint?) async {
      let center = NotificationCenter.default
      center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
      await settle(300)
      let s = state()
      if let then { guardian.simulatedPointer = then }
      center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
      say("  NOT DRIVEN a real NSMenu: macOS draws it on a display, so this sends the notifications AppKit sends for one")
      check(s.nothing, "while a menu (stand-in) is open: zero players, zero audible (\(s.words))")
    }

    // MARK: Output

    func capture(_ page: Page, _ step: String) async {
      w.displayIfNeeded()
      let name = page.name.lowercased().replacingOccurrences(of: " ", with: "-") + "-\(step).png"
      guard let img = DSTooltipProbe.captureImage(w, panel: nil), !Self.isBlank(img),
            let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        blanks += 1
        return
      }
      try? png.write(to: out.appendingPathComponent(name))
    }

    private static func isBlank(_ img: CGImage) -> Bool {
      let rep = NSBitmapImageRep(cgImage: img)
      var seen = Set<Int>()
      for y in stride(from: 8, to: rep.pixelsHigh, by: 40) {
        for x in stride(from: 8, to: rep.pixelsWide, by: 40) {
          if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) { seen.insert(Int(c.redComponent * 15) * 256 + Int(c.greenComponent * 15) * 16 + Int(c.blueComponent * 15)) }
        }
      }
      return seen.count < 3
    }

    func check(_ ok: Bool, _ what: String) {
      if !ok { failures += 1 }
      say("  \(ok ? "PASS" : "FAIL") \(what)")
    }

    func say(_ s: String) {
      print("hover-probe: \(s)")
      lines.append(s)
    }

    func finish() -> Int32 {
      say("\nPointer moves were forwarded. \(guardian.debugRealCursorHovers) real SwiftUI hover events from the real cursor reached the guard and were dropped.")
      if blanks > 0 { check(false, "\(blanks) captures were blank") }
      say(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL, \(failures) check(s) failed")
      try? (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("hover-probe.log"), atomically: true, encoding: .utf8)
      return failures == 0 ? 0 : 1
    }
  }
}
