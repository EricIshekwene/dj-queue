import Foundation

/// Auto-update (round 4 S5): a commit to `main` in the source checkout is gated (build + tests in a scratch
/// checkout), then installed over `~/Applications/DJ Queue.app` with a DB backup, an engine restart and a verify
/// pass. The runner (`djq autoupdate run`, started by the watcher LaunchAgent) is the only writer of `state.json`;
/// the app only reads it and asks for things through `request.json` and `window.json` (DECISIONS-R4-AUTOUPDATE.md).
public enum AutoUpdate {
  /// Watcher LaunchAgent (WatchPaths on the main ref, the request file and the window file).
  public static let watcherLabel = "com.djlovd.queue.autoupdate"
  /// Posted (distributed) after every state change so the app refreshes its banner and menu-bar dot at once.
  public static let changedSignal = "com.djlovd.queue.autoupdate.changed"
  /// Posted when an install finished and this process is not the LaunchAgent engine (it can't be kickstarted):
  /// a plain-launched app relaunches itself from the new bundle.
  public static let restartSignal = "com.djlovd.queue.autoupdate.restart"

  /// Signals carry the app-support folder they're about, so a dev run never moves Eric's real app (and the other way).
  public static let scopeKey = "appSupport"

  public static func post(_ signal: String, _ paths: Paths) {
    DistributedNotificationCenter.default().postNotificationName(.init(signal), object: nil,
                                                                 userInfo: [scopeKey: paths.appSupport.standardizedFileURL.path],
                                                                 deliverImmediately: true)
  }

  public static func postChanged(_ paths: Paths) { post(changedSignal, paths) }

  /// True when a received signal is about this database (signals without a scope are ignored).
  public static func isFor(_ userInfo: [AnyHashable: Any]?, _ paths: Paths) -> Bool {
    (userInfo?[scopeKey] as? String) == paths.appSupport.standardizedFileURL.path
  }

  /// A dev run that sets DJQ_ROOT but not DJQ_HOME would back up, install and restore against the REAL app
  /// support folder and app: auto-update refuses it.
  public static func unsafeDevEnvironment(_ environment: [String: String]) -> Bool {
    !(environment["DJQ_ROOT"] ?? "").isEmpty && (environment["DJQ_HOME"] ?? "").isEmpty
  }

  /// Docs-only = every changed path is Markdown or lives under design/, docs/, refs/ or screenshots/.
  /// An empty list is not docs-only (nothing to judge).
  public static func isDocsOnly(_ files: [String]) -> Bool {
    !files.isEmpty && files.allSatisfy { f in
      f.lowercased().hasSuffix(".md") || ["design/", "docs/", "refs/", "screenshots/"].contains { f.hasPrefix($0) }
    }
  }
}

/// Where auto-update keeps its files. Everything lives under the app-support folder (so `DJQ_HOME` scratch
/// covers dev runs), except the installed app and the `djq` link, which `DJQ_APP_DIR` / `DJQ_BIN_DIR` redirect.
public struct AutoUpdatePaths: Sendable {
  public var dir: URL
  public var logs: URL
  public var launchAgents: URL
  public var appDir: URL  // ~/Applications
  public var binDir: URL  // ~/bin (djq link)

