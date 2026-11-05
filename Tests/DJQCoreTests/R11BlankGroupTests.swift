import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: a group with no name and no tags (an older build's cleared Settings field, `djq hashtag-groups add "   " "#"`)
/// is never offered, a blank name with tags stays usable, and nothing here touches captions or Postiz content.
@Suite struct R11BlankGroupTests {
  func group(_ id: String, _ name: String, _ tags: [String] = [], sort: Int = 0) -> HashtagSet {
    HashtagSet(id: id, name: name, category: "Dj", tags: tags, sort: sort)
  }

  func fixture() throws -> (Store, BulkActions) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r11-\(UUID().uuidString)")
    let paths = Paths(root: dir.appendingPathComponent("root"), appSupport: dir.appendingPathComponent("support"),
                      logs: dir.appendingPathComponent("logs"), launchAgents: dir.appendingPathComponent("la"))
    try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let store = try Store(paths: paths)
    return (store, BulkActions(store: store))
  }

  @Test func blankWithNoTagsIsNotOffered() {
    #expect(HashtagGroups.pickable([group("a", "")]).isEmpty)
    #expect(HashtagGroups.pickable([group("a", "", ["#", " "])]).isEmpty)
  }

  @Test func whitespaceOnlyNameCountsAsBlank() {
    #expect(HashtagGroups.pickable([group("a", "  \n\t")]).isEmpty)
    #expect(HashtagGroups.label(group("a", "   ", ["#a"])) == "Untitled group")
  }

  @Test func blankWithTagsIsOfferedAsUntitled() {
    let g = group("a", "", ["#piano"])
    #expect(HashtagGroups.pickable([g]) == [g])
    #expect(HashtagGroups.label(g) == "Untitled group")
  }

  @Test func normalGroupsAreUnchanged() {
    let named = group("a", "Piano", ["#piano"]), noTags = group("b", "No tags yet", sort: 1), blank = group("c", "", sort: 2)
    #expect(HashtagGroups.pickable([named, blank, noTags]) == [named, noTags])
    #expect(HashtagGroups.label(named) == "Piano")
    #expect(HashtagGroups.label(noTags) == "No tags yet")
  }

  @Test func aClearedNameKeepsThePreviousOne() {
    let old = group("a", "Piano", ["#piano"])
    #expect(HashtagGroups.keepingName(group("a", "  ", ["#keys"]), old: old) == group("a", "Piano", ["#keys"]))
    #expect(HashtagGroups.keepingName(group("a", "Keys", ["#keys"]), old: old) == group("a", "Keys", ["#keys"]))
  }

  @Test func updateNeverStoresABlankNameOverARealOne() throws {
    let (store, bulk) = try fixture()
    try store.save(group("a", "Piano", ["#piano"]))
    try HashtagGroups.update(group("a", "", ["#keys"]), store: store, bulk: bulk)
    #expect(try store.hashtagSets() == [group("a", "Piano", ["#keys"])])
  }

  @Test func aRowAlreadyBlankStaysEditable() throws {
    let (store, bulk) = try fixture()
    try store.save(group("a", ""))
    try HashtagGroups.update(group("a", "", ["#keys"]), store: store, bulk: bulk)
    #expect(try store.hashtagSets() == [group("a", "", ["#keys"])])
    try HashtagGroups.update(group("a", "Keys", ["#keys"]), store: store, bulk: bulk)
    #expect(try store.hashtagSets() == [group("a", "Keys", ["#keys"])])
  }

  /// What `djq hashtag-groups add "   " "#"` runs before it writes anything.
  @Test func theCommandCantMakeOne() {
    #expect(HashtagGroups.problem(name: "   ", tags: HashtagGroups.parseTags("#"), existing: []) == .noName)
  }

  /// Captions read every stored group: a blank name makes no difference to a group with tags, and a blank row adds nothing.
  @Test func captionsDontChange() {
    var v = Version(number: 1)
    v.hashtagSetIds = ["a", "b", "c"]
    v.extraHashtags = ["#extra"]
    let r = VersionResolver.resolve([v], number: 1, settings: Settings())
    let all = [group("a", "Named", ["#one"]), group("b", "", ["#two"]), group("c", "")]
    let named = [group("a", "Named", ["#one"]), group("b", "Also named", ["#two"]), group("c", "Named too")]
    #expect(Captions.hashtags(r, sets: all) == ["#one", "#two", "#extra"])
    #expect(Captions.hashtags(r, sets: all) == Captions.hashtags(r, sets: named))
  }
}
