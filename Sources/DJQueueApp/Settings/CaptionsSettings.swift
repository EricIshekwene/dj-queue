import DJQCore
import SwiftUI

/// Captions & titles: caption templates, Eric's own hashtag groups and YouTube title templates (create, edit, delete —
/// saved as you type), and where titles come from. Which template / groups / title template are the default is chosen
/// in New clip defaults. Round 7: no groups ship with the app; "hashtag groups" in all copy.
struct CaptionsSettings: View {
  @Bindable var model: AppModel
  @State private var templates: [CaptionTemplate] = []
  @State private var sets: [HashtagSet] = []
  /// What changing each group's tags reaches, shown under its row.
  @State private var reach: [String: HashtagGroups.Impact] = [:]
  @State private var titles: [TitleTemplate] = []

  private var defaults: NewClipDefaults { model.settings.defaults }

  var body: some View {
    SettingsScroll {
      SettingsGroupHeader("Hashtag groups", description: "Your own groups. A clip has no hashtags until you pick a group in the editor (or set default groups in New clip defaults); extra hashtags can always be added per clip.", first: true)
      if sets.isEmpty {
        Text("No hashtag groups yet").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          .padding(.top, DS.space.sm)
      }
      ForEach($sets) { $s in
        HashtagSetRow(set: $s, isDefault: defaults.hashtagSetIds.contains(s.id), reach: reach[s.id], onSave: save, onDelete: deleteSet)
      }
      DSButton("Add hashtag group", icon: "plus", variant: .ghost, size: .sm, tooltip: "Make a new hashtag group: a name and its hashtags") { addSet() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("YouTube title templates", description: "{text} = the clip's overlay text, else its title, else the raw marker tag. Over YouTube's limit only {text} is shortened. In the editor, pick one and then edit the title freely.")
      ForEach($titles) { $t in titleRow($t) }
      DSButton("Add title template", icon: "plus", variant: .ghost, size: .sm, tooltip: "Add a YouTube title template") { addTitle() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("Caption templates", description: "{text} overlay text on one line · {tag} raw marker tag · {set} session name · {hashtags} the clip's hashtags")
      ForEach($templates) { $t in
        templateRow($t)
      }
      DSButton("Add template", icon: "plus", variant: .ghost, size: .sm, tooltip: "Add an empty caption template") { addTemplate() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("Titles")
      SettingsRow("Where titles come from", description: "videos.json (title, title_suggestions) or an agent running djq title / djq suggest. The app never makes titles up.") {
        EmptyView()
      }
      SettingsRow("Ask an agent", description: "Copies a prompt with each clip's tag, set position and the exact djq command. Suggestions appear in the editor.") {
        DSButton(askTitle, icon: "doc.on.doc", variant: .outline, size: .sm,
                 disabledReason: model.needsTitleHelp.isEmpty ? "Every clip has a title or a confident suggestion" : nil,
                 tooltip: "Copy a song-name prompt for untitled clips") {
          model.copyAgentPrompt(model.needsTitleHelp.sorted())
        }
      }
    }
    .onAppear(perform: load)
  }

  private var askTitle: String {
    let n = model.needsTitleHelp.count
    return n == 0 ? "Copy agent prompt" : "Copy prompt for \(n) clip\(n == 1 ? "" : "s")"
  }

  // MARK: Templates

  private func templateRow(_ t: Binding<CaptionTemplate>) -> some View {
    let id = t.wrappedValue.id
    let usedBy = templateUse(id)
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: DS.space.xs) {
        DSTextField(placeholder: "Template name", text: t.name, size: .sm).frame(width: 240)
          .accessibilityLabel("Template name")
        if id == defaults.captionTemplateId { DSBadge("Default", style: .soft(.neutral), help: "New clips use this template") }
        Spacer(minLength: 0)
        DSIconButton("trash", tooltip: "Delete this template…", size: .sm,
                     disabledReason: usedBy.map { "Used by New clip defaults (\($0)) — choose another template there first" }) {
          deleteTemplate(t.wrappedValue)
        }
      }
      DSTextArea(placeholder: "{text}\n\n{hashtags}", text: t.template, minHeight: 104, maxHeight: 180)
        .accessibilityLabel("Template")
    }
    .padding(.vertical, DS.space.md)
    .overlay(alignment: .bottom) { DSSeparator() }
    .onChange(of: t.wrappedValue) { _, nt in try? model.store.save(nt) }
  }

  private func templateUse(_ id: String) -> String? {
    if defaults.captionTemplateId == id { return "caption template" }
    if let p = defaults.platformCaptionTemplates.first(where: { $0.value == id })?.key { return p.displayName }
    return nil
  }

  private func addTemplate() {
    let t = CaptionTemplate(id: newId(), name: "New template", template: "{text}\n\n{hashtags}", sort: (templates.map(\.sort).max() ?? 0) + 1)
    try? model.store.save(t)
    templates.append(t)
  }

  /// Asks first: templates aren't in the undo history, and clips that chose this one lose it.
  private func deleteTemplate(_ t: CaptionTemplate) {
    model.confirm(ConfirmRequest(
      title: "Delete “\(t.name)”?",
      message: "Clips that chose this template show “Missing template” until you pick another. You can't undo this.",
      verb: "Delete template", icon: "trash", destructive: true) {
        if model.perform("Template “\(t.name)” deleted", { try model.store.deleteCaptionTemplate(t.id) }) {
          templates.removeAll { $0.id == t.id }
          model.revalidateStages()
        }
      })
  }

  // MARK: Hashtag groups

  private func save(_ s: HashtagSet) {
    model.saveGroupEdit(s)
    measureReach()
  }

  private func measureReach() {
    reach = Dictionary(uniqueKeysWithValues: sets.compactMap { s in
      (try? HashtagGroups.impact(of: s.id, store: model.store)).map { (s.id, $0) }
    })
  }

  private func addSet() {
    let s = HashtagSet(id: newId(), name: "New group", category: "My groups", tags: [],
                       sort: (sets.map(\.sort).max() ?? -1) + 1)
    try? model.store.save(s)
    sets.append(s)
  }

  private func deleteSet(_ s: HashtagSet) {
    model.confirmDeleteGroup(s, undoHint: "Undo (⌘Z) brings it back.") { sets.removeAll { $0.id == s.id } }
  }

  // MARK: YouTube title templates

  private func titleRow(_ t: Binding<TitleTemplate>) -> some View {
    let id = t.wrappedValue.id
    let isDefault = id == defaults.youtubeTitleTemplateId
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: DS.space.xs) {
        DSTextField(placeholder: "Template name", text: t.name, size: .sm).frame(width: 240)
          .accessibilityLabel("Title template name")
        if isDefault { DSBadge("Default", style: .soft(.neutral), help: "New clips use this title template") }
        Spacer(minLength: 0)
        DSIconButton("trash", tooltip: "Delete this title template…", size: .sm,
                     disabledReason: isDefault ? "New clip defaults uses it — choose another YouTube title template there first"
                       : titles.count <= 1 ? "Keep at least one title template" : nil) {
          deleteTitle(t.wrappedValue)
        }
      }
      DSTextField(placeholder: "{text} | DJ Lovd", text: t.template, size: .sm)
        .accessibilityLabel("Title template")
    }
    .padding(.vertical, DS.space.md)
    .overlay(alignment: .bottom) { DSSeparator() }
    .onChange(of: t.wrappedValue) { _, _ in saveTitles() }
  }

  private func saveTitles() {
    guard var s = try? model.store.settings(), s.youtubeTitleTemplates != titles else { return }
    s.youtubeTitleTemplates = titles
    _ = model.perform { try model.store.save(s) }
  }

  private func addTitle() {
    titles.append(TitleTemplate(id: newId(), name: "New title template", template: "{text} | DJ Lovd"))
    saveTitles()
  }

  /// Undoable (⌘Z). Clips that chose it follow the default title template.
  private func deleteTitle(_ t: TitleTemplate) {
    model.confirm(ConfirmRequest(
      title: "Delete “\(t.name)”?",
      message: "Clips that chose this title template use the default one instead; titles you typed stay. Undo (⌘Z) brings it back.",
      verb: "Delete title template", icon: "trash", destructive: true) {
        if model.undoable("Title template “\(t.name)” deleted", "title-template-delete", settings: true, {
          var s = try model.store.settings()
          s.youtubeTitleTemplates.removeAll { $0.id == t.id }
          try model.store.save(s)
        }) {
          titles.removeAll { $0.id == t.id }
        }
      })
  }

  private func load() {
    templates = (try? model.store.captionTemplates()) ?? []
    sets = (try? model.store.hashtagSets()) ?? []
    measureReach()
    titles = (try? model.store.settings().youtubeTitleTemplates) ?? []
  }
}

