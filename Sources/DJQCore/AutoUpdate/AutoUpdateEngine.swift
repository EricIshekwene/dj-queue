import Foundation

/// How auto-update restarts, stops and starts the engine. `live` drives the engine LaunchAgent with launchctl
/// (kickstart -k to restart; bootout/bootstrap around a database restore). Without a loaded LaunchAgent it asks a
/// plain-launched app (same database) to relaunch. Dev runs never touch launchd.
public struct AutoUpdateEngineControl: Sendable {
  public var restart: @Sendable () -> (ok: Bool, message: String)
  public var stop: @Sendable () -> String
  public var start: @Sendable () -> (ok: Bool, message: String)
  /// True when verify should wait for the restarted engine's first heartbeat (a LaunchAgent engine is running).
  public var expectsHeartbeat: @Sendable () -> Bool

  public init(restart: @escaping @Sendable () -> (ok: Bool, message: String), stop: @escaping @Sendable () -> String,
              start: @escaping @Sendable () -> (ok: Bool, message: String), expectsHeartbeat: @escaping @Sendable () -> Bool) {
    self.restart = restart; self.stop = stop; self.start = start; self.expectsHeartbeat = expectsHeartbeat
  }

  public static func live(paths: Paths, environment: [String: String]) -> AutoUpdateEngineControl {
    let dev = ["DJQ_HOME", "DJQ_ROOT"].contains { !(environment[$0] ?? "").isEmpty }
    let target = "gui/\(getuid())/\(LaunchAgent.label)"
    if dev {
      return AutoUpdateEngineControl(
        restart: {
          AutoUpdate.post(AutoUpdate.restartSignal, paths)
          return (true, "engine restart skipped (dev environment); asked an open dev app on this database to relaunch")
        },
        stop: { "engine stop skipped (dev environment)" },
        start: { (true, "engine start skipped (dev environment)") },
        expectsHeartbeat: { false })
    }
    return AutoUpdateEngineControl(
      restart: {
        if LaunchAgent.isLoaded() {
          let r = LaunchAgent.run("/bin/launchctl", ["kickstart", "-k", target])
          return r.status == 0 ? (true, "engine restarted (launchctl kickstart)")
            : (false, "launchctl kickstart failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        AutoUpdate.post(AutoUpdate.restartSignal, paths)
        return (true, "engine LaunchAgent not loaded; asked an open app to relaunch")
      },
      stop: {
        guard LaunchAgent.isLoaded() else { return "engine LaunchAgent not loaded; nothing to stop" }
        let r = LaunchAgent.run("/bin/launchctl", ["bootout", target])
        return r.status == 0 ? "engine stopped (launchctl bootout)" : "engine stop failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
      },
      start: {
        if LaunchAgent.isLoaded() { return (true, "engine already running") }
        guard LaunchAgent.isInstalled(paths: paths) else {
          AutoUpdate.post(AutoUpdate.restartSignal, paths)
          return (true, "engine LaunchAgent not installed; asked an open app to relaunch")
        }
        let r = LaunchAgent.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.agentPlist.path])
        return r.status == 0 ? (true, "engine started (launchctl bootstrap)")
          : (false, "launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
      },
      expectsHeartbeat: { LaunchAgent.isLoaded() })
  }

  /// For tests: counts calls, never touches launchd.
  public static func recording(_ log: @escaping @Sendable (String) -> Void) -> AutoUpdateEngineControl {
    AutoUpdateEngineControl(restart: { log("restart"); return (true, "restarted (test)") },
                            stop: { log("stop"); return "stopped (test)" },
                            start: { log("start"); return (true, "started (test)") },
                            expectsHeartbeat: { false })
  }
}
