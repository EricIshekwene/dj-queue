import DJQCore
import Foundation

/// Planning-leaf snapshot data: throwaway models copied from the seeded snapshot DB, for states the shared sample
/// model must not be changed into (other leaves' shots render from it afterwards). They live inside the snapshot
/// runner's temp folder, so they are deleted with it. Never touches a real database.
extension SampleData {
  @MainActor
  private static func sandbox(_ c: SnapshotContext, name: String, from source: Store? = nil,
                              _ change: (Store, DayMath, String) throws -> Void) -> AppModel? {
    do {
      let src = c.store.paths
      let tmp = src.appSupport.deletingLastPathComponent().appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
      let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      try? FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
      try (source ?? c.store).db.backup(to: paths.database.path)
      let store = try Store(paths: paths, clock: FixedClock(c.now))
      let dm = DayMath(settings: try store.settings())
      try change(store, dm, dm.key(c.now))
      for v in try store.videos() { try store.refreshState(videoId: v.id) }
      let m = AppModel(store: store)
      m.frozen = true
      m.now = c.now
      m.refreshNow()
      // AppModel.init points the shared cover cache at its store; covers belong to the main sample store.
      ThumbCache.shared.store = c.store
      return m
    } catch {
      FileHandle.standardError.write(Data("\(name) sandbox failed: \(error)\n".utf8))
      ThumbCache.shared.store = c.store
      return nil
    }
  }

  /// Nothing going out today, and only three days scheduled with an empty Queue ("Queue running low").
  @MainActor
  static func planningSandbox(_ c: SnapshotContext) -> AppModel? {
    sandbox(c, name: "planning") { store, dm, today in
      try store.db.run("DELETE FROM platform_posts WHERE scheduled_at>=? AND scheduled_at<?", [dm.date(today), dm.date(dm.addDays(today, 1))])
      try store.db.run("DELETE FROM plan_slots WHERE date=?", [today])
      try store.db.run("UPDATE platform_posts SET state='skipped' WHERE scheduled_at<? AND state IN ('due','overdue')", [dm.date(today)])
      try store.db.run("DELETE FROM platform_posts WHERE scheduled_at>=?", [dm.date(dm.addDays(today, 3))])
      try store.db.run("DELETE FROM plan_slots WHERE date>=?", [dm.addDays(today, 3)])
      for v in try Queue(store: store).ordered() { try store.setExcluded(v.id, true) }
    }
  }

  /// Today's clip with nothing posted yet, so a clip moved onto today swaps with it (the ask-first sheet).
  @MainActor
  static func askFirstSandbox(_ c: SnapshotContext) -> AppModel? {
    sandbox(c, name: "ask") { store, dm, today in
      try store.db.run("UPDATE platform_posts SET state='planned', url=NULL, posted_at=NULL WHERE scheduled_at>=? AND scheduled_at<?",
                       [dm.date(today), dm.date(dm.addDays(today, 1))])
    }
  }

  /// Tomorrow's X post was deleted in Postiz (its job is final), so the clip refuses to move. From the Postiz sample.
  @MainActor
  static func removedInPostizSandbox(_ c: SnapshotContext) -> AppModel? {
    sandbox(c, name: "removed", from: c.postiz.store) { store, dm, today in
      let tomorrow = dm.addDays(today, 1)
      guard let p = try store.posts(where: "platform='x' AND scheduled_at>=? AND scheduled_at<?", [dm.date(tomorrow), dm.date(dm.addDays(tomorrow, 1))]).first else { return }
      try store.db.run("UPDATE postiz_jobs SET closed_at=?, final=1, close_reason='vanished' WHERE post_id=?", [c.now, p.id])
    }
  }

  /// A plain copy, for shots that change data.
  @MainActor
  static func scratchSandbox(_ c: SnapshotContext) -> AppModel? { sandbox(c, name: "scratch") { _, _, _ in } }

  /// Two clips a day from today on, so cards stack and month cells overflow.
  @MainActor
  static func denseCalendarSandbox(_ c: SnapshotContext) -> AppModel? {
    sandbox(c, name: "dense") { store, dm, today in
      var st = try store.settings()
      st.postsPerDay = 3
      try store.save(st)
      var pool = try Queue(store: store).ordered()
      // Two stay waiting, with the schedule reaching the horizon ("N in Queue waiting").
      if let last = pool.popLast() {
        let day = dm.addDays(today, Planner.autoScheduleHorizonDays)
        let week = dm.weekStart(of: dm.date(day))
        if try store.week(week) == nil { try store.save(Week(weekStart: week, state: .draft, approvedAt: nil)) }
        try store.save(PlanSlot(id: newId(), date: day, position: 0, videoId: last.id, pinned: false, weekStart: week))
      }
      pool.removeLast(min(2, pool.count))
      for d in 0..<21 {
        let day = dm.addDays(today, d)
        let used = Set(try store.planSlots(where: "date=?", [day]).map(\.position))
        for pos in 0..<(d % 3 == 0 ? 3 : 2) where !used.contains(pos) && !pool.isEmpty {
          let v = pool.removeFirst()
          let week = dm.weekStart(of: dm.date(day))
          if try store.week(week) == nil { try store.save(Week(weekStart: week, state: .draft, approvedAt: nil)) }
          try store.save(PlanSlot(id: newId(), date: day, position: pos, videoId: v.id, pinned: false, weekStart: week))
        }
      }
    }
  }
}
