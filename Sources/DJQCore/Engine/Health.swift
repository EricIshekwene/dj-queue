import Foundation

/// Mac-awake timeline for the Health screen (spec §8).
public enum Health {
  /// Awake periods from heartbeats: start/tick/wake extend a period; sleep/stop or a gap > 3 min ends it.
  public static func awakePeriods(store: Store, since: Date) throws -> [DateInterval] {
    var out: [DateInterval] = []
    var start: Date?
    var last: Date?
    for hb in try store.heartbeats(since: since) {
      switch hb.kind {
      case .sleep, .stop:
        if let s = start { out.append(DateInterval(start: s, end: max(s, hb.at))) }
        start = nil
      case .start, .tick, .wake:
        if let s = start, let l = last, hb.at.timeIntervalSince(l) > Engine.sleepGap {
          out.append(DateInterval(start: s, end: l))
          start = hb.at
        } else if start == nil {
          start = hb.at
        }
      }
      last = hb.at
    }
    if let s = start, let l = last { out.append(DateInterval(start: s, end: max(s, l))) }
    return out
  }

  /// Posts that went overdue since `since` (red ticks on the timeline).
  public static func missedSlots(store: Store, since: Date) throws -> [PlatformPost] {
    let ids = try store.db.query("SELECT DISTINCT post_id FROM post_history WHERE to_state='overdue' AND at>=?", [since])
      .compactMap { $0.string("post_id") }
    return try ids.compactMap { try store.post(id: $0) }.sorted { $0.scheduledAt < $1.scheduledAt }
  }
}

/// Daily rotating DB backup to `_app/backups/` (spec §3): one file per day, keep 14.
public enum Backup {
  public static let keep = 14

  @discardableResult
  public static func runIfDue(store: Store) throws -> URL? {
    let dm = try store.dayMath()
    let dir = store.paths.backups
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("queue-\(dm.key(store.clock.now)).sqlite")
    guard !fm.fileExists(atPath: url.path) else { return nil }
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
    try? fm.removeItem(at: tmp)
    try store.db.backup(to: tmp.path)
    try fm.moveItem(at: tmp, to: url)
    for old in list(store.paths).dropFirst(keep) { try? fm.removeItem(at: old) }
    try store.setKV("lastBackupAt", store.clock.now)
    return url
  }

  /// Backups, newest first.
  public static func list(_ paths: Paths) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("queue-") && $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
}

/// `~/Library/LaunchAgents/com.djlovd.queue.engine.plist` (RunAtLoad + KeepAlive, runs the app with `--agent`).
/// `launchctl` is only called when the caller asks (`load:` / `unload:`), so tests never touch the real agent.
public enum LaunchAgent {
  public static let label = "com.djlovd.queue.engine"

  /// Writes the plist. `appPath` is the .app bundle (its CFBundleExecutable is used) or an executable.
  public static func install(appPath: String, paths: Paths, load: Bool = false) throws {
    let exe = executable(for: appPath)
    let plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [exe, "--agent"],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Interactive",
      "StandardOutPath": paths.logs.appendingPathComponent("agent.out.log").path,
      "StandardErrorPath": paths.logs.appendingPathComponent("agent.err.log").path,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    try data.write(to: paths.agentPlist, options: .atomic)
    if load {
      _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
      let r = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.agentPlist.path])
      if r.status != 0 { throw EngineError("launchctl bootstrap failed: \(r.output)") }
    }
  }

  public static func isLoaded() -> Bool {
    run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
  }

  public static func uninstall(paths: Paths, unload: Bool = false) throws {
    if unload { _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"]) }
    if FileManager.default.fileExists(atPath: paths.agentPlist.path) {
      try FileManager.default.removeItem(at: paths.agentPlist)
    }
  }

  public static func isInstalled(paths: Paths) -> Bool { FileManager.default.fileExists(atPath: paths.agentPlist.path) }

  static func executable(for appPath: String) -> String {
    guard appPath.hasSuffix(".app") else { return appPath }
    let info = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    let name = (NSDictionary(contentsOf: info)?["CFBundleExecutable"] as? String)
      ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    return URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/\(name)").path
  }

  @discardableResult
  static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
