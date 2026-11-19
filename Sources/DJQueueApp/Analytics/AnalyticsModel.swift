import DJQCore
import Observation
import SwiftUI

/// Chart colours (round 39). The app has no platform colours (DESIGN-v2 §2.1: a platform is a glyph and a name), but a
/// chart that splits by platform needs one hue per platform. These are the data-viz reference categorical slots 1–6,
/// light and dark each validated against our surfaces (#FFFFFF, #2F2F2F) for colour-blind and normal-vision
/// separation; the contrast warning on three light slots is why every chart also carries a legend with names and a
/// table. A platform keeps its hue in every chart, whatever the filter (colour follows the entity, never its rank).
extension DS {
  enum chart {
    static func color(_ p: Platform) -> Color {
      switch p {
      case .tiktok: Color(light: 0x2A78D6, dark: 0x3987E5)  // slot 1 blue
      case .instagram: Color(light: 0xEB6834, dark: 0xD95926)  // slot 2 orange
      case .youtube: Color(light: 0x1BAF7A, dark: 0x199E70)  // slot 3 aqua
      case .facebook: Color(light: 0xEDA100, dark: 0xC98500)  // slot 4 yellow
      case .threads: Color(light: 0xE87BA4, dark: 0xD55181)  // slot 5 magenta
      case .x: Color(light: 0x008300, dark: 0x0CA30C)  // slot 6 green
      }
    }
    /// Legend and stack order: the slot order above.
    static let order: [Platform] = [.tiktok, .instagram, .youtube, .facebook, .threads, .x]
    /// One-hue sequential ramp (blue 100…650) for the posting heatmap; index 0 = nothing posted.
    static let heat: [Color] = [
      Color(light: 0xF3F3F3, dark: 0x2A2A2A),
      Color(light: 0xCDE2FB, dark: 0x184F95), Color(light: 0x9EC5F4, dark: 0x1C5CAB),
      Color(light: 0x6DA7EC, dark: 0x256ABF), Color(light: 0x3987E5, dark: 0x3987E5), Color(light: 0x1C5CAB, dark: 0x6DA7EC),
    ]
    /// Emphasis: the one series that matters.
    static let accent = Color(light: 0x2A78D6, dark: 0x3987E5)
    /// Second series in two-way comparisons (first post vs repost).
    static let second = Color(light: 0xEB6834, dark: 0xD95926)
    /// De-emphasised context (every single post behind its median).
    static let context = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.14)
    static let grid = Color(light: 0xE1E0D9, dark: 0x3A3A3A)
  }
}

/// The Analytics screen's state (round 39): the period, the platforms, the metric tab, and the built report. The
/// report is built off the main thread from the database each time the app reloads or a choice changes.
@MainActor @Observable
final class AnalyticsProbe {
  static let shared = AnalyticsProbe()

  var range: AnalyticsRange = .d30 { didSet { remember() } }
  var platforms: Set<Platform> = [] { didSet { remember() } }
  var metric: AnalyticsReport.KPIId = .views
  var report: AnalyticsReport?
  var loading = false
  var refreshing = false
  /// Which channel metric each platform's small chart shows.
  var channelMetric: [Platform: String] = [:]
  private var building: Task<Void, Never>?

  init() {
    if let r = UserDefaults.standard.string(forKey: "analytics.range").flatMap(AnalyticsRange.init(rawValue:)) { range = r }
    if let p = UserDefaults.standard.array(forKey: "analytics.platforms") as? [String] { platforms = Set(p.compactMap(Platform.init(rawValue:))) }
  }

  private func remember() {
    guard !AppModel.isSnapshotRun else { return }
    UserDefaults.standard.set(range.rawValue, forKey: "analytics.range")
    UserDefaults.standard.set(platforms.map(\.rawValue), forKey: "analytics.platforms")
  }

  func load(_ model: AppModel) async {
    let (store, range, platforms, now) = (model.store, range, platforms, model.now)
    if model.frozen {
      report = try? AnalyticsReport.build(store: store, range: range, platforms: platforms, now: now)
      return
    }
    loading = report == nil
    let r = await Task.detached(priority: .userInitiated) {
      try? AnalyticsReport.build(store: store, range: range, platforms: platforms, now: now)
    }.value
    // A slower build for choices since changed never replaces the newer one.
    guard !Task.isCancelled, range == self.range, platforms == self.platforms else { return }
    if let r { report = r }
    loading = false
  }

  /// "Refresh numbers": a budgeted pull of what's due (and posts not asked for 6 h), then a rebuild.
  func pullNow(_ model: AppModel) {
    guard !refreshing else { return }
    refreshing = true
    let svc = model.postizBridge.service
    Task.detached {
      let r = Result { try svc.analytics(force: true, limit: 12) }
      await MainActor.run {
        self.refreshing = false
        switch r {
        case .success(let s):
          model.show(s.isEmpty ? "Nothing new: numbers are up to date, or this hour's Postiz budget is in use" : "Pulled \(s)")
        case .failure(let e):
          model.show("Couldn't reach Postiz: \(e.localizedDescription)", error: true)
        }
        model.refresh()
      }
    }
  }

  func togglePlatform(_ p: Platform) {
    if platforms.contains(p) { platforms.remove(p) } else { platforms.insert(p) }
    if platforms.count == Platform.allCases.count { platforms = [] }
  }
}
