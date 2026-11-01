import Foundation

/// Why a video isn't `ready` yet, and per-platform limit problems (spec §6 Validation, §7 platform checks).
public struct ValidationIssue: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable { case noCrop, noText, noCaption, tooLong, tooLarge, missingFile, noTitle }
  public var kind: Kind
  public var platform: Platform?
  public var message: String
  public var id: String { "\(kind.rawValue)-\(platform?.rawValue ?? "all")" }
}

public enum Validation {
  public static func issues(video v: Video, store: Store) throws -> [ValidationIssue] {
    var out: [ValidationIssue] = []
    if v.missing { out.append(.init(kind: .missingFile, platform: nil, message: "File missing")) }
    guard v.type == .short else { return out }
    let edit = try store.edit(videoId: v.id)
    let settings = try store.settings()
    if edit.crop == nil { out.append(.init(kind: .noCrop, platform: nil, message: "Set the crop")) }
    let r = try store.resolvedVersion(videoId: v.id, number: 1, settings: settings)
    let hasVersion = try !store.versions(videoId: v.id).isEmpty
    if !hasVersion || !(r?.hasText ?? false) && !(r?.noText ?? false) {
      out.append(.init(kind: .noText, platform: nil, message: "Add text or choose No text"))
    }
    if !hasVersion || (r?.caption.isEmpty ?? true) && r?.captionTemplateId == nil {
      // A caption template counts as a caption: v1 must have chosen one or written one.
      out.append(.init(kind: .noCaption, platform: nil, message: "Add a caption"))
    }
    out += platformIssues(video: v, edit: edit, settings: settings)
    return out
  }

  /// Length checks per enabled platform; skipped platforms and per-platform trims are respected.
  public static func platformIssues(video v: Video, edit: Edit, settings: Settings) -> [ValidationIssue] {
    var out: [ValidationIssue] = []
    for p in settings.activePlatforms where !edit.skippedPlatforms.contains(p) {
      guard let lim = settings.limits[p] else { continue }
      let d = edit.trim(duration: v.duration, platform: p).duration
      if d > lim.maxDuration + 0.05 {
        out.append(.init(kind: .tooLong, platform: p,
                         message: "Too long for \(p.displayName) (\(fmt(d)) > \(fmt(lim.maxDuration)))"))
      }
    }
    return out
  }

  public static func isReady(video v: Video, store: Store) throws -> Bool {
    try issues(video: v, store: store).isEmpty
  }

  public static func fmt(_ s: Double) -> String {
    let t = Int(s.rounded())
    return "\(t / 60):" + String(format: "%02d", t % 60)
  }
}
