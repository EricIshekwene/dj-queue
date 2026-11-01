import Foundation

/// Why a video isn't `ready` yet, and per-platform limit problems (spec §6 Validation, §7 platform checks).
public struct ValidationIssue: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable { case noCrop, noText, noCaption, tooLong, tooLarge, missingFile, noTitle, captionTooLong, titleTooLong, corrupt }
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
    let settings = try store.settings()
    // Unreadable edit/version rows make the video not ready (reported here and by the Doctor);
    // they must not abort intake or the engine tick.
    guard let edit = try? store.edit(videoId: v.id), let versions = try? store.versions(videoId: v.id) else {
      out.append(.init(kind: .corrupt, platform: nil, message: "Saved edit can't be read — see Doctor"))
      return out
    }
    if edit.crop == nil { out.append(.init(kind: .noCrop, platform: nil, message: "Set the crop")) }
    let r = try store.resolvedVersion(videoId: v.id, number: 1, settings: settings)
    let hasVersion = !versions.isEmpty
    if !hasVersion || !(r?.hasText ?? false) && !(r?.noText ?? false) {
      out.append(.init(kind: .noText, platform: nil, message: "Add text or choose No text"))
    }
    if !hasVersion || (r?.caption.isEmpty ?? true) && r?.captionTemplateId == nil {
      // A caption template counts as a caption: v1 must have chosen one or written one.
      out.append(.init(kind: .noCaption, platform: nil, message: "Add a caption"))
    }
    out += platformIssues(video: v, edit: edit, settings: settings)
    if let r, hasVersion {
      let session = try store.session(id: v.sessionId)?.name ?? ""
      let sets = try store.hashtagSets(), templates = try store.captionTemplates()
      let rules = PrefillRules.load(store.paths)
      for p in settings.activePlatforms where !edit.skippedPlatforms.contains(p) {
        let lim = settings.limits[p]?.captionLimit ?? 2200
        let c = Captions.caption(for: p, version: r, video: v, sessionName: session, sets: sets, templates: templates,
                                 settings: settings, rules: rules)
        if c.count > lim {
          out.append(.init(kind: .captionTooLong, platform: p, message: "Caption too long for \(p.displayName) (\(c.count)/\(lim))"))
        }
      }
      if settings.activePlatforms.contains(.youtube), !edit.skippedPlatforms.contains(.youtube) {
        let lim = settings.limits[.youtube]?.titleLimit ?? 100
        let t = Captions.youtubeTitle(r, video: v, limit: lim, rules: rules)
        if t.count > lim {
          out.append(.init(kind: .titleTooLong, platform: .youtube, message: "YouTube title too long (\(t.count)/\(lim))"))
        }
      }
    }
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