  public init(_ paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) {
    dir = paths.appSupport.appendingPathComponent("autoupdate")
    logs = paths.logs
    launchAgents = paths.launchAgents
    // A dev run (DJQ_HOME set) never installs over the real app: without DJQ_APP_DIR / DJQ_BIN_DIR it uses
    // $DJQ_HOME/Applications and $DJQ_HOME/bin.
    let home = environment["DJQ_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: LaunchAgent.realHome)
    appDir = environment["DJQ_APP_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Applications")
    binDir = environment["DJQ_BIN_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("bin")
  }

  public static let appName = "DJ Queue.app"
  public var state: URL { dir.appendingPathComponent("state.json") }
  public var config: URL { dir.appendingPathComponent("config.json") }
  public var request: URL { dir.appendingPathComponent("request.json") }
  public var window: URL { dir.appendingPathComponent("window.json") }
  public var lock: URL { dir.appendingPathComponent("run.lock") }
  /// The bundle that was installed before the current one (kept for `djq autoupdate rollback`).
  public var previous: URL { dir.appendingPathComponent("previous/\(Self.appName)") }
  /// The previous bundle's predecessor, held only during an install so a failed verify can restore both slots.
  public var previousOlder: URL { dir.appendingPathComponent("previous-older/\(Self.appName)") }
  /// A gated build waiting for the window to close (or for "Restart & update").
  public var staged: URL { dir.appendingPathComponent("staged/\(Self.appName)") }
  /// The build a failed verify rolled back from (kept for a look; replaced by the next failure).
  public var failed: URL { dir.appendingPathComponent("failed/\(Self.appName)") }
  public var backups: URL { dir.appendingPathComponent("backups") }
  /// Scratch checkout the gate builds and tests in (its .build cache is kept between runs).
  public var work: URL { dir.appendingPathComponent("work") }
  public var runs: URL { dir.appendingPathComponent("runs") }
  public var log: URL { logs.appendingPathComponent("autoupdate.log") }
  public var installedApp: URL { appDir.appendingPathComponent(Self.appName) }
  public var watcherPlist: URL { launchAgents.appendingPathComponent("\(AutoUpdate.watcherLabel).plist") }
}

/// `config.json` — written by `djq autoupdate on|off` and Settings → Engine.
public struct AutoUpdateConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  /// Source checkout to watch (default ~/code/dj-queue; `DJQ_AUTOUPDATE_REPO` overrides).
  public var repo: String?
  public var branch: String
  /// Seconds the watcher waits after a trigger before reading the branch (a merge and its tag settle first).
  public var debounce: Double

  public init(enabled: Bool = true, repo: String? = nil, branch: String = "main", debounce: Double = 20) {
    self.enabled = enabled; self.repo = repo; self.branch = branch; self.debounce = debounce
  }

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    repo = try c.decodeIfPresent(String.self, forKey: .repo)
    branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
    debounce = try c.decodeIfPresent(Double.self, forKey: .debounce) ?? 20
  }

  public func repoPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let r = environment["DJQ_AUTOUPDATE_REPO"], !r.isEmpty { return r }
    return repo ?? URL(fileURLWithPath: LaunchAgent.realHome).appendingPathComponent("code/dj-queue").path
  }
}

/// One line of "What's new" (first-parent commits on main since the installed build).
public struct AutoUpdateCommit: Codable, Equatable, Hashable, Sendable {
  public var sha: String
  public var subject: String
  public init(sha: String, subject: String) { self.sha = sha; self.subject = subject }
}

/// A build: its version string (CFBundleShortVersionString, e.g. "0.6.0" or "0.6.0-dev.2") and commit.
public struct AutoUpdateBuild: Codable, Equatable, Sendable {
  public var version: String
  public var commit: String?
  public var at: Date?
  public init(version: String, commit: String?, at: Date? = nil) { self.version = version; self.commit = commit; self.at = at }
  public var shortCommit: String { commit.map { String($0.prefix(7)) } ?? "unknown" }
}

/// A gated build ready to install.
public struct AutoUpdateCandidate: Codable, Equatable, Sendable {
  public var version: String
  public var commit: String
  public var whatsNew: [AutoUpdateCommit]
  public var builtAt: Date
  /// True once Eric picked "Later": it installs when the window closes (it would anyway; this only changes wording).
  public var later: Bool
  public init(version: String, commit: String, whatsNew: [AutoUpdateCommit], builtAt: Date, later: Bool = false) {
    self.version = version; self.commit = commit; self.whatsNew = whatsNew; self.builtAt = builtAt; self.later = later
  }
}

/// Why an update didn't install (failed build or tests, a failed verify).
public struct AutoUpdateBlock: Codable, Equatable, Sendable {
  public var version: String
  public var commit: String
  /// One plain sentence ("2 tests failed: RenderTests.overlay, …").
  public var reason: String
  /// True when the build installed and then failed its checks (a gate block is false). Such a block only clears
  /// when a newer build installs and verifies, never because the failed build is "up to date".
  public var afterInstall: Bool = false
  /// Last lines of the failing step's output.
  public var detail: String
  /// Full output of the run.
  public var log: String?
  public var at: Date
  public init(version: String, commit: String, reason: String, detail: String, log: String?, at: Date, afterInstall: Bool = false) {
    self.version = version; self.commit = commit; self.reason = reason; self.detail = detail; self.log = log; self.at = at
    self.afterInstall = afterInstall
  }

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    version = try c.decode(String.self, forKey: .version)
    commit = try c.decode(String.self, forKey: .commit)
    reason = try c.decode(String.self, forKey: .reason)
    afterInstall = try c.decodeIfPresent(Bool.self, forKey: .afterInstall) ?? false
    detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    log = try c.decodeIfPresent(String.self, forKey: .log)
    at = try c.decode(Date.self, forKey: .at)
  }
}

