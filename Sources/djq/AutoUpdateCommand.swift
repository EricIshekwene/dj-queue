import DJQCore
import Foundation

/// `djq autoupdate on|off|status|run|rollback|log` (round 4 S5). Dispatched from main.swift before the database
/// opens: nothing here reads or writes the queue except the runner's backup/verify steps.
enum AutoUpdateCommand {
  static let usage = """
    usage: djq autoupdate <command>

      status [--json]                 on/off, watcher, installed build, main, ready/blocked, last result
      on [--repo PATH] [--branch B]   turn auto-update on and load the watcher (installed app only)
      off                             turn it off and unload the watcher (nothing else changes)
      run [--force] [--trigger T]     check main now: gate → backup → install → restart → verify (T: manual|watch|launch)
      rollback [--restore-db]         swap back to the previous build (refused after a schema migration unless --restore-db)
      log [--lines N] [--run]         the auto-update log (or the newest run's full build/test output)
    """

  static func run(_ argv: [String], paths: Paths) throws -> Int32 {
    var args = argv
    func flag(_ name: String) -> Bool {
      if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
      return false
    }
    func option(_ name: String) -> String? {
      guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
      let v = args[i + 1]
      args.removeSubrange(i...(i + 1))
      return v
    }
    let files = AutoUpdateStore(paths)
    let au = files.paths
    let env = ProcessInfo.processInfo.environment
    let dev = ["DJQ_HOME", "DJQ_ROOT"].contains { !(env[$0] ?? "").isEmpty }
    guard let sub = args.first else { print(usage); return 0 }
    args.removeFirst()

    switch sub {
    case "status":
      let s = files.state()
      let c = files.config()
      let installed = BundleInfo.build(au.installedApp)
      let repo = c.repoPath()
      let head = gitHead(repo, c.branch)
      if flag("--json") {
        struct Status: Encodable {
          var enabled: Bool, configured: Bool, watcherInstalled: Bool, watcherLoaded: Bool, repo: String, branch: String
          var main: String?, installed: AutoUpdateBuild?, previous: AutoUpdateBuild?, running: Bool, state: AutoUpdateState
        }
        let st = Status(enabled: c.enabled, configured: files.configIfSet() != nil, watcherInstalled: AutoUpdateWatcher.isInstalled(au),
                        watcherLoaded: AutoUpdateWatcher.isLoaded(), repo: repo, branch: c.branch, main: head, installed: installed,
                        previous: BundleInfo.build(au.previous), running: s.isRunning, state: s)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        print(String(decoding: try e.encode(st), as: UTF8.self))
        return 0
      }
      print("auto-update  \(c.enabled ? "on" : "off")\(files.configIfSet() == nil ? " (not set up yet — `djq autoupdate on`)" : "")")
      print("watcher      \(AutoUpdateWatcher.isInstalled(au) ? "installed" : "not installed") · \(AutoUpdateWatcher.isLoaded() ? "loaded" : "not loaded")")
      print("watching     \(repo) · \(c.branch)\(head.map { " @ \(String($0.prefix(7)))" } ?? " (can't read)")")
      print("installed    \(installed.map { "\($0.version) (\($0.shortCommit))" } ?? "none at \(au.installedApp.path)")")
      if let p = BundleInfo.build(au.previous) { print("previous     \(p.version) (\(p.shortCommit)) — kept for rollback") }
      print("now          \(s.isRunning ? "\(s.phase.label)\(s.working.map { " · \(String($0.prefix(7)))" } ?? "")" : "idle")")
      if let r = s.ready {
        print("ready        \(r.version) (\(String(r.commit.prefix(7)))) · \(r.whatsNew.count) change(s) · \(r.later ? "installs when the window closes" : "waiting for the window to close")")
      }
      if let b = s.blocked { print("blocked      \(b.version) (\(String(b.commit.prefix(7)))): \(b.reason)") }
      if let l = s.last { print("last         \(l.kind.rawValue) · \(l.message)") }
      print("log          \(au.log.path)")
      return 0

    case "on":
      var c = files.config()
      c.enabled = true
      if let r = option("--repo") { c.repo = URL(fileURLWithPath: r).standardizedFileURL.path }
      if let b = option("--branch") { c.branch = b }
      try files.saveConfig(c)
      if dev {
        print("auto-update on (config: \(au.config.path)); no watcher in a dev environment — run `djq autoupdate run` by hand")
        return 0
      }
      try AutoUpdateWatcher.install(au, repo: c.repoPath(), branch: c.branch, load: true)
      print("auto-update on: watching \(c.repoPath()) · \(c.branch) (\(au.watcherPlist.path) loaded)")
      return 0

    case "off":
      var c = files.config()
      c.enabled = false
      try files.saveConfig(c)
      try AutoUpdateWatcher.uninstall(au, unload: !dev)
      print("auto-update off: the watcher is unloaded; commits to \(c.branch) aren't installed until `djq autoupdate on`")
      return 0

    case "run":
      let force = flag("--force")
      let trigger = try option("--trigger").map { t -> AutoUpdateRunner.Trigger in
        guard let x = AutoUpdateRunner.Trigger(rawValue: t) else { throw AutoUpdateCLIError("unknown trigger \(t) (manual|watch|launch)") }
        return x
      } ?? .manual
      let runner = AutoUpdateRunner(paths: paths)
      let r = runner.run(trigger: trigger, force: force)
      return [.failed, .blocked, .rolledBack].contains(r.kind) ? 1 : 0

    case "rollback":
      let runner = AutoUpdateRunner(paths: paths)
      do {
        _ = try runner.rollback(restoreDB: flag("--restore-db"))
      } catch let e as AutoUpdateRunner.RollbackError {
        throw AutoUpdateCLIError(e.description)
      }
      return 0

    case "log":
      let n = option("--lines").flatMap(Int.init) ?? 40
      if flag("--run") {
        let runs = ((try? FileManager.default.contentsOfDirectory(at: au.runs, includingPropertiesForKeys: nil)) ?? [])
          .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let newest = runs.first else { print("(no runs yet)"); return 0 }
        print("== \(newest.path)")
        let s = (try? String(contentsOf: newest, encoding: .utf8)) ?? ""
        print(s.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n"))
        return 0
      }
      let lines = files.logTail(n)
      print(lines.isEmpty ? "(no auto-update log yet: \(au.log.path))" : lines.joined(separator: "\n"))
      return 0

    case "help", "-h", "--help":
      print(usage)
      return 0

    default:
      throw AutoUpdateCLIError("unknown autoupdate command \(sub)\n\n\(usage)")
    }
  }

  static func gitHead(_ repo: String, _ branch: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    p.waitUntilExit()
    return p.terminationStatus == 0 && !out.isEmpty ? out : nil
  }
}

struct AutoUpdateCLIError: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}
