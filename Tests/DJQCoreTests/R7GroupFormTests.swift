import Foundation
import Testing
@testable import DJQCore

/// v0.8.1: making hashtag groups from the editor. The form and `djq hashtag-groups add` share these rules; the editor
/// model's own path is checked by `DJQ_EDITOR_SELFTEST` and the live script (the app target isn't importable here).
@Suite struct R7GroupFormTests {
  /// What the editor does when a group goes on: the version gets the id, a written caption gets its tags in place.
  func turnOn(_ id: String, _ s: Store, _ video: Video, version: inout Version) throws -> ResolvedVersion {
    let st = try s.settings(), sets = try s.hashtagSets()
    let before = VersionResolver.resolve([version], number: 1, settings: st, video: video)
    version.hashtagSetIds = before.hashtagSetIds + [id]
    let after = VersionResolver.resolve([version], number: 1, settings: st, video: video)
    Captions.retag(&version, before: before, after: after, sets: sets)
    return VersionResolver.resolve([version], number: 1, settings: st, video: video)
  }

  func caption(_ r: ResolvedVersion, _ s: Store, _ video: Video) throws -> String {
    Captions.sharedCaption(version: r, video: video, sessionName: "Set", sets: try s.hashtagSets(),
                           templates: try s.captionTemplates(), settings: try s.settings())
  }

  @Test func tagsNormaliseLikeEverywhereElse() {
    #expect(HashtagGroups.parseTags("Amapiano, #PIANO  ##yanos\nsa") == ["#amapiano", "#piano", "#yanos", "#sa"])
    #expect(HashtagGroups.parseTags("#piano piano #Piano") == ["#piano"])
    #expect(HashtagGroups.parseTags(" # , ## ").isEmpty)
    for t in HashtagGroups.parseTags("A #b") { #expect(t == Captions.normalizeTag(t)) }
  }

  @Test func blankNameOrNoTagsCantSave() {
    #expect(HashtagGroups.problem(name: "  \n", tags: ["#a"], existing: []) == .noName)
    #expect(HashtagGroups.problem(name: "Piano", tags: [], existing: []) == .noTags)
    #expect(HashtagGroups.problem(name: "Piano", tags: HashtagGroups.parseTags(" # "), existing: []) == .noTags)
    #expect(HashtagGroups.problem(name: "Piano", tags: ["#a"], existing: []) == nil)
    #expect(HashtagGroups.Problem.noName.message == "Give the group a name")
    #expect(HashtagGroups.Problem.noTags.message == "Add at least one hashtag")
  }

  @Test func duplicateNamesAreRefusedExceptTheGroupBeingEdited() {
    let g = HashtagSet(id: "a", name: "Piano", category: HashtagGroups.category, tags: ["#a"], sort: 0)
    #expect(HashtagGroups.problem(name: " piano ", tags: ["#b"], existing: [g]) == .duplicateName("Piano"))
    #expect(HashtagGroups.problem(name: "PIANO", tags: ["#b"], existing: [g], editing: "a") == nil)
    #expect(HashtagGroups.problem(name: "Piano · SA", tags: ["#b"], existing: [g]) == nil)
  }

  @Test func newGroupGoesAfterTheOthersWithACleanName() throws {
    let f = try Fixture()
    #expect(HashtagGroups.make(name: " First ", tags: ["#a"], existing: []).sort == 0)
    try f.store.save(HashtagSet(id: "old", name: "Old", category: HashtagGroups.category, tags: ["#o"], sort: 4))
    let g = HashtagGroups.make(name: " Piano ", tags: ["#a"], existing: try f.store.hashtagSets())
    #expect(g.name == "Piano" && g.sort == 5 && g.category == "My groups")
  }

  /// The same store Settings and New clip defaults read, journaled so `djq bulk undo` can take it back.
  @Test func createThenToggleOnFillsATemplateCaption() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-0"))
    let g = HashtagGroups.make(name: "Piano", tags: HashtagGroups.parseTags("Amapiano piano"), existing: [])
    let bulk = BulkActions(store: f.store)
    let r = try bulk.record("hashtag-group-add", hashtagGroups: true, revalidate: false) { try f.store.save(g) }
    #expect(r.batchId != nil)
    #expect(try f.store.hashtagSets().map(\.id) == [g.id])
    var version = Version(number: 1)
    let out = try turnOn(g.id, f.store, v, version: &version)
    #expect(try caption(out, f.store, v).hasSuffix("#amapiano #piano"))
    _ = try bulk.undo(try #require(r.batchId))
    #expect(try f.store.hashtagSets().isEmpty)
  }

  @Test func toggleOnKeepsTypedTextAndNeverDuplicatesATag() throws {
    let f = try Fixture()
    try f.intake()
    let v = try #require(try f.store.video(id: "clip-0"))
    let g = HashtagGroups.make(name: "Piano", tags: ["#amapiano", "#piano"], existing: [])
    try f.store.save(g)
    // Typed by hand first, mixed case.
    var version = Version(number: 1)
    version.caption = "My own words #Amapiano"
    var out = try turnOn(g.id, f.store, v, version: &version)
    #expect(try caption(out, f.store, v) == "My own words #Amapiano\n#piano")
    // Already in the extras too.
    version = Version(number: 1)
    version.extraHashtags = ["#piano", "#djlovd"]
    out = try turnOn(g.id, f.store, v, version: &version)
    let tags = Captions.tags(in: try caption(out, f.store, v))
    #expect(tags.filter { $0 == "#piano" }.count == 1)
    #expect(Set(tags) == ["#amapiano", "#piano", "#djlovd"])
  }

  @Test func editingAGroupSwapsTagsInAWrittenCaption() {
    let next = Captions.replaceHashtags(in: "Words\n#a #b", old: ["#a", "#b"], new: ["#a", "#c"])
    #expect(next == "Words\n#a #c")
  }
}

/// v0.8.1 review F1, F2: editing or deleting a group never touches a clip with scheduled or posted posts.
@Suite struct R7GroupChangeTests {
  static let group = HashtagSet(id: "piano", name: "Piano", category: HashtagGroups.category, tags: ["#amapiano", "#piano"], sort: 0)
  static let second = HashtagSet(id: "sa", name: "SA", category: HashtagGroups.category, tags: ["#yanos"], sort: 1)

