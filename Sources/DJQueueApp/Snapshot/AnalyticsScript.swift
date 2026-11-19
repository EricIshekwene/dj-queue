import AppKit
import DJQCore
import SwiftUI

/// `DJQ_ANALYTICS_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 39): the Analytics screen clicked through in the real
/// main window, off every display, on the analytics sample (twelve weeks of made-up history). Real clicks on the metric
/// tabs, a platform chip and a Top clips row; the period is set the way its segmented control sets it (a labelled
/// stand-in: the script can't aim at one segment of the capsule). Then Library's Most views order and views tags, and
/// a post's numbers in the Posts inspector. `DJQ_ANALYTICS_SABOTAGE=1` drops every snapshot first, so the number
/// checks must fail.
@MainActor
enum AnalyticsScript {
  static func run(model: AppModel, store: Store, out: URL) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let look = env["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark" ? "dark" : "light"
    var failures = 0
    var log: [String] = []
    func note(_ s: String) { print("analytics-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      note("\(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }
    defer { try? log.joined(separator: "\n").write(to: out.appendingPathComponent("analytics-checks-\(look).txt"), atomically: true, encoding: .utf8) }
    if env["DJQ_ANALYTICS_SABOTAGE"] != nil {
      _ = try? store.db.run("DELETE FROM post_metric_snapshots")
      note("sabotage: every snapshot deleted")
    }
    model.refreshNow()
    let probe = AnalyticsProbe.shared
    probe.range = .d90
    probe.platforms = []
    probe.metric = .views
    probe.report = nil

    SnapshotContext.resetUI(model)
    model.screen = .analytics
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
      await wait(800)
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "analytics-%02d-%@-%@.png", step, name, look))
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
    func click(_ label: String) async -> Bool {
      guard let a = anchor(host, ScriptAnchor.prefix + label) else { note("no control “\(label)”"); return false }
      let f = a.convert(a.bounds, to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: f.midX, y: f.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait(600)
      return true
    }
    /// Waits for the report the screen builds for the current choices.
    func report(_ ok: (AnalyticsReport) -> Bool = { _ in true }) async -> AnalyticsReport? {
      for _ in 0..<80 { if let r = probe.report, ok(r) { return r }; await wait(100) }
      return probe.report
    }
    func scrollView(_ v: NSView) -> NSScrollView? {
      if let s = v as? NSScrollView, s.documentView.map({ $0.frame.height > 1500 }) == true { return s }
      for c in v.subviews { if let hit = scrollView(c) { return hit } }
      return nil
    }
    func scroll(to y: CGFloat) async {
      guard let s = scrollView(host), let doc = s.documentView else { note("no scroll view"); return }
      let top = doc.isFlipped ? y : doc.frame.height - s.contentView.bounds.height - y
      s.contentView.scroll(to: NSPoint(x: 0, y: max(0, top)))
      s.reflectScrolledClipView(s.contentView)
      await wait(500)
    }

    // 1. The screen opens on every platform, 90 days, Views.
    let r0 = await report()
    let views0 = r0?.kpis.first { $0.id == .views }?.value ?? 0
    check("the report is built", r0 != nil)
    check("views were gained in the period", views0 > 0)
    check("six metric tabs show", ["Views", "Likes", "Engagement", "Followers", "Posts", "Views / post"].allSatisfy { has("Analytics tab \($0)") })
    check("every platform has a chip", DS.chart.order.allSatisfy { has("Analytics platform \($0.displayName)") })
    check("consistency counts days posted", (r0?.consistency.activeDays ?? 0) > 0 && (r0?.consistency.longestStreak ?? 0) > 0)
    await shot("overview")

    // 2. A click on a tab charts that metric.
    check("Likes tab clicked", await click("Analytics tab Likes"))
    check("the chart shows likes", probe.metric == .likes)
    await shot("likes")
    check("Posts tab clicked", await click("Analytics tab Posts"))
    check("the chart shows posts", probe.metric == .posts)
    await shot("posts")

    // 3. The period (stand-in for the segmented control's click).
    note("stand-in: the 30D segment sets AnalyticsProbe.range, which is what its click sets")
    probe.range = .d30
    let r30 = await report { $0.range == .d30 }
    check("30 days: a day per bar", r30?.range == .d30 && r30?.timeline.count == 30)
    check("30 days: the change from the 30 days before shows", r30?.kpis.first { $0.id == .views }?.change != nil)
    await shot("30-days")

    // 4. One platform: a real click on its chip.
    check("TikTok chip clicked", await click("Analytics platform TikTok"))
    let rt = await report { $0.platforms == [.tiktok] }
    check("only TikTok is counted", rt?.platforms == [.tiktok])
    check("TikTok views are fewer than every platform's", (rt?.kpis.first { $0.id == .views }?.value ?? .infinity) < (r30?.kpis.first { $0.id == .views }?.value ?? 0))
    probe.metric = .views
    await shot("tiktok")
    await scroll(to: 1250)
    check("TikTok: every post's curve is there", (rt?.curves.posts.filter { $0.platform == .tiktok }.count ?? 0) > 5)
    await shot("tiktok-curves")

    // 5. Back to every platform; scroll the whole board.
    check("TikTok chip clicked again", await click("Analytics platform TikTok"))
    let rAll = await report { $0.platforms.count == 6 && $0.range == .d30 }
    check("every platform again", rAll?.platforms.count == 6)
    await scroll(to: 700)
    await shot("consistency")
    await scroll(to: 1700)
    check("a top clip row shows", has("Analytics clip 1"))
    await shot("top-clips")

    // 6. A top clip opens its preview with its numbers.
    check("top clip clicked", await click("Analytics clip 1"))
    await wait(600)
    check("its preview opened", model.previewVideo?.id == rAll?.topClips.first?.videoId)
    for _ in 0..<40 where !has("Clip performance") { await wait(100) }  // its numbers load after it opens
    check("the preview shows the clip's numbers", has("Clip performance"))
    await shot("clip-preview")
    model.previewVideo = nil
    await wait(400)

    // 7. Library: Most views (stand-in for the sort menu, a real NSMenu) and the views tag.
    note("stand-in: Library's sort menu is a system menu; setting ListPrefs' sort, which is what its item sets")
    ListPrefs.shared.setSort(.library, ClipSort.views.rawValue)
    model.setViewMode(.grid, for: .library)
    model.screen = .library
    await wait(1200)
    let shown = model.listSorted(.library, model.libraryAll.filter { $0.type == .short })
    let ordered = zip(shown, shown.dropFirst()).allSatisfy { (model.viewsByVideo[$0.id] ?? -1) >= (model.viewsByVideo[$1.id] ?? -1) }
    check("Library › Most views is in views order", ordered && (model.viewsByVideo[shown.first?.id ?? ""] ?? 0) > 0)
    await shot("library-most-views")
    ListPrefs.shared.setSort(.library, nil)

    // 8. Posts: a post's numbers over time in the inspector.
    let snapped = Set(((try? store.snapshotsByPost()) ?? [:]).filter { $0.value.count >= 3 }.keys)
    if let p = model.posts.filter({ snapped.contains($0.id) }).max(by: { ($0.postedAt ?? .distantPast) < ($1.postedAt ?? .distantPast) }) {
      ListPrefs.shared.setStatus(.posts, nil)
      model.postsSelection = p.id
      model.screen = .posts
      await wait(1500)
      for _ in 0..<40 where !has("Post numbers chart") { await wait(100) }
      check("the inspector draws the post's views over time", has("Post numbers chart"))
      await shot("post-inspector")
    } else {
      check("a post with three pulls exists", false)
    }

    note("\(failures == 0 ? "PASS" : "FAIL") analytics script: \(failures) failure(s)")
    return failures == 0 ? 0 : 1
  }
}
