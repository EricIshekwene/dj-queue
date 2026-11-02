import Foundation
import SQLite3

/// The auto-update pipeline (S5): commit on main → gate (tests + app build in a scratch checkout) → DB backup →
/// install → engine restart → verify (ids, scores, titles, counts; no new Doctor errors) → notice. A failed gate
/// blocks the update (nothing installed); a failed verify rolls back to the kept previous bundle.
///
/// One run at a time (`run.lock`); a commit that lands mid-run is picked up by the same run before it ends, so a
/// burst of commits costs one extra pass, not one per commit. The runner never pushes, pulls or fetches from GitHub:
/// it reads the local checkout only.
public final class AutoUpdateRunner: @unchecked Sendable {
  public enum Trigger: String, Sendable, CaseIterable {
    /// The watcher LaunchAgent (a commit, a tag, a request or the window file changed).
    case watch
    /// The app started (launch check).
    case launch
    /// `djq autoupdate run` by hand (runs even when auto-update is off).
    case manual
  }

  public let paths: Paths
  public let au: AutoUpdatePaths
  public let files: AutoUpdateStore
  public var environment: [String: String]
  /// Commands run in order inside the scratch checkout; the last one must leave `build/DJ Queue.app`.
  public var gate: [[String]] = AutoUpdateRunner.defaultGate
  /// How the runner restarts, stops and starts the engine (tests and dev runs swap this out).
  public var engine: AutoUpdateEngineControl
  /// Longest wait for the restarted engine's first heartbeat before verify fails.
  public var heartbeatTimeout: TimeInterval = 90
  /// Longest wait for a running render before giving up until the next trigger.
  public var idleTimeout: TimeInterval = 2 * 3600
  public var pollInterval: TimeInterval = 10
  /// Pause after the engine restart before verifying (the new engine opens and migrates the database).
  public var settle: TimeInterval = 5
  /// Longest a single gate command may run.
  public var stepTimeout: TimeInterval = 45 * 60
  public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  /// Progress lines (the CLI prints them; the watcher's stdout goes to a log).
  public var progress: (String) -> Void = { print($0) }
  public var now: () -> Date = { Date() }

  public static let defaultGate: [[String]] = [["/bin/zsh", "scripts/test.sh"], ["/bin/zsh", "scripts/build-app.sh"]]

  public init(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.paths = paths
    self.environment = environment
    au = AutoUpdatePaths(paths, environment: environment)
    files = AutoUpdateStore(au)
    engine = .live(paths: paths, environment: environment)
  }

  var isDev: Bool { ["DJQ_HOME", "DJQ_ROOT"].contains { !(environment[$0] ?? "").isEmpty } }

  // MARK: State helpers

  private var state = AutoUpdateState()

  private func save() {
    do { try files.saveState(state) } catch { files.log("ERROR can't write state: \(error)") }
    AutoUpdate.postChanged(paths)
  }

  private func phase(_ p: AutoUpdateState.Phase, _ line: String? = nil) {
    state.phase = p
    save()
    if let line { say(line) }
  }

  private func say(_ line: String) {
    files.log(line)
    progress(line)
  }

  private func finish(_ kind: AutoUpdateResult.Kind, _ message: String, commit: String?) -> AutoUpdateResult {
    let r = AutoUpdateResult(kind: kind, message: message, commit: commit, at: now())
    state.last = r
    say("\(kind.rawValue): \(message)")
    return r
  }

  private func notice(_ title: String, _ body: String, _ kind: String, _ commit: String?) {
    let id = "\(kind)-\(commit.map { String($0.prefix(7)) } ?? "none")-\(Int(now().timeIntervalSince1970))"
    state.notices.append(AutoUpdateNotice(id: id, title: title, body: body, at: now()))
    state.notices = Array(state.notices.suffix(10))
  }

  // MARK: Run

