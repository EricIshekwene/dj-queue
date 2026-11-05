import Foundation

/// How auto-update restarts, stops and starts the engine. `live` drives the engine LaunchAgent with launchctl
/// (kickstart -k to restart; bootout/bootstrap around a database restore). Without a loaded LaunchAgent it asks a
/// plain-launched app (same database) to relaunch. Dev runs never touch launchd.
public struct AutoUpdateEngineControl: Sendable {
  public var restart: @Sendable () -> (ok: Bool, message: String)
  /// Stops the engine LaunchAgent; `wasLoaded` tells `start` whether to load it again.
  public var stop: @Sendable () -> (wasLoaded: Bool, message: String)
  /// Starts what `stop` stopped (never loads an engine Eric had unloaded).
  public var start: @Sendable (_ wasLoaded: Bool) -> (ok: Bool, message: String)
  /// True when verify should wait for the restarted engine's first heartbeat (a LaunchAgent engine is running).
  public var expectsHeartbeat: @Sendable () -> Bool

  public init(restart: @escaping @Sendable () -> (ok: Bool, message: String), stop: @escaping @Sendable () -> (wasLoaded: Bool, message: String),
              start: @escaping @Sendable (_ wasLoaded: Bool) -> (ok: Bool, message: String), expectsHeartbeat: @escaping @Sendable () -> Bool) {
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
        stop: { (false, "engine stop skipped (dev environment)") },
        start: { _ in (true, "engine start skipped (dev environment)") },
        expectsHeartbeat: { false })
    }
    return AutoUpdateEngineControl(
      restart: {
        if LaunchAgent.isLoaded() {
          let r = LaunchAgent.run("/bin/launchctl", ["kickstart", "-k", target])
          return r.status == 0 ? (true, "engine restarted (launchctl kickstart)")
            : (false, "launchctl kickstart failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Round 9: an installed agent that isn't loaded is brought back, so an install never leaves the engine down
        // (2026-11-05: it stayed down 15:18–16:13 because no app was open to answer the signal).
        if LaunchAgent.isInstalled(paths: paths) {
          let r = LaunchAgent.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.agentPlist.path])
          if r.status == 0 { return (true, "engine started (launchctl bootstrap; it wasn't loaded)") }
        }
        AutoUpdate.post(AutoUpdate.restartSignal, paths)
        return (true, "engine LaunchAgent not loaded; asked an open app to relaunch")
      },
      stop: {
        guard LaunchAgent.isLoaded() else { return (false, "engine LaunchAgent not loaded; nothing to stop") }
        let r = LaunchAgent.run("/bin/launchctl", ["bootout", target])
        return (true, r.status == 0 ? "engine stopped (launchctl bootout)" : "engine stop failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
      },
      start: { wasLoaded in
        if LaunchAgent.isLoaded() { return (true, "engine already running") }
        guard wasLoaded, LaunchAgent.isInstalled(paths: paths) else {
          AutoUpdate.post(AutoUpdate.restartSignal, paths)
          return (true, "engine LaunchAgent wasn't loaded; asked an open app to relaunch")
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
                            stop: { log("stop"); return (true, "stopped (test)") },
                            start: { _ in log("start"); return (true, "started (test)") },
                            expectsHeartbeat: { false })
  }
}
