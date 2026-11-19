import DJQCore
import SwiftUI

/// ANALYTICS shots (round 39, prefix 4x): the screen on the analytics sample (all platforms; TikTok alone; the
/// Likes tab), the whole board drawn at once for the README, and the empty state.
extension SnapshotShots {
  static func analytics(_ c: SnapshotContext) -> [Shot] {
    let probe = AnalyticsProbe.shared
    func open(_ m: AppModel, range: AnalyticsRange = .d90, platforms: Set<Platform> = [], metric: AnalyticsReport.KPIId = .views) {
      probe.range = range
      probe.platforms = platforms
      probe.metric = metric
      probe.channelMetric = [:]
      probe.report = try? AnalyticsReport.build(store: m.store, range: range, platforms: platforms, now: m.now)
      m.screen = .analytics
    }
    func board(_ m: AppModel, _ platforms: Set<Platform>, metric: AnalyticsReport.KPIId) -> AnyView {
      open(m, platforms: platforms, metric: metric)
      guard let r = probe.report else { return AnyView(Text("no report")) }
      return AnyView(AnalyticsBoard(model: m, report: r).padding(DS.space.xl))
    }
    let a = c.analytics
    return [
      c.main("40-analytics", a) { m in open(m) },
      c.main("41-analytics-30d-likes", a) { m in open(m, range: .d30, metric: .likes) },
      c.main("42-analytics-tiktok", a) { m in open(m, platforms: [.tiktok]) },
      c.main("43-analytics-empty", c.empty) { m in open(m) },
      c.view("44-analytics-board", width: 1280) { board(a, [], metric: .views) },
      c.view("45-analytics-board-tiktok", width: 1280) { board(a, [.tiktok], metric: .posts) },
    ]
  }
}
