import AppKit
import DJQCore
import SwiftUI

/// Evidence run for DSTooltip in the REAL main window (design/TOOLTIPS-DECISIONS.md):
/// `DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1 DJQueueApp --snapshot <dir>`.
///
/// Builds the real AppModel on a throwaway copy of the dev DB (same seeding as SnapshotRunner), opens the real main
/// window in front, click-through and without activating the app (it never steals focus or answers the user's
/// cursor), then drives the tooltip through synthetic mouse-moved events posted to the app's own queue — the same
/// hover path a real pointer takes.
/// For each case it captures the window server's composite of the main window + the tooltip panel and records
/// the frames (`probe.json`). Cases: toolbar at the window's top edge (must flip below), sidebar status near the
/// bottom edge, the delay group hand-off, Escape, dark mode, and the window pushed into the screen's top-right
/// corner (must flip + shift and stay on screen). Then every tooltip type on every page — video-preview buttons on
/// a hovered tile, disabled (label + why), keycaps, plain — each captured on hover and after leaving; the run fails
/// if a bubble doesn't open, renders no text (`textPixels`) or stays after the pointer leaves.
@MainActor
enum DSTooltipProbe {
  struct Record: Encodable {
    var name: String
    var label: String
    var side: String
    var anchor: [Double]
    var bubble: [Double]?
    var window: [Double]
    var insideWindow: Bool
    var insideScreen: Bool
    var openedAfterMs: Int?
    var note: String
    /// Bubble pixels that contrast with its background (text, keycaps). ~0 = an empty bubble.
    var textPixels: Int? = nil
    /// After the pointer left the trigger: was the panel gone?
    var hiddenAfterLeave: Bool? = nil
  }

  static func run(outputDir: String) async -> Int32 {
    defer { cleanUp() }
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      var problems = try await nested(out: out)
      if ProcessInfo.processInfo.environment["DJQ_TOOLTIP_PROBE"] == "nested" {
        problems.forEach { print("tooltip-probe: FAIL \($0)") }
        return problems.isEmpty ? 0 : 1
      }
      let model = try makeModel()
      let w = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
      w.isReleasedWhenClosed = false
      w.appearance = NSAppearance(named: .aqua)
      let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      w.setFrameOrigin(NSPoint(x: screen.midX - 720, y: screen.midY - 450))
      // In front but inert: macOS stops drawing a fully covered window's SwiftUI layers (the capture comes back blank),
      // so the window is shown without activating the app and lets every real click and hover pass through to
      // whatever is under it — the user's pointer never drives it, only the probe's posted events do.
      w.ignoresMouseEvents = true
      w.orderFrontRegardless()
      let c = DSTooltipController.shared
      c.requireActiveApp = false
      c.simulatedPointer = offscreen
      var records: [Record] = []

      func settle(_ ms: Int = 1200) async throws { try await Task.sleep(for: .milliseconds(ms)); w.displayIfNeeded() }

      /// Moves the synthetic pointer to `a`'s centre and waits for the tooltip (or `timeout`).
      func hover(_ a: DSTooltipAnchorView, timeout: Int = 1500) async throws -> Int? {
        guard let r = a.visibleScreenRect else { return nil }
        let start = Date()
        await post(.mouseMoved, at: CGPoint(x: r.midX, y: r.midY), in: w)
        while Date().timeIntervalSince(start) * 1000 < Double(timeout) {
          try await Task.sleep(for: .milliseconds(20))
          if c.debugShown === a, c.debugPanelFrame != nil { return Int(Date().timeIntervalSince(start) * 1000) }
        }
        return nil
      }

      func record(_ name: String, _ a: DSTooltipAnchorView, opened: Int?, note: String) async throws {
        try await Task.sleep(for: .milliseconds(250))  // let the 120 ms fade/slide finish
        let rect = a.visibleScreenRect ?? .zero
        let b = c.debugPanelFrame
        let vis = (w.screen ?? NSScreen.main)?.frame ?? screen
        records.append(Record(name: name, label: a.content.label ?? a.content.disabledReason ?? "", side: c.debugSide?.rawValue ?? "-",
                              anchor: arr(rect), bubble: b.map(arr), window: arr(w.frame),
                              insideWindow: b.map { w.frame.contains($0) } ?? false, insideScreen: b.map { vis.contains($0) } ?? false,
                              openedAfterMs: opened, note: note, textPixels: b == nil ? nil : textPixels(c.debugPanelWindow)))
        try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent("\(name).png"))
        print("tooltip-probe: \(name) · \(a.content.label ?? "") · side \(c.debugSide?.rawValue ?? "-") · opened \(opened.map { "\($0) ms" } ?? "no")")
      }

