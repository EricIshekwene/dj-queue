import Foundation
import Testing
@testable import DJQCore

/// Auto-update (round 4 S5) against a throwaway git repo whose "gate" is a shell script that makes a fake app
/// bundle (its djq prints canned JSON), so the whole pipeline runs in seconds: gate → backup → install → restart →
/// verify, docs-only skips, blocked builds, the window-open "ready" path, rollback and serialised runs.
@Suite(.serialized) struct AutoUpdateTests {
  final class Env {
    let dir: URL
    let repo: URL
    let paths: Paths
    let videos: URL
    final class Calls: @unchecked Sendable {
      private let lock = NSLock()
      private var list: [String] = []
      func add(_ s: String) { lock.withLock { list.append(s) } }
      var all: [String] { lock.withLock { list } }
    }
    let engineCalls = Calls()
    var restarts: Int { engineCalls.all.filter { $0 == "restart" }.count }
    var extraEnv: [String: String] = [:]

    init() throws {
      dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-au-\(UUID().uuidString)")
      repo = dir.appendingPathComponent("repo")
      paths = Paths(root: dir.appendingPathComponent("DJ Video"), appSupport: dir.appendingPathComponent("support"),
                    logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("LaunchAgents"))
      videos = dir.appendingPathComponent("videos.json")
      let fm = FileManager.default
      try fm.createDirectory(at: repo, withIntermediateDirectories: true)
      try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
      _ = try Store(paths: paths)  // a real database file for the backup and schema checks
      try #"[{"id":"clip-0","score":80,"title":"Yayo"},{"id":"clip-1","score":null,"title":null}]"#.write(to: videos, atomically: true, encoding: .utf8)
      try write("gate.sh", """
        set -e
        if [ -f FAIL_TESTS ]; then echo '✘ Test "fake fails" failed after 0.1 seconds.'; exit 1; fi
        if [ -n "$COMMIT_DURING_GATE" ] && [ -f "$COMMIT_DURING_GATE" ]; then
          rm "$COMMIT_DURING_GATE"
          echo late >> "$REPO_UNDER_TEST/late.txt"
          git -C "$REPO_UNDER_TEST" add -A && git -C "$REPO_UNDER_TEST" commit -qm "late commit"
        fi
        if T=$(git describe --tags --abbrev=0 2>/dev/null); then
          A=$(git rev-list --count "$T"..HEAD); V="${T#v}"; [ "$A" != "0" ] && V="$V-dev.$A"
        else
          V="0.0.0-dev.$(git rev-list --count HEAD)"
        fi
        A="build/DJ Queue.app/Contents"
        mkdir -p "$A/MacOS"
        cat > "$A/Info.plist" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$V</string><key>DJQGitCommit</key><string>$(git rev-parse HEAD)</string></dict></plist>
        EOF
        cp djq.sh "$A/MacOS/djq"
        chmod +x "$A/MacOS/djq"
        """)
      try write("djq.sh", """
        #!/bin/sh
        case "$1" in
          videos) cat "$FAKE_VIDEOS" ;;
          doctor) echo '{"findings":[]}' ;;
          autoupdate) exit 0 ;;
          *) exit 1 ;;
        esac
        """)
      try write("Sources.swift", "// code\n")
      git("init", "-q", "-b", "main")
      git("config", "user.email", "t@example.com")
      git("config", "user.name", "t")
      commit("first")
    }

