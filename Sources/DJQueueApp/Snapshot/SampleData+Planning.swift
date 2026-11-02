import DJQCore
import Foundation

/// Planning-leaf snapshot data: a SECOND throwaway model ("sandbox"), copied from the seeded snapshot DB, for
/// states the shared sample model must not be changed into (other leaves' shots render from it afterwards):
/// next week approved, and a day with nothing due. Lives inside the snapshot runner's temp folder, so it is
/// deleted with it. Never touches a real database.
extension SampleData {
  @MainActor
  static func planningSandbox(_ c: SnapshotContext) -> AppModel? {
    do {
      let src = c.store.paths
      let tmp = src.appSupport.deletingLastPathComponent().appendingPathComponent("planning-\(UUID().uuidString.prefix(8))")
      let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      try? FileManager.default.createSymbolicLink(at: paths.thumbs, withDestinationURL: src.thumbs)
      try c.store.db.backup(to: paths.database.path)
      let store = try Store(paths: paths, clock: FixedClock(c.now))
      let dm = DayMath(settings: try store.settings())
      let today = dm.key(c.now)

      // Next week approved (posts created by the real planner).
      let nextWeek = dm.addDays(dm.weekStart(of: c.now), 7)
      try Planner(store: store).approveWeek(nextWeek)

      // Nothing due today: drop today's posts and settle earlier leftovers.
      try store.db.run("DELETE FROM platform_posts WHERE scheduled_at>=? AND scheduled_at<?",
                       [dm.date(today), dm.date(dm.addDays(today, 1))])
      try store.db.run("UPDATE platform_posts SET state='skipped' WHERE scheduled_at<? AND state IN ('due','overdue')", [dm.date(today)])
      for v in try store.videos() { try store.refreshState(videoId: v.id) }

      let m = AppModel(store: store)
      m.frozen = true
      m.now = c.now
      m.refreshNow()
      m.weekStart = nextWeek
      // AppModel.init points the shared cover cache at its store; covers belong to the main sample store.
      ThumbCache.shared.store = c.store
      return m
    } catch {
      FileHandle.standardError.write(Data("planning sandbox failed: \(error)\n".utf8))
      ThumbCache.shared.store = c.store
      return nil
    }
  }
}
