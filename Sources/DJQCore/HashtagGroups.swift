import Foundation

/// The rules for making a hashtag group, shared by the editor's form and `djq hashtag-groups` (v0.8.1). Every group
/// lives in the one `hashtag_sets` table, so a group made anywhere shows up in Settings, New clip defaults and every clip.
public enum HashtagGroups {
  /// The category every group made by hand goes in (the editor shows category headings only when there are several).
  public static let category = "My groups"

  /// What's wrong with a group, worst first. `message` is what the disabled Save button says.
  public enum Problem: Equatable, Sendable {
    case noName, noTags
    case duplicateName(String)

    public var message: String {
      switch self {
      case .noName: "Give the group a name"
      case .noTags: "Add at least one hashtag"
      case .duplicateName(let n): "You already have a group called “\(n)” — turn that one on, or use another name"
      }
    }
  }

  /// Typed text → tags: split on spaces, commas and new lines, each one `Captions.normalizeTag`ged, duplicates dropped.
  public static func parseTags(_ raw: String) -> [String] {
    var seen = Set<String>()
    return raw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { Captions.normalizeTag(String($0)) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  public static func cleanName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The group already called `name` (ignoring case and outer spaces), leaving out the one being edited.
  public static func named(_ name: String, in existing: [HashtagSet], except id: String? = nil) -> HashtagSet? {
    let n = cleanName(name).lowercased()
    return existing.first { $0.id != id && cleanName($0.name).lowercased() == n }
  }

  /// Nil when the group can be saved. `editing` = the id of the group being edited, which may keep its own name.
  public static func problem(name: String, tags: [String], existing: [HashtagSet], editing id: String? = nil) -> Problem? {
    if cleanName(name).isEmpty { return .noName }
    if let same = named(name, in: existing, except: id) { return .duplicateName(same.name) }
    return tags.isEmpty ? .noTags : nil
  }

  /// A new group placed after the existing ones (the caller saves it).
  public static func make(name: String, tags: [String], existing: [HashtagSet]) -> HashtagSet {
    HashtagSet(id: newId(), name: cleanName(name), category: category, tags: tags, sort: (existing.map(\.sort).max() ?? -1) + 1)
  }
}
