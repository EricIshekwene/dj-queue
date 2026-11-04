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
