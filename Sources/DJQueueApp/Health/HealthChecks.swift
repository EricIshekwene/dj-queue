import DJQCore
import Observation
import SwiftUI

/// Facts the Health screen reads from the system (LaunchAgent, disk, backups) plus the 7-day awake timeline, loaded
/// off the main thread. One shared instance; snapshot shots set `override` to show a chosen state.
@MainActor
@Observable
final class HealthProbe {
  static let shared = HealthProbe()

  struct Facts: Equatable {
    var agentLoaded: Bool?
    var diskFree: Int64?
    var lastBackup: Date?
  }

  var facts = Facts()
  /// Snapshot: use these facts instead of probing.
  var override: Facts?
  var awake: [DateInterval] = []
  var missed: [PlatformPost] = []
  var loading = false

  var current: Facts { override ?? facts }

  func refresh(_ model: AppModel) async {
    let store = model.store
    let since = model.dm.date(model.dm.addDays(model.todayKey, -6))
    if model.frozen {
      awake = (try? Health.awakePeriods(store: store, since: since)) ?? []
      missed = (try? Health.missedSlots(store: store, since: since)) ?? []
      if override == nil { facts = Facts(agentLoaded: true, diskFree: nil, lastBackup: Backup.list(store.paths).first.flatMap(Self.modified)) }
      return
    }
    loading = true
    let r = await Task.detached { () -> (Facts, [DateInterval], [PlatformPost]) in
      let loaded = LaunchAgent.isLoaded()
      let free = (try? store.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage
      let last = Backup.list(store.paths).first.flatMap(Self.modified)
      let awake = (try? Health.awakePeriods(store: store, since: since)) ?? []
      let missed = (try? Health.missedSlots(store: store, since: since)) ?? []
      return (Facts(agentLoaded: loaded, diskFree: free, lastBackup: last), awake, missed)
    }.value
    facts = r.0
    awake = r.1
    missed = r.2
    loading = false
  }

  nonisolated static func modified(_ u: URL) -> Date? {
    try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}

/// One collapsible Health check row (DESIGN-v2 §6.8): status icon, name, one-line value; expands to detail + fix.
struct HealthCheck: Identifiable {
  enum Action { case runTick, openLog, openEngineSettings, runDoctor }
  let id: String
  var title: String
  var tone: DSTone
  var value: String
  var detail: String
  var fix: String?
  var action: (title: String, Action)?

  var needsAttention: Bool { tone == .warning || tone == .danger }
}

extension AppModel {
  /// The eight checks: Engine, Last tick, Render queue, Disk, Backup, ffmpeg, LaunchAgent, Proxies.
  func healthChecks(_ f: HealthProbe.Facts) -> [HealthCheck] {
    var out: [HealthCheck] = []
    let hb = lastHeartbeat
    out.append(HealthCheck(
      id: "engine", title: "Engine", tone: engineRunning ? .success : .danger,
      value: engineRunning ? (engineInProcess ? "Running in this app" : "Running in the background") : "Stopped",
      detail: engineRunning
        ? "The engine ticks every minute: it renders, makes posts due, sends reminders and backs up the database."
        : "No heartbeat for over 3 minutes\(hb.map { " (last: \(Fmt.relative($0.at, now: now)))" } ?? ""). Posts aren't prepared and reminders don't arrive.",
      fix: engineRunning ? nil : "Open DJ Queue, or turn on Run at login in Settings → Engine.",
      action: engineRunning ? ("Open engine log", .openLog) : ("Open engine settings", .openEngineSettings)))

    let tickAge = hb.map { now.timeIntervalSince($0.at) }
    let tick = engine?.lastTick
    out.append(HealthCheck(
      id: "tick", title: "Last tick", tone: tickAge.map { $0 < 180 ? .success : .warning } ?? .warning,
      value: hb.map { "\(Fmt.relative($0.at, now: now)) · \($0.kind.rawValue)" } ?? "Never",
      detail: tick.map { "\($0.steps.count) steps\($0.errors.isEmpty ? ", no errors" : " · \($0.errors.count) errors: \($0.errors.joined(separator: "; "))")" }
        ?? "The last heartbeat the engine wrote to the database.",
      fix: (tickAge ?? .infinity) < 180 ? nil : "Run a tick now; if it doesn't move, open the engine log.",
      action: ("Run tick now", .runTick)))

    out.append(HealthCheck(
      id: "render", title: "Render queue", tone: .success,
      value: renderQueue == 0 ? "Idle" : renderLine?.capitalized ?? "\(renderQueue) waiting",
      detail: renderQueue == 0 ? "Nothing waiting to render." : "\(renderQueue) render\(renderQueue == 1 ? "" : "s") pending or running. Renders run on engine ticks.",
      fix: nil, action: nil))

    let low: Int64 = 50_000_000_000, critical: Int64 = 10_000_000_000
    let disk = f.diskFree
    out.append(HealthCheck(
      id: "disk", title: "Disk", tone: disk.map { $0 < critical ? .danger : $0 < low ? .warning : .success } ?? .neutral,
      value: disk.map { "\(Fmt.bytes($0)) free" } ?? "Checking…",
      detail: "Free space on the volume that holds the DJ Video folder. Renders and proxies need room.",
      fix: (disk ?? .max) < low ? "Free some space: delete old renders (Settings → Rendering → cleanup) or move footage." : nil, action: nil))

    let backupAge = f.lastBackup.map { now.timeIntervalSince($0) }
    out.append(HealthCheck(
      id: "backup", title: "Backup", tone: backupAge.map { $0 < 2 * 86400 ? .success : .warning } ?? .warning,
      value: f.lastBackup.map { "Last \(Fmt.relative($0, now: now))" } ?? "None yet",
      detail: "The engine copies the database once a day and keeps the last \(Backup.keep).",
      fix: (backupAge ?? .infinity) < 2 * 86400 ? nil : "Leave the engine running for a tick; the daily backup runs on its own.",
      action: (backupAge ?? .infinity) < 2 * 86400 ? nil : ("Run tick now", .runTick)))

    let ffmpeg = Tools.ffmpeg != nil, ffprobe = Tools.ffprobe != nil
    out.append(HealthCheck(
      id: "ffmpeg", title: "ffmpeg", tone: ffmpeg && ffprobe ? .success : .danger,
      value: ffmpeg && ffprobe ? "Installed" : ffmpeg ? "ffprobe missing" : "Missing",
      detail: "Renders, covers, proxies and duration checks use ffmpeg and ffprobe.",
      fix: ffmpeg && ffprobe ? nil : "Install with Homebrew: brew install ffmpeg", action: nil))

    let agent = f.agentLoaded
    out.append(HealthCheck(
      id: "agent", title: "LaunchAgent", tone: agent.map { $0 ? .success : .warning } ?? .neutral,
      value: agent.map { $0 ? "Loaded · runs at login" : "Not loaded" } ?? "Checking…",
      detail: "Keeps the engine and the menu-bar item running when the window is closed.",
      fix: agent == false ? "Turn on Run at login in Settings → Engine." : nil,
      action: agent == false ? ("Open engine settings", .openEngineSettings) : nil))

    let pending = proxies.pendingCount, busy = proxies.isBusy
    out.append(HealthCheck(
      id: "proxies", title: "Proxies", tone: .success,
      value: busy ? "Encoding · \(pending) queued" : pending > 0 ? "\(pending) queued" : "Idle",
      detail: "540 px preview copies for autoplay, made in the background and paused while a render runs.",
      fix: nil, action: nil))
    return out
  }

  /// The Health report Eric pastes to an agent: the checks, then Doctor's markdown.
  func healthReportMarkdown(_ checks: [HealthCheck]) -> String {
    var s = "# DJ Queue health\n\n"
    for c in checks {
      let mark = c.tone == .success ? "OK" : c.tone == .danger ? "FAIL" : c.tone == .warning ? "WARN" : "—"
      s += "- **\(c.title)** [\(mark)]: \(c.value)\(c.fix.map { " — fix: \($0)" } ?? "")\n"
    }
    if let r = doctorReport { s += "\n" + Doctor.markdown(r) }
    return s
  }
}