  /// One run: handles requests from the app, gates the newest commit on the branch if it's new, and installs a
  /// ready build when the window isn't in use (or right away for "Restart & update"). Returns the last outcome.
  @discardableResult
  public func run(trigger: Trigger, force: Bool = false) -> AutoUpdateResult {
    guard let lock = AutoUpdateLock.acquire(au.lock) else {
      // The running pass re-reads the branch and the request file before it ends, so nothing is lost.
      let r = AutoUpdateResult(kind: .waiting, message: "An update run is already in progress; it picks up the newest commit before it ends.",
                               commit: nil, at: now())
      files.log("\(trigger.rawValue): \(r.message)")
      progress(r.message)
      return r
    }
    defer { lock.release() }
    state = files.state()
    if AutoUpdate.unsafeDevEnvironment(environment) {
      say("refused: DJQ_ROOT is set without DJQ_HOME, so this run would install over the real app")
      return AutoUpdateResult(kind: .failed, message: "Refused: DJQ_ROOT is set without DJQ_HOME (a dev run would install over the real app).", commit: nil, at: now())
    }
    let config = files.config()
    let request = takeRequest()
    // Never set up (no config.json) counts as off for automatic triggers: only `djq autoupdate on` (the v0.6.0
    // install runs it) starts installing on its own.
    let on = config.enabled && files.configIfSet() != nil
    if !on, trigger != .manual, request?.action != .install {
      say("\(trigger.rawValue): auto-update is off (djq autoupdate on turns it back on)")
      return AutoUpdateResult(kind: .upToDate, message: "Auto-update is off.", commit: nil, at: now())
    }
    state.runPid = getpid()
    if trigger == .watch, config.debounce > 0, request == nil {
      // A merge is often followed by its tag within seconds: read the branch once things settle.
      sleep(config.debounce)
    }
    var installNow = request?.action == .install
    if request?.action == .later { state.ready?.later = true }
    var result = AutoUpdateResult(kind: .upToDate, message: "Nothing to do.", commit: nil, at: now())
    var force = force
    for _ in 0..<6 {
      let repo = config.repoPath(environment: environment)
      guard let head = git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/\(config.branch)^{commit}"]) else {
        result = finish(.failed, "Can't read branch \(config.branch) in \(repo).", commit: nil)
        break
      }
      result = pass(repo: repo, head: head, force: force, installNow: &installNow)
      force = false
      // Another commit or request arrived while this pass ran: one more pass handles all of them.
      let again = git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/\(config.branch)^{commit}"])
      let r = takeRequest()
      if r?.action == .install { installNow = true }
      if r?.action == .later { state.ready?.later = true }
      if again == head && r == nil { break }
      say("new \(again != head ? "commit" : "request") arrived during the run; checking again")
    }
    state.phase = .idle
    state.runPid = nil
    state.working = nil
    save()
    return result
  }

  private func takeRequest() -> AutoUpdateRequest? {
    guard let r = files.request() else { return nil }
    files.clearRequest()
    files.log("request: \(r.action.rawValue)")
    return r
  }

  private func pass(repo: String, head: String, force: Bool, installNow: inout Bool) -> AutoUpdateResult {
    let short = String(head.prefix(7))
    let version = describeVersion(repo, head)
    let key = "\(head) \(version)"
    let installed = installedBuild(repo)
    state.working = head
    phase(.checking)

    if installed?.commit == head, installed?.version == version, !force {
      state.handled = key
      // A gate block on an older commit is over; a build that failed its checks and was left installed stays flagged.
      if let b = state.blocked, !b.afterInstall || b.commit != head, isAncestor(repo, b.commit, of: head) { state.blocked = nil }
      if let r = state.ready, isAncestor(repo, r.commit, of: head) { state.ready = nil }
      if let b = state.blocked, b.afterInstall, b.commit == head {
        return finish(.failed, "Installed \(version) (\(short)) failed its checks after install: \(b.reason)", commit: head)
      }
      return finish(.upToDate, "Installed \(version) (\(short)) is the newest build.", commit: head)
    }
    if let ready = state.ready, ready.commit == head, ready.version == version, FileManager.default.fileExists(atPath: au.staged.path) {
      return installOrWait(repo: repo, candidate: ready, installNow: &installNow)
    }
    if let rb = state.rolledBackFrom, !force {
      if rb == head {
        state.handled = key
        return finish(.upToDate, "\(short) was rolled back; the next commit installs as usual.", commit: head)
      }
      // Docs on top of a rolled-back commit don't bring its code back.
      if isAncestor(repo, rb, of: head), AutoUpdate.isDocsOnly(changedFiles(repo, rb, head)) {
        state.rolledBackFrom = head
        state.handled = key
        return finish(.skippedDocs, "Skipped \(short): only docs changed since the rolled-back \(String(rb.prefix(7))).", commit: head)
      }
    }
    if state.handled == key, !force {
      if let ready = state.ready, FileManager.default.fileExists(atPath: au.staged.path) {
        return installOrWait(repo: repo, candidate: ready, installNow: &installNow)
      }
      return state.last ?? finish(.upToDate, "Nothing new on main since \(short).", commit: head)
    }
    if let ic = installed?.commit, ic != head, isAncestor(repo, ic, of: head), !force {
      let changed = changedFiles(repo, ic, head)
      if AutoUpdate.isDocsOnly(changed) {
        state.handled = key
        // A block on a commit this one contains is over: main is back to the installed code plus docs.
        if let b = state.blocked, isAncestor(repo, b.commit, of: head) { state.blocked = nil }
        return finish(.skippedDocs, "Skipped \(short): only docs changed (\(changed.count) file\(changed.count == 1 ? "" : "s")).", commit: head)
      }
    }

    // Gate.
    let logURL = au.runs.appendingPathComponent("\(stamp())-\(short).log")
    switch runGate(repo: repo, head: head, log: logURL) {
    case .failure(let block):
      var b = block
      b.version = version
      state.blocked = b
      state.handled = key
      notice("Update blocked", "\(version): \(b.reason)", "blocked", head)
      pruneRuns()
      return finish(.blocked, "\(version) (\(short)) blocked: \(b.reason)", commit: head)
    case .success(let bundle):
      let built = BundleInfo.build(bundle)
      let candidate = AutoUpdateCandidate(version: built?.version ?? version, commit: head,
                                          whatsNew: whatsNew(repo, from: installed?.commit, to: head), builtAt: now())
      do {
        try replace(au.staged, with: bundle, move: true)
      } catch {
        state.handled = key
        return finish(.failed, "Couldn't stage the build: \(error)", commit: head)
      }
      if let b = state.blocked, isAncestor(repo, b.commit, of: head) { state.blocked = nil }
      state.ready = candidate
      state.handled = key
      pruneRuns()
      say("gate passed for \(candidate.version) (\(short)); \(candidate.whatsNew.count) change(s)")
      return installOrWait(repo: repo, candidate: candidate, installNow: &installNow)
    }
  }

  private func installOrWait(repo: String, candidate: AutoUpdateCandidate, installNow: inout Bool) -> AutoUpdateResult {
    let windowOpen = files.window()?.inUse == true
    if windowOpen && !installNow {
      if state.last?.kind != .ready || state.last?.commit != candidate.commit {
        notice("Update ready: \(candidate.version)", "\(candidate.whatsNew.count) change\(candidate.whatsNew.count == 1 ? "" : "s"). Restart & update from the banner, or it installs when you close the window.",
               "ready", candidate.commit)
      }
      save()
      return finish(.ready, "\(candidate.version) is ready; it installs when the window closes (or on Restart & update).", commit: candidate.commit)
    }
    let reopen = installNow && windowOpen
    installNow = false
    return install(repo: repo, candidate: candidate, reopenWindow: reopen)
  }

  // MARK: Install

  private func install(repo: String, candidate: AutoUpdateCandidate, reopenWindow: Bool) -> AutoUpdateResult {
    let short = String(candidate.commit.prefix(7))
    // Never interrupt a render: wait for the engine to be idle.
    var waited: TimeInterval = 0
    if renderingCount() > 0 {
      phase(.waitingForIdle, "waiting for a render to finish before installing \(candidate.version)")
      while renderingCount() > 0 {
        if waited >= idleTimeout {
          save()
          return finish(.waiting, "A render is still running after \(Int(idleTimeout / 60)) min; \(candidate.version) installs on the next check.", commit: candidate.commit)
        }
        sleep(pollInterval)
        waited += pollInterval
      }
    }

    phase(.installing, "installing \(candidate.version) (\(short))")
    let fm = FileManager.default
    let hasDB = fm.fileExists(atPath: paths.database.path)
    // Fail closed: an unreadable schema would make every later rollback and restore guard guess.
    guard let schemaBefore = hasDB ? userVersion() : 0 else {
      save()
      return finish(.failed, "Couldn't read the database schema, nothing installed (is the database locked or damaged?).", commit: candidate.commit)
    }
    let current = BundleInfo.build(au.installedApp)
    let currentDJQ = djq(in: au.installedApp)
    let before = currentDJQ.flatMap { fingerprint($0) }
    let errorsBefore = currentDJQ.flatMap { doctorErrors($0) } ?? []
    var backupPath: String?
    do {
      backupPath = try backupDatabase(label: candidate.version)?.path
    } catch {
      save()
      return finish(.failed, "Database backup failed, nothing installed: \(error)", commit: candidate.commit)
    }
    if let b = backupPath { say("database backed up to \(b)") }

    let hadPrevious = fm.fileExists(atPath: au.installedApp.path)
    // The kept build's predecessor waits aside until verify passes, so a rollback leaves a kept build behind.
    try? fm.removeItem(at: au.previousOlder.deletingLastPathComponent())
    if hadPrevious, fm.fileExists(atPath: au.previous.path) { try? replace(au.previousOlder, with: au.previous, move: true) }
    do {
      if hadPrevious { try replace(au.previous, with: au.installedApp, move: true) }
      try replace(au.installedApp, with: au.staged, move: true)
      linkCLI()
    } catch {
      // Put both slots back the way they were.
      if hadPrevious, !fm.fileExists(atPath: au.installedApp.path), fm.fileExists(atPath: au.previous.path) {
        try? replace(au.installedApp, with: au.previous, move: true)
      }
      if fm.fileExists(atPath: au.previousOlder.path) { try? replace(au.previous, with: au.previousOlder, move: true) }
      linkCLI()
      save()
      return finish(.failed, "Install failed, previous build left in place: \(error)", commit: candidate.commit)
    }
    let restartedAt = now()
    let restart = engine.restart()
    say(restart.message)
    sleep(settle)

    phase(.verifying, "verifying \(candidate.version)")
    var problems: [String] = []
    if !restart.ok { problems.append("the engine didn't restart (\(restart.message))") }
    else if !engineCameBack(since: restartedAt) {
      problems.append("the engine didn't start on the new build within \(Int(heartbeatTimeout)) s")
    }
    let newBuild = BundleInfo.build(au.installedApp)
    if newBuild?.version != candidate.version || newBuild?.commit.map({ $0 != candidate.commit }) == true {
      problems.append("the installed app reports \(newBuild?.version ?? "no version"), expected \(candidate.version)")
    }
    if let newDJQ = djq(in: au.installedApp) {
      if let before {
        if let after = fingerprint(newDJQ) {
          problems += compare(before, after)
        } else {
          problems.append("the new djq couldn't list clips")
        }
      }
      if let errorsAfter = doctorErrors(newDJQ) {
        let fresh = errorsAfter.subtracting(errorsBefore)
        if !fresh.isEmpty { problems.append("Doctor reports new errors: \(fresh.sorted().joined(separator: ", "))") }
      } else {
        problems.append("Doctor didn't run")
      }
    } else {
      problems.append("the new build has no djq")
    }
    if environment["DJQ_AUTOUPDATE_FAIL_VERIFY"] == "1" { problems.append("forced verify failure (DJQ_AUTOUPDATE_FAIL_VERIFY=1)") }
    let schemaAfterRead = hasDB ? userVersion() : 0
    if schemaAfterRead == nil { problems.append("the database schema couldn't be read after the update") }
    // Unknown counts as migrated: the guards below then refuse rather than guess.
    let schemaAfter = schemaAfterRead ?? Int.max

    let record = AutoUpdateInstall(to: AutoUpdateBuild(version: candidate.version, commit: candidate.commit, at: now()),
                                   from: current.map { b in AutoUpdateBuild(version: b.version, commit: b.commit ?? state.installed?.commit) },
                                   schemaBefore: schemaBefore, schemaAfter: schemaAfter, backup: backupPath, at: now())
    if !problems.isEmpty {
      return rollBackFailedInstall(candidate: candidate, previous: hadPrevious ? current : nil, problems: problems, record: record)
    }

    try? fm.removeItem(at: au.previousOlder.deletingLastPathComponent())
    recordInstall(record)
    state.failedInstall = nil
    if let b = state.blocked, isAncestor(repo, b.commit, of: candidate.commit) { state.blocked = nil }
    state.rolledBackFrom = nil
    state.reopenWindow = reopenWindow
    notice("DJ Queue updated to \(candidate.version)",
           candidate.whatsNew.isEmpty ? "Your data checked out the same after the update." : candidate.whatsNew.prefix(3).map(\.subject).joined(separator: " · "),
           "installed", candidate.commit)
    pruneBackups()
    save()
    return finish(.installed, "Installed \(candidate.version) (\(short)); data and Doctor verified\(schemaAfter != schemaBefore ? "; database schema \(schemaBefore) → \(schemaAfter)" : "").",
                  commit: candidate.commit)
  }

  private func recordInstall(_ r: AutoUpdateInstall) {
    state.history.append(r)
    state.history = Array(state.history.suffix(20))
    state.installed = r.to
    state.ready = nil
  }

  /// The engine wrote a `start` heartbeat after `since` (it opened the database on the new build). Skipped when the
  /// engine control says there's no engine to wait for (dev runs, tests, no LaunchAgent).
  func engineCameBack(since: Date) -> Bool {
    guard engine.expectsHeartbeat() else { return true }
    var waited: TimeInterval = 0
    while waited <= heartbeatTimeout {
      if (scalar("SELECT count(*) FROM heartbeats WHERE kind='start' AND at > ?", since.timeIntervalSince1970 - 1) ?? 0) > 0 { return true }
      sleep(2)
      waited += 2
    }
    return false
  }

  private func rollBackFailedInstall(candidate: AutoUpdateCandidate, previous: AutoUpdateBuild?, problems: [String],
                                     record: AutoUpdateInstall) -> AutoUpdateResult {
    let short = String(candidate.commit.prefix(7))
    let why = problems.joined(separator: "; ")
    phase(.rollingBack, "verify failed for \(candidate.version): \(why)")
    let fm = FileManager.default
    /// The failed build stays installed: record it (so `rollback --restore-db` finds its backup) and keep the block.
    func leaveInstalled(_ reason: String, _ message: String) -> AutoUpdateResult {
      recordInstall(record)
      state.blocked = AutoUpdateBlock(version: candidate.version, commit: candidate.commit, reason: reason, detail: why,
                                      log: au.log.path, at: now(), afterInstall: true)
      state.failedInstall = state.blocked
      try? fm.removeItem(at: au.previousOlder.deletingLastPathComponent())
      notice("Update failed", "\(candidate.version) is still installed: \(why)", "failed", candidate.commit)
      save()
      return finish(.failed, message, commit: candidate.commit)
    }
    guard previous != nil, fm.fileExists(atPath: au.previous.path) else {
      return leaveInstalled("Checks after installing failed (\(why)); there's no previous build to roll back to.",
                            "\(candidate.version) (\(short)) failed verify and no previous build is kept: \(why)")
    }
    let migrated = record.schemaAfter != record.schemaBefore
    var quiesced: (lock: EngineLock, wasLoaded: Bool)?
    if migrated {
      // The new build migrated the database. The old build can't open it, so the backup has to come back too —
      // but only if nothing posted since (restoring would lose it and risk a double post). Unknown = changed.
      let changed = backupDate(record.backup).flatMap { postChanges(since: $0) }
      guard changed == 0, let backup = record.backup else {
        return leaveInstalled("Checks after installing failed (\(why)). It migrated the database (schema \(record.schemaBefore) → \(record.schemaAfter == Int.max ? "unknown" : String(record.schemaAfter))) and posts changed since (or couldn't be counted), so it was left installed. `djq autoupdate rollback --restore-db` goes back if you accept losing those changes.",
                              "\(candidate.version) failed verify after migrating the database; left installed: \(why)")
      }
      // Stop the engine (it runs the new build) and hold its lock through the restore and the swap.
      guard let q = quiesceEngine() else {
        return leaveInstalled("Checks after installing failed (\(why)). It migrated the database and another process still runs the engine on it, so it was left installed. Quit DJ Queue, then `djq autoupdate rollback --restore-db`.",
                              "\(candidate.version) failed verify after migrating the database; the engine couldn't be stopped; left installed: \(why)")
      }
      quiesced = q
      do {
        try restoreDatabase(from: URL(fileURLWithPath: backup), keepingCurrentAs: "after-failed-\(candidate.version)")
        say("restored the database from \(backup) (schema → \(record.schemaBefore))")
      } catch {
        resume(q)
        return leaveInstalled("Checks after installing failed (\(why)) and restoring the database backup failed: \(error). Left installed.",
                              "\(candidate.version) failed verify; database restore failed: \(error)")
      }
    }
    do {
      try swapBack()
    } catch {
      if let q = quiesced { resume(q) }
      return leaveInstalled("Checks after installing failed (\(why)) and the rollback failed: \(error).",
                            "rollback of \(candidate.version) failed: \(error)")
    }
    if let q = quiesced { resume(q) } else { say(engine.restart().message) }
    let back = previous?.version ?? "the previous build"
    state.blocked = AutoUpdateBlock(version: candidate.version, commit: candidate.commit, reason: "Checks after installing failed: \(why). Rolled back to \(back).",
                                    detail: why, log: au.log.path, at: now())
    state.ready = nil
    state.rolledBackFrom = candidate.commit
    state.installed = previous.map { AutoUpdateBuild(version: $0.version, commit: $0.commit ?? state.installed?.commit, at: now()) }
    notice("Update rolled back", "\(candidate.version) failed its checks (\(why)); back on \(back).", "rolledback", candidate.commit)
    save()
    return finish(.rolledBack, "\(candidate.version) (\(short)) failed verify, rolled back to \(back): \(why)", commit: candidate.commit)
  }

  /// installed → failed/, previous → installed, previous-older → previous. On error the slots are put back.
  private func swapBack() throws {
    let fm = FileManager.default
    try replace(au.failed, with: au.installedApp, move: true)
    do {
      try replace(au.installedApp, with: au.previous, move: true)
    } catch {
      try? replace(au.installedApp, with: au.failed, move: true)
      throw error
    }
    if fm.fileExists(atPath: au.previousOlder.path) { try? replace(au.previous, with: au.previousOlder, move: true) }
    linkCLI()
  }

  // MARK: Rollback (djq autoupdate rollback)

  public struct RollbackError: Error, CustomStringConvertible {
    public let description: String
  }

  /// Swaps the installed bundle with the kept previous one (so a second rollback rolls forward again). Refused
  /// when the database is newer than the kept build expects, unless `restoreDB` also restores the backup taken
  /// just before that install (later changes are lost; the message says how many). When the kept build's schema
  /// can't be known (it predates schema stamps and no install record exists) it's refused unless `force`.
  public func rollback(restoreDB: Bool, force: Bool = false) throws -> AutoUpdateResult {
    guard let lock = AutoUpdateLock.acquire(au.lock) else {
      throw RollbackError(description: "An update run is in progress; try again when `djq autoupdate status` says idle.")
    }
    defer { lock.release() }
    if AutoUpdate.unsafeDevEnvironment(environment) {
      throw RollbackError(description: "Refused: DJQ_ROOT is set without DJQ_HOME (a dev run would touch the real app).")
    }
    state = files.state()
    let fm = FileManager.default
    guard fm.fileExists(atPath: au.previous.path), let prev = BundleInfo.build(au.previous) else {
      throw RollbackError(description: "No previous build is kept (\(au.previous.path)).")
    }
    let cur = BundleInfo.build(au.installedApp)
    let curCommit = cur?.commit ?? state.installed?.commit
    let record = state.history.last { $0.to.commit == curCommit && $0.to.version == cur?.version }
    let hasDB = fm.fileExists(atPath: paths.database.path)
    guard let schemaNow = hasDB ? userVersion() : 0 else {
      throw RollbackError(description: "Refused: the database schema couldn't be read (is it locked?). Try again in a moment.")
    }
    let schemaPrev = BundleInfo.schema(au.previous) ?? record?.schemaBefore
    if schemaPrev == nil, !force {
      throw RollbackError(description: """
        Refused: \(prev.version) predates schema stamps and there's no install record, so it can't be checked against the database \
        (schema \(schemaNow)). If you know \(prev.version) uses the same schema, run `djq autoupdate rollback --force`.
        """)
    }
    let needsRestore = schemaNow > (schemaPrev ?? schemaNow)
    var quiesced: (lock: EngineLock, wasLoaded: Bool)?
    if needsRestore {
      let lost = record.flatMap { backupDate($0.backup) }.flatMap { postChanges(since: $0) }
      guard restoreDB else {
        throw RollbackError(description: """
          Refused: the database is at schema \(schemaNow) and \(prev.version) expects \(schemaPrev!), so it can't open it. \
          `djq autoupdate rollback --restore-db` also restores \(record?.backup ?? "the pre-update backup"), taken before that update; \
          \(lost.map { "\($0) post change\($0 == 1 ? "" : "s")" } ?? "an unknown number of post changes") since then would be lost.
          """)
      }
      guard let b = record?.backup, fm.fileExists(atPath: b), record?.schemaBefore == schemaPrev else {
        throw RollbackError(description: "The backup taken before \(cur?.version ?? "this update") is missing, so the database can't go back to schema \(schemaPrev!).")
      }
      try waitIdle()
      guard let q = quiesceEngine() else {
        throw RollbackError(description: "Refused: another process still runs the engine on this database (a DJ Queue window opened without the background engine?). Quit DJ Queue and try again.")
      }
      quiesced = q
      do {
        try restoreDatabase(from: URL(fileURLWithPath: b), keepingCurrentAs: "before-rollback-\(cur?.version ?? "unknown")")
      } catch {
        resume(q)
        throw error
      }
      say("restored the database from \(b)")
    } else {
      try waitIdle()
    }
    phase(.rollingBack, "rolling back \(cur?.version ?? "?") → \(prev.version)")
    let tmp = au.dir.appendingPathComponent("swap/\(AutoUpdatePaths.appName)")
    do {
      try replace(tmp, with: au.installedApp, move: true)
      do {
        try replace(au.installedApp, with: au.previous, move: true)
      } catch {
        try? replace(au.installedApp, with: tmp, move: true)
        throw error
      }
    } catch {
      if let q = quiesced { resume(q) }
      state.phase = .idle
      save()
      throw RollbackError(description: "The swap failed (\(error)); the installed build was put back.")
    }
    do {
      try replace(au.previous, with: tmp, move: true)
    } catch {
      // The rollback itself worked; only the kept copy of the newer build is stranded.
      say("warning: the rolled-back build stayed at \(tmp.path) (couldn't move it to the kept slot: \(error))")
    }
    linkCLI()
    if let q = quiesced { resume(q) } else { say(engine.restart().message) }
    let prevCommit = prev.commit ?? record?.from?.commit
    // Swapping back to a newer build (a second rollback) is a roll forward: nothing to skip then.
    let repo = files.config().repoPath(environment: environment)
    let forward = curCommit != nil && prevCommit != nil && curCommit != prevCommit && isAncestor(repo, curCommit!, of: prevCommit!)
    state.installed = AutoUpdateBuild(version: prev.version, commit: prevCommit, at: now())
    state.rolledBackFrom = forward ? nil : curCommit
    if let b = state.blocked, b.afterInstall, b.commit == curCommit { state.blocked = nil }
    if state.failedInstall?.commit == curCommit { state.failedInstall = nil }
    state.ready = nil
    state.phase = .idle
    state.runPid = nil
    var message = forward
      ? "Rolled forward \(cur?.version ?? "the installed build") → \(prev.version)."
      : "Rolled back \(cur?.version ?? "the installed build") → \(prev.version). Auto-update skips \(curCommit.map { String($0.prefix(7)) } ?? "that commit") until a newer commit lands."
    // A build older than auto-update has no `djq autoupdate`: the watcher would fail on every trigger.
    if let d = djq(in: au.installedApp), shell(d.path, ["autoupdate", "status"], cwd: nil).status != 0 {
      try? AutoUpdateWatcher.uninstallHoldingLock(au, unload: AutoUpdateWatcher.isRealLaunchAgentsFolder(au))
      var c = files.config()
      c.enabled = false
      try? files.saveConfig(c)
      message += " \(prev.version) has no auto-update, so the watcher is off."
    }
    notice(forward ? "Rolled forward to \(prev.version)" : "Rolled back to \(prev.version)", message, "rollback", curCommit)
    let r = finish(.rolledBack, message, commit: curCommit)
    save()
    return r
  }

  /// Stops the engine and takes its lock for a database restore + swap. nil (engine started again) when another
  /// process still holds the engine lock after 30 s, e.g. a plain-launched app that runs the engine itself.
  private func quiesceEngine() -> (lock: EngineLock, wasLoaded: Bool)? {
    let s = engine.stop()
    say(s.message)
    var waited: TimeInterval = 0
    while waited <= 30 {
      if let l = EngineLock.acquire(paths) { return (l, s.wasLoaded) }
      sleep(1)
      waited += 1
    }
    say(engine.start(s.wasLoaded).message)
    return nil
  }

  private func resume(_ q: (lock: EngineLock, wasLoaded: Bool)) {
    q.lock.release()
    say(engine.start(q.wasLoaded).message)
  }

  private func waitIdle() throws {
    var waited: TimeInterval = 0
    while renderingCount() > 0 {
      if waited >= idleTimeout { throw RollbackError(description: "A render is still running; try again when it finishes.") }
      sleep(pollInterval)
      waited += pollInterval
    }
  }

  // MARK: Gate

  enum GateResult { case success(URL), failure(AutoUpdateBlock) }

  private func runGate(repo: String, head: String, log: URL) -> GateResult {
    let short = String(head.prefix(7))
    func fail(_ reason: String, _ detail: String) -> GateResult {
      .failure(AutoUpdateBlock(version: "", commit: head, reason: reason, detail: detail, log: log.path, at: now()))
    }
    let fm = FileManager.default
    try? fm.createDirectory(at: au.runs, withIntermediateDirectories: true)
    fm.createFile(atPath: log.path, contents: Data("auto-update gate for \(head)\n".utf8))
    // Clean scratch checkout of exactly this commit (the .build cache survives between runs).
    phase(.testing, "gate: checking out \(short) in \(au.work.path)")
    let work = au.work.path
    var steps: [[String]] = []
    if !fm.fileExists(atPath: au.work.appendingPathComponent(".git").path) {
      try? fm.removeItem(at: au.work)
      try? fm.createDirectory(at: au.work.deletingLastPathComponent(), withIntermediateDirectories: true)
      steps.append(["/usr/bin/git", "clone", "--quiet", "--no-checkout", repo, work])
    } else {
      steps.append(["/usr/bin/git", "-C", work, "remote", "set-url", "origin", repo])
    }
    steps += [["/usr/bin/git", "-C", work, "fetch", "--quiet", "--force", "--tags", "origin", "+\(head):refs/autoupdate/candidate"],
              ["/usr/bin/git", "-C", work, "checkout", "--quiet", "--force", "--detach", head],
              ["/usr/bin/git", "-C", work, "clean", "-ffdxq", "-e", ".build"]]
    for s in steps {
      let r = shell(s[0], Array(s.dropFirst()), cwd: nil, log: log)
      if r.status != 0 { return fail("Couldn't check out \(short) for testing.", r.tail) }
    }
    // Tests and builds never see the real database: scratch DJQ_HOME / DJQ_ROOT, no notifications.
    let home = au.dir.appendingPathComponent("gate-home"), root = au.dir.appendingPathComponent("gate-root")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    var env = environment.filter { !$0.key.hasPrefix("DJQ_") }
    env["DJQ_HOME"] = home.path
    env["DJQ_ROOT"] = root.path
    env["DJQ_NOTIFY"] = "0"
    env["PATH"] = Self.searchPath(env["PATH"])
    for (i, cmd) in gate.enumerated() {
      let label = cmd.dropFirst().first ?? cmd[0]
      if i == gate.count - 1 { phase(.building, "gate: \(label)") } else { say("gate: \(label)") }
      let r = shell(cmd[0], Array(cmd.dropFirst()), cwd: work, env: env, log: log, timeout: stepTimeout)
      if r.status != 0 {
        return fail(Self.reason(command: label, output: r.output, status: r.status, timedOut: r.timedOut), r.tail)
      }
    }
    let bundle = au.work.appendingPathComponent("build/\(AutoUpdatePaths.appName)")
    guard fm.fileExists(atPath: bundle.path) else { return fail("The build finished but made no app bundle.", "missing \(bundle.path)") }
    return .success(bundle)
  }

  static func searchPath(_ existing: String?) -> String {
    var parts = (existing ?? "").split(separator: ":").map(String.init)
    for p in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"] where !parts.contains(p) { parts.append(p) }
    return parts.joined(separator: ":")
  }

  /// One plain sentence from a failing step: the failing test names, else the first compiler error.
  static func reason(command: String, output: String, status: Int32, timedOut: Bool) -> String {
    if timedOut { return "\(command) took too long and was stopped." }
    let lines = output.split(separator: "\n").map(String.init)
    var tests: [String] = []
    for l in lines {
      // Swift Testing: ✘ Test "name" failed / ✘ Test name() failed; XCTest: Test Case '-[A b]' failed
      if let r = l.range(of: #"Test (".*?"|\S+\(\)) (recorded an issue|failed)"#, options: .regularExpression) {
        let name = l[r].replacingOccurrences(of: "Test ", with: "").replacingOccurrences(of: #" (recorded an issue|failed).*"#, with: "", options: .regularExpression)
        if !tests.contains(name) { tests.append(name) }
      } else if let r = l.range(of: #"Test Case '-\[.*\]' failed"#, options: .regularExpression) {
        let name = String(l[r]).replacingOccurrences(of: "Test Case '-[", with: "").replacingOccurrences(of: "]' failed", with: "")
        if !tests.contains(name) { tests.append(name) }
      }
    }
    if !tests.isEmpty {
      let shown = tests.prefix(3).joined(separator: ", ")
      return "\(tests.count) test\(tests.count == 1 ? "" : "s") failed: \(shown)\(tests.count > 3 ? " and \(tests.count - 3) more" : "")."
    }
    if let e = lines.first(where: { $0.contains("error:") }) {
      let msg = e.components(separatedBy: "error:").last?.trimmingCharacters(in: .whitespaces) ?? e
      return "Build failed: \(msg)"
    }
    return "\(command) failed (exit \(status))."
  }

  // MARK: Git

  func git(_ repo: String, _ args: [String]) -> String? {
    let r = shell("/usr/bin/git", ["-C", repo] + args, cwd: nil)
    guard r.status == 0 else { return nil }
    let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }

  /// Paths changed between two commits; renames count as a delete plus an add (code moved into docs/ isn't docs-only).
  func changedFiles(_ repo: String, _ a: String, _ b: String) -> [String] {
    (git(repo, ["diff", "--name-only", "--no-renames", a, b]) ?? "").split(separator: "\n").map(String.init)
  }

  func isAncestor(_ repo: String, _ a: String, of b: String) -> Bool {
    a == b || shell("/usr/bin/git", ["-C", repo, "merge-base", "--is-ancestor", a, b], cwd: nil).status == 0
  }

  /// Same rule as scripts/build-app.sh: latest tag (v0.6.0 → 0.6.0), plus "-dev.N" for commits since it.
  func describeVersion(_ repo: String, _ sha: String) -> String {
    if let tag = git(repo, ["describe", "--tags", "--abbrev=0", sha]) {
      let ahead = git(repo, ["rev-list", "--count", "\(tag)..\(sha)"]) ?? "0"
      let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
      return ahead == "0" ? v : "\(v)-dev.\(ahead)"
    }
    return "0.0.0-dev.\(git(repo, ["rev-list", "--count", sha]) ?? "0")"
  }

  /// The installed bundle's version + commit (Info.plist `DJQGitCommit`; older bundles: the state or the tag).
  func installedBuild(_ repo: String) -> AutoUpdateBuild? {
    guard var b = BundleInfo.build(au.installedApp) else { return nil }
    if b.commit == nil {
      if let s = state.installed, s.version == b.version { b.commit = s.commit }
      else if !b.version.contains("-") { b.commit = git(repo, ["rev-list", "-n", "1", "v\(b.version)"]) }
    }
    return b
  }

  func whatsNew(_ repo: String, from: String?, to: String) -> [AutoUpdateCommit] {
    var args = ["log", "--first-parent", "--format=%H%x09%s"]
    if let from, isAncestor(repo, from, of: to) { args.append("\(from)..\(to)") } else { args += ["-n", "10", to] }
    return (git(repo, args) ?? "").split(separator: "\n").prefix(30).compactMap { line in
      let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
      return p.count == 2 ? AutoUpdateCommit(sha: p[0], subject: p[1]) : nil
    }
  }

  // MARK: Install helpers

  /// Replaces `dest` with `src` (moved, or copied when `move` is false).
  func replace(_ dest: URL, with src: URL, move: Bool) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
  }

  /// Points `~/bin/djq` at the installed bundle's CLI (like build-app.sh --install; a real file there is left alone).
  func linkCLI() {
    let fm = FileManager.default
    let link = au.binDir.appendingPathComponent("djq")
    let target = au.installedApp.appendingPathComponent("Contents/MacOS/djq").path
    try? fm.createDirectory(at: au.binDir, withIntermediateDirectories: true)
    if let attrs = try? fm.attributesOfItem(atPath: link.path), attrs[.type] as? FileAttributeType != .typeSymbolicLink {
      say("warning: \(link.path) is not a symlink; left alone")
      return
    }
    try? fm.removeItem(at: link)
    do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target) } catch { say("warning: couldn't link \(link.path): \(error)") }
  }

  func djq(in app: URL) -> URL? {
    let u = app.appendingPathComponent("Contents/MacOS/djq")
    return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
  }

  /// id → "score|title" for every clip, from `djq videos --state all --json` (the agents' read door).
  func fingerprint(_ djq: URL) -> [String: String]? {
    let r = shell(djq.path, ["videos", "--state", "all", "--json"], cwd: nil, env: djqEnv)
    guard r.status == 0, let arr = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [[String: Any]] else { return nil }
    var out: [String: String] = [:]
    for v in arr {
      guard let id = v["id"] as? String else { continue }
      let score = (v["score"] as? Int).map(String.init) ?? "-"
      out[id] = "\(score)|\((v["title"] as? String) ?? "")"
    }
    return out
  }

  func compare(_ before: [String: String], _ after: [String: String]) -> [String] {
    var out: [String] = []
    if before.count != after.count { out.append("clip count \(before.count) → \(after.count)") }
    let changed = before.filter { after[$0.key] != $0.value }.map(\.key).sorted()
    if !changed.isEmpty {
      out.append("\(changed.count) clip\(changed.count == 1 ? "" : "s") changed score, title or went missing (\(changed.prefix(3).map { String($0.prefix(8)) }.joined(separator: ", ")))")
    }
    return out
  }

  /// Error ids from `djq doctor --json` (auto-update's own findings excluded), or nil when it didn't run.
  func doctorErrors(_ djq: URL) -> Set<String>? {
    let r = shell(djq.path, ["doctor", "--json"], cwd: nil, env: djqEnv)
    guard r.status == 0 || r.status == 2,
          let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
          let findings = obj["findings"] as? [[String: Any]] else { return nil }
    return Set(findings.filter { ($0["severity"] as? String) == "error" }.compactMap { $0["id"] as? String }.filter { !$0.hasPrefix("autoupdate") })
  }

  var djqEnv: [String: String] {
    var e = environment
    e["DJQ_NOTIFY"] = "0"
    return e
  }

  // MARK: Database (read-only checks, backup, restore)

  private func openDB(readOnly: Bool) -> OpaquePointer? {
    guard FileManager.default.fileExists(atPath: paths.database.path) else { return nil }
    var db: OpaquePointer?
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
    guard sqlite3_open_v2(paths.database.path, &db, flags, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return nil
    }
    sqlite3_busy_timeout(db, 5000)
    return db
  }

  private func scalar(_ sql: String, _ bind: Double? = nil) -> Int? {
    guard let db = openDB(readOnly: true) else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    if let bind { sqlite3_bind_double(stmt, 1, bind) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  func userVersion() -> Int? { scalar("PRAGMA user_version") }

  /// Posts mid-render (the engine marks them `rendering` while ffmpeg runs). Manual posting has no in-flight state.
  func renderingCount() -> Int { scalar("SELECT count(*) FROM platform_posts WHERE state='rendering'") ?? 0 }

  /// Post history rows written after `date` (what a database restore would lose).
  /// nil when it can't be counted (callers treat that as "changed").
  func postChanges(since date: Date) -> Int? {
    scalar("SELECT count(*) FROM post_history WHERE at > ?", date.timeIntervalSince1970)
  }

  func backupDate(_ path: String?) -> Date? {
    guard let path else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  /// SQLite online backup of the live database to `autoupdate/backups/queue-before-<version>-<stamp>.sqlite`,
  /// checked with `PRAGMA integrity_check`. nil when there's no database yet.
  func backupDatabase(label: String) throws -> URL? {
    guard let src = openDB(readOnly: true) else { return nil }
    defer { sqlite3_close(src) }
    try FileManager.default.createDirectory(at: au.backups, withIntermediateDirectories: true)
    let dest = au.backups.appendingPathComponent("queue-before-\(label)-\(stamp()).sqlite")
    try copyDB(from: src, toPath: dest.path)
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    // Read-write: a backup of a WAL database is itself in WAL mode, which a read-only handle can't always open.
    guard sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw RollbackError(description: "can't open the backup") }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
          let c = sqlite3_column_text(stmt, 0), String(cString: c) == "ok" else {
      throw RollbackError(description: "the backup failed its integrity check")
    }
    return dest
  }

  /// Copies a backup over the live database (online backup API, so open connections see it), after saving the
  /// current database beside the backups as `queue-<label>-<stamp>.sqlite`.
  func restoreDatabase(from backup: URL, keepingCurrentAs label: String) throws {
    try FileManager.default.createDirectory(at: au.backups, withIntermediateDirectories: true)
    if let cur = openDB(readOnly: true) {
      defer { sqlite3_close(cur) }
      try copyDB(from: cur, toPath: au.backups.appendingPathComponent("queue-\(label)-\(stamp()).sqlite").path)
    }
    var src: OpaquePointer?
    defer { sqlite3_close(src) }
    guard sqlite3_open_v2(backup.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw RollbackError(description: "can't open \(backup.path)") }
    guard let dest = openDB(readOnly: false) else { throw RollbackError(description: "can't open the database") }
    defer { sqlite3_close(dest) }
    guard let b = sqlite3_backup_init(dest, "main", src, "main") else {
      throw RollbackError(description: String(cString: sqlite3_errmsg(dest)))
    }
    var rc: Int32
    repeat {
      rc = sqlite3_backup_step(b, -1)
      if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(100) }
    } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
    let fin = sqlite3_backup_finish(b)
    guard rc == SQLITE_DONE, fin == SQLITE_OK else { throw RollbackError(description: "restore failed (\(rc)/\(fin))") }
  }

  private func copyDB(from src: OpaquePointer, toPath path: String) throws {
    var out: OpaquePointer?
    defer { sqlite3_close(out) }
    guard sqlite3_open(path, &out) == SQLITE_OK, let b = sqlite3_backup_init(out, "main", src, "main") else {
      throw RollbackError(description: "can't start a backup to \(path)")
    }
    let step = sqlite3_backup_step(b, -1)
    let fin = sqlite3_backup_finish(b)
    guard step == SQLITE_DONE, fin == SQLITE_OK else { throw RollbackError(description: "backup to \(path) failed (\(step)/\(fin))") }
  }

  // MARK: Housekeeping

  func stamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: now())
  }

  /// Keeps the 10 newest pre-update backups by time (plus any a history entry still points at).
  func pruneBackups() {
    let keep = Set(state.history.compactMap(\.backup))
    func mtime(_ u: URL) -> Date { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast }
    let all = ((try? FileManager.default.contentsOfDirectory(at: au.backups, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "sqlite" }.sorted { mtime($0) > mtime($1) }
    for old in all.dropFirst(10) where !keep.contains(old.path) { try? FileManager.default.removeItem(at: old) }
  }

  /// Keeps the 20 newest run logs.
  func pruneRuns() {
    let all = ((try? FileManager.default.contentsOfDirectory(at: au.runs, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    for old in all.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
  }

  // MARK: Processes

  struct ShellResult {
    var status: Int32
    var output: String
    var timedOut = false
    /// Last 30 lines.
    var tail: String { output.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).joined(separator: "\n") }
  }

  /// Runs a tool and waits. With `log`, output is appended to that file as it arrives (the run log Eric can read).
  func shell(_ tool: String, _ args: [String], cwd: String?, env: [String: String]? = nil, log: URL? = nil,
             timeout: TimeInterval? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var e = env ?? environment
    e["PATH"] = Self.searchPath(e["PATH"])
    p.environment = e
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-autoupdate-\(UUID().uuidString).out")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let h = try? FileHandle(forWritingTo: tmp) else { return ShellResult(status: -1, output: "can't create \(tmp.path)") }
    p.standardOutput = h
    p.standardError = h
    p.standardInput = FileHandle.nullDevice
    if let log, let lh = try? FileHandle(forWritingTo: log) {
      lh.seekToEndOfFile()
      lh.write(Data("\n$ \(([tool] + args).joined(separator: " "))\n".utf8))
      try? lh.close()
    }
    do { try p.run() } catch {
      try? h.close()
      return ShellResult(status: -1, output: "\(error)")
    }
    var timedOut = false
    if let timeout {
      let deadline = Date().addingTimeInterval(timeout)
      while p.isRunning {
        if Date() > deadline {
          timedOut = true
          p.terminate()
          break
        }
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
    p.waitUntilExit()
    try? h.close()
    let data = (try? Data(contentsOf: tmp)) ?? Data()
    if let log, let lh = try? FileHandle(forWritingTo: log) {
      lh.seekToEndOfFile()
      lh.write(data)
      try? lh.close()
    }
    return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: timedOut)
  }
}