    func write(_ name: String, _ text: String) throws {
      let u = repo.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (text.hasSuffix("\n") ? text : text + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ args: String...) -> String {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      p.arguments = ["-C", repo.path] + args
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = FileHandle.nullDevice
      try? p.run()
      let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      p.waitUntilExit()
      return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func commit(_ msg: String) -> String {
      git("add", "-A")
      git("commit", "-qm", msg)
      return git("rev-parse", "HEAD")
    }

    var environment: [String: String] {
      var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DJQ_") }
      e["DJQ_APP_DIR"] = dir.appendingPathComponent("Applications").path
      e["DJQ_BIN_DIR"] = dir.appendingPathComponent("bin").path
      e["DJQ_AUTOUPDATE_REPO"] = repo.path
      e["FAKE_VIDEOS"] = videos.path
      e["REPO_UNDER_TEST"] = repo.path
      for (k, v) in extraEnv { e[k] = v }
      return e
    }

    func runner() -> AutoUpdateRunner {
      let r = AutoUpdateRunner(paths: paths, environment: environment)
      r.gate = [["/bin/sh", "gate.sh"]]
      let calls = engineCalls
      r.engine = .recording { calls.add($0) }
      r.settle = 0
      r.sleep = { _ in }
      r.progress = { _ in }
      return r
    }

    var files: AutoUpdateStore { AutoUpdateStore(AutoUpdatePaths(paths, environment: environment)) }
    var au: AutoUpdatePaths { files.paths }
    var installed: AutoUpdateBuild? { BundleInfo.build(au.installedApp) }

    func setUp() throws { try files.saveConfig(AutoUpdateConfig(enabled: true, debounce: 0)) }

    deinit { try? FileManager.default.removeItem(at: dir) }
  }

  @Test func docsOnlyRule() {
    #expect(AutoUpdate.isDocsOnly(["README.md", "design/DESIGN-v2.md", "docs/metadata.md", "refs/a.png", "screenshots/x.png"]))
    #expect(AutoUpdate.isDocsOnly(["skills/dj-queue-agent/SKILL.md"]))
    #expect(!AutoUpdate.isDocsOnly(["README.md", "Sources/DJQCore/Store.swift"]))
    #expect(!AutoUpdate.isDocsOnly(["scripts/build-app.sh"]))
    #expect(!AutoUpdate.isDocsOnly([]))
  }

  @Test func gateFailureReasonNamesTheTests() {
    let out = """
      ✔ Test "a" passed
      ✘ Test "fake fails" failed after 0.1 seconds with 1 issue.
      ✘ Test undoOrder() recorded an issue at UndoOrderTests.swift:12:5
      """
    let r = AutoUpdateRunner.reason(command: "scripts/test.sh", output: out, status: 1, timedOut: false)
    #expect(r == #"2 tests failed: "fake fails", undoOrder()."#)
    let b = AutoUpdateRunner.reason(command: "scripts/test.sh", output: "x.swift:3:1: error: cannot find 'foo' in scope", status: 1, timedOut: false)
    #expect(b == "Build failed: cannot find 'foo' in scope")
  }

  @Test func installsThenSkipsDocsThenBlocksThenRecovers() throws {
    let e = try Env()
    try e.setUp()
    // First run: nothing installed yet → gate, back up, install, restart.
    let first = e.git("rev-parse", "HEAD")
    var r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    #expect(e.installed?.commit == first)
    #expect(e.restarts == 1)
    var s = e.files.state()
    #expect(s.installed?.commit == first)
    #expect(s.history.count == 1)
    let backup = try #require(s.history.last?.backup)
    #expect(FileManager.default.fileExists(atPath: backup))
    #expect(s.notices.last?.title.hasPrefix("DJ Queue updated to") == true)
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: e.au.binDir.appendingPathComponent("djq").path)
    #expect(link == e.au.installedApp.appendingPathComponent("Contents/MacOS/djq").path)

    // Nothing new → no-op.
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .upToDate)
    #expect(e.restarts == 1)

    // Docs-only commit → skipped, nothing installed.
    try e.write("README.md", "# hi")
    try e.write("design/NOTES.md", "notes")
    e.commit("docs")
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .skippedDocs)
    #expect(e.installed?.commit == first)