/// The outcome of the last run, for `status`, Doctor and Settings.
public struct AutoUpdateResult: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case installed, skippedDocs, upToDate, ready, blocked, rolledBack, failed, waiting }
  public var kind: Kind
  public var message: String
  public var commit: String?
  public var at: Date
  public init(kind: Kind, message: String, commit: String?, at: Date) { self.kind = kind; self.message = message; self.commit = commit; self.at = at }
}

/// One install (newest last), kept for rollback: the schema before and after tells whether the older build can
/// still open the database, and `backup` is the copy taken just before the install.
public struct AutoUpdateInstall: Codable, Equatable, Sendable {
  public var to: AutoUpdateBuild
  public var from: AutoUpdateBuild?
  public var schemaBefore: Int
  public var schemaAfter: Int
  public var backup: String?
  public var at: Date
  public init(to: AutoUpdateBuild, from: AutoUpdateBuild?, schemaBefore: Int, schemaAfter: Int, backup: String?, at: Date) {
    self.to = to; self.from = from; self.schemaBefore = schemaBefore; self.schemaAfter = schemaAfter; self.backup = backup; self.at = at
  }
}

/// A notification for the app to deliver once (the runner has no notification rights; the app process does).
public struct AutoUpdateNotice: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var body: String
  public var at: Date
  public init(id: String, title: String, body: String, at: Date) { self.id = id; self.title = title; self.body = body; self.at = at }
}

/// `state.json`. Written only by the runner, atomically; read by the app, Doctor and `djq autoupdate status`.
public struct AutoUpdateState: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case idle, checking, testing, building, waitingForIdle, installing, verifying, rollingBack
    public var label: String {
      switch self {
      case .idle: "Idle"
      case .checking: "Checking for changes"
      case .testing: "Building and running tests"
      case .building: "Building the app"
      case .waitingForIdle: "Waiting for a render to finish"
      case .installing: "Installing"
      case .verifying: "Checking your data after the update"
      case .rollingBack: "Rolling back"
      }
    }
  }

  public var phase: Phase = .idle
  /// pid of the runner while a run is in progress (nil when idle).
  public var runPid: Int32?
  /// Commit the current run is working on.
  public var working: String?
  public var installed: AutoUpdateBuild?
  public var ready: AutoUpdateCandidate?
  public var blocked: AutoUpdateBlock?
  public var last: AutoUpdateResult?
  /// Commit + version last handled (installed, skipped or blocked), so a trigger with nothing new is a no-op.
  public var handled: String?
  /// Commit a rollback stepped back from: never reinstalled automatically (the next commit installs as usual).
  public var rolledBackFrom: String?
  /// After "Restart & update": the relaunched app opens its window again.
  public var reopenWindow: Bool = false
  public var history: [AutoUpdateInstall] = []
  public var notices: [AutoUpdateNotice] = []

  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? .idle
    runPid = try c.decodeIfPresent(Int32.self, forKey: .runPid)
    working = try c.decodeIfPresent(String.self, forKey: .working)
    installed = try c.decodeIfPresent(AutoUpdateBuild.self, forKey: .installed)
    ready = try c.decodeIfPresent(AutoUpdateCandidate.self, forKey: .ready)
    blocked = try c.decodeIfPresent(AutoUpdateBlock.self, forKey: .blocked)
    last = try? c.decodeIfPresent(AutoUpdateResult.self, forKey: .last)
    handled = try c.decodeIfPresent(String.self, forKey: .handled)
    rolledBackFrom = try c.decodeIfPresent(String.self, forKey: .rolledBackFrom)
    reopenWindow = try c.decodeIfPresent(Bool.self, forKey: .reopenWindow) ?? false
    history = try c.decodeIfPresent([AutoUpdateInstall].self, forKey: .history) ?? []
    notices = try c.decodeIfPresent([AutoUpdateNotice].self, forKey: .notices) ?? []
  }

  /// A run is in progress (its pid is alive). A crashed runner's leftover phase reads as idle.
  public var isRunning: Bool {
    guard phase != .idle, let p = runPid else { return false }
    return kill(p, 0) == 0
  }

  /// What the menu-bar dot shows: an update is ready, or one is blocked.
  public var needsAttention: Bool { ready != nil || blocked != nil }
}