  enum Row: CaseIterable, Sendable { case template, writtenWithHashtags, writtenLiteral, followsDefaults }

  /// One scheduled clip per row, with an X and a YouTube post; clip-3 uses the group and has no posts.
  func fixture(_ row: Row) throws -> (Fixture, [PlatformPost], Settings) {
    let f = try Fixture()
    try f.intake()
    for g in [Self.group, Self.second] { try f.store.save(g) }
    var s = try f.store.settings()
    var v1 = Version(number: 1)
    switch row {
    case .template: v1.hashtagSetIds = [Self.second.id, Self.group.id]
    case .writtenWithHashtags: v1.hashtagSetIds = [Self.second.id, Self.group.id]; v1.caption = "My words\n{hashtags}"
    case .writtenLiteral: v1.hashtagSetIds = [Self.second.id, Self.group.id]; v1.caption = "My words #amapiano #piano"
    case .followsDefaults: s.defaults.hashtagSetIds = [Self.group.id]
    }
    try f.store.save(s)
    if row != .followsDefaults { try f.store.save(v1, videoId: "clip-0") }
    var other = Version(number: 1)
    other.hashtagSetIds = [Self.group.id]
    try f.store.save(other, videoId: "clip-3")
    let now = f.clock.now.timeIntervalSince1970
    for (i, p) in [Platform.x, .youtube].enumerated() {
      try f.store.db.run("""
        INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
        VALUES(?,'clip-0',?,1,1,'regular',?,'planned','manual',?,?)
        """, ["p\(i)", p.rawValue, now + 86400, now, now])
    }
    let render = try FakeRenderer(store: f.store).ensureRender(videoId: "clip-0", versionNo: 1, platform: nil)
    let posts = try f.store.posts(where: "video_id=?", ["clip-0"]).map { p in
      var p = p
      p.renderId = render.id
      return p
    }
    return (f, posts, s)
  }

