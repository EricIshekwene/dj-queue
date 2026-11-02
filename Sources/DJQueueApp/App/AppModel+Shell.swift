import DJQCore
import SwiftUI

/// One attention card under a screen's toolbar (DESIGN-v2 §3). Danger cards can't be dismissed while
/// unresolved; warning cards with `dismissible` hide for 24 h (`dismissWarning(id)`).
struct AttentionItem: Identifiable {
  let id: String
  var tone: DSTone
  var title: String
  var message: String?
  var actionTitle: String?
  var dismissible = false
  var action: (() -> Void)?
}

/// Shell state: attention cards, sidebar counts, engine line, health dot.
extension AppModel {
  /// Cards shown on every screen (ScreenScaffold), loudest first.
  var attentionItems: [AttentionItem] {
    var out: [AttentionItem] = []
    if let e = loadError {
      out.append(.init(id: "load", tone: .danger, title: "Can't read the database", message: e, actionTitle: "Open Health",
                       action: { [weak self] in self?.screen = .health }))
    }
    if !problems.isEmpty {
      let n = problems.count
      out.append(.init(id: "problems", tone: .danger, title: "\(n) post\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention",
                       message: problemParts, actionTitle: "Review", action: { [weak self] in self?.reviewProblems() }))
    }
    if settings.paused {
      out.append(.init(id: "paused", tone: .warning, title: "Posting paused", message: "Nothing is handed to you until you resume",
                       actionTitle: "Resume", action: { [weak self] in self?.setPaused(false) }))
    }
    var soft: [AttentionItem] = []
    if loaded && !engineRunning {
      soft.append(.init(id: "engine", tone: .warning, title: "Engine not running", message: "Posts won't be prepared",
                        actionTitle: "Open Health", dismissible: true, action: { [weak self] in self?.screen = .health }))
    }
    if loaded && runway.approvedDays < settings.approvedRunwayAlertDays {
      soft.append(.init(id: "approve", tone: .warning, title: "Approved runway \(runway.approvedDays) d",
                        message: "Approve next week", actionTitle: "Open Week", dismissible: true,
                        action: { [weak self] in self?.goToNextWeek() }))
    }
    if loaded && runway.totalDays < settings.totalRunwayAlertDays {
      soft.append(.init(id: "record", tone: .warning, title: "Total runway \(runway.totalDays) d", message: "Record a new set",
                        dismissible: true))
    }
    out += soft.filter { d in dismissedWarnings[d.id].map { now.timeIntervalSince($0) > 86400 } ?? true }
    return out
  }

  /// "Instagram copyright · X failed".
  var problemParts: String {
    let parts = problems.prefix(3).map { p -> String in
      let what = p.state.isCopyright ? "copyright" : p.state == .overdue ? "missed" : (p.errorType?.displayName ?? p.state.displayName).lowercased()
      return "\(p.platform.displayName) \(what)"
    }
    return parts.joined(separator: " · ") + (problems.count > 3 ? " · …" : "")
  }

  // MARK: Sidebar

  /// Right-aligned count per sidebar row (nil = none). Score = unscored, Edit = scored not ready,
  /// Queue = ready + planned, Today = due today, Posts = problems.
  func sidebarCount(_ s: Screen) -> Int? {
    let n: Int
    switch s {
    case .score: n = scoreList.count
    case .edit: n = editList.count
    case .queue: n = queueList.count
    case .today: n = dueBadge
    case .posts: n = problems.count
    default: return nil
    }
    return n > 0 ? n : nil
  }

  /// Today turns into a near-black capsule when something is due now; Posts is red.
  func sidebarCountStyle(_ s: Screen) -> DSCount.Style {
    switch s {
    case .today: dueNow.isEmpty ? .plain : .attention
    case .posts: .danger
    default: .plain
    }
  }

  /// Health row dot: red = engine stopped / database error; amber = paused or a runway warning; green otherwise.
  var healthTone: DSTone {
    if loadError != nil || (loaded && !engineRunning) { return .danger }
    if settings.paused || !settings.pausedPlatforms.isEmpty || runway.approvedDays < settings.approvedRunwayAlertDays { return .warning }
    return .success
  }

  /// Sidebar footer engine line: tone + text ("Running · next 7:00 PM TikTok", "Paused", "Engine stopped").
  var engineLine: (tone: DSTone, text: String) {
    if !engineRunning { return (.danger, loaded ? "Engine stopped" : "Starting…") }
    if settings.paused { return (.warning, "Paused") }
    guard let p = nextPost else { return (.success, "Running") }
    let day = dm.key(p.scheduledAt) == todayKey ? "" : Fmt.day(p.scheduledAt, tz: tz, style: "EEE") + " "
    return (.success, "Running · next \(day)\(Self.clockText(p.scheduledAt, tz: tz)) \(p.platform.displayName)")
  }

  /// "7:00 PM".
  static func clockText(_ d: Date, tz: TimeZone) -> String { Fmt.day(d, tz: tz, style: "h:mm a") }

  /// Sidebar collapses to icons under 1200 pt or when Eric collapses it.
  func sidebarIsCompact(width: CGFloat) -> Bool { sidebarCollapsed || width < 1200 }
}