/// `request.json` — the app's way to ask the runner for something (the watcher starts on any write).
public struct AutoUpdateRequest: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable {
    /// Launch check / "Check now": the same run a commit starts.
    case check
    /// "Restart & update": install the ready build now (after the engine is idle), then reopen the window.
    case install
    /// "Later": install when the window closes.
    case later
  }
  public var action: Action
  public var at: Date
  public init(action: Action, at: Date = Date()) { self.action = action; self.at = at }
}

/// `window.json` — written by the app when its main window opens or closes. The runner treats the window as
/// "in use" while it's open in a live process; it installs a ready build as soon as it isn't.
public struct AutoUpdateWindow: Codable, Equatable, Sendable {
  public var open: Bool
  public var pid: Int32
  public var at: Date
  public init(open: Bool, pid: Int32 = getpid(), at: Date = Date()) { self.open = open; self.pid = pid; self.at = at }
  public var inUse: Bool { open && kill(pid, 0) == 0 }
}

/// JSON files (atomic writes, ISO dates) + the log.
public struct AutoUpdateStore: Sendable {
  public let paths: AutoUpdatePaths
  public init(_ paths: AutoUpdatePaths) { self.paths = paths }
  public init(_ paths: Paths) { self.paths = AutoUpdatePaths(paths) }

  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
  }()
  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  func read<T: Decodable>(_ url: URL, _ type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? Self.decoder.decode(type, from: data)
  }

  func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.encoder.encode(value).write(to: url, options: .atomic)
  }

  public func state() -> AutoUpdateState { read(paths.state, AutoUpdateState.self) ?? AutoUpdateState() }
  public func saveState(_ s: AutoUpdateState) throws { try write(s, to: paths.state) }

  /// nil = never set up (`djq autoupdate on` or the v0.6.0 install writes it).
  public func configIfSet() -> AutoUpdateConfig? { read(paths.config, AutoUpdateConfig.self) }
  public func config() -> AutoUpdateConfig { configIfSet() ?? AutoUpdateConfig() }
  public func saveConfig(_ c: AutoUpdateConfig) throws { try write(c, to: paths.config) }

  public func request() -> AutoUpdateRequest? { read(paths.request, AutoUpdateRequest.self) }
  public func saveRequest(_ r: AutoUpdateRequest) throws { try write(r, to: paths.request) }
  /// Clears the request (left as an empty file so the watcher's WatchPaths entry keeps a target).
  public func clearRequest() { try? Data().write(to: paths.request, options: .atomic) }

  public func window() -> AutoUpdateWindow? { read(paths.window, AutoUpdateWindow.self) }
  public func saveWindow(_ w: AutoUpdateWindow) throws { try write(w, to: paths.window) }

  /// Appends one timestamped line to `~/Library/Logs/DJ Queue/autoupdate.log` (rotated at 2 MB, keeps 1).
  public func log(_ line: String) {
    let fm = FileManager.default
    try? fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    let url = paths.log
    if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
      let old = url.appendingPathExtension("1")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: url, to: old)
    }
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    let data = Data("\(f.string(from: Date())) \(line)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(data)
      try? h.close()
    } else {
      try? data.write(to: url)
    }
  }

  /// Last `n` lines of the log.
  public func logTail(_ n: Int) -> [String] {
    guard let s = try? String(contentsOf: paths.log, encoding: .utf8) else { return [] }
    return Array(s.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).map(String.init))
  }
}

/// Info.plist of a bundle: version + what build-app.sh stamps (`DJQGitCommit`, `DJQSchemaVersion`).
public enum BundleInfo {
  public static func build(_ app: URL) -> AutoUpdateBuild? {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let d = NSDictionary(contentsOf: plist), let v = d["CFBundleShortVersionString"] as? String else { return nil }
    return AutoUpdateBuild(version: v, commit: (d["DJQGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 })
  }

  /// The database schema the bundle's code expects (nil for bundles built before v0.6.0).
  public static func schema(_ app: URL) -> Int? {
    let d = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    if let n = d?["DJQSchemaVersion"] as? Int { return n }
    return (d?["DJQSchemaVersion"] as? String).flatMap(Int.init)
  }
}

/// A non-blocking exclusive lock (`flock`) that serialises runs; released when the object goes away.
public final class AutoUpdateLock: @unchecked Sendable {
  private var fd: Int32
  private init(fd: Int32) { self.fd = fd }

  public static func acquire(_ url: URL) -> AutoUpdateLock? {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return nil
    }
    return AutoUpdateLock(fd: fd)
  }

  public func release() {
    guard fd >= 0 else { return }
    flock(fd, LOCK_UN)
    close(fd)
    fd = -1
  }

  deinit { release() }
}
