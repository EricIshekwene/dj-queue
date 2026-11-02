import Foundation

/// Doctor's `autoupdate` checks (read-only): the watcher is loaded when auto-update is on, and the last run
/// didn't block, fail or roll back. Silent until auto-update has been set up (`config.json` exists).
extension Doctor {
  func autoUpdate() throws -> [DoctorFinding] {
    let files = AutoUpdateStore(store.paths)
    guard let config = files.configIfSet() else { return [] }
    let au = files.paths
    var out: [DoctorFinding] = []
    if !config.enabled {
      out.append(.init(id: "autoupdate.off", severity: .info, title: "Auto-update is off",
                       detail: "Commits to main aren't installed automatically.", where_: [au.config.path],
                       fix: "Eric: `djq autoupdate on` (or Settings → Engine → Auto-update). Agents: leave it as Eric set it."))
      return out
    }
    if !AutoUpdateWatcher.isInstalled(au) || !autoUpdateWatcherLoaded() {
      out.append(.init(id: "autoupdate.watcher", severity: .warning,
                       title: AutoUpdateWatcher.isInstalled(au) ? "Auto-update watcher not loaded" : "Auto-update watcher not installed",
                       detail: "Auto-update is on but nothing watches main, so commits won't install.", where_: [au.watcherPlist.path],
                       fix: "`djq autoupdate on` reinstalls and loads it (installed app only)."))
    }
    let s = files.state()
    if let b = s.blocked, !(b.afterInstall && s.failedInstall?.commit == b.commit) {
      out.append(.init(id: "autoupdate.blocked", severity: .warning, title: "Update \(b.version) blocked",
                       detail: b.reason, where_: [b.log ?? au.log.path, String(b.commit.prefix(7))],
                       fix: "Fix the failing build or tests on main and commit; the watcher retries on the next commit. `djq autoupdate log` shows the run."))
    }
    if let f = s.failedInstall {
      out.append(.init(id: "autoupdate.failed", severity: .warning, title: "Update \(f.version) failed its checks and is still installed",
                       detail: f.reason, where_: [au.log.path, String(f.commit.prefix(7))],
                       fix: "Eric decides: `djq autoupdate rollback --restore-db` goes back to the build before it (changes since its backup are lost), or a fixed commit on main replaces it."))
    } else if let r = s.last, r.kind == .failed {
      out.append(.init(id: "autoupdate.failed", severity: .warning, title: "Last auto-update failed",
                       detail: r.message, where_: [au.log.path], fix: "Read `djq autoupdate log`; `djq autoupdate run` retries."))
    }
    if let r = s.ready, store.clock.now.timeIntervalSince(r.builtAt) > 86400 {
      out.append(.init(id: "autoupdate.ready", severity: .info, title: "Update \(r.version) waiting for the window to close",
                       detail: "Built \(Int(store.clock.now.timeIntervalSince(r.builtAt) / 3600)) h ago.", where_: [],
                       fix: "Eric: Restart & update from the banner, or close the main window."))
    }
    return out
  }
}
