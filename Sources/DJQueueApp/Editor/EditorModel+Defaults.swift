import DJQCore
import Foundation

/// Round 29: one part of the clip's caption setup that "Make default…" can save for new clips.
enum EditorDefaultPart: String, CaseIterable, Identifiable {
  case template, groups, extra, title, platforms
  var id: String { rawValue }

  var label: String {
    switch self {
    case .template: "Caption template"
    case .groups: "Hashtag groups"
    case .extra: "Extra hashtags"
    case .title: "YouTube title template"
    case .platforms: "Post to"
    }
  }
}

/// A row of the form: what this clip has, and why it can't be picked (nil = it can).
struct EditorDefaultRow: Identifiable, Equatable {
  var part: EditorDefaultPart
  var value: String
  /// This clip has what new clips already get.
  var isDefault: Bool
  var offReason: String?
  var id: EditorDefaultPart { part }
}

/// The "Make default…" form under the Caption section. `picked` seeds the checkboxes; `reach` is what the picks would
/// reach in clips that already exist.
struct EditorDefaultsForm: Equatable {
  var picked: Set<EditorDefaultPart>
  var updateExisting = false
  var reach = CaptionDefaults.Reach()
}

extension EditorModel {
  /// The clip's caption setup, part by part, against New clip defaults.
  var defaultRows: [EditorDefaultRow] {
    let r = resolved, d = defaults
    var rows: [EditorDefaultRow] = []
    let tid = r.captionTemplateId ?? d.captionTemplateId
    let tname = templates.first { $0.id == tid }?.name
    rows.append(EditorDefaultRow(
      part: .template, value: captionIsWritten ? "Your own text" : tname ?? "Missing template",
      isDefault: !captionIsWritten && tid == d.captionTemplateId,
      offReason: captionIsWritten ? "The caption is your own text. Save it as a template first (Template ▸ Save caption as template…)"
        : tname == nil ? "That template no longer exists" : nil))
    let groupNames = r.hashtagSetIds.compactMap { id in sets.first { $0.id == id }.map(HashtagGroups.label) }
    rows.append(EditorDefaultRow(part: .groups, value: groupNames.isEmpty ? "None" : groupNames.joined(separator: ", "),
                                 isDefault: r.hashtagSetIds == d.hashtagSetIds, offReason: nil))
    rows.append(EditorDefaultRow(part: .extra, value: r.extraHashtags.isEmpty ? "None" : r.extraHashtags.joined(separator: " "),
                                 isDefault: r.extraHashtags == d.extraHashtags, offReason: nil))
    if !isPhoto {
      let yid = r.youtubeTitleTemplateId ?? d.youtubeTitleTemplateId
      let yname = youtubeTitleTemplates.first { $0.id == yid }?.name
      rows.append(EditorDefaultRow(
        part: .title, value: !r.youtubeTitle.isEmpty ? "Your own title" : yname ?? "Missing template",
        isDefault: r.youtubeTitle.isEmpty && yid == d.youtubeTitleTemplateId,
        offReason: !r.youtubeTitle.isEmpty ? "The YouTube title is typed for this clip. Pick a title template to make one the default"
          : yname == nil ? "That title template no longer exists" : nil))
    }
    let on = defaultPlatforms
    let names = EditorPlatforms.order.filter { on.contains($0) && settings.enabledPlatforms.contains($0) }.map(\.editorShortName)
    rows.append(EditorDefaultRow(part: .platforms, value: names.isEmpty ? "Nowhere" : names.joined(separator: ", "),
                                 isDefault: on == d.platforms, offReason: nil))
    return rows
  }

  /// Where new clips would post: this clip's platforms. A photo post can't say anything about YouTube, so that stays as it is.
  private var defaultPlatforms: Set<Platform> {
    var on = Set(Platform.allCases.filter { !resolvedEdit.isSkipped($0) })
    if isPhoto {
      for p in Platform.allCases where !p.supportsPhotos {
        if defaults.platforms.contains(p) { on.insert(p) } else { on.remove(p) }
      }
    }
    return on
  }

  /// The defaults the picks would save (nil fields stay as they are).
  func defaultsChoice(_ picked: Set<EditorDefaultPart>) -> CaptionDefaults.Choice {
    let rows = defaultRows.filter { picked.contains($0.part) && $0.offReason == nil && !$0.isDefault }.map(\.part)
    let r = resolved
    var c = CaptionDefaults.Choice()
    if rows.contains(.template) { c.captionTemplateId = r.captionTemplateId ?? defaults.captionTemplateId }
    if rows.contains(.groups) { c.hashtagSetIds = r.hashtagSetIds }
    if rows.contains(.extra) { c.extraHashtags = r.extraHashtags }
    if rows.contains(.title) { c.youtubeTitleTemplateId = r.youtubeTitleTemplateId ?? defaults.youtubeTitleTemplateId }
    if rows.contains(.platforms) { c.platforms = defaultPlatforms }
    return c
  }

  /// Why "Make default…" can't open (nil = it can).
  var defaultsOffReason: String? { groupsOffReason }

  /// Opens the form with every part that differs from the defaults ticked (or just `only`, from the template menu).
  func openDefaultsForm(only: EditorDefaultPart? = nil) {
    guard defaultsOffReason == nil else { return }
    commitCaptionDraft()
    let open = defaultRows.filter { $0.offReason == nil && !$0.isDefault }.map(\.part)
    let picked = Set(only.map { open.contains($0) ? [$0] : [] } ?? open)
    defaultsForm = EditorDefaultsForm(picked: picked)
    refreshDefaultsReach()
  }

  func toggleDefaultPart(_ part: EditorDefaultPart) {
    guard var form = defaultsForm else { return }
    if form.picked.contains(part) { form.picked.remove(part) } else { form.picked.insert(part) }
    defaultsForm = form
    refreshDefaultsReach()
  }

  /// What the picks reach in clips that exist (read on the save queue, like a group's impact).
  func refreshDefaultsReach() {
    guard var form = defaultsForm else { return }
    let choice = defaultsChoice(form.picked), store = store
    form.reach = choice.isEmpty ? CaptionDefaults.Reach() : Self.saveQueue.sync { (try? CaptionDefaults.reach(choice, store: store)) ?? CaptionDefaults.Reach() }
    defaultsForm = form
  }

  /// Saves the picks as New clip defaults, through the core path (one Undo). Existing clips keep theirs unless the form
  /// says to update the ones without posts.
  @discardableResult
  func saveDefaultsForm() -> Bool {
    guard defaultsOffReason == nil, let form = defaultsForm else { return false }
    commitCaptionDraft()
    let choice = defaultsChoice(form.picked)
    guard !choice.isEmpty else { return false }
    let update = form.updateExisting, id = videoId, number = versionNo
    guard let change = writeGroup(failure: "Couldn't save the defaults", { try CaptionDefaults.save(choice, updateExisting: update, source: (id, number), store: $0, bulk: $1) })
    else { return false }
    defaultsForm = nil
    let parts = defaultRows.filter { form.picked.contains($0.part) }.map { $0.part.label.lowercased() }
    let n = change.kept.count
    var message = "New \(noun)s start with this \(Self.list(parts))"
    if update {
      message += n == 0 ? "" : ". \(n) clip\(n == 1 ? "" : "s") with scheduled or posted posts keep\(n == 1 ? "s" : "") theirs"
    } else if n > 0 {
      message += ". Clips you already have keep theirs"
    }
    if let journal = appHooks.afterGroupEdit { journal(change.result, message) } else { show(message) }
    reloadAfterDefaults(touched: change.kept.contains(videoId))
    return true
  }

  static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
  }
}