      func park() async throws {
        await post(.mouseMoved, at: CGPoint(x: w.frame.midX, y: w.frame.minY + 2), in: w)  // empty strip, no trigger
        c.hide(resetGroup: true)
        try await Task.sleep(for: .milliseconds(450))
      }

      // `DJQ_TOOLTIP_PROBE=r6` runs only the round-6 cases (step 9).
      let r6Only = ProcessInfo.processInfo.environment["DJQ_TOOLTIP_PROBE"] == "r6"
      var sawReason = false, sawKeys = false
      var tilePicks: [String: Int] = [:]
      var n = 8
      if !r6Only {
        // 1. Queue: toolbar triggers sit 10 pt under the window's top edge → preferred top must flip below.
        SnapshotContext.resetUI(model)
        model.screen = .queue
        try await settle(1800)
        let all = anchors(in: w)
        try JSONEncoder.pretty.encode(all.map { [$0.content.label ?? "", $0.content.shortcut ?? "", $0.content.disabledReason ?? "",
                                                 "\(Int($0.visibleScreenRect?.minX ?? 0) - Int(w.frame.minX)),\(Int(w.frame.maxY - ($0.visibleScreenRect?.maxY ?? 0)))"] })
          .write(to: out.appendingPathComponent("anchors-queue.json"))
        let toolbar = all.filter { ($0.visibleScreenRect?.maxY ?? 0) > w.frame.maxY - 60 }.sorted { ($0.visibleScreenRect?.minX ?? 0) < ($1.visibleScreenRect?.minX ?? 0) }
        guard let tA = toolbar.dropLast().last, let tB = toolbar.last else { throw ProbeError.noAnchors("toolbar") }
        var opened = try await hover(tA)
        try await record("01-queue-toolbar-top-edge-flips-below", tA, opened: opened, note: "first hover: full delay; window top edge above")
        // 2. Delay group: straight to the neighbour → opens at once.
        opened = try await hover(tB)
        try await record("02-queue-toolbar-delay-group-instant", tB, opened: opened, note: "moved from the previous trigger: delay group")
        // 3. Escape closes and keeps it closed while the pointer stays.
        postKey(53, in: w)
        try await Task.sleep(for: .milliseconds(700))
        records.append(Record(name: "03-escape-closes", label: tB.content.label ?? "", side: "-", anchor: arr(tB.visibleScreenRect ?? .zero),
                              bubble: c.debugPanelFrame.map(arr), window: arr(w.frame), insideWindow: false, insideScreen: false,
                              openedAfterMs: nil, note: c.debugPanelFrame == nil ? "closed after Esc, stayed closed 700 ms" : "STILL OPEN"))
        try await park()

        // 4. Sidebar engine status near the window's bottom-left edge.
        if let s = all.filter({ ($0.visibleScreenRect?.minX ?? .infinity) < w.frame.minX + 260 })
          .min(by: { ($0.visibleScreenRect?.minY ?? 0) < ($1.visibleScreenRect?.minY ?? 0) }) {
          opened = try await hover(s)
          try await record("04-sidebar-bottom-left", s, opened: opened, note: "bottom-left of the window")
          try await park()
        }

        // 5. Collapsed sidebar: icon rows explain themselves (label + ⌘ shortcut).
        model.sidebarCollapsed = true
        try await settle()
        let rail = anchors(in: w).filter { ($0.visibleScreenRect?.maxX ?? .infinity) < w.frame.minX + 90 && $0.content.shortcut != nil }
        if let r = rail.dropFirst(2).first {
          opened = try await hover(r)
          try await record("05-collapsed-sidebar-row-shortcut", r, opened: opened, note: "compact sidebar row, keycaps")
          try await park()
        }
        model.sidebarCollapsed = false

        // 6. Dark mode, Calendar, a content trigger.
        w.appearance = NSAppearance(named: .darkAqua)
        model.screen = .calendar
        try await settle(1600)
        let week = anchors(in: w).filter { ($0.visibleScreenRect?.minX ?? 0) > w.frame.minX + 300 && ($0.visibleScreenRect?.maxY ?? 0) < w.frame.maxY - 80 }
        if let d = week.first {
          opened = try await hover(d)
          try await record("06-dark-week-content", d, opened: opened, note: "dark: light bubble, no shadow")
          try await park()
        }

        // 7. Window pushed into the screen's top-right corner: toolbar's last trigger must flip below and shift left.
        w.appearance = NSAppearance(named: .aqua)
        model.screen = .queue
        w.setFrameTopLeftPoint(NSPoint(x: screen.maxX - w.frame.width, y: screen.maxY))
        try await settle(1600)
        if let last = anchors(in: w).filter({ ($0.visibleScreenRect?.maxY ?? 0) > w.frame.maxY - 60 })
          .max(by: { ($0.visibleScreenRect?.maxX ?? 0) < ($1.visibleScreenRect?.maxX ?? 0) }) {
          opened = try await hover(last)
          try await record("07-window-at-screen-top-right-corner", last, opened: opened, note: "window flush with screen top + right edges")
          try await park()
        }

        // 8. Every tooltip type on every page, through the same hover path: the hovered tile's controls (video-preview
        // buttons, score badge, select circle), a disabled trigger (label + why), a shortcut (keycaps) and plain text.
        // Each is captured on hover and again after the pointer leaves; the bubble must hold text and then be gone.
        w.setFrameOrigin(NSPoint(x: screen.midX - 720, y: screen.midY - 450))
        let pages: [(String, Screen, DSViewMode?, NSAppearance.Name)] = [
          ("library-grid", .library, .grid, .aqua), ("queue-grid", .queue, .grid, .aqua), ("edit-grid", .edit, .grid, .aqua),
          ("score-grid", .score, .grid, .aqua), ("queue-cards", .queue, .wide, .aqua), ("edit-cards", .edit, .wide, .aqua),
          ("calendar", .calendar, nil, .aqua), ("calendar-3day", .calendar, nil, .aqua), ("calendar-month", .calendar, nil, .aqua),
          ("calendar-day", .calendar, nil, .aqua), ("posts", .posts, nil, .aqua), ("health", .health, nil, .aqua),
          ("library-grid-dark", .library, .grid, .darkAqua), ("queue-grid-dark", .queue, .grid, .darkAqua),
        ]
        for (page, scr, mode, look) in pages {
          SnapshotContext.resetUI(model)
          DSClipCardDebug.hoverIds = []
          w.appearance = NSAppearance(named: look)
          if let mode { model.viewModes[scr] = mode }
          model.calendarMode = ["calendar-3day": .threeDay, "calendar-month": .month, "calendar-day": .day][page] ?? .week
          model.screen = scr
          try await settle(1600)
          let before = anchors(in: w)
          var picks: [DSTooltipAnchorView] = []
          if mode == .grid || mode == .wide, let first = model.visibleIds[scr]?.first {
            DSClipCardDebug.hoverIds = [first]
            model.screen = scr == .library ? .health : .library
            try await Task.sleep(for: .milliseconds(50))
            model.screen = scr
            try await settle(1200)
            // The hovered tile's own controls: one per label that only appears (or appears once more) while hovered.
            var seen: [String: Int] = [:]
            for a in before { seen[legend(a), default: 0] += 1 }
            for a in anchors(in: w) {
              let k = legend(a)
              if (seen[k] ?? 0) > 0 { seen[k]! -= 1 } else if !picks.contains(where: { legend($0) == k }) { picks.append(a) }
            }
            tilePicks[page] = picks.count
          }
          let rest = anchors(in: w).filter { a in !picks.contains { $0 === a } }
          if !sawReason, let r = rest.first(where: { !($0.content.disabledReason ?? "").isEmpty }) { picks.append(r); sawReason = true }
          if !sawKeys, let k = rest.first(where: { !($0.content.shortcut ?? "").isEmpty }) { picks.append(k); sawKeys = true }
          let content = rest.filter { ($0.visibleScreenRect?.minX ?? 0) > w.frame.minX + 300 && ($0.visibleScreenRect?.maxY ?? 0) < w.frame.maxY - 80 }
          if let p = content.first(where: { a in !picks.contains { $0.content == a.content } }) { picks.append(p) }
          for a in picks {
            let slug = (a.content.label ?? a.content.disabledReason ?? "").lowercased()
              .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(28)
            let name = String(format: "%02d-%@-%@", n, page, String(slug))
            n += 1
            let opened = try await hover(a)
            try await record(name + "-hover", a, opened: opened, note: "\(page): hover")
            let presented = c.debugPresented
            await post(.mouseMoved, at: emptyPoint(in: w), in: w)  // leave to a spot with no trigger under it
            try await Task.sleep(for: .milliseconds(400))
            // Gone, and nothing (a parent trigger's bubble) opened on the way out.
            let hidden = c.debugPanelFrame == nil && c.debugPanelWindow?.isVisible != true && c.debugPresented == presented
            records[records.count - 1].hiddenAfterLeave = hidden
            try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent(name + "-left.png"))
            try await park()
          }
        }
      }
      DSClipCardDebug.hoverIds = []
      w.appearance = NSAppearance(named: .aqua)

      // 8b. Badges over a playing preview (v0.7.1): a Library tile plays its proxy, in its hover state, under its score
      // and length badges. Both must open like every other case, over a drawn video frame (not the poster), with no
      // AppKit view (the player) over them at their centre.
      var playingMissing: [String] = []
      if !r6Only {
        SnapshotContext.resetUI(model)
        model.viewModes[.library] = .grid
        model.screen = .library
        try await settle(1600)
        let shorts = (model.visibleIds[.library] ?? []).filter { model.videoById[$0]?.type == .short && model.videoById[$0]?.missing == false }
        if let id = shorts.first, let url = await makeProxy(model, id) {
          let saved = model.playback
          model.proxyURLs[id] = url
          model.playback.gridHoverOnly = false  // in memory only: plays without a pointer (never saved)
          DSClipCardDebug.hoverIds = [id]
          model.screen = .health
          try await Task.sleep(for: .milliseconds(50))
          model.screen = .library
          try await settle(1200)
          var player: DSPlayerNSView?
          for _ in 0..<50 where player == nil {
            player = playerViews(in: w).first { $0.isShowingVideo && $0.visibleRect.width > 1 }
            if player == nil { try await Task.sleep(for: .milliseconds(100)) }
          }
          if let player, let pr = player.window.map({ $0.convertToScreen(player.convert(player.bounds, to: nil)) }) {
            let over = anchors(in: w).filter { a in
              guard let r = a.visibleScreenRect, pr.contains(CGPoint(x: r.midX, y: r.midY)) else { return false }
              return a.content.label?.hasPrefix("Score ") == true || a.content.label?.hasPrefix("Length ") == true
            }
            if over.count < 2 { playingMissing.append("playing tile: score and length badges not found over the video (\(over.count))") }
            for a in over {
              let slug = (a.content.label ?? "").lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(28)
              let name = String(format: "%02d-%@-%@", n, "library-playing", String(slug))
              n += 1
              let cover = coveringView(a, in: w)
              let opened = try await hover(a)
              try await record(name + "-hover", a, opened: opened,
                               note: "library-playing: hover over a playing preview" + (cover.map { " · COVERED by \(type(of: $0))" } ?? ""))
              if let cover { playingMissing.append("\(name): \(type(of: cover)) is over the badge") }
              if !player.isShowingVideo { playingMissing.append("\(name): the video stopped drawing") }
              let presented = c.debugPresented
              await post(.mouseMoved, at: emptyPoint(in: w), in: w)
              try await Task.sleep(for: .milliseconds(400))
              records[records.count - 1].hiddenAfterLeave = c.debugPanelFrame == nil && c.debugPanelWindow?.isVisible != true
                && c.debugPresented == presented
              try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent(name + "-left.png"))
              try await park()
            }
          } else {
            playingMissing.append("playing tile: its video never drew (proxy \(url.lastPathComponent))")
          }
          model.playback = saved
          model.proxyURLs[id] = nil
          DSClipCardDebug.hoverIds = []
        } else {
          playingMissing.append("playing tile: no proxy could be made for the first short clip")
        }
      }
      problems += playingMissing

      // 9. Round 6 (Postiz): the sidebar's Test run row, then Settings → Publishing with no key — the disabled
      // "Postiz" segment (label + why), the "Channel disabled" status badge and a platform's detail chevron. Each must be
      // reached and pass like every other case.
      var r6Missing: [String] = []
      do {
        SnapshotContext.resetUI(model)
        if var st = try? model.store.settings() {
          st.publishing.testMode = true
          try? model.store.save(st)
        }
        model.postiz.hasKey = false
        model.refreshNow()
        model.screen = .queue
        try await settle(1600)
        func probeOne(_ page: String, _ want: (DSTooltipAnchorView) -> Bool, _ what: String) async throws {
          guard let a = anchors(in: w).first(where: want) else { r6Missing.append("\(page): \(what) not found"); return }
          let slug = (a.content.label ?? a.content.disabledReason ?? "").lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(28)
          let name = String(format: "%02d-%@-%@", n, page, String(slug))
          n += 1
          let opened = try await hover(a)
          try await record(name + "-hover", a, opened: opened, note: "\(page): \(what)")
          let presented = c.debugPresented
          await post(.mouseMoved, at: emptyPoint(in: w), in: w)
          try await Task.sleep(for: .milliseconds(400))
          records[records.count - 1].hiddenAfterLeave = c.debugPanelFrame == nil && c.debugPanelWindow?.isVisible != true
            && c.debugPresented == presented
          try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent(name + "-left.png"))
          try await park()
        }
        try await probeOne("r6-sidebar", { $0.content.label == TestRunBadge.help }, "Test run row")
        SettingsUIState.shared.reset()
        model.settingsSection = .publishing
        model.showSettings = true
        try await settle(1600)
        try await probeOne("r6-publishing", { ($0.content.disabledReason ?? "").hasPrefix("Add your Postiz API key") && $0.content.label?.hasPrefix("Postiz posts") == true },
                           "disabled Postiz segment")
        try await probeOne("r6-publishing", { $0.content.label?.hasSuffix("needs reconnecting in Postiz") == true }, "Channel disabled badge")
        try await probeOne("r6-publishing", { $0.content.label?.hasPrefix("Show ") == true && $0.content.label?.hasSuffix("Postiz options") == true },
                           "platform detail chevron")
        model.showSettings = false
        if var st = try? model.store.settings() {
          st.publishing.testMode = false
          try? model.store.save(st)
        }
        model.refreshNow()
      }
      problems += r6Missing

      // A hover that opened nothing, an empty bubble, or a bubble that stayed (or another that opened) after leaving
      // fails the run — and so does a sweep that didn't reach what it covers: each grid's hovered-tile buttons, a
      // disabled trigger and a keycaps trigger.
      for r in records where r.name.hasSuffix("-hover") && (r.bubble == nil || (r.textPixels ?? 0) < 12 || r.hiddenAfterLeave != true) {
        problems.append("\(r.name) · bubble \(r.bubble == nil ? "none" : "shown") · text px \(r.textPixels ?? 0) · hidden after leave \(r.hiddenAfterLeave.map { "\($0)" } ?? "-")")
      }
      for (page, label) in r6Only ? [] : [("library-grid", "Preview the clip and its status"), ("queue-grid", QueueClipActions.postTodayHelp),
                            ("edit-grid", EditClipActions.openHelp), ("library-grid-dark", "Preview the clip and its status"),
                            ("queue-grid-dark", QueueClipActions.postTodayHelp)]
      where !records.contains(where: { $0.note == "\(page): hover" && $0.label == label }) {
        problems.append("\(page): its hovered tile's \"\(label)\" button wasn't reached (tile picks: \(tilePicks[page] ?? 0))")
      }
      if !sawReason && !r6Only { problems.append("no disabled trigger (label + why) was reached") }
      if !sawKeys && !r6Only { problems.append("no keycaps trigger was reached") }
      problems.forEach { print("tooltip-probe: FAIL \($0)") }

      try JSONEncoder.pretty.encode(records).write(to: out.appendingPathComponent("probe.json"))
      print("tooltip-probe: \(records.count) cases → \(out.path) (SwiftUI hover-ins: \(c.debugHoverEvents), forwarded moves: \(forwarded), "
            + "real-cursor hovers dropped: \(c.debugRealCursorHovers))")
      w.orderOut(nil)
      w.close()
      return problems.isEmpty ? 0 : 1
    } catch {
      FileHandle.standardError.write(Data("tooltip-probe failed: \(error)\n".utf8))
      return 1
    }
  }

  /// A trigger nested in another (a probe-only fixture in its own small window). Leaving both at once must not open
  /// the parent's bubble on the way out (the round-5 flash), and moving from the inner one onto the parent must
  /// open the parent's at once (delay group). Returns what failed.
  static func nested(out: URL) async throws -> [String] {
    let c = DSTooltipController.shared
    c.requireActiveApp = false
    c.simulatedPointer = offscreen
    let fixture = DS.color.surface.frame(width: 320, height: 200)
      .overlay { DS.color.hover.frame(width: 90, height: 44).dsTooltip("Inner trigger") }
      .dsTooltip("Outer trigger")
      .frame(width: 420, height: 280)
    .background(DS.color.surfaceRaised)
    let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let w = SnapshotWindow.make(NSRect(x: screen.midX - 210, y: screen.midY - 140, width: 420, height: 280), [.borderless])
    w.isReleasedWhenClosed = false
    w.contentView = NSHostingView(rootView: fixture)
    w.ignoresMouseEvents = true
    w.orderFrontRegardless()
    defer { w.orderOut(nil); w.close() }
    try await Task.sleep(for: .milliseconds(900))
    w.displayIfNeeded()
    let all = anchors(in: w)
    guard let inner = all.first(where: { $0.content.label == "Inner trigger" }), let outer = all.first(where: { $0.content.label == "Outer trigger" }),
          let ir = inner.visibleScreenRect, let or = outer.visibleScreenRect else { return ["nested: fixture triggers not found"] }
    var problems: [String] = []
    func wait(for a: DSTooltipAnchorView, ms: Int) async throws -> Int? {
      let start = Date()
      while Date().timeIntervalSince(start) * 1000 < Double(ms) {
        if c.debugShown === a, c.debugPanelFrame != nil { return Int(Date().timeIntervalSince(start) * 1000) }
        try await Task.sleep(for: .milliseconds(10))
      }
      return nil
    }
    // 1. Inner open, then leave both at once: nothing else may open.
    await post(.mouseMoved, at: CGPoint(x: ir.midX, y: ir.midY), in: w)
    if try await wait(for: inner, ms: 1500) == nil { problems.append("nested: inner bubble didn't open") }
    try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent("00-nested-inner-hover.png"))
    let presented = c.debugPresented
    await post(.mouseMoved, at: CGPoint(x: w.frame.minX + 8, y: w.frame.minY + 8), in: w)
    try await Task.sleep(for: .milliseconds(400))
    if c.debugPresented != presented || c.debugPanelFrame != nil { problems.append("nested: the parent's bubble opened while leaving both") }
    try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent("00-nested-left-both.png"))
    c.hide(resetGroup: true)
    try await Task.sleep(for: .milliseconds(450))
    // 2. Inner open, then onto the parent only: the parent's opens at once.
    await post(.mouseMoved, at: CGPoint(x: ir.midX, y: ir.midY), in: w)
    _ = try await wait(for: inner, ms: 1500)
    await post(.mouseMoved, at: CGPoint(x: or.minX + 20, y: or.midY), in: w)
    if (try await wait(for: outer, ms: 150)) == nil { problems.append("nested: moving onto the parent didn't open its bubble at once") }
    try capture(w, panel: c.debugPanelWindow)?.write(to: out.appendingPathComponent("00-nested-onto-parent.png"))
    await post(.mouseMoved, at: CGPoint(x: w.frame.minX + 8, y: w.frame.minY + 8), in: w)
    c.hide(resetGroup: true)
    c.simulatedPointer = offscreen
    try await Task.sleep(for: .milliseconds(450))
    print("tooltip-probe: nested · \(problems.isEmpty ? "pass" : problems.joined(separator: "; "))")
    return problems
  }

  enum ProbeError: Error { case noAnchors(String) }

  /// A proxy for `id` in the run's throwaway support folder (made with ffmpeg if it isn't cached; the source is
  /// only read). nil when it can't be made.
  static func makeProxy(_ model: AppModel, _ id: String) async -> URL? {
    let range = model.playback.loop
    if let u = model.proxies.cachedProxy(videoId: id, range: range) { return u }
    return await withCheckedContinuation { cont in
      model.proxies.request(id, priority: .visible, range: range) { r in cont.resume(returning: try? r.get()) }
    }
  }

  static func playerViews(in w: NSWindow) -> [DSPlayerNSView] {
    var found: [DSPlayerNSView] = []
    func walk(_ v: NSView) {
      if let p = v as? DSPlayerNSView { found.append(p) }
      v.subviews.forEach(walk)
    }
    if let root = w.contentView { walk(root) }
    return found
  }

  /// The AppKit view that takes the pointer at the trigger's centre when it isn't SwiftUI's own content — e.g. a
  /// video player view over a badge, which would take its clicks and hover in the app. nil = the trigger is on top.
  static func coveringView(_ a: DSTooltipAnchorView, in w: NSWindow) -> NSView? {
    guard let r = a.visibleScreenRect, let root = w.contentView else { return nil }
    let pw = w.convertPoint(fromScreen: CGPoint(x: r.midX, y: r.midY))
    guard let hit = root.hitTest(root.superview?.convert(pw, from: nil) ?? pw) else { return nil }
    var v: NSView? = hit
    while let x = v {
      if x is DSPlayerNSView { return x }
      v = x.superview
    }
    return nil
  }

  // MARK: Helpers

  /// The real model on a throwaway copy of the dev DB (never the source DB), seeded like SnapshotRunner.
  /// Throwaway DB folders this run created (and only those) — removed by `cleanUp()` when the run ends.
  static var scratchDirs: [URL] = []

  static func cleanUp() {
    for d in scratchDirs { try? FileManager.default.removeItem(at: d) }
    scratchDirs = []
  }

  static func makeModel() throws -> AppModel {
    let src = Paths.standard
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-tooltip-probe-\(UUID().uuidString)")
    scratchDirs.append(tmp)
    let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                      launchAgents: tmp.appendingPathComponent("LaunchAgents"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src.thumbs, withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
    if FileManager.default.fileExists(atPath: src.database.path) { try Store(paths: src).db.backup(to: paths.database.path) }
    let dm = DayMath(settings: AppSettings())
    let now = dm.at(dm.key(Date()), minutes: 16 * 60 + 10)
    let clock = FixedClock(now)
    let store = try Store(paths: paths, clock: clock)
    if try store.videos().isEmpty { try Intake(store: store).run() }
    try SampleData.seed(store: store, clock: clock, now: now)
    try SampleData.seedPostiz(store: store, clock: clock, now: now)
    clock.set(now)
    let model = AppModel(store: store)
    model.frozen = true
    model.now = now
    model.refreshNow()
    model.loaded = true
    return model
  }

  /// A point in the window's sidebar that no trigger covers (where "leaving" goes, so no other bubble opens).
  static func emptyPoint(in w: NSWindow) -> CGPoint {
    let rects = anchors(in: w).compactMap(\.visibleScreenRect)
    for f in stride(from: 0.45, to: 0.9, by: 0.03) {
      for x in [w.frame.minX + 130, w.frame.minX + 30, w.frame.midX] {
        let p = CGPoint(x: x, y: w.frame.maxY - w.frame.height * f)
        if !rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(p) }) { return p }
      }
    }
    return CGPoint(x: w.frame.midX, y: w.frame.minY + 2)
  }

  static func legend(_ a: DSTooltipAnchorView) -> String {
    [a.content.label, a.content.shortcut, a.content.disabledReason].map { $0 ?? "" }.joined(separator: "|")
  }

  static func anchors(in w: NSWindow) -> [DSTooltipAnchorView] {
    var found: [DSTooltipAnchorView] = []
    func walk(_ v: NSView) {
      if let a = v as? DSTooltipAnchorView, !a.content.isEmpty, a.visibleScreenRect != nil { found.append(a) }
      v.subviews.forEach(walk)
    }
    if let root = w.contentView?.superview ?? w.contentView { walk(root) }
    return found
  }

  /// Posts a real mouse-moved event to our own queue (never the user's cursor). AppKit derives tracking-area
  /// enter/exit from the window server's pointer, not from posted events; after 80 ms the probe hands the move to the
  /// tracking logic as the enter/exit pairs a real pointer there would produce, for whatever SwiftUI didn't deliver
  /// (counted as forwarded moves). SwiftUI events that followed the user's real cursor instead are dropped and counted.
  static func post(_ type: NSEvent.EventType, at screenPoint: CGPoint, in w: NSWindow) async {
    let c = DSTooltipController.shared
    c.simulatedPointer = screenPoint
    let before = c.debugHoverEvents
    let p = w.convertPoint(fromScreen: screenPoint)
    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
      NSApp.postEvent(e, atStart: false)
    }
    try? await Task.sleep(for: .milliseconds(80))
    // Reconcile either way: a SwiftUI hover-in in these 80 ms may belong to another trigger (SwiftUI also follows
    // the real cursor; `swiftUIHover` drops those), so it doesn't prove the move reached the triggers under the point.
    if c.debugPointerMoved(to: screenPoint, in: w), c.debugHoverEvents == before { forwarded += 1 }
  }

  /// Nowhere, until the probe's first move (real-cursor hovers before it are dropped too).
  static let offscreen = CGPoint(x: -100_000, y: -100_000)

  static var forwarded = 0

  private static func postKey(_ code: UInt16, in w: NSWindow) {
    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: code) {
      DSTooltipController.shared.debugHandle(e)
    }
  }

  private static func arr(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

  /// Counts the panel's pixels that contrast with the bubble's own fill (its median luminance): the text and keycaps.
  /// An empty bubble — the round-5 bug — scores ~0.
  static func textPixels(_ panel: NSWindow?) -> Int {
    guard let panel, panel.isVisible, let fromArray else { return 0 }
    var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(panel.windowNumber))]
    guard let arr = CFArrayCreate(nil, &ids, 1, nil) else { return 0 }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let r = panel.frame
    guard let img = fromArray(CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height), arr, 1 << 4)?
      .takeRetainedValue() else { return 0 }
    let rep = NSBitmapImageRep(cgImage: img)
    var lums: [CGFloat] = []
    for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
      for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
        guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), p.alphaComponent > 0.95 else { continue }
        lums.append(0.2126 * p.redComponent + 0.7152 * p.greenComponent + 0.0722 * p.blueComponent)
      }
    }
    guard !lums.isEmpty else { return 0 }
    let bg = lums.sorted()[lums.count / 2]
    return lums.filter { abs($0 - bg) > 0.35 }.count
  }

  /// Window-server composite of the main window plus the tooltip panel (own windows: no permission needed).
  private typealias FromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
  private static let fromArray: FromArray? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let sym = dlsym(h, "CGWindowListCreateImageFromArray") else { return nil }
    return unsafeBitCast(sym, to: FromArray.self)
  }()

  private static func capture(_ w: NSWindow, panel: NSWindow?) -> Data? {
    guard let img = captureImage(w, panel: panel) else { return WindowCapture.png(w) }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
  }

  /// The window server's image of `w` (plus `panel` when visible), framed by the window: own windows need no
  /// Screen Recording permission.
  static func captureImage(_ w: NSWindow, panel: NSWindow?) -> CGImage? {
    // The tooltip panel, any sheet on the window, then the window itself (front to back).
    let wins = [panel?.isVisible == true ? panel : nil, w.attachedSheet, w].compactMap { $0 }
    var ids: [UnsafeRawPointer?] = wins.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
    guard let fromArray, let arr = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    var r = w.frame
    if let s = w.attachedSheet { r = r.union(s.frame) }
    let cg = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    guard let img = fromArray(cg, arr, 1 << 4)?.takeRetainedValue(), img.width > 10 else { return nil }
    return img
  }

}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
  }
}
