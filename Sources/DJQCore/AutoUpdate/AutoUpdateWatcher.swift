import Foundation

/// `~/Library/LaunchAgents/com.djlovd.queue.autoupdate.plist`: runs `djq autoupdate run --trigger watch` from the
/// installed app whenever the branch ref, the tags, the app's request file or its window file changes. launchd
/// never starts a second copy while one runs; the run lock covers manual runs.
public enum AutoUpdateWatcher {
  /// Paths launchd watches. A commit or merge on main rewrites `refs/heads/main` (or `packed-refs` after a gc);
  /// tagging touches `refs/tags`, so a release tag re-labels a dev build.
  public static func watchPaths(repo: String, branch: String, au: AutoUpdatePaths) -> [String] {
    let gitDir = commonGitDir(repo)
    let ref = (gitDir as NSString).appendingPathComponent("refs/heads/\(branch)")
    return [ref, (ref as NSString).deletingLastPathComponent, (gitDir as NSString).appendingPathComponent("packed-refs"),
            (gitDir as NSString).appendingPathComponent("refs/tags"), au.request.path, au.window.path]
  }

  /// The repository's shared .git folder (a worktree's `.git` is a file pointing elsewhere).
  static func commonGitDir(_ repo: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
      let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      p.waitUntilExit()
      if p.terminationStatus == 0, !out.isEmpty { return out }
    }
    return (repo as NSString).appendingPathComponent(".git")
  }

  public static func plist(djq: String, repo: String, branch: String, au: AutoUpdatePaths) -> [String: Any] {
    [
      "Label": AutoUpdate.watcherLabel,
      "ProgramArguments": [djq, "autoupdate", "run", "--trigger", "watch"],
      "WatchPaths": watchPaths(repo: repo, branch: branch, au: au),
      "RunAtLoad": true,
      // At most one start per 30 s; a burst of commits is handled by the run's own re-check.
      "ThrottleInterval": 30,
      // Builds and tests run at background priority so they never get in the way.
      "ProcessType": "Background",
      "LowPriorityIO": true,
      "Nice": 10,
      "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"],
      "StandardOutPath": au.logs.appendingPathComponent("autoupdate.out.log").path,
      "StandardErrorPath": au.logs.appendingPathComponent("autoupdate.out.log").path,
    ]
  }

  /// Writes the plist (and loads it when `load`). Refused in dev environments and for a `djq` outside the
  /// installed app, like the engine LaunchAgent: a dev build must never install itself over the real app.
  public static func install(_ au: AutoUpdatePaths, repo: String, branch: String, load: Bool,
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    for k in ["DJQ_HOME", "DJQ_ROOT"] where !(environment[k] ?? "").isEmpty {
      throw EngineError("Won't install the auto-update watcher while \(k) is set (dev environment). Use `djq autoupdate run` to run it by hand.")
    }
    let djq = au.installedApp.appendingPathComponent("Contents/MacOS/djq").path
    guard FileManager.default.isExecutableFile(atPath: djq) else {
      throw EngineError("\(au.installedApp.path) isn't installed yet — install it with scripts/build-app.sh --install first.")
    }
    let fm = FileManager.default
    try fm.createDirectory(at: au.dir, withIntermediateDirectories: true)
    // WatchPaths needs the files to exist to watch them.
    for f in [au.request, au.window] where !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: Data()) }
    let data = try PropertyListSerialization.data(fromPropertyList: plist(djq: djq, repo: repo, branch: branch, au: au), format: .xml, options: 0)
    try fm.createDirectory(at: au.launchAgents, withIntermediateDirectories: true)
    try fm.createDirectory(at: au.logs, withIntermediateDirectories: true)
    try data.write(to: au.watcherPlist, options: .atomic)
    if load {
      _ = LaunchAgent.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(AutoUpdate.watcherLabel)"])
      let r = LaunchAgent.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", au.watcherPlist.path])
      if r.status != 0 { throw EngineError("launchctl bootstrap failed: \(r.output)") }
    }
  }

  public static func uninstall(_ au: AutoUpdatePaths, unload: Bool) throws {
    if unload { _ = LaunchAgent.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(AutoUpdate.watcherLabel)"]) }
    if FileManager.default.fileExists(atPath: au.watcherPlist.path) { try FileManager.default.removeItem(at: au.watcherPlist) }
  }

  public static func isInstalled(_ au: AutoUpdatePaths) -> Bool { FileManager.default.fileExists(atPath: au.watcherPlist.path) }

  public static func isLoaded() -> Bool {
    LaunchAgent.run("/bin/launchctl", ["print", "gui/\(getuid())/\(AutoUpdate.watcherLabel)"]).status == 0
  }
}

/// The app's side: ask for a check or an install, and say whether the main window is open. With the watcher
/// loaded, writing the file is enough (launchd starts it); otherwise (dev, or the watcher is off) the bundled `djq`
/// runs once in the background.
public enum AutoUpdateClient {
  public static func ask(_ action: AutoUpdateRequest.Action, paths: Paths, djq: URL?) {
    let files = AutoUpdateStore(paths)
    try? files.saveRequest(AutoUpdateRequest(action: action))
    kick(files, djq: djq, trigger: action == .install ? "manual" : "launch")
  }

  public static func windowChanged(open: Bool, paths: Paths, djq: URL?) {
    let files = AutoUpdateStore(paths)
    try? files.saveWindow(AutoUpdateWindow(open: open))
    // Closing the window installs a ready build; opening it needs no run.
    if !open, files.state().ready != nil { kick(files, djq: djq, trigger: "launch") }
  }

  static func kick(_ files: AutoUpdateStore, djq: URL?, trigger: String) {
    if AutoUpdateWatcher.isInstalled(files.paths), AutoUpdateWatcher.isLoaded() { return }
    guard let djq, FileManager.default.isExecutableFile(atPath: djq.path) else { return }
    let p = Process()
    p.executableURL = djq
    p.arguments = ["autoupdate", "run", "--trigger", trigger]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try? p.run()
  }
}
