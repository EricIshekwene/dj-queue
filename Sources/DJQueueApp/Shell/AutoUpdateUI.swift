import AppKit
import DJQCore
import SwiftUI

/// The app's side of auto-update (round 4 S5, DECISIONS-R4-AUTOUPDATE.md 14–16). The runner (`djq autoupdate run`)
/// is the only writer of `state.json`; this controller reads it (on the runner's distributed signal, plus every
/// 30 s), asks for things through `AutoUpdateClient` (request.json / window.json), delivers the runner's notices once,
/// and relaunches the app after an install when no engine LaunchAgent can restart it. The banner, the menu-bar dot
/// and Settings → Engine all read it.
///
/// `DJQ_AUTOUPDATE_FAKE=ready|blocked|installing` replaces the state with canned values (snapshots, dev looks) and
/// turns every side effect off.
@MainActor
@Observable
final class AutoUpdateUI {
  static let shared = AutoUpdateUI()

  enum Fake: String { case ready, blocked, installing }

  /// What the banner at the top of the content column shows.
  enum Banner: Equatable {
    case ready(AutoUpdateCandidate)
    /// "Restart & update" was asked, or the runner is installing: the phase label with a spinner.
    case working(label: String, version: String?)
    case blocked(AutoUpdateBlock)
  }

  /// The small dot on the menu-bar icon (distinct from the red "needs attention" dot).
  enum Dot: Equatable {
    case none
    case ready(String)
    case blocked(String)
  }

  private(set) var state = AutoUpdateState()
  /// config.json exists (auto-update was set up) …
  private(set) var configured = false
  /// … and says on.
  private(set) var enabled = false
  /// Settings → Engine: why the last switch change didn't fully apply (dev runs, launchctl).
  var settingsError: String?
  /// When "Restart & update" was pressed (the banner shows the runner's phase until it finishes).
  private(set) var installRequestedAt: Date?
  /// Commit whose ready banner "Later" hid.
  private(set) var hiddenReady: String?
  /// Commit whose blocked banner was dismissed.
  private(set) var dismissedBlocked: String?
  private(set) var paths: Paths?
  let fake: Fake?

  @ObservationIgnored private var started = false
  @ObservationIgnored private var windowOpen: Bool?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var distributed: [NSObjectProtocol] = []
  @ObservationIgnored private var timer: Timer?
  /// Every AutoUpdateClient call goes through one serial queue, so window.json and request.json writes land in the
  /// order they were made (window state before the launch check; a fast close + reopen ends "open").
  @ObservationIgnored private let client = DispatchQueue(label: "djq.autoupdate.client", qos: .utility)

  /// The build this process runs, read once at launch: after an install the bundle path on disk holds the new
  /// build, so re-reading its Info.plist would say "already up to date" in the old process.
  let launchBuild: AutoUpdateBuild? = AutoUpdateUI.readLaunchBuild()
  /// Where this process runs from, captured at launch (standardised).
  let launchBundlePath = Bundle.main.bundleURL.standardizedFileURL.path

  private enum Key {
    static let later = "djq.autoupdate.laterCommit"
    static let dismissed = "djq.autoupdate.dismissedBlocked"
    static let delivered = "djq.autoupdate.deliveredNotices"
    static let reopened = "djq.autoupdate.reopenedInstallAt"
  }

  static let mainWindowName = "DJQueueMain"
  /// Longest the banner shows "Starting the update" when no run reports back (launchd throttles the watcher to one
  /// start per 30 s, so a request can wait that long). A finished run newer than the request clears it sooner.
  static let requestGrace: TimeInterval = 120

  private init() {
    fake = ProcessInfo.processInfo.environment["DJQ_AUTOUPDATE_FAKE"].flatMap(Fake.init(rawValue:))
    if let fake {
      state = Self.fakeState(fake)
      configured = true
      enabled = true
    } else {
      hiddenReady = UserDefaults.standard.string(forKey: Key.later)
      dismissedBlocked = UserDefaults.standard.string(forKey: Key.dismissed)
    }
  }

  // MARK: Environment

