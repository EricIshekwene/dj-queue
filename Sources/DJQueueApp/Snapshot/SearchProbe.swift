import AppKit
import DJQCore
import SwiftUI

/// Evidence run for whole-app search in the REAL main window (round 10, S1-R13):
/// `DJQ_SEARCH_PROBE=1 DJQueueApp --snapshot <dir>` with the dev-root env. Exit 1 when any step fails.
///
/// Same rules as `DSTooltipProbe`: the real AppModel on a throwaway copy of the dev DB, the real main window in front,
/// click-through and never activating the app; the user's pointer and keyboard never reach it.
///
/// How the keys travel. Each step builds a real `NSEvent` and hands it to the window through the entry points
/// `NSApplication.sendEvent` itself uses: `NSWindow.performKeyEquivalent(with:)` for Command keys and
/// `NSWindow.sendEvent(_:)` for the rest (typing goes through the field editor, arrows and Tab through `onKeyPress`, ↩
/// through `onSubmit`, Esc through `onExitCommand`). Only the first hop differs from a person at the keyboard:
/// `NSApp.postEvent` is dropped for keys while the app isn't active, because `NSApp.keyWindow` is nil. Activating the app
/// would take the keyboard from whoever is using the Mac, so the probe doesn't. "Search everywhere" is clicked the same
/// way: real mouse events into `NSWindow.sendEvent`.
///
/// What isn't a key. `start` resets the UI and picks the screen before each flow. Inside a flow, direct model calls set
/// the scene (the editor or Settings open before ⌘K, a filter that must get cleared, stale recents, a new caption); each
/// one has a `SETUP` line in `steps.txt`. Two steps can't come from keys, and say so: ⌘, is a menu command, which a snapshot
/// run doesn't have, so "Settings opens while the palette is up" sets `showSettings` directly. And `results` reads
/// `paletteContent`, the list the palette renders, to say what's expected: chip counts, bold and subtitles on screen are
/// checked by eye in the captures, while ↩ running the rendered list is what proves a row is really there.
///
/// Run it with the lid open and the display awake: macOS doesn't draw otherwise, so flows wait for the display.
///
/// `DJQ_SEARCH_PROBE=sabotage` makes one assertion expect the wrong week, to show the run can fail.
@MainActor
final class SearchProbe {
  struct Step: Encodable {
    var theme: String
    var flow: String
    var step: String
    var file: String?
    var passed: Bool
    var note: String
  }

  private let model: AppModel
  private let window: NSWindow
  private let out: URL
  private var theme = "light"
  private var flow = ""
  private var shotNo = 0
  private var steps: [Step] = []
  private var problems: [String] = []
  private let sabotage = ProcessInfo.processInfo.environment["DJQ_SEARCH_PROBE"] == "sabotage"
  private var ui: BrowseUI { .shared }
  private var prefs: ListPrefs { .shared }

  // Seeded into the throwaway DB.
  private let captionWord = "rooftop"
  private let caption = "Sunrise rooftop encore, see you in Lagos"
  private let externalId = "probe-ext-4471"
  private let groupName = "Probe harbour tags"
  private let templateName = "Probe tide template"
  private let titleTemplateName = "Probe tide title"
  private var captionClip = ""
  private var post = ""