/// One hashtag group: name, space-separated tags (typed freely, saved as a list), Default badge, delete.
private struct HashtagSetRow: View {
  @Binding var set: HashtagSet
  let isDefault: Bool
  var reach: HashtagGroups.Impact?
  let onSave: (HashtagSet) -> Void
  let onDelete: (HashtagSet) -> Void
  @State private var tags = ""
  @State private var saveTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      fields
      if let reach, reach.kept + reach.others > 0 {
        Text(reach.editSummary).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, DS.space.xs)
    .onAppear { tags = set.tags.joined(separator: " ") }
    // Saved once typing pauses: each save is a journaled change that can freeze clips.
    .onChange(of: set) { _, s in
      saveTask?.cancel()
      saveTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        onSave(s)
      }
    }
  }

  private var fields: some View {
    HStack(spacing: DS.space.xs) {
      DSTextField(placeholder: "Group name", text: $set.name, size: .sm).frame(width: 170)
        .accessibilityLabel("Group name")
      DSTextField(placeholder: "#amapiano #piano", text: Binding(get: { tags }, set: { t in
        tags = t
        let parsed = t.split(whereSeparator: \.isWhitespace).map(String.init)
        if parsed != set.tags { set.tags = parsed }
      }), size: .sm)
      .accessibilityLabel("Hashtags")
      if isDefault { DSBadge("Default", style: .soft(.neutral), help: "New clips get this group") }
      DSIconButton("trash", tooltip: "Delete this hashtag group…", size: .sm) {
        onDelete(set)
      }
    }
  }
}
