import Foundation

/// Round 20 (Eric: "everything should apply from the bulk edit except captions, and make that apparent"). What a bulk
/// change does to a clip's versions, and the line every bulk dialog shows when the selection has clips with more than
/// one version.
public enum BulkVersionScope: Sendable, Hashable {
  /// Crop, trim, cover, aspect, platforms, text look: one edit for the clip, so every version. (Round 30: a version can
  /// have its own trim; a bulk trim reset clears those too, so every version follows the default again.)
  case every
  /// Template, hashtag groups, extras, YouTube title, caption text: v1 only; v2 and later keep theirs.
  case captionsV1Only
  /// Both kinds in one change (Reset to defaults with Caption and other sections).
  case allButCaptions

  /// The line for a selection where `multi` clips have v2 or later (nil when none do).
  /// `keepsWords`: the change resets text, and each version keeps its own on-video words.
  public func note(multi: Int, keepsWords: Bool = false) -> String? {
    guard multi > 0 else { return nil }
    let who = multi == 1 ? "1 clip here has" : "\(multi) clips here have"
    let words = keepsWords ? " Each version keeps its own on-video words." : ""
    switch self {
    case .every: return "\(who) more than one version. This applies to every version." + words
    case .captionsV1Only: return "\(who) more than one version. Captions change on v1 only: v2 and later keep their own."
    case .allButCaptions:
      return "\(who) more than one version. Everything applies to every version except captions, which change on v1 only." + words
    }
  }

  /// The toast's short form.
  public var short: String {
    switch self {
    case .every: "Every version"
    case .captionsV1Only: "Captions on v1 only"
    case .allButCaptions: "Every version, captions on v1 only"
    }
  }

  /// For Reset to defaults: which kind of change these sections make.
  public static func of(_ sections: Set<BulkSection>) -> BulkVersionScope {
    if sections == [.caption] { return .captionsV1Only }
    return sections.contains(.caption) ? .allButCaptions : .every
  }
}