  static func run(outputDir: String) async -> Int32 {
    defer { DSTooltipProbe.cleanUp() }
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let model = try DSTooltipProbe.makeModel()
      let w = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
      w.isReleasedWhenClosed = false
      let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      w.setFrameOrigin(NSPoint(x: screen.midX - 720, y: screen.midY - 450))
      w.ignoresMouseEvents = true  // in front but inert (DSTooltipProbe)
      w.orderFrontRegardless()
      DSTooltipController.shared.requireActiveApp = false
      DSTooltipController.shared.simulatedPointer = DSTooltipProbe.offscreen
      let p = SearchProbe(model: model, window: w, out: out)
      try p.seed()
      try await Task.sleep(for: .milliseconds(1600))
      for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        p.theme = name
        p.shotNo = 0
        w.appearance = NSAppearance(named: look)
        try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: true)
        let flows: [(String, () async -> Void)] = [
          ("caption", p.captionFlow), ("post", p.postFlow), ("week", p.weekFlow), ("calendar", p.calendarFlow), ("session", p.sessionFlow), ("setting", p.settingsFlow),
          ("auto-update", p.autoUpdateFlow), ("health", p.healthFlow), ("action", p.actionFlow), ("show-all", p.showAllFlow),
          ("chip-fallback", p.chipFallbackFlow), ("no-empty-show-all", p.duplicateActionFlow), ("editor", p.editorFlow),
          ("settings", p.fromSettingsFlow), ("modals", p.modalsFlow), ("hand-off", p.handOffFlow), ("recents", p.recentsFlow), ("fresh", p.freshFlow),
        ]
        // `DJQ_SEARCH_PROBE_ONLY=health,action` runs those flows while working on them. A full run leaves it unset.
        let only = ProcessInfo.processInfo.environment["DJQ_SEARCH_PROBE_ONLY"]?.split(separator: ",").map(String.init)
        for (name, flow) in flows where only?.contains(name) ?? true { await flow() }
      }
      p.problems.forEach { print("search-probe: FAIL \($0)") }
      try p.report()
      w.orderOut(nil)
      w.close()
      print("search-probe: \(p.steps.count) steps → \(out.path) · \(p.problems.isEmpty ? "pass" : "\(p.problems.count) failed")")
      return p.problems.isEmpty ? 0 : 1
    } catch {
      FileHandle.standardError.write(Data("search-probe failed: \(error)\n".utf8))
      return 1
    }
  }

  private init(model: AppModel, window: NSWindow, out: URL) {
    self.model = model
    self.window = window
    self.out = out
  }

  private func seed() throws {
    let store = model.store
    guard let clip = model.ordered.first ?? model.videos.first(where: { $0.type == .short }) else { throw ProbeError.noData("no clip") }
    captionClip = clip.id
    var last = try store.versions(videoId: clip.id).last ?? Version(number: 1)
    last.caption = caption
    try store.save(last, videoId: clip.id)
    // The oldest post: at the far end of a newest-first list, so opening it has to scroll.
    guard var p = model.posts.min(by: { ($0.scheduledAt, $0.id) < ($1.scheduledAt, $1.id) }) else { throw ProbeError.noData("no post") }
    p.externalId = externalId
    try store.save(p)
    post = p.id
    try store.save(HashtagSet(id: "probe-group", name: groupName, category: "My groups", tags: ["#probeharbour"], sort: 99))
    try store.save(CaptionTemplate(id: "probe-template", name: templateName, template: "{text}\n\n{hashtags}", sort: 99))
    var settings = try store.settings()
    settings.youtubeTitleTemplates.append(TitleTemplate(id: "probe-title", name: titleTemplateName, template: "{text} | Probe"))
    try store.save(settings)
    model.refreshNow()
  }

  enum ProbeError: Error { case noData(String) }

  // MARK: Driving

  private func start(_ name: String, screen: Screen = .queue) async {
    flow = name
    SnapshotContext.resetUI(model)
    ui.reset()
    SettingsUIState.shared.reset()
    PostsCardState.shared.expanded = []
    model.postsSelection = nil
    model.screen = screen
    await settle(500)
    await waitForDisplay()
  }

  /// macOS draws nothing with the lid closed or the display asleep, and keys into an undrawn window prove nothing. So
  /// flows wait for it to come back (up to 20 minutes) instead of failing for a reason that isn't the app's.
  private func waitForDisplay() async {
    for n in 0..<240 {
      guard let img = DSTooltipProbe.captureImage(window, panel: nil), Self.isBlank(img) else { return }
      if n == 0 { print("search-probe: the display isn't drawing, waiting") }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  private func settle(_ ms: Int = 320) async {
    try? await Task.sleep(for: .milliseconds(ms))
    window.displayIfNeeded()
  }

  private func event(_ chars: String, ignoring: String? = nil, code: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent? {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                     isARepeat: false, keyCode: code)
  }

  private func command(_ char: String, code: UInt16) async {
    if let e = event(char, code: code, flags: .command), !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
    if let e = event(char, code: code, flags: .command, type: .keyUp) { window.sendEvent(e) }
    await settle()
  }

  private func commandK() async { await command("k", code: 40) }
  private func commandF() async { await command("f", code: 3) }

  private func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) async {
    if let e = event(chars, ignoring: ignoring, code: code, flags: flags) { window.sendEvent(e) }
    if let e = event(chars, ignoring: ignoring, code: code, flags: flags, type: .keyUp) { window.sendEvent(e) }
    await settle(140)
  }

  private func down() async { await press("\u{F701}", code: 125, flags: [.function, .numericPad]) }
  private func up() async { await press("\u{F700}", code: 126, flags: [.function, .numericPad]) }
  private func tab() async { await press("\t", code: 48) }
  private func shiftTab() async { await press("\u{19}", code: 48, flags: .shift, ignoring: "\t") }
  private func enter() async { await press("\r", code: 36) }
  private func esc() async { await press("\u{1b}", code: 53) }
  private func backspace() async { await press("\u{7f}", code: 51) }

  /// Tab until `scope`'s chip is on.
  private func tabTo(_ scope: SearchScope, _ text: String) async {
    let on = SearchScope.allCases.filter { results(text).counts[$0] != nil }
    for _ in 0..<(on.firstIndex(of: scope) ?? 0) { await tab() }
    check(ui.paletteScope == scope, "Tab reaches the \(scope.title) chip")
  }

  private func type(_ text: String) async {
    for c in text { await keystroke(c) }
    await settle()
  }

  private func keystroke(_ c: Character) async {
    let s = String(c)
    if let e = event(s, code: 0) { window.sendEvent(e) }
    if let e = event(s, code: 0, type: .keyUp) { window.sendEvent(e) }
    try? await Task.sleep(for: .milliseconds(12))
  }

  /// A real click: mouse down and up at the centre of `rect` (screen coordinates), into the window.
  private func click(_ rect: CGRect) async {
    let p = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
    for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
      if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
        window.sendEvent(e)
      }
      await settle(60)
    }
    await settle()
  }

  // MARK: Recording

  private func check(_ ok: Bool, _ what: String) {
    steps.append(Step(theme: theme, flow: flow, step: what, file: nil, passed: ok, note: ""))
    if !ok { problems.append("[\(theme)] \(flow): \(what)") }
  }

  private func setupNote(_ what: String) {
    steps.append(Step(theme: theme, flow: flow, step: "SETUP \(what)", file: nil, passed: true, note: "direct model call"))
  }

  /// Captures the window. A blank capture (a covered window draws nothing) fails the step.
  @discardableResult
  private func shot(_ name: String) async -> CGImage? {
    await settle(160)
    await waitForDisplay()
    shotNo += 1
    let file = String(format: "%@/%02d-%@-%@.png", theme, shotNo, flow, name)
    guard let img = DSTooltipProbe.captureImage(window, panel: nil) else {
      check(false, "capture \(name)")
      return nil
    }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(file))
    let blank = Self.isBlank(img)
    steps.append(Step(theme: theme, flow: flow, step: "shot \(name)", file: file, passed: !blank, note: blank ? "blank" : ""))
    if blank { problems.append("[\(theme)] \(flow): \(name) capture is blank") }
    return img
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

  /// Mean difference of two captures inside `rect` (window points, top-left origin).
  private static func difference(_ a: CGImage?, _ b: CGImage?, in rect: CGRect) -> Double {
    guard let a, let b, a.width == b.width else { return 0 }
    let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
    let scale = CGFloat(a.width) / 1440
    var sum = 0.0, n = 0.0
    for y in stride(from: rect.minY, to: rect.maxY, by: 6) {
      for x in stride(from: rect.minX, to: rect.maxX, by: 6) {
        guard let p = ra.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB),
              let q = rb.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) else { continue }
        sum += Double(abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent))
        n += 1
      }
    }
    return n == 0 ? 0 : sum / n
  }

  private func results(_ text: String, _ scope: SearchScope = .all) -> PaletteContent { model.paletteContent(text: text, scope: scope) }

  // MARK: Flows

  private func openPalette() async {
    await commandK()
    check(model.showPalette, "⌘K opens the palette")
  }

  private func closePalette() async {
    await esc()
    if model.showPalette { await esc() }
    check(!model.showPalette, "esc closes the palette")
  }

  /// Clip found by caption text: its hit says where it matched, ↩ opens the clip's action page, esc returns to the results.
  private func captionFlow() async {
    await start("caption")
    await shot("start")
    await openPalette()
    await shot("opened")
    await type("\(captionWord) encore")
    check(ui.paletteQuery == "\(captionWord) encore", "typing reaches the field")
    let c = results(ui.paletteQuery)
    check(c.flat.first?.id == "clip.\(captionClip)", "the clip is the first hit")
    check(c.flat.first?.subtitle?.hasPrefix("Caption: ") == true, "the row says it matched the caption")
    await shot("caption-hit")
    await enter()
    check(ui.paletteClipId == captionClip, "↩ opens the clip's action page")
    await shot("action-page")
    await esc()
    check(ui.paletteClipId == nil && ui.paletteQuery == "\(captionWord) encore", "esc goes back to the results")
    await shot("back-to-results")
    await closePalette()
    await shot("closed")
    await openPalette()
    await type("left behind")
    await commandK()
    check(!model.showPalette, "⌘K closes the palette too")
    await openPalette()
    check(ui.paletteQuery.isEmpty, "and the next one starts empty")
    await closePalette()
  }

  /// Post by external id: opens Posts with the hiding search and chip cleared, row in view, inspector open.
  private func postFlow() async {
    await start("post")
    setupNote("a Posts search, status chip and Platform filter that hide the post")
    prefs.setSearch(.posts, "nothing-matches-this")
    prefs.setStatus(.posts, PostsTab.scheduled.rawValue)
    let other = Platform.allCases.first { $0 != model.postById[post]?.platform } ?? .x
    prefs.setFilter(.posts, ListFilterKey.platform, other.rawValue)
    model.screen = .posts
    await settle(500)
    await shot("hidden-by-filters")
    await openPalette()
    await type(externalId)
    check(results(externalId).flat.first?.id == SearchId.post(post), "the post is the first hit")
    await shot("post-hit")
    await enter()
    await settle(900)
    check(model.screen == .posts, "opens Posts")
    check(!model.showPalette, "the palette closes")
    check(prefs[.posts].search.isEmpty && prefs[.posts].status == nil && prefs[.posts].filters.isEmpty, "the filters that hid it are cleared")
    check(model.postsSelection == post, "the inspector shows the post")
    let f = ProbeFrames.frames["post:\(post)"]
    check(f.map { $0.minY > 60 && $0.maxY < window.frame.height - 10 } == true, "its row is in view (\(f.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "not on screen"))")
    await shot("post-open")
  }

  /// The Calendar's commands, and the old names for it, come up and work.
  private func calendarFlow() async {
    await start("calendar")
    await openPalette()
    await type("calendar: month")
    check(results("calendar: month").flat.first?.id == "calendar.month", "“calendar: month” finds the command")
    await shot("month-hit")
    await enter()
    await settle(500)
    check(model.screen == .calendar && model.calendarMode == .month, "it opens Month")
    await shot("month-open")
    await start("calendar")
    await openPalette()
    await type("today")
    check(results("today").flat.contains { $0.id == "calendar.open" }, "“today” finds Open Calendar")
    await shot("today-hit")
    await esc()
    await esc()
  }

  /// "12 nov"-style date opens that week; "next week" and a month name work too.
  private func weekFlow() async {
    await start("week")
    let target = model.dm.addDays(model.thisWeek, 7)
    let text = Fmt.day(model.dm.date(model.dm.addDays(target, 3)), tz: model.tz, style: "d MMM").lowercased()
    await openPalette()
    await type(text)
    let c = results(text)
    check(c.sections.first?.title == "Weeks", "“\(text)” puts Weeks first")
    check(c.flat.first?.id == SearchId.week(target), "“\(text)” finds the week of \(target)")
    check(c.flat.first?.subtitle?.contains("clip") == true || c.flat.first?.subtitle?.contains("No clips") == true, "the subtitle has its clip count")
    await shot("date-hit")
    await enter()
    await settle(500)
    check(model.screen == .calendar && model.calendarMode == .week, "opens the Calendar's Week view")
    check(model.shownWeek == (sabotage ? "1999-01-04" : target), "shows that week")
    await shot("week-open")
    await openPalette()
    await type("this week")
    check(results("this week").flat.first?.id == SearchId.week(model.thisWeek), "“this week” finds this week")
    await shot("this-week-hit")
    await enter()
    await settle(500)
    check(model.shownWeek == model.thisWeek, "“this week” opens it")
    await shot("this-week-open")
  }

  /// Session by name, narrowed with the Sessions chip by Tab: opens Library filtered to it.
  private func sessionFlow() async {
    await start("session")
    guard let s = model.sessions.first(where: { x in model.videos.contains { $0.sessionId == x.id } }) else { return check(false, "a session with clips") }
    let text = Captions.setName(s.name)
    setupNote("a Library search, status chip and Kind filter that would hide the session's clips")
    prefs.setSearch(.library, "nothing-matches-this")
    prefs.setStatus(.library, LibraryFilter.excluded.rawValue)
    prefs.setFilter(.library, ListFilterKey.kind, Kind.talking.rawValue)
    model.screen = .library
    await settle(500)
    await shot("hidden-by-filters")
    await openPalette()
    await type(text)
    await shot("typed")
    check(results(text).counts[.sessions] != nil, "the Sessions chip is offered")
    await tabTo(.sessions, text)
    await shot("sessions-chip")
    await enter()
    await settle(800)
    check(model.screen == .library, "opens Library")
    check(prefs[.library].filters == [ListFilterKey.session: s.id], "filtered to the session and nothing else")
    check(prefs[.library].search.isEmpty && prefs[.library].status == nil, "the search and status chip are cleared")
    let shown = model.visibleIds[.library] ?? []
    check(!shown.isEmpty && shown.allSatisfy { model.video($0)?.sessionId == s.id }, "Library shows only that session's clips")
    await shot("library-filtered")
  }

  /// One row in each kind of pane: the section opens, the row is scrolled into view and flashes.
  private func settingsFlow() async {
    let cases: [(String, SettingsSection, String, String)] = [
      ("repost cooldown", .schedule, SettingsAnchor.row("Repost cooldown"), "schedule"),
      ("ask an agent", .captions, SettingsAnchor.row("Ask an agent"), "captions-own-scroll"),
      ("youtube title template", .newClipDefaults, SettingsAnchor.row("YouTube title template"), "defaults-own-scroll"),
      ("update log", .engine, SettingsAnchor.row("Update log"), "engine-far-down"),
      (groupName.lowercased(), .captions, SettingsAnchor.hashtagGroup("probe-group"), "hashtag-group"),
      (templateName.lowercased(), .captions, SettingsAnchor.captionTemplate("probe-template"), "caption-template"),
      (titleTemplateName.lowercased(), .captions, SettingsAnchor.titleTemplate("probe-title"), "title-template"),
    ]
    for (text, section, anchor, name) in cases {
      await start("setting-\(name)")
      await openPalette()
      await type(text)
      let top = results(text).flat.first
      check(top?.title.lowercased().contains(text) == true, "“\(text)” is the first hit (\(top?.title ?? "none"))")
      await shot("hit")
      await enter()
      await settle(650)
      check(model.showSettings && model.settingsSection == section, "opens \(section.title)")
      let f = ProbeFrames.frames["setting:\(anchor)"]
      let (w, h) = (window.frame.width, window.frame.height)
      let modal = CGRect(x: (w - 760) / 2, y: (h - 560) / 2, width: 760, height: 560)
      let footer: CGFloat = section == .newClipDefaults ? 56 : 0
      check(f.map { $0.minY >= modal.minY + 40 && $0.maxY <= modal.maxY - footer } == true,
            "the row is flashing and in view (\(f.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "no highlight"))")
      await shot("row-flash")
      await settle(1700)
      check(SettingsUIState.shared.flashAnchor == nil, "the flash ends")
      await shot("after-flash")
    }
  }

  /// The "Auto-update" header sits inside `.id(AutoUpdateSettings.anchor)`. Coming from the bottom of Engine, where it's out
  /// of view, proves the scroll finds the header's own anchor.
  private func autoUpdateFlow() async {
    await start("auto-update-header")
    await openPalette()
    await type("daily backup")
    await enter()
    await settle(650)
    check(ProbeFrames.frames["setting:\(SettingsAnchor.row("Daily backup"))"] != nil, "lands at the bottom of Engine first")
    await shot("daily-backup")
    await settle(1700)
    await openPalette()
    await type("auto-update")
    check(results("auto-update").flat.first?.id == SearchId.setting("engine.\(SettingsAnchor.group("Auto-update"))"), "the header is the first hit")
    await enter()
    await settle(650)
    let f = ProbeFrames.frames["setting:\(SettingsAnchor.group("Auto-update"))"]
    let top = (window.frame.height - 560) / 2
    check(f.map { $0.minY >= top + 40 && $0.maxY <= top + 560 } == true, "the header is flashing and in view (\(f.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "no highlight"))")
    await shot("header-flash")
  }

  /// Health places open Health, the runway opens the Queue, and neither row repeats its second line.
  private func healthFlow() async {
    await start("health-backups", screen: .score)
    await openPalette()
    await type("backups")
    await tabTo(.actions, "backups")
    check(results("backups", .actions).flat.first?.id == SearchId.health("backups"), "Backups is the first row under Actions")
    await shot("hit")
    await enter()
    await settle(600)
    check(model.screen == .health && !model.showPalette, "Backups opens Health")
    await shot("health")
    await start("health-runway", screen: .score)
    await openPalette()
    await type("runway")
    await tabTo(.actions, "runway")
    let row = results("runway", .actions).flat.first
    check(row?.id == SearchId.health("runway"), "Runway is the first row under Actions")
    check(row?.subtitle?.contains("scheduled") == true, "its second line has the numbers")
    await shot("hit")
    await enter()
    await settle(600)
    check(model.screen == .queue, "Runway opens the Queue, where it shows")
    await shot("queue")
    await start("health-subtitle", screen: .score)
    await openPalette()
    await type("database")
    let backups = results("database").flat.first { $0.id == SearchId.health("backups") }
    check(backups?.subtitle == HealthPlace.all.first { $0.id == "backups" }?.subtitle, "a subtitle hit isn't repeated (\(backups?.subtitle ?? "no row"))")
    check(backups?.subtitleMatches.isEmpty == false, "the match is marked in the subtitle")
    await shot("subtitle-match")
    await closePalette()
    await openPalette()
    await type("settings")
    let pane = results("settings").flat.first { $0.id.hasPrefix("search.pane.") }
    check(pane?.subtitle == "Settings", "a section row reads Settings once (\(pane?.subtitle ?? "no row"))")
    await shot("section-rows")
    await closePalette()
  }

  /// An action by its title and by its subtitle, and one that changes screen from the editor.
  private func actionFlow() async {
    await start("action", screen: .score)
    await openPalette()
    await type("keyboard shortcuts")
    await shot("hit")
    await enter()
    await settle(400)
    check(model.showShortcuts, "the action runs")
    await shot("ran")
    setupNote("the cheat sheet closed")
    model.showShortcuts = false
    await openPalette()
    await type("check the app")
    check(results("check the app").flat.first?.id == "health.doctor", "an action is found by its subtitle")
    await shot("by-subtitle")
    await closePalette()
    await start("action-from-editor")
    setupNote("the editor opened on a clip before ⌘K")
    model.openEditor(captionClip, in: [captionClip])
    await settle(1200)
    await openPalette()
    await type("open doctor")
    await enter()
    await settle(900)
    check(model.screen == .health && model.editor == nil, "an action that changes screen closes the editor")
    await shot("health")
  }

  /// A chip that lost its hits goes back to All and stays there when the hits return.
  private func chipFallbackFlow() async {
    await start("chip-fallback")
    await openPalette()
    await type("blend")
    await tabTo(.clips, "blend")
    await shot("clips-chip")
    await type("zz")
    check(ui.paletteScope == .all, "no hits: back to All")
    await shot("no-hits")
    await backspace()
    await backspace()
    check(ui.paletteQuery == "blend", "backspace reaches the field")
    check(ui.paletteScope == .all, "the chip doesn't come back by itself")
    await shot("all-again")
    await closePalette()
  }

  /// The selected clip's "Actions for…" row and its own hit are one row: no "Show all" for a section that's gone.
  private func duplicateActionFlow() async {
    await start("no-empty-show-all")
    guard let v = model.video(captionClip) else { return check(false, "the clip") }
    setupNote("one clip selected before ⌘K")
    model.visibleIds[.queue] = [captionClip]
    model.setSelection([captionClip], screen: .queue)
    let text = model.displayName(v)
    await openPalette()
    await type(text)
    let c = results(text)
    check(c.flat.filter { $0.id == "clip.\(captionClip)" }.count == 1, "the clip is listed once")
    check(!c.sections.contains { s in s.rows.allSatisfy { $0.command.id.hasPrefix("show.") } }, "no section holds only a Show all row")
    await shot("once")
    await closePalette()
  }

  /// A broad word: groups are capped at five, the Show all row opens the chip, Tab and ⇧Tab walk the chips, ↑ ↓ move.
  private func showAllFlow() async {
    await start("show-all")
    let text = "blend"
    await openPalette()
    await type(text)
    let c = results(text)
    check(c.sections.allSatisfy { $0.rows.filter { !$0.command.id.hasPrefix("show.") }.count <= AppModel.paletteGroupCap }, "groups stop at five rows")
    guard let row = c.flat.firstIndex(where: { $0.id == "show.clip" }) else { return check(false, "a Show all clips row") }
    await shot("capped")
    for _ in 0..<(row + 1) { await down() }
    await up()
    await shot("show-all-selected")
    await enter()
    check(ui.paletteScope == .clips, "Show all opens the Clips chip")
    let all = results(text, .clips)
    check(all.flat.count > AppModel.paletteGroupCap, "every clip is listed (\(all.flat.count))")
    await shot("all-clips")
    let before = ui.paletteScope
    await tab()
    check(ui.paletteScope != before, "Tab moves to the next chip")
    await shot("next-chip")
    await shiftTab()
    check(ui.paletteScope == before, "⇧Tab moves back")
    await closePalette()
  }

  /// ⌘K from the editor: the palette opens over it, and a result that navigates closes the editor.
  private func editorFlow() async {
    await start("editor")
    setupNote("the editor opened on a clip before ⌘K")
    model.openEditor(captionClip, in: [captionClip])
    await settle(1800)
    await shot("editor")
    await openPalette()
    await shot("palette-over-editor")
    await type(externalId)
    await enter()
    await settle(1000)
    check(model.editor == nil, "the editor closed")
    check(model.screen == .posts && model.postsSelection == post, "Posts shows the post")
    await shot("post-open")
    await start("editor-go-to")
    setupNote("the editor opened on a clip before ⌘K")
    model.openEditor(captionClip, in: [captionClip])
    await settle(1200)
    await openPalette()
    await type("go to library")
    await enter()
    await settle(800)
    check(model.editor == nil && model.screen == .library, "Go to closes the editor the same way")
    await shot("library")
  }

  /// ⌘K from Settings: above the modal. A setting stays in Settings; a result that navigates closes it.
  private func fromSettingsFlow() async {
    await start("settings")
    setupNote("Settings opened on Alerts before ⌘K")
    model.settingsSection = .alerts
    model.showSettings = true
    await settle(700)
    let before = await shot("settings-open")
    await openPalette()
    let after = await shot("palette-over-settings")
    check(Self.difference(before, after, in: CGRect(x: 420, y: 200, width: 600, height: 240)) > 0.05, "the palette draws above the modal")
    await esc()
    check(!model.showPalette && model.showSettings, "esc closes only the palette")
    await openPalette()
    await type("late grace")
    await enter()
    await settle(650)
    check(model.showSettings && model.settingsSection == .schedule, "a setting stays in Settings and changes section")
    check(ProbeFrames.frames["setting:\(SettingsAnchor.row("Late grace"))"] != nil, "and lands on the row")
    await shot("setting-from-settings")
    await settle(1700)
    await openPalette()
    await type(externalId)
    await enter()
    await settle(1000)
    check(!model.showSettings, "a post closes Settings")
    check(model.screen == .posts && model.postsSelection == post, "and opens in Posts")
    await shot("post-from-settings")
    await start("settings-open-clip")
    setupNote("Settings opened before ⌘K")
    model.showSettings = true
    await settle(500)
    await openPalette()
    await type("\(captionWord) encore")
    await enter()
    check(ui.paletteClipId == captionClip, "a clip's action page opens over Settings")
    await shot("action-page")
    await enter()  // Open in editor
    await settle(1200)
    check(model.editor?.videoId == captionClip && !model.showSettings, "Open in editor closes Settings")
    await shot("editor")
  }

  /// ⌘K over a dialog: a setting never lands under it, and a result that leaves takes it along.
  private func modalsFlow() async {
    await start("over-cheat-sheet")
    setupNote("the cheat sheet opened before ⌘K")
    model.showShortcuts = true
    await settle(400)
    await openPalette()
    await shot("palette-over-sheet")
    await type("late grace")
    await enter()
    await settle(650)
    check(model.showSettings && !model.showShortcuts, "a setting closes the cheat sheet")
    check(ProbeFrames.frames["setting:\(SettingsAnchor.row("Late grace"))"] != nil, "and the row shows")
    await shot("setting")
    await start("over-dialog")
    setupNote("the Mark posted dialog opened before ⌘K")
    model.markPostedTarget = model.postById[post]
    await settle(400)
    await openPalette()
    await type(externalId)
    await enter()
    await settle(900)
    check(model.markPostedTarget == nil && model.postsSelection == post, "a result that leaves closes the dialog")
    await shot("post")
    await start("settings-under-palette")
    await openPalette()
    setupNote("Settings opened directly while the palette is up: ⌘, is a menu command, and snapshot runs have no menu")
    model.showSettings = true
    await settle(400)
    check(!model.showPalette, "Settings opening closes the palette, so nothing strands the caret")
    await shot("settings")
  }

  /// ⌘F filters the page; nothing fits, so "Search everywhere" carries the text into ⌘K, which finds the clip's caption.
  private func handOffFlow() async {
    for s in [Screen.score, .edit, .queue, .library, .posts] {
      guard let page = ListPage.of(s) else { continue }
      await start("hand-off-\(s.rawValue)", screen: s)
      await commandF()
      await settle(400)
      await type(captionWord)
      check(prefs[page].search == captionWord, "⌘F's field gets the text")
      await settle(300)
      await shot("nothing-fits")
      let label = "Look for “\(captionWord)” across the whole app"
      guard let button = DSTooltipProbe.anchors(in: window).first(where: { $0.content.label == label }), let r = button.visibleScreenRect else {
        check(false, "the empty state offers Search everywhere")
        continue
      }
      await click(r)
      await settle(400)
      check(model.showPalette && ui.paletteQuery == captionWord, "Search everywhere opens ⌘K with the text")
      check(results(captionWord).flat.contains { $0.id == "clip.\(captionClip)" }, "⌘K finds what the page filter couldn't")
      await shot("search-everywhere")
      await closePalette()
      check(prefs[page].search == captionWord, "the page's filter stays")
      setupNote("the page's filter cleared for the next flow")
      prefs.clearFilters(page)
    }
  }

  /// A search result shows up in Recents and runs again; a stale recent is dropped without a crash.
  private func recentsFlow() async {
    await start("recents")
    setupNote("Recents emptied")
    model.recentCommands = []
    await openPalette()
    await type("next week")
    await enter()
    await settle(400)
    let id = SearchId.week(model.dm.addDays(model.thisWeek, 7))
    check(model.recentCommands.first == id, "the result joins Recents")
    model.recentCommands = [id, SearchId.post("gone"), SearchId.session("gone"), SearchId.setting("captions.hashtag:gone"), "clip.gone"]
    setupNote("stale recents injected")
    await openPalette()
    let rows = results("").sections.first { $0.title == "Recents" }?.rows.map(\.command.id)
    check(rows == [id], "only the live recent is listed")
    await shot("recents")
    await enter()
    await settle(400)
    check(model.screen == .calendar, "the recent runs")
    await shot("recent-ran")
  }

  /// New text is searchable after the next refresh, through the same off-main load the running app uses (this probe's
  /// model is frozen, which otherwise loads on the main actor).
  private func freshFlow() async {
    await start("fresh")
    let word = theme == "light" ? "brandnewlight" : "brandnewdark"
    await openPalette()
    await type(word)
    check(results(word).flat.first?.id != "clip.\(captionClip)", "not findable yet")
    await shot("before")
    setupNote("a caption saved through the store, as an edit elsewhere would")
    await save(caption: "\(caption) \(word)")
    check(results(word).flat.first?.id == "clip.\(captionClip)", "found after the background refresh")
    await shot("after")
    await closePalette()
    setupNote("the caption put back")
    await save(caption: caption)
  }

  private func save(caption text: String) async {
    guard var v = try? model.store.versions(videoId: captionClip).last else { return check(false, "the clip's version") }
    v.caption = text
    try? model.store.save(v, videoId: captionClip)
    let generation = model.searchGeneration
    model.frozen = false
    model.refresh()
    for _ in 0..<60 where model.searchGeneration == generation { await settle(50) }
    model.frozen = true
    check(model.searchGeneration != generation, "the background load landed")
  }

  private func report() throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try e.encode(steps).write(to: out.appendingPathComponent("steps.json"))
    let lines = steps.map { "\($0.passed ? "pass" : "FAIL")  \($0.theme)  \($0.flow)  \($0.step)" + ($0.file.map { "  → \($0)" } ?? "") }
    try lines.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("steps.txt"), atomically: true, encoding: .utf8)
  }
}
