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
  /// Groups added here and not changed yet. They aren't saved, so one Eric never fills in goes away with the screen.
  @State private var drafts: Set<String> = []
  @State private var titles: [TitleTemplate] = []
  /// Each template's save waiting for typing to pause.
  @State private var templateSaves: [String: Task<Void, Never>] = [:]
  @State private var link = ""
  @State private var linkSave: Task<Void, Never>?

  private var defaults: NewClipDefaults { model.settings.defaults }

  var body: some View {
    SettingsScroll {
      SettingsGroupHeader("Hashtag groups", description: "Your own groups. A clip has no hashtags until you pick a group in the editor (or set default groups in New clip defaults); extra hashtags can always be added per clip.", first: true)
      if sets.isEmpty {
        Text("No hashtag groups yet").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          .padding(.top, DS.space.sm)
      }
      ForEach($sets) { $s in
        HashtagSetRow(set: $s, isDefault: defaults.hashtagSetIds.contains(s.id), reach: reach[s.id], canMoveUp: canMove(s, -1),
                      canMoveDown: canMove(s, 1), onMove: moveSet, onSave: save, onDelete: deleteSet)
      }
      DSButton("Add hashtag group", icon: "plus", variant: .ghost, size: .sm, tooltip: "Make a new hashtag group: a name and its hashtags") { addSet() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("YouTube title templates", description: "{text} = the clip's overlay text, else its title, else the raw marker tag. Over YouTube's limit only {text} is shortened. In the editor, pick one and then edit the title freely.")
      ForEach($titles) { $t in titleRow($t) }
      DSButton("Add title template", icon: "plus", variant: .ghost, size: .sm, tooltip: "Add a YouTube title template") { addTitle() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("Caption templates", description: "{text} overlay text on one line · {title} the clip's title · {set} session name · {link} the link line · {tag} raw marker tag · {hashtags} the clip's hashtags. \(CaptionTemplates.hashtagHint).")
      ForEach($templates) { $t in
        templateRow($t)
      }
      DSButton("Add template", icon: "plus", variant: .ghost, size: .sm, tooltip: "Add an empty caption template") { addTemplate() }
        .padding(.top, DS.space.xs)
      SettingsRow("Link line", description: "What {link} fills in and the editor's Link chip adds. Clips with scheduled or posted posts keep their captions.", stacked: true) {
        DSTextField(placeholder: Defaults.captionLink, text: $link, size: .sm)
          .accessibilityLabel("Link line")
          .onChange(of: link) { _, l in
            linkSave?.cancel()
            linkSave = Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(600))
              guard !Task.isCancelled else { return }
              model.saveCaptionLink(l)
            }
          }
      }

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
    let usedBy = CaptionTemplates.blocker(of: id, settings: model.settings)
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: DS.space.xs) {
        DSTextField(placeholder: "Template name", text: t.name, size: .sm).frame(width: 240)
          .accessibilityLabel("Template name")
        if id == defaults.captionTemplateId { DSBadge("Default", style: .soft(.neutral), help: "New clips use this template") }
        Spacer(minLength: 0)
        DSIconButton("trash", tooltip: "Delete this template…", size: .sm, disabledReason: usedBy) {
          deleteTemplate(t.wrappedValue)
        }
      }
      DSTextArea(placeholder: "{text}\n\n{hashtags}", text: t.template, hint: CaptionTemplates.hashtagHint, minHeight: 104, maxHeight: 180)
        .accessibilityLabel("Template")
    }
    .padding(.vertical, DS.space.md)
    .overlay(alignment: .bottom) { DSSeparator() }
    // Saved once typing pauses: each save is a journaled change that can freeze clips with posts.
    .onChange(of: t.wrappedValue) { _, nt in
      templateSaves[id]?.cancel()
      templateSaves[id] = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        model.saveTemplateEdit(nt)
      }
    }
  }

  private func addTemplate() {
    let t = CaptionTemplate(id: newId(), name: "New template", template: "{text}\n\n{hashtags}", sort: (templates.map(\.sort).max() ?? 0) + 1)
    try? model.store.save(t)
    templates.append(t)
  }

  private func deleteTemplate(_ t: CaptionTemplate) {
    templateSaves[t.id]?.cancel()
    model.confirmDeleteTemplate(t, undoHint: "Undo (⌘Z) brings it back.") { templates.removeAll { $0.id == t.id } }
  }

  // MARK: Hashtag groups

  private func save(_ s: HashtagSet) {
    if drafts.contains(s.id) {
      guard !HashtagGroups.cleanName(s.name).isEmpty, model.saveNewGroup(s) else { return }
      drafts.remove(s.id)
    } else {
      model.saveGroupEdit(s)
    }
    measureReach()
  }

  private func measureReach() {
    reach = Dictionary(uniqueKeysWithValues: sets.compactMap { s in
      (try? HashtagGroups.impact(of: s.id, store: model.store)).map { (s.id, $0) }
    })
  }

  private func addSet() {
    let s = HashtagGroups.make(name: "New group", tags: [], existing: sets)
    drafts.insert(s.id)
    sets.append(s)
  }

  /// Saved groups move past each other; a draft stays at the end until it's saved.
  private func canMove(_ s: HashtagSet, _ by: Int) -> Bool {
    let saved = sets.filter { !drafts.contains($0.id) }
    return saved.firstIndex { $0.id == s.id }.map { saved.indices.contains($0 + by) } ?? false
  }

  private func moveSet(_ s: HashtagSet, _ by: Int) {
    guard model.moveGroup(s, by: by), let stored = try? model.store.hashtagSets() else { return }
    sets = stored + sets.filter { drafts.contains($0.id) }
  }

  private func deleteSet(_ s: HashtagSet) {
    if drafts.remove(s.id) != nil {
      sets.removeAll { $0.id == s.id }
      return
    }
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
    drafts = []
    measureReach()
    titles = (try? model.store.settings().youtubeTitleTemplates) ?? []
    link = (try? model.store.settings().captionLink) ?? Defaults.captionLink
  }
}

/// One hashtag group: name, space-separated tags (typed freely, saved as a list), Default badge, delete.
private struct HashtagSetRow: View {
  @Binding var set: HashtagSet
  let isDefault: Bool
  var reach: HashtagGroups.Impact?
  var canMoveUp = false
  var canMoveDown = false
  var onMove: (HashtagSet, Int) -> Void = { _, _ in }
  let onSave: (HashtagSet) -> Void
  let onDelete: (HashtagSet) -> Void
  @State private var tags = ""
  @State private var saveTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      fields
      if HashtagGroups.cleanName(set.name).isEmpty {
        EditorHint("Needs a name", icon: "exclamationmark.circle", tone: .warning)
      }
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
      DSIconButton("chevron.up", tooltip: "Move up: its tags come earlier when groups are turned on", size: .sm,
                   disabledReason: canMoveUp ? nil : "Already first") { onMove(set, -1) }
      DSIconButton("chevron.down", tooltip: "Move down: its tags come later when groups are turned on", size: .sm,
                   disabledReason: canMoveDown ? nil : "Already last") { onMove(set, 1) }
      DSIconButton("trash", tooltip: "Delete this hashtag group…", size: .sm) {
        onDelete(set)
      }
    }
  }
}