    // Failing tests → blocked with the reason, nothing installed.
    try e.write("FAIL_TESTS", "1")
    let bad = e.commit("break a test")
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .blocked)
    s = e.files.state()
    #expect(s.blocked?.commit == bad)
    #expect(s.blocked?.reason == #"1 test failed: "fake fails"."#)
    #expect(s.needsAttention)
    #expect(e.installed?.commit == first)
    #expect(s.notices.last?.title == "Update blocked")
    // The same commit isn't re-gated on every trigger.
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .blocked)

    // Fix → installs; the block clears; the old bundle is kept for rollback.
    try FileManager.default.removeItem(at: e.repo.appendingPathComponent("FAIL_TESTS"))
    try e.write("Sources.swift", "// fixed")
    let fixed = e.commit("fix the test")
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    s = e.files.state()
    #expect(s.blocked == nil)
    #expect(e.installed?.commit == fixed)
    #expect(BundleInfo.build(e.au.previous)?.commit == first)
    // What's new = first-parent commits since the installed build (docs commit included).
    #expect(s.history.last?.to.commit == fixed)
  }

  @Test func aDocsOnlyRevertClearsABlock() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try e.write("FAIL_TESTS", "1")
    e.commit("broken")
    #expect(e.runner().run(trigger: .watch).kind == .blocked)
    try FileManager.default.removeItem(at: e.repo.appendingPathComponent("FAIL_TESTS"))
    try e.write("README.md", "# notes")
    e.commit("revert + docs")
    #expect(e.runner().run(trigger: .watch).kind == .skippedDocs)
    #expect(e.files.state().blocked == nil)
  }

  @Test func windowOpenWaitsThenRestartAndUpdateInstalls() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("feature")
    try e.files.saveWindow(AutoUpdateWindow(open: true))  // this process = "the app with its window open"
    var r = e.runner().run(trigger: .watch)
    #expect(r.kind == .ready)
    var s = e.files.state()
    #expect(s.ready?.commit == v2)
    #expect(s.ready?.whatsNew.map(\.subject) == ["feature"])
    #expect(FileManager.default.fileExists(atPath: e.au.staged.path))
    #expect(e.installed?.commit != v2)
    #expect(s.notices.last?.title.hasPrefix("Update ready") == true)

    // "Later" only marks it; still waiting while the window is open.
    try e.files.saveRequest(AutoUpdateRequest(action: .later))
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .ready)
    #expect(e.files.state().ready?.later == true)

    // "Restart & update": installs now and asks the relaunched app to reopen its window.
    try e.files.saveRequest(AutoUpdateRequest(action: .install))
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    s = e.files.state()
    #expect(e.installed?.commit == v2)
    #expect(s.ready == nil)
    #expect(s.reopenWindow)
    #expect(!FileManager.default.fileExists(atPath: e.au.staged.path))
  }

  @Test func laterInstallsWhenTheWindowCloses() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("feature")
    try e.files.saveWindow(AutoUpdateWindow(open: true))
    #expect(e.runner().run(trigger: .watch).kind == .ready)
    try e.files.saveWindow(AutoUpdateWindow(open: false))
    let r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    #expect(e.installed?.commit == v2)
    #expect(!e.files.state().reopenWindow)
  }

  @Test func verifyFailureRollsBackToThePreviousBundle() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("feature")
    e.extraEnv["DJQ_AUTOUPDATE_FAIL_VERIFY"] = "1"
    let r = e.runner().run(trigger: .watch)
    #expect(r.kind == .rolledBack)
    #expect(e.installed?.commit == first)
    #expect(BundleInfo.build(e.au.failed)?.commit == v2)

    let s = e.files.state()
    #expect(s.blocked?.commit == v2)
    #expect(s.rolledBackFrom == v2)
    #expect(e.restarts == 3)  // install, new build, rollback
    // Not retried on the next trigger.
    e.extraEnv = [:]
    #expect(e.runner().run(trigger: .watch).kind != .installed)
  }

  @Test func aFailedUpdateKeepsTheOlderBuildForRollback() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("v2")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v3")
    e.commit("v3")
    e.extraEnv["DJQ_AUTOUPDATE_FAIL_VERIFY"] = "1"
    #expect(e.runner().run(trigger: .watch).kind == .rolledBack)
    #expect(e.installed?.commit == v2)
    #expect(BundleInfo.build(e.au.previous)?.commit == first)
    #expect(!FileManager.default.fileExists(atPath: e.au.previousOlder.path))
  }

  @Test func changedDataFailsVerify() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    e.commit("feature")
    // The new build's djq reports a different score: verify must catch it.
    try e.write("djq.sh", """
      #!/bin/sh
      case "$1" in
        videos) echo '[{"id":"clip-0","score":10,"title":"Yayo"},{"id":"clip-1","score":null,"title":null}]' ;;
        doctor) echo '{"findings":[{"id":"db.integrity","severity":"error"}]}' ;;
        *) exit 0 ;;
      esac
      """)
    e.commit("bad djq")
    let r = e.runner().run(trigger: .watch)
    #expect(r.kind == .rolledBack)
    #expect(r.message.contains("changed score, title"))
    #expect(r.message.contains("Doctor reports new errors: db.integrity"))
  }

  @Test func rollbackSwapsAndRefusesAfterAMigration() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("feature")
    e.runner().run(trigger: .manual)
    #expect(e.installed?.commit == v2)

    // Plain rollback (no schema change): swap, and the swapped-out build becomes "previous".
    var r = try e.runner().rollback(restoreDB: false)
    #expect(r.kind == .rolledBack)
    #expect(e.installed?.commit == first)
    #expect(BundleInfo.build(e.au.previous)?.commit == v2)
    #expect(e.files.state().rolledBackFrom == v2)
    #expect(e.runner().run(trigger: .watch).kind == .upToDate)  // v2 isn't reinstalled
    #expect(e.installed?.commit == first)
    r = try e.runner().rollback(restoreDB: false)  // roll forward again
    #expect(e.installed?.commit == v2)
    #expect(r.message.hasPrefix("Rolled forward"))
    #expect(e.files.state().rolledBackFrom == nil)

    // Pretend v2 migrated the database: the rollback is refused unless the backup is restored too.
    var s = e.files.state()
    let db = try SQLite(path: e.paths.database.path)
    let schema = try #require(try db.one("PRAGMA user_version")?.int("user_version"))
    s.history[s.history.count - 1].schemaBefore = schema
    try e.files.saveState(s)
    try db.exec("PRAGMA user_version = \(schema + 1)")
    #expect(throws: AutoUpdateRunner.RollbackError.self) { try e.runner().rollback(restoreDB: false) }
    do {
      _ = try e.runner().rollback(restoreDB: false)
    } catch let err as AutoUpdateRunner.RollbackError {
      #expect(err.description.hasPrefix("Refused:"))
      #expect(err.description.contains("--restore-db"))
    }
    _ = try e.runner().rollback(restoreDB: true)
    #expect(try db.one("PRAGMA user_version")?.int("user_version") == schema)
    #expect(e.installed?.commit == first)
  }

  @Test func runsAreSerialisedAndALateCommitGetsOneMorePass() throws {
    let e = try Env()
    try e.setUp()
    // A second runner while one holds the lock does nothing (the running one re-checks before it ends).
    let held = try #require(AutoUpdateLock.acquire(e.au.lock))
    #expect(e.runner().run(trigger: .watch).kind == .waiting)
    held.release()

    // A commit lands while the gate runs: the same run handles it in a second pass.
    let marker = e.dir.appendingPathComponent("commit-once")
    FileManager.default.createFile(atPath: marker.path, contents: Data())
    e.extraEnv["COMMIT_DURING_GATE"] = marker.path
    let r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    #expect(e.installed?.commit == e.git("rev-parse", "HEAD"))
    #expect(e.git("log", "-1", "--format=%s") == "late commit")
    #expect(e.files.state().history.count == 2)
  }

  @Test func offSkipsAutomaticTriggersButNotManualRuns() throws {
    let e = try Env()
    try e.files.saveConfig(AutoUpdateConfig(enabled: false, debounce: 0))
    #expect(e.runner().run(trigger: .watch).message == "Auto-update is off.")
    #expect(e.installed == nil)
    #expect(e.runner().run(trigger: .manual).kind == .installed)
  }

  /// The new build's djq "migrates" the database (user_version 99) and, with `withPost`, records a post change
  /// after the backup; DJQ_AUTOUPDATE_FAIL_VERIFY then fails its checks.
  func migratingBuild(_ e: Env, withPost: Bool) throws {
    let db = e.paths.database.path
    let post = withPost ? "/usr/bin/sqlite3 '\(db)' \"INSERT INTO post_history(post_id,at,from_state,to_state,note) VALUES('p1', strftime('%s','now')+60, 'due', 'posted', NULL)\";" : ""
    try e.write("djq.sh", """
      #!/bin/sh
      case "$1" in
        videos) /usr/bin/sqlite3 '\(db)' 'PRAGMA user_version=99'; \(post) cat "$FAKE_VIDEOS" ;;
        doctor) echo '{"findings":[]}' ;;
        *) exit 0 ;;
      esac
      """)
  }

  func schema(_ e: Env) throws -> Int { try #require(try SQLite(path: e.paths.database.path).one("PRAGMA user_version")?.int("user_version")) }

  @Test func aMigratedFailureWithNewPostsStaysInstalledAndFlagged() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    let before = try schema(e)
    e.runner().run(trigger: .manual)
    try migratingBuild(e, withPost: true)
    let v2 = e.commit("migrating build")
    e.extraEnv["DJQ_AUTOUPDATE_FAIL_VERIFY"] = "1"
    var r = e.runner().run(trigger: .watch)
    #expect(r.kind == .failed)
    #expect(e.installed?.commit == v2)  // left installed: posts changed after the backup
    var s = e.files.state()
    #expect(s.blocked?.afterInstall == true)
    #expect(s.history.last?.to.commit == v2)
    #expect(s.rolledBackFrom == nil)
    // The next trigger keeps the failure visible (no silent "up to date").
    e.extraEnv = [:]
    r = e.runner().run(trigger: .watch)
    #expect(r.kind == .failed)
    #expect(e.files.state().blocked?.commit == v2)
    // Rollback is refused without --restore-db, then restores the pre-update backup with it.
    #expect(try schema(e) == 99)
    do {
      _ = try e.runner().rollback(restoreDB: false)
      Issue.record("rollback should be refused")
    } catch let err as AutoUpdateRunner.RollbackError {
      #expect(err.description.contains("1 post change"))
    }
    _ = try e.runner().rollback(restoreDB: true)
    #expect(try schema(e) == before)
    #expect(e.installed?.commit == first)
    s = e.files.state()
    #expect(s.blocked == nil)
    #expect(e.engineCalls.all.suffix(2) == ["stop", "start"])
  }

  @Test func aMigratedFailureWithNoNewPostsRestoresTheBackup() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    let before = try schema(e)
    e.runner().run(trigger: .manual)
    try migratingBuild(e, withPost: false)
    e.commit("migrating build")
    e.extraEnv["DJQ_AUTOUPDATE_FAIL_VERIFY"] = "1"
    #expect(e.runner().run(trigger: .watch).kind == .rolledBack)
    #expect(try schema(e) == before)
    #expect(e.installed?.commit == first)
    #expect(e.engineCalls.all.suffix(2) == ["stop", "start"])
  }

  @Test func docsAfterARollbackDontBringItBack() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    e.commit("v2")
    e.runner().run(trigger: .manual)
    _ = try e.runner().rollback(restoreDB: false)
    try e.write("README.md", "# docs")
    e.commit("docs on top")
    #expect(e.runner().run(trigger: .watch).kind == .skippedDocs)
    #expect(e.installed?.commit == first)
    try e.write("Sources.swift", "// v3")
    let v3 = e.commit("v3")
    #expect(e.runner().run(trigger: .watch).kind == .installed)
    #expect(e.installed?.commit == v3)
  }

  @Test func renamesIntoDocsAreNotDocsOnlyAndTagsRelabel() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try FileManager.default.createDirectory(at: e.repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
    e.git("mv", "Sources.swift", "docs/Sources.swift")
    let moved = e.commit("move code into docs/")
    #expect(e.runner().run(trigger: .watch).kind == .installed)
    #expect(e.installed?.commit == moved)
    // A tag on the installed commit changes the version label: same code, rebuilt and verified.
    e.git("tag", "-a", "v9.9.0", "-m", "release")
    let r = e.runner().run(trigger: .watch)
    #expect(r.kind == .installed)
    #expect(e.files.state().installed?.version == "9.9.0")
  }

  @Test func rollbackToAnUnstampedBuildWithoutARecordNeedsForce() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    e.commit("v2")
    e.runner().run(trigger: .manual)
    var s = e.files.state()
    s.history = []  // e.g. installed by hand with build-app.sh
    try e.files.saveState(s)
    #expect(throws: AutoUpdateRunner.RollbackError.self) { try e.runner().rollback(restoreDB: false) }
    _ = try e.runner().rollback(restoreDB: false, force: true)
    #expect(e.installed?.commit == first)
  }

  @Test func aStaleReadyBuildClearsOnceInstalled() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    e.commit("v2")
    e.runner().run(trigger: .manual)
    var s = e.files.state()
    s.ready = AutoUpdateCandidate(version: "old", commit: first, whatsNew: [], builtAt: Date())
    s.handled = nil
    try e.files.saveState(s)
    #expect(e.runner().run(trigger: .watch).kind == .upToDate)
    #expect(e.files.state().ready == nil)
  }

  @Test func verifyWaitsForTheEngineToComeBack() throws {
    let e = try Env()
    try e.setUp()
    let first = e.git("rev-parse", "HEAD")
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    let v2 = e.commit("v2")
    // An engine that restarts but never writes a heartbeat (crashes at launch): verify fails, rollback.
    var r = e.runner()
    r.heartbeatTimeout = 4
    r.engine = AutoUpdateEngineControl(restart: { (true, "kickstarted") }, stop: { (true, "stopped") }, start: { _ in (true, "started") },
                                       expectsHeartbeat: { true })
    var result = r.run(trigger: .watch)
    #expect(result.kind == .rolledBack)
    #expect(result.message.contains("didn't start on the new build"))
    #expect(e.installed?.commit == first)
    // An engine that comes back (writes its start heartbeat) passes.
    try e.write("Sources.swift", "// v3")
    let v3 = e.commit("v3")
    let db = e.paths.database.path
    r = e.runner()
    r.heartbeatTimeout = 4
    r.engine = AutoUpdateEngineControl(restart: {
      let d = try? SQLite(path: db)
      _ = try? d?.run("INSERT INTO heartbeats(at, kind) VALUES(?, 'start')", [Date().addingTimeInterval(1)])
      return (true, "kickstarted")
    }, stop: { (true, "stopped") }, start: { _ in (true, "started") }, expectsHeartbeat: { true })
    result = r.run(trigger: .watch)
    #expect(result.kind == .installed)
    #expect(e.installed?.commit == v3)
    _ = v2
  }

  @Test func aFailedKickstartFailsVerify() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try e.write("Sources.swift", "// v2")
    e.commit("v2")
    let r = e.runner()
    r.engine = AutoUpdateEngineControl(restart: { (false, "launchctl kickstart failed: boom") }, stop: { (true, "stopped") },
                                       start: { _ in (true, "started") }, expectsHeartbeat: { true })
    let result = r.run(trigger: .watch)
    #expect(result.kind == .rolledBack)
    #expect(result.message.contains("the engine didn't restart"))
  }

  @Test func aLaterGateBlockDoesntHideAFailedInstall() throws {
    let e = try Env()
    try e.setUp()
    e.runner().run(trigger: .manual)
    try migratingBuild(e, withPost: true)
    let v2 = e.commit("migrating build")
    e.extraEnv["DJQ_AUTOUPDATE_FAIL_VERIFY"] = "1"
    #expect(e.runner().run(trigger: .watch).kind == .failed)
    e.extraEnv = [:]
    try e.write("FAIL_TESTS", "1")
    e.commit("broken on top")
    #expect(e.runner().run(trigger: .watch).kind == .blocked)
    let s = e.files.state()
    #expect(s.failedInstall?.commit == v2)
    #expect(s.needsAttention)
    let store = try Store(paths: e.paths)
    let d = Doctor(store: store)
    d.agentLoaded = { true }
    d.autoUpdateWatcherLoaded = { true }
    d.probeDurations = false
    #expect(d.run().findings.contains { $0.id == "autoupdate.failed" && $0.fix.contains("--restore-db") })
    // Replaced by a build that verifies: the flag clears.
    try FileManager.default.removeItem(at: e.repo.appendingPathComponent("FAIL_TESTS"))
    try e.write("djq.sh", """
      #!/bin/sh
      case "$1" in
        videos) cat "$FAKE_VIDEOS" ;;
        doctor) echo '{"findings":[]}' ;;
        *) exit 0 ;;
      esac
      """)
    e.commit("fixed")
    #expect(e.runner().run(trigger: .watch).kind == .installed)
    #expect(e.files.state().failedInstall == nil)
  }

  @Test func devRootWithoutDevHomeIsRefused() throws {
    let e = try Env()
    try e.setUp()
    e.extraEnv["DJQ_ROOT"] = e.paths.root.path
    #expect(e.runner().run(trigger: .manual).message.hasPrefix("Refused"))
    #expect(e.installed == nil)
  }

  @Test func neverSetUpCountsAsOffAndDevRunsStayInScratch() throws {
    let e = try Env()
    #expect(e.runner().run(trigger: .launch).message == "Auto-update is off.")
    #expect(e.installed == nil)
    let au = AutoUpdatePaths(e.paths, environment: ["DJQ_HOME": "/tmp/djq-dev-home"])
    #expect(au.appDir.path == "/tmp/djq-dev-home/Applications")
    #expect(au.binDir.path == "/tmp/djq-dev-home/bin")
  }

  @Test func doctorReportsBlockedAndMissingWatcher() throws {
    let e = try Env()
    try e.setUp()
    try e.write("FAIL_TESTS", "1")
    e.commit("broken")
    e.runner().run(trigger: .manual)
    let store = try Store(paths: e.paths)
    let d = Doctor(store: store)
    d.agentLoaded = { true }
    d.autoUpdateWatcherLoaded = { false }
    d.probeDurations = false
    let ids = Set(d.run().findings.map(\.id))
    #expect(ids.contains("autoupdate.blocked"))
    #expect(ids.contains("autoupdate.watcher"))
    #expect(!d.run().findings.contains { $0.id.hasPrefix("autoupdate") && $0.severity == .error })
  }

  @Test func watcherPlistWatchesTheBranchAndTheAppFiles() throws {
    let e = try Env()
    let au = e.au
    let plist = AutoUpdateWatcher.plist(djq: "/x/djq", repo: e.repo.path, branch: "main", au: au)
    let watch = try #require(plist["WatchPaths"] as? [String])
    #expect(watch.contains { $0.hasSuffix(".git/refs/heads/main") })
    #expect(watch.contains { $0.hasSuffix(".git/refs/tags") })
    #expect(watch.contains(au.request.path))
    #expect(watch.contains(au.window.path))
    #expect(plist["ProgramArguments"] as? [String] == ["/x/djq", "autoupdate", "run", "--trigger", "watch"])
    // Dev environments never install the watcher.
    #expect(throws: EngineError.self) {
      try AutoUpdateWatcher.install(au, repo: e.repo.path, branch: "main", load: false, environment: ["DJQ_HOME": "/tmp/x"])
    }
  }
}