  struct Out: Equatable { var hash: String; var caption: String }

  func outputs(_ f: Fixture, _ posts: [PlatformPost]) throws -> [Out] {
    let s = try f.store.settings()
    return try posts.sorted { $0.id < $1.id }.map { p in
      let spec = try PostizPayload.spec(store: f.store, post: p, settings: s, integrationId: "ch-\(p.platform.rawValue)")
      return Out(hash: spec.contentHash, caption: spec.content)
    }
  }

  func caption(_ f: Fixture, _ id: String) throws -> String {
    let v = try #require(try f.store.video(id: id)), saved = try f.store.versions(videoId: id)
    let r = VersionResolver.resolve(saved.isEmpty ? [Version(number: 1)] : saved, number: 1, settings: try f.store.settings(), video: v)
    return Captions.sharedCaption(version: r, video: v, sessionName: "Set", sets: try f.store.hashtagSets(),
                                  templates: try f.store.captionTemplates(), settings: try f.store.settings())
  }

  @Test(arguments: Row.allCases) func deleteKeepsTheHashAndUndoRestores(row: Row) throws {
    let (f, posts, _) = try fixture(row)
    let before = try outputs(f, posts), versions = try f.store.versions(videoId: "clip-0")
    #expect(try HashtagGroups.impact(of: Self.group.id, store: f.store).kept == 1)
    let bulk = BulkActions(store: f.store)
    let change = try HashtagGroups.delete(Self.group, store: f.store, bulk: bulk)
    #expect(change.kept == ["clip-0"])
    #expect(try outputs(f, posts) == before)
    #expect(!(try caption(f, "clip-3").contains("#amapiano")))
    #expect(try !f.store.hashtagSets().contains { $0.id == Self.group.id })
    _ = try bulk.undo(try #require(change.result.batchId))
    #expect(try f.store.hashtagSets().contains { $0.id == Self.group.id })
    #expect(try f.store.versions(videoId: "clip-0") == versions)
    #expect(try outputs(f, posts) == before)
    #expect(try caption(f, "clip-3").contains("#amapiano #piano"))
  }

  @Test(arguments: Row.allCases) func editKeepsTheHashAndUndoRestores(row: Row) throws {
    let (f, posts, _) = try fixture(row)
    let before = try outputs(f, posts), versions = try f.store.versions(videoId: "clip-0")
    var edited = Self.group
    edited.tags = ["#amapiano", "#new"]
    let bulk = BulkActions(store: f.store)
    let change = try HashtagGroups.update(edited, store: f.store, bulk: bulk)
    #expect(change.kept == ["clip-0"])
    #expect(try outputs(f, posts) == before)
    #expect(try caption(f, "clip-3").hasSuffix("#amapiano #new"))  // no posts: it follows
    _ = try bulk.undo(try #require(change.result.batchId))
    #expect(try f.store.versions(videoId: "clip-0") == versions)
    #expect(try f.store.hashtagSets().first { $0.id == Self.group.id }?.tags == Self.group.tags)
  }

  @Test func renamingReachesNoClip() throws {
    let (f, posts, _) = try fixture(.template)
    let before = try outputs(f, posts), versions = try f.store.versions(videoId: "clip-0")
    var edited = Self.group
    edited.name = "Keys"
    let change = try HashtagGroups.update(edited, store: f.store, bulk: BulkActions(store: f.store))
    #expect(change.kept.isEmpty)
    #expect(try f.store.versions(videoId: "clip-0") == versions)
    #expect(try outputs(f, posts) == before)
  }

  // MARK: The editor's session (re-review R1)

  /// Reproduces the reviewer's sequence: nothing edited in the clip, so closing journals nothing and nothing can un-freeze it.
  @Test(arguments: Row.allCases) func sessionNeverClaimsAFreeze(row: Row) throws {
    let (f, posts, _) = try fixture(row)
    let bulk = BulkActions(store: f.store), before = try outputs(f, posts)
    let open = try bulk.begin("editor", ids: ["clip-0", "clip-1"])
    let (first, next) = try bulk.split(open)
    #expect(first.batchId == nil)
    var edited = Self.group
    edited.tags = ["#amapiano", "#new"]
    let change = try HashtagGroups.update(edited, store: f.store, bulk: bulk)
    #expect(change.kept == ["clip-0"])
    #expect(try outputs(f, posts) == before)
    let closed = try bulk.commit(next)
    #expect(closed.batchId == nil, "closing the editor journals no “Edits to X”")
    #expect(closed.changed.isEmpty)
    #expect(try outputs(f, posts) == before)
    // The group batch's own undo is the only way back, and it leaves the hash alone too.
    _ = try bulk.undo(try #require(change.result.batchId))
    #expect(try outputs(f, posts) == before)
  }

  /// Same for a session that was open when `djq` froze the clip from another process (no split, no history push).
  @Test func sessionMovesPastAGroupChangeFromElsewhere() throws {
    let (f, posts, _) = try fixture(.template)
    let bulk = BulkActions(store: f.store), before = try outputs(f, posts)
    let open = try bulk.begin("editor", ids: ["clip-0"])
    try HashtagGroups.delete(Self.group, store: f.store, bulk: BulkActions(store: f.store))
    #expect(try bulk.commit(open).batchId == nil)
    #expect(try outputs(f, posts) == before)
  }

  /// Eric's own edits to the frozen clip are still the session's, and undoing them keeps the freeze.
  @Test func sessionKeepsEricsOwnEditsOnTopOfAFreeze() throws {
    let (f, posts, _) = try fixture(.template)
    let bulk = BulkActions(store: f.store), before = try outputs(f, posts)
    let open = try bulk.begin("editor", ids: ["clip-0"])
    let change = try HashtagGroups.delete(Self.group, store: f.store, bulk: bulk)
    #expect(change.kept == ["clip-0"])
    var v = try #require(try f.store.versions(videoId: "clip-0").first)
    v.text = "Eric's change"
    try f.store.save(v, videoId: "clip-0")
    let closed = try bulk.commit(open)
    #expect(closed.changed == ["clip-0"])
    _ = try bulk.undo(try #require(closed.batchId))
    #expect(try outputs(f, posts) == before)
    #expect(try f.store.versions(videoId: "clip-0").first?.hashtagSetIds == [])
  }

  // MARK: Unsaved editor changes (re-review R2)

  /// The saved version is the freeze; the memory is what the open editor would have written over it.
  @Test func unsavedEditsKeepAFreezeMadeElsewhere() throws {
    let (f, posts, _) = try fixture(.template)
    let before = try outputs(f, posts)
    var memory = try f.store.versions(videoId: "clip-0")
    memory[0].text = "Typed, not saved yet"
    try HashtagGroups.delete(Self.group, store: f.store, bulk: BulkActions(store: f.store))
    let merged = try #require(HashtagGroups.keepingFreeze(memory: memory, saved: try f.store.versions(videoId: "clip-0")))
    #expect(merged[0].text == "Typed, not saved yet")
    #expect(merged[0].hashtagSetIds == [])
    for v in merged { try f.store.save(v, videoId: "clip-0") }
    var restored = merged
    restored[0].text = nil
    for v in restored { try f.store.save(v, videoId: "clip-0") }
    #expect(try outputs(f, posts) == before)
  }

  @Test func unsavedEditsStandWhenNothingWasFrozen() {
    var saved = Version(number: 1), memory = Version(number: 1)
    saved.hashtagSetIds = ["a"]
    memory.hashtagSetIds = ["a", "b"]
    #expect(HashtagGroups.keepingFreeze(memory: [memory], saved: [saved]) == nil)
    memory.hashtagSetIds = []  // Eric turned everything off himself
    saved.hashtagSetIds = []
    saved.extraHashtags = ["#x"]
    #expect(HashtagGroups.keepingFreeze(memory: [memory], saved: [saved]) == nil)
  }

  // MARK: Undo of an older group batch (re-review R3)

  @Test func undoingAnAddCantTakeTagsOffAScheduledClip() throws {
    let f = try Fixture()
    try f.intake()
    let bulk = BulkActions(store: f.store)
    let g = HashtagGroups.make(name: "Later", tags: ["#later"], existing: [])
    let add = try HashtagGroups.create(g, store: f.store, bulk: bulk)
    var v = Version(number: 1)
    v.hashtagSetIds = [g.id]
    try f.store.save(v, videoId: "clip-0")
    let now = f.clock.now.timeIntervalSince1970
    try f.store.db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
      VALUES('p',?,'x',1,1,'regular',?,'planned','manual',?,?)
      """, ["clip-0", now + 86400, now, now])
    let id = try #require(add.result.batchId)
    #expect(throws: (any Error).self) { try bulk.undo(id) }
    #expect(try f.store.hashtagSets().contains { $0.id == g.id })
    _ = try bulk.undo(id, force: true)
    #expect(try !f.store.hashtagSets().contains { $0.id == g.id })
  }

  @Test func finishedPostsWithoutOutputDontFreeze() throws {
    let (f, _, _) = try fixture(.template)
    try f.store.db.run("UPDATE platform_posts SET state='failed' WHERE video_id='clip-0'")
    #expect(try HashtagGroups.impact(of: Self.group.id, store: f.store).kept == 0)
    #expect(try HashtagGroups.impact(of: Self.group.id, store: f.store).others == 2)
  }

  @Test func aGroupDeletedMeanwhileStaysDeleted() throws {
    let f = try Fixture()
    let c = try HashtagGroups.update(Self.group, store: f.store, bulk: BulkActions(store: f.store))
    #expect(c.result.batchId == nil)
    #expect(try f.store.hashtagSets().isEmpty)
  }

  @Test func wordingCarriesTheCounts() {
    typealias I = HashtagGroups.Impact
    #expect(I(kept: 3, others: 5).deleteSummary
      == "3 clips with scheduled or posted posts keep these tags. 5 other clips lose them, except tags typed into a caption.")
    #expect(I(kept: 1, others: 1).deleteSummary
      == "1 clip with scheduled or posted posts keeps these tags. 1 other clip loses them, except tags typed into a caption.")
    #expect(I(kept: 2, others: 0).editSummary == "2 clips with scheduled or posted posts keep the current tags.")
    #expect(I(kept: 0, others: 1).editSummary == "1 other clip follows the change, except tags typed into a caption.")
    #expect(I(kept: 0, others: 0).deleteSummary == "No active clip uses this group.")
  }

  @Test func editingAGroupThatAlreadySharesItsNameIsAllowed() {
    let a = HashtagSet(id: "a", name: "Piano", category: "x", tags: ["#a"], sort: 0)
    let b = HashtagSet(id: "b", name: "piano", category: "x", tags: ["#b"], sort: 1)
    #expect(HashtagGroups.problem(name: "Piano", tags: ["#c"], existing: [a, b], editing: "a") == nil)
    #expect(HashtagGroups.problem(name: "piano", tags: ["#c"], existing: [a, b], editing: "a") == nil)
    let c = HashtagSet(id: "c", name: "Keys", category: "x", tags: ["#c"], sort: 2)
    #expect(HashtagGroups.problem(name: "PIANO", tags: ["#c"], existing: [a, c], editing: "c") == .duplicateName("Piano"))
  }

  @Test func duplicateMessageFitsATooltip() {
    #expect(HashtagGroups.Problem.duplicateName("Piano").message == "A group called “Piano” already exists")
    #expect(HashtagGroups.Problem.duplicateName("Piano").message.count <= 45)
  }

  // MARK: ChangeSignal

  /// A hang here is the bug: a local post from the main actor once deadlocked on a `.main` observer.
  /// The limit is generous on purpose: the auto-update gate runs the suite under load, where the main actor can be busy
  /// with other tests for minutes (1 min tripped it on 2026-11-06 and 2026-11-07). A real deadlock still never returns.
  @MainActor @Test(.timeLimit(.minutes(5))) func localSignalFromTheMainActorReturnsAndArrives() async throws {
    _ = try Fixture()  // sets DJQ_NO_SIGNAL
    #expect(ChangeSignal.isLocal)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      var token: NSObjectProtocol?
      token = NotificationCenter.default.addObserver(forName: .init(ChangeSignal.name), object: nil, queue: .main) { _ in
        if let t = token { NotificationCenter.default.removeObserver(t); token = nil; done.resume() }
      }
      ChangeSignal.post()
    }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let box = Box(done)
      let o = ChangeSignal.observe { box.fire() }
      box.remove = { o.center.removeObserver(o.token) }
      ChangeSignal.post()
    }
  }

  final class Box: @unchecked Sendable {
    let done: CheckedContinuation<Void, Never>
    var remove: (() -> Void)?
    init(_ d: CheckedContinuation<Void, Never>) { done = d }
    func fire() {
      guard let r = remove else { return }
      remove = nil
      r()
      done.resume()
    }
  }

  // MARK: ⌘Z

  func key(_ c: String? = "z", cmd: Bool = true, shift: Bool = false, opt: Bool = false, ctrl: Bool = false,
           typing: Bool = false, covered: Bool = false) -> EditorLogic.UndoKey {
    EditorLogic.undoKey(characters: c, command: cmd, shift: shift, option: opt, control: ctrl, textEditing: typing, covered: covered)
  }

  @Test func undoKeys() {
    #expect(key() == .undo)
    #expect(key("Z", shift: true) == .redo)
    #expect(key("z", shift: true) == .redo)
    #expect(key(typing: true) == .fieldUndo)
    #expect(key("Z", shift: true, typing: true) == .fieldRedo)
    #expect(key(covered: true) == .ignore)
    #expect(key("Z", shift: true, typing: true, covered: true) == .ignore)
    #expect(key(cmd: false) == .ignore)
    #expect(key(opt: true) == .ignore)
    #expect(key(ctrl: true) == .ignore)
    #expect(key("a") == .ignore)
    #expect(key(nil) == .ignore)
  }

  // MARK: djq

  func djq(_ home: URL, _ args: [String]) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = try #require(R6PostizCLITests.binary)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["DJQ_HOME"] = home.path
    env["DJQ_ROOT"] = home.appendingPathComponent("DJ Video").path
    env["DJQ_POSTIZ_OFFLINE"] = "1"; env["DJQ_NO_SIGNAL"] = "1"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out; p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  @Test func djqAppliesTheSameRules() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("djq-groups-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent("DJ Video/Sessions"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let blank = try djq(home, ["hashtag-groups", "add", "   ", "#a"])
    #expect(blank.status != 0 && blank.out.contains("Give the group a name"))
    let noTags = try djq(home, ["hashtag-groups", "add", "Piano", "#"])
    #expect(noTags.status != 0 && noTags.out.contains("Add at least one hashtag"))
    let ok = try djq(home, ["hashtag-groups", "add", "  Piano ", "Amapiano piano"])
    #expect(ok.status == 0 && ok.out.contains("“Piano”: #amapiano #piano"))
    let dup = try djq(home, ["hashtag-groups", "add", "piano", "#b"])
    #expect(dup.status != 0 && dup.out.contains("already exists"))
    let edit = try djq(home, ["hashtag-groups", "edit", "piano", "--name", "  Keys "])
    #expect(edit.status == 0 && edit.out.contains("“Keys”"))
    let emptied = try djq(home, ["hashtag-groups", "edit", "keys", "--tags", "#"])
    #expect(emptied.status != 0 && emptied.out.contains("Add at least one hashtag"))
  }
}
