import Foundation

/// The write path for caption templates and the default one, shared by the editor and Settings. No `djq` command manages
/// them, so there is nothing to keep in step there. Every write is one journaled batch; `CaptionHold` keeps the captions of
/// clips with scheduled or posted posts byte-identical.
public enum CaptionTemplates {
  public static let setDefaultAction = "default-caption-template"

  public static let addAction = "caption-template-add"
  public static let editAction = "caption-template-edit"
  public static let deleteAction = "caption-template-delete"

  /// Journaled changes that write clips on their own: an open editor session moves past them (`rebasedOntoGroupChanges`).
  static let batchActions = [setDefaultAction, editAction, deleteAction]

  /// What the editor's form and Settings say beside a template.
  public static let hashtagHint = "You can type hashtags here too; {hashtags} adds the clip's groups"

  // MARK: Rules

  /// What's wrong with a template, worst first. `message` is what the disabled Save button says.
  public enum Problem: Equatable, Sendable {
    case noName, noText
    case duplicateName(String)

    public var message: String {
      switch self {
      case .noName: "Give the template a name"
      case .noText: "Write the template"
      case .duplicateName(let n): "A template called “\(n)” already exists"
      }
    }
  }

  /// Nil when the template can be saved. `editing` = the id being edited: it may keep its name.
  public static func problem(name: String, template: String, existing: [CaptionTemplate], editing id: String? = nil) -> Problem? {
    let clean = HashtagGroups.cleanName(name).lowercased()
    if clean.isEmpty { return .noName }
    if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noText }
    let same = existing.first { $0.id != id && HashtagGroups.cleanName($0.name).lowercased() == clean }
    return same.map { .duplicateName($0.name) }
  }

  /// A new template placed after the existing ones (the caller saves it).
  public static func make(name: String, template: String, existing: [CaptionTemplate]) -> CaptionTemplate {
    CaptionTemplate(id: newId(), name: HashtagGroups.cleanName(name), template: template, sort: (existing.map(\.sort).max() ?? -1) + 1)
  }

  /// Why `id` can't be deleted (nil = it can): New clip defaults uses it, here or for a platform.
  public static func blocker(of id: String, settings: Settings) -> String? {
    if settings.defaults.captionTemplateId == id {
      return "Used by New clip defaults (caption template) — choose another template there first"
    }
    if let p = settings.defaults.platformCaptionTemplates.first(where: { $0.value == id })?.key {
      return "Used by New clip defaults (\(p.displayName)) — choose another template there first"
    }
    return nil
  }

  /// A template from a written caption: the clip's overlay text, title, set name and link become tokens, the clip's own run of
  /// hashtags becomes `{hashtags}`, and tags typed by hand stay as they are. A caption with none of the clip's tags gets
  /// `{hashtags}` at the end, so the template still takes a clip's groups.
  public static func template(fromCaption caption: String, version r: ResolvedVersion, video: Video, sessionName: String,
                              sets: [HashtagSet], link: String) -> String {
    var out = caption
    // Tags match in any case; a token only as written, so the template fills back to the same caption.
    func word(_ value: String, anyCase: Bool = false) -> NSRegularExpression? {
      try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}{])"# + NSRegularExpression.escapedPattern(for: value) + #"(?![\p{L}\p{N}}])"#,
                               options: anyCase ? [.caseInsensitive] : [])
    }
    let tags = Captions.hashtags(r, sets: sets).filter { !Captions.normalizeTag($0).isEmpty }
    let run = (out as NSString).range(of: tags.joined(separator: " "), options: [.backwards, .caseInsensitive])
    if !tags.isEmpty, run.location != NSNotFound, Captions.isTagBoundary(out as NSString, run) {
      out = (out as NSString).replacingCharacters(in: run, with: "{hashtags}")
    } else {
      var placed = false
      for t in tags {
        guard let re = word(t, anyCase: true), let m = re.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) else { continue }
        out = placed ? Captions.removeRange(out as NSString, m.range) : (out as NSString).replacingCharacters(in: m.range, with: "{hashtags}")
        placed = true
      }
    }
    var values: [(token: String, value: String)] = [("{text}", Captions.oneLine(Captions.textValue(r, video: video)))]
    if let title = video.titleText { values.append(("{title}", Captions.oneLine(title))) }
    values += [("{set}", Captions.setName(sessionName)), ("{link}", Captions.oneLine(link))]
    var seen = Set<String>()
    for (token, value) in values.filter({ !$0.value.isEmpty && seen.insert($0.value.lowercased()).inserted })
      .sorted(by: { $0.value.count > $1.value.count }) {
      guard let re = word(value), let m = re.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) else { continue }
      out = (out as NSString).replacingCharacters(in: m.range, with: token)
    }
    return out.contains("{hashtags}") ? out : out + "\n\n{hashtags}"
  }

  // MARK: Writes

  @discardableResult
  public static func create(_ t: CaptionTemplate, store: Store, bulk: BulkActions) throws -> HashtagGroups.Change {
    HashtagGroups.Change(result: try bulk.record(addAction, captionTemplates: true, revalidate: false) { try store.save(t) }, kept: [])
  }

  /// A version that a change to template `id` reaches: no written caption, and some platform without its own caption builds from it.
  private static func uses(_ r: ResolvedVersion, _ id: String, _ settings: Settings) -> Bool {
    r.caption.isEmpty && Platform.allCases.contains {
      (r.platformCaptions[$0] ?? "").isEmpty && Captions.templateId(for: $0, version: r, settings: settings) == id
    }
  }

  /// Clips with scheduled or posted posts that build a caption from `id`, and the other active clips that do.
  private static func users(of id: String, store: Store) throws -> (kept: [Video], others: [Video]) {
    let settings = try store.settings(), posted = try HashtagGroupsMigration.clipsWithPosts(store)
    var kept: [Video] = [], others: [Video] = []
    for v in try store.videos() where try resolved(v, settings, store: store).resolved.contains(where: { uses($0, id, settings) }) {
      if posted.contains(v.id) { kept.append(v) } else if v.type == .short, !v.excluded { others.append(v) }
    }
    return (kept, others)
  }

  public static func impact(of id: String, store: Store) throws -> HashtagGroups.Impact {
    let u = try users(of: id, store: store)
    return HashtagGroups.Impact(kept: u.kept.count, others: u.others.count)
  }

  /// Each version built from `id` gets that caption as its written caption, its hashtags as `{hashtags}`. The caller's
  /// `CaptionHold.keep` then proves it: a platform on another template, or one the written form can't match, keeps its own.
  private static func freeze(_ v: Video, using id: String, _ from: CaptionHold.Sources, store: Store) throws {
    let (versions, all) = try resolved(v, from.settings, store: store)
    let session = try store.sessionName(for: v)
    guard let template = from.templates.first(where: { $0.id == id })?.template else { return }
    for (version, r) in zip(versions, all) where uses(r, id, from.settings) && (r.captionTemplateId ?? from.settings.defaults.captionTemplateId) == id {
      var written = version
      written.caption = Captions.fill(template, text: Captions.textValue(r, video: v), tag: v.tag, set: Captions.setName(session),
                                      hashtags: ["{hashtags}"], title: v.titleText ?? "", link: from.settings.captionLink)
      try store.save(written, videoId: v.id)
    }
  }

  /// Saves `t` over the stored template. New text reaches every clip built from it except those with scheduled or posted posts,
  /// which keep byte-identical captions; a rename reaches nothing. A template that no longer exists stays deleted.
  @discardableResult
  public static func update(_ t: CaptionTemplate, store: Store, bulk: BulkActions) throws -> HashtagGroups.Change {
    let before = try CaptionHold.Sources(store)
    guard let old = before.templates.first(where: { $0.id == t.id }) else {
      return HashtagGroups.Change(result: BulkResult(batchId: nil, action: editAction, dryRun: false, videoIds: [], changed: [], skipped: [:],
                                                     remainingIssues: [:], summary: "\(editAction): template is gone"), kept: [])
    }
    let kept = old.template == t.template ? [] : try users(of: t.id, store: store).kept
    let r = try bulk.record(editAction, ids: kept.map(\.id), captionTemplates: true, revalidate: old.template != t.template) {
      let saved = try kept.map { ($0, try CaptionHold.outputs($0, before, store: store)) }
      for v in kept { try freeze(v, using: t.id, before, store: store) }
      try store.save(t)
      for (v, outputs) in saved { try CaptionHold.keep(v, as: outputs, store: store) }
    }
    return HashtagGroups.Change(result: r, kept: kept.map(\.id))
  }

  /// Deletes `t`, unless New clip defaults uses it. Clips with scheduled or posted posts keep byte-identical captions; the
  /// others that chose it go back to the default template.
  @discardableResult
  public static func delete(_ t: CaptionTemplate, store: Store, bulk: BulkActions) throws -> HashtagGroups.Change {
    let before = try CaptionHold.Sources(store)
    if let why = blocker(of: t.id, settings: before.settings) { throw EngineError(why) }
    let kept = try users(of: t.id, store: store).kept
    let chose = try store.videos().filter { try store.versions(videoId: $0.id).contains { $0.captionTemplateId == t.id } }
    let ids = kept.map(\.id) + chose.map(\.id)
    let r = try bulk.record(deleteAction, ids: ids, captionTemplates: true) {
      let saved = try kept.map { ($0, try CaptionHold.outputs($0, before, store: store)) }
      for v in kept { try freeze(v, using: t.id, before, store: store) }
      for v in chose {
        for var version in try store.versions(videoId: v.id) where version.captionTemplateId == t.id {
          version.captionTemplateId = nil
          try store.save(version, videoId: v.id)
        }
      }
      try store.deleteCaptionTemplate(t.id)
      for (v, outputs) in saved { try CaptionHold.keep(v, as: outputs, store: store) }
    }
    return HashtagGroups.Change(result: r, kept: kept.map(\.id))
  }

  // MARK: Default

  /// Makes `id` the default template. Clips with posts that follow the default stay on the old one (any platform with its
  /// own default template then keeps its caption as that platform's own); every other clip follows the new default.
  /// Per-platform default templates aren't touched.
  @discardableResult
  public static func setDefault(_ id: String, store: Store, bulk: BulkActions) throws -> HashtagGroups.Change {
    let before = try CaptionHold.Sources(store), old = before.settings.defaults.captionTemplateId
    guard before.templates.contains(where: { $0.id == id }) else { throw EngineError("No caption template \(id)") }
    guard id != old else {
      return HashtagGroups.Change(result: BulkResult(batchId: nil, action: setDefaultAction, dryRun: false, videoIds: [], changed: [], skipped: [:],
                                                     remainingIssues: [:], summary: "\(setDefaultAction): nothing changed"), kept: [])
    }
    let kept = try followers(before.settings, store: store)
    let r = try bulk.record(setDefaultAction, ids: kept.map(\.id), params: ["template": id, "was": old], settings: true) {
      let saved = try kept.map { ($0, try CaptionHold.outputs($0, before, store: store)) }
      for v in kept { try pin(v, to: old, settings: before.settings, store: store) }
      var s = before.settings
      s.defaults.captionTemplateId = id
      try store.save(s)
      for (v, outputs) in saved { try CaptionHold.keep(v, as: outputs, store: store) }
    }
    return HashtagGroups.Change(result: r, kept: kept.map(\.id))
  }

  /// A version with no chosen template and no written caption (carried forward counts as chosen or written).
  private static func follows(_ r: ResolvedVersion) -> Bool { r.captionTemplateId == nil && r.caption.isEmpty }

  private static func resolved(_ v: Video, _ settings: Settings, store: Store) throws -> (versions: [Version], resolved: [ResolvedVersion]) {
    var vs = try store.versions(videoId: v.id)
    if !vs.contains(where: { $0.number == 1 }) { vs.insert(Version(number: 1), at: 0) }
    return (vs, vs.map { VersionResolver.resolve(vs, number: $0.number, settings: settings, video: v) })
  }

  /// Clips with scheduled or posted posts that follow the default template in some version.
  private static func followers(_ settings: Settings, store: Store) throws -> [Video] {
    try HashtagGroupsMigration.clipsWithPosts(store).sorted().compactMap { try store.video(id: $0) }
      .filter { try resolved($0, settings, store: store).resolved.contains(where: follows) }
  }

  private static func pin(_ v: Video, to template: String, settings: Settings, store: Store) throws {
    let (versions, all) = try resolved(v, settings, store: store)
    for (version, r) in zip(versions, all) where follows(r) {
      var pinned = version
      pinned.captionTemplateId = template
      try store.save(pinned, videoId: v.id)
    }
  }
}