  private static let env = ProcessInfo.processInfo.environment
  static var isDev: Bool { ["DJQ_HOME", "DJQ_ROOT"].contains { !(env[$0] ?? "").isEmpty } }
  /// A dev run with DJQ_ROOT but no DJQ_HOME (and no DJQ_APP_DIR + DJQ_BIN_DIR): its app-support folder, installed
  /// app and LaunchAgents are the real ones, so the app never asks the runner or changes the setting from here.
  /// (With DJQ_HOME set, the core puts the app and the `djq` link under $DJQ_HOME.)
  static var devUnsafe: Bool {
    isDev && (env["DJQ_HOME"] ?? "").isEmpty && ["DJQ_APP_DIR", "DJQ_BIN_DIR"].contains { (env[$0] ?? "").isEmpty }
  }

  static func readLaunchBuild() -> AutoUpdateBuild? {
    guard let info = Bundle.main.infoDictionary, let v = info["CFBundleShortVersionString"] as? String else { return nil }
    return AutoUpdateBuild(version: v, commit: (info["DJQGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 })
  }

  /// The `djq` that runs the runner when the watcher isn't loaded: the one inside this bundle, else the one beside
  /// this executable (a dev `.build/debug` run).
  static var djqURL: URL? {
    let fm = FileManager.default
    let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/djq")
    if fm.isExecutableFile(atPath: inBundle.path) { return inBundle }
    if let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("djq"),
       fm.isExecutableFile(atPath: beside.path) { return beside }
    return nil
  }

  // MARK: Start

  /// Idempotent. Called from the menu-bar label (every launch mode but snapshots shows it), the banner and the popover.
  func start(host: AppHost) {
    guard !started, fake == nil else { return }
    if case .snapshot = host.mode { return }
    guard let p = host.model?.store.paths else { return }
    started = true
    paths = p
    Log.shared.info("autoupdate: app side started (\(host.mode == .agent ? "agent" : "normal") launch, build \(launchBuild?.version ?? "dev"))")
    refresh()
    observe()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
      Task { @MainActor in
        AutoUpdateUI.shared.refresh()
        AutoUpdateUI.shared.evaluateWindow()
      }
    }
    // Window state first (the client queue is serial), then the launch check (S5-R4: a launch runs the same check a
    // commit does, once auto-update is set up and on), so the runner never reads a stale window.json.
    evaluateWindow()
    if configured, enabled { ask(.check) }
  }

  /// Settings → Engine in a snapshot (no `start`): read state for these paths without any side effects.
  func attach(_ p: Paths) {
    guard paths == nil else { return }
    paths = p
    refresh()
  }

  // MARK: Refresh

  func refresh() {
    if let fake {
      let s = Self.fakeState(fake)
      if s.phase != state.phase || s.ready != state.ready || s.blocked != state.blocked { state = s }
      return
    }
    guard let paths else { return }
    let store = AutoUpdateStore(paths)
    let s = store.state()
    if s != state { state = s }
    let c = store.configIfSet()
    if configured != (c != nil) { configured = c != nil }
    if enabled != (c?.enabled ?? false) { enabled = c?.enabled ?? false }
    if let t = installRequestedAt, !state.isRunning,
       (state.last?.at ?? .distantPast) > t || Date().timeIntervalSince(t) > Self.requestGrace { installRequestedAt = nil }
    guard started else { return }
    deliverNotices()
    reopenIfAsked()
  }

  /// Each notice once (the runner has no notification rights), only while it's fresh (< 1 h).
  private func deliverNotices() {
    let ids = state.notices.map(\.id)
    let seen = Set(UserDefaults.standard.stringArray(forKey: Key.delivered) ?? [])
    guard ids.contains(where: { !seen.contains($0) }) else { return }
    for n in state.notices where !seen.contains(n.id) && Date().timeIntervalSince(n.at) < 3600 {
      UserNotifier.shared.deliver(AppNotification(key: "autoupdate:\(n.id)", title: n.title, body: n.body, actions: [.open]))
    }
    // The runner keeps the last 10 notices; anything it dropped can't come back, so the current ids are enough.
    UserDefaults.standard.set(ids, forKey: Key.delivered)
  }

  /// After "Restart & update" the relaunched app opens its window again, once per install, and only in the process
  /// running the build that was just installed (the old process may still see the state for a moment).
  private func reopenIfAsked() {
    guard state.reopenWindow, let installed = state.installed, let at = installed.at else { return }
    guard at.timeIntervalSince1970 > UserDefaults.standard.double(forKey: Key.reopened) else { return }
    guard let mine = launchBuild, mine.commit == installed.commit, mine.version == installed.version else { return }
    UserDefaults.standard.set(at.timeIntervalSince1970, forKey: Key.reopened)
    guard Date().timeIntervalSince(at) < 600 else { return }
    WindowManager.shared.showMain()
  }

  // MARK: Observers

  private func observe() {
    let nc = NotificationCenter.default
    // Any of these can change whether the main window is on screen; the state is re-read from the window itself.
    let names = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification,
                 NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification]
    for name in names {
      observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
        MainActor.assumeIsolated {
          guard let w = note.object as? NSWindow, w.frameAutosaveName == AutoUpdateUI.mainWindowName else { return }
          AutoUpdateUI.shared.evaluateWindow()
        }
      })
    }
    observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      MainActor.assumeIsolated {
        guard let w = note.object as? NSWindow, w.frameAutosaveName == AutoUpdateUI.mainWindowName else { return }
        AutoUpdateUI.shared.evaluateWindow(closing: w)
      }
    })
    observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { AutoUpdateUI.shared.setWindow(open: false, now: true) }
    })
    let dnc = DistributedNotificationCenter.default()
    // Signals name the database they're about: a dev run's runner never moves this app (and the other way round).
    distributed.append(dnc.addObserver(forName: .init(AutoUpdate.changedSignal), object: nil, queue: .main) { note in
      let scope = note.userInfo?[AutoUpdate.scopeKey] as? String
      Task { @MainActor in
        guard let p = AutoUpdateUI.shared.paths, AutoUpdate.isFor(scope.map { [AutoUpdate.scopeKey: $0] }, p) else { return }
        AutoUpdateUI.shared.refresh()
      }
    })
    distributed.append(dnc.addObserver(forName: .init(AutoUpdate.restartSignal), object: nil, queue: .main) { note in
      let scope = note.userInfo?[AutoUpdate.scopeKey] as? String
      Task { @MainActor in
        guard let p = AutoUpdateUI.shared.paths, AutoUpdate.isFor(scope.map { [AutoUpdate.scopeKey: $0] }, p) else { return }
        AutoUpdateUI.shared.handleRestart()
      }
    })
  }

  /// The main window counts as in use while it's on screen (visible, even if another app has focus or it's covered)
  /// or minimised; it stops when it closes. Re-read from the window, so close-then-reopen ends "open".
  func evaluateWindow(closing: NSWindow? = nil) {
    guard started else { return }
    let w = NSApp.windows.first { $0.frameAutosaveName == Self.mainWindowName }
    let open = w.map { $0 !== closing && ($0.isVisible || $0.isMiniaturized) } ?? false
    setWindow(open: open)
  }

  /// Tells the runner whether the main window is in use (Later = "install when the window closes").
  /// `now` writes synchronously (app termination).
  private func setWindow(open: Bool, now: Bool = false) {
    guard windowOpen != open, let paths, fake == nil, !Self.devUnsafe else { return }
    windowOpen = open
    let djq = Self.djqURL
    if now {
      client.sync { AutoUpdateClient.windowChanged(open: open, paths: paths, djq: djq) }
    } else {
      client.async { AutoUpdateClient.windowChanged(open: open, paths: paths, djq: djq) }
    }
  }

  /// The runner installed a build but no engine LaunchAgent could restart us: relaunch from the installed bundle.
  /// Acts only in the installed app itself (this process runs from the runner's installed-app path) and never in a
  /// dev run (DJQ_HOME / DJQ_ROOT) or a `.build` binary; under the loaded LaunchAgent launchd restarts us, so a
  /// process ignores the signal then. A copy relaunched without its window runs as `--agent` and must still follow
  /// the next update, hence the check is on the agent, not the launch mode.
  private func handleRestart() {
    guard fake == nil, !Self.isDev, let paths, let mine = launchBuild else { return }
    if case .snapshot = AppHost.shared.mode { return }
    let app = AutoUpdatePaths(paths).installedApp
    guard app.standardizedFileURL.path == launchBundlePath else { return }
    // Keep the window as it was: open → plain launch (it opens its window); closed → menu bar only.
    let windowOpen = NSApp.windows.contains { $0.frameAutosaveName == Self.mainWindowName && ($0.isVisible || $0.isMiniaturized) }
    Task {
      let relaunch = await Task.detached(priority: .userInitiated) { () -> Bool in
        if LaunchAgent.isLoaded() { return false }
        // The installed bundle now holds a different build than the one this process started with.
        guard let installed = BundleInfo.build(app) else { return false }
        return installed.commit != mine.commit || installed.version != mine.version
      }.value
      guard relaunch else { return }
      Log.shared.info("autoupdate: relaunching from the installed \(BundleInfo.build(app)?.version ?? "?")")
      Self.relaunch(app, agent: !windowOpen)
      NSApp.terminate(nil)
    }
  }

  /// Opens the bundle once this process has exited (it waits for our pid), so there's never a second copy:
  /// a plain `open` (no `-n`) then launches the new build.
  private static func relaunch(_ app: URL, agent: Bool) {
    var args = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$@\"",
                String(getpid()), app.path]
    if agent { args += ["--args", "--agent"] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
  }

  // MARK: Actions

  /// Why the app can't ask the runner right now (nil = it can). Used as `disabledReason`.
  var actionBlockedReason: String? {
    if fake != nil { return nil }
    if paths == nil { return "DJ Queue is still starting." }
    if Self.devUnsafe { return "Dev run with DJQ_ROOT only: set DJQ_HOME too, so an update can't touch the installed app." }
    return nil
  }

  var checkBlockedReason: String? {
    if let r = actionBlockedReason { return r }
    if state.isRunning { return "A check is already running: \(state.phase.label.lowercased())." }
    if !enabled { return "Turn on Install updates from main first." }
    return nil
  }

  /// "Restart & update": install the ready build now. The runner waits for any render to finish first (S5-R3).
  func restartAndUpdate() {
    guard state.ready != nil, actionBlockedReason == nil else { return }
    installRequestedAt = Date()
    ask(.install)
  }

  /// "Later": hide the banner for this build; it installs when the window closes.
  func later() {
    guard let r = state.ready else { return }
    hiddenReady = r.commit
    if fake == nil { UserDefaults.standard.set(r.commit, forKey: Key.later) }
    ask(.later)
  }

  func checkNow() {
    guard checkBlockedReason == nil else { return }
    ask(.check)
  }

  /// Hides the blocked banner (and the menu-bar dot) for this commit; the menu-bar row stays.
  func dismissBlocked() {
    guard let b = problem else { return }
    dismissedBlocked = b.commit
    if fake == nil { UserDefaults.standard.set(b.commit, forKey: Key.dismissed) }
  }

  /// Menu bar "Show why": bring the blocked banner back and open the window.
  func showBlocked() {
    dismissedBlocked = nil
    if fake == nil { UserDefaults.standard.removeObject(forKey: Key.dismissed) }
    WindowManager.shared.showMain()
  }

  /// The run log of the block, else the auto-update log.
  var logURL: URL? {
    let fm = FileManager.default
    if let l = problem?.log, fm.fileExists(atPath: l) { return URL(fileURLWithPath: l) }
    guard let paths else { return nil }
    let log = AutoUpdatePaths(paths).log
    return fm.fileExists(atPath: log.path) ? log : nil
  }

  func openLog() {
    if let u = logURL { NSWorkspace.shared.open(u) }
  }

  private func ask(_ action: AutoUpdateRequest.Action) {
    guard fake == nil, let paths, !Self.devUnsafe else { return }
    let djq = Self.djqURL
    client.async { AutoUpdateClient.ask(action, paths: paths, djq: djq) }
  }

  /// Settings → Engine "Install updates from main": saves the config, then installs or removes the watcher.
  /// Dev runs can't install the watcher (DJQ_HOME / DJQ_ROOT): the setting is still saved and the error shown.
  func setEnabled(_ on: Bool) {
    guard fake == nil, let paths else { return }
    settingsError = nil
    if Self.devUnsafe {
      // DJQ_ROOT without DJQ_HOME: these are the real config and LaunchAgents folders.
      settingsError = "Not changed: this dev run (DJQ_ROOT without DJQ_HOME) would edit the installed app's setting and watcher."
      return
    }
    let store = AutoUpdateStore(paths)
    var c = store.config()
    c.enabled = on
    do {
      try store.saveConfig(c)
    } catch {
      settingsError = "Couldn't save the setting: \(error.localizedDescription)"
      return
    }
    configured = true
    enabled = on
    let au = AutoUpdatePaths(paths)
    let dev = Self.isDev
    let repo = c.repoPath(), branch = c.branch
    Task {
      let err = await Task.detached(priority: .userInitiated) { () -> String? in
        do {
          // A dev run never unloads the real watcher (same label for every copy).
          if on { try AutoUpdateWatcher.install(au, repo: repo, branch: branch, load: true) } else { try AutoUpdateWatcher.uninstall(au, unload: !dev) }
          return nil
        } catch {
          return error.localizedDescription
        }
      }.value
      if let err {
        settingsError = on ? "Saved, but the update watcher isn't running: \(err)" : "Saved, but the update watcher wasn't removed: \(err)"
      }
    }
  }

  // MARK: Derived

  var isWorking: Bool {
    let s = state
    let installing: Set<AutoUpdateState.Phase> = [.waitingForIdle, .installing, .verifying, .rollingBack]
    return (s.isRunning && installing.contains(s.phase)) || installRequestedAt != nil
  }

  /// What the blocked banner, dot and row show: a build that failed its checks and stayed installed first (it's the
  /// one running), else a gate block.
  var problem: AutoUpdateBlock? { state.failedInstall ?? state.blocked }

  var workingLabel: String { state.isRunning && state.phase != .idle ? state.phase.label : "Starting the update" }

  var banner: Banner? {
    if isWorking { return .working(label: workingLabel, version: state.ready?.version) }
    if let r = state.ready, !r.later, hiddenReady != r.commit { return .ready(r) }
    if let b = problem, dismissedBlocked != b.commit { return .blocked(b) }
    return nil
  }

  var dot: Dot {
    if let r = state.ready { return .ready(r.version) }
    if let b = problem, dismissedBlocked != b.commit { return .blocked(b.version) }
    return .none
  }

  /// One line for the status item's help tag ("Update 0.6.0 ready").
  var statusText: String? {
    if isWorking { return "Updating: \(workingLabel.lowercased())" }
    if let r = state.ready { return "Update \(r.version) ready" }
    if let b = problem { return b.afterInstall ? "Update \(b.version) failed its checks" : "Update \(b.version) blocked" }
    return nil
  }

  // MARK: Fake (snapshots)

  static func fakeState(_ f: Fake) -> AutoUpdateState {
    let now = Date()
    var s = AutoUpdateState()
    let head = "9d4e7f21c0b8a3e5f6a7b8c9d0e1f2a3b4c5d6e7"
    s.installed = AutoUpdateBuild(version: "0.5.0", commit: "4f2c9a1e8b7d6c5a4f3e2d1c0b9a8f7e6d5c4b3a", at: now.addingTimeInterval(-2 * 86400))
    let ready = AutoUpdateCandidate(version: "0.6.0", commit: head, whatsNew: [
      AutoUpdateCommit(sha: head, subject: "Settings → Engine: auto-update switch, status and log"),
      AutoUpdateCommit(sha: "7a1b2c3d4e5f60718293a4b5c6d7e8f901234567", subject: "Update ready banner with What's new, Restart & update and Later"),
      AutoUpdateCommit(sha: "3c9e8d7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d", subject: "Auto-update core: watcher, gated install with backup, verify and rollback"),
    ], builtAt: now.addingTimeInterval(-300))
    switch f {
    case .ready:
      s.ready = ready
      s.last = AutoUpdateResult(kind: .ready, message: "0.6.0 is ready; it installs when the window closes (or on Restart & update).",
                                commit: head, at: now.addingTimeInterval(-300))
    case .installing:
      s.ready = ready
      s.phase = .waitingForIdle
      s.runPid = getpid()
      s.working = head
      s.last = AutoUpdateResult(kind: .ready, message: "0.6.0 is ready; it installs when the window closes (or on Restart & update).",
                                commit: head, at: now.addingTimeInterval(-300))
    case .blocked:
      let reason = "2 tests failed: AutoUpdateTests.rollbackRefusedAfterMigration, RenderTests.overlayPosition"
      s.blocked = AutoUpdateBlock(version: "0.6.0", commit: head, reason: reason,
                                  detail: "✘ Test rollbackRefusedAfterMigration() failed\n✘ Test overlayPosition() failed", log: nil,
                                  at: now.addingTimeInterval(-600))
      s.last = AutoUpdateResult(kind: .blocked, message: "0.6.0 (9d4e7f2) blocked: \(reason)", commit: head, at: now.addingTimeInterval(-600))
    }
    return s
  }
}
