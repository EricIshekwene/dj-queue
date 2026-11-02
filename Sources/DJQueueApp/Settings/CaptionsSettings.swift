import DJQCore
import SwiftUI

/// Captions & titles: caption templates and hashtag sets (create, edit, delete — saved as you type), and where
/// titles come from. Which template/sets are the default is chosen in New clip defaults.
struct CaptionsSettings: View {
  @Bindable var model: AppModel
  @State private var templates: [CaptionTemplate] = []
  @State private var sets: [HashtagSet] = []
  @State private var newCategory = ""

  private var defaults: NewClipDefaults { model.settings.defaults }

  var body: some View {
    SettingsScroll {
      SettingsGroupHeader("Caption templates", description: "{text} overlay text on one line · {tag} raw marker tag · {set} session name · {hashtags} the clip's hashtags", first: true)
      ForEach($templates) { $t in
        templateRow($t)
      }
      DSButton("Add template", icon: "plus", variant: .ghost, size: .sm) { addTemplate() }
        .padding(.top, DS.space.xs)

      SettingsGroupHeader("Hashtag sets", description: "Grouped by primary category. A clip's hashtags come from its chosen sets.")
      ForEach(categories, id: \.self) { cat in
        DSEyebrow(cat).padding(.top, DS.space.md)
        ForEach($sets) { $s in
          if s.category == cat { HashtagSetRow(set: $s, isDefault: defaults.hashtagSetIds.contains(s.id), onSave: save, onDelete: deleteSet) }
        }
        DSButton("Add set to \(cat)", icon: "plus", variant: .ghost, size: .sm) { addSet(cat) }
          .padding(.top, DS.space.xxs)
      }
      HStack(spacing: DS.space.xs) {
        DSTextField(placeholder: "New category, e.g. Afrobeats", text: $newCategory, size: .sm, onSubmit: addCategory)
          .frame(width: 260)
        DSButton("Add category", variant: .outline, size: .sm,
                 disabledReason: newCategory.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a category name first" : nil) { addCategory() }
      }
      .padding(.top, DS.space.md)

      SettingsGroupHeader("Titles")
      SettingsRow("Where titles come from", description: "videos.json (title, title_suggestions) or an agent running djq title / djq suggest. The app never makes titles up.") {
        EmptyView()
      }
      SettingsRow("Ask an agent", description: "Copies a prompt with each clip's tag, set position and the exact djq command. Suggestions appear in the editor.") {
        DSButton(askTitle, icon: "doc.on.doc", variant: .outline, size: .sm,
                 disabledReason: model.needsTitleHelp.isEmpty ? "Every clip has a title or a confident suggestion" : nil) {
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
        if id == defaults.captionTemplateId { DSBadge("Default", style: .soft(.neutral)) }
        Spacer(minLength: 0)
        DSIconButton("trash", tooltip: "Delete template", size: .sm,
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

  private func deleteTemplate(_ t: CaptionTemplate) {
    if model.perform("Template deleted", { try model.store.deleteCaptionTemplate(t.id) }) {
      templates.removeAll { $0.id == t.id }
    }
  }

  // MARK: Hashtag sets

  private var categories: [String] {
    var seen: [String] = []
    for s in sets where !seen.contains(s.category) { seen.append(s.category) }
    return seen
  }

  private func save(_ s: HashtagSet) { try? model.store.save(s) }

  private func addSet(_ cat: String) {
    let s = HashtagSet(id: newId(), name: "New set", category: cat, tags: [],
                       sort: (sets.filter { $0.category == cat }.map(\.sort).max() ?? -1) + 1)
    try? model.store.save(s)
    sets.append(s)
  }

  private func addCategory() {
    let c = newCategory.trimmingCharacters(in: .whitespaces)
    guard !c.isEmpty else { return }
    addSet(c)
    newCategory = ""
  }

  private func deleteSet(_ s: HashtagSet) {
    if model.perform("Hashtag set deleted", { try model.store.deleteHashtagSet(s.id) }) {
      sets.removeAll { $0.id == s.id }
    }
  }

  private func load() {
    templates = (try? model.store.captionTemplates()) ?? []
    sets = (try? model.store.hashtagSets()) ?? []
  }
}

/// One hashtag set: name, space-separated tags (typed freely, saved as a list), Default badge, delete.
private struct HashtagSetRow: View {
  @Binding var set: HashtagSet
  let isDefault: Bool
  let onSave: (HashtagSet) -> Void
  let onDelete: (HashtagSet) -> Void
  @State private var tags = ""

  var body: some View {
    HStack(spacing: DS.space.xs) {
      DSTextField(placeholder: "Set name", text: $set.name, size: .sm).frame(width: 170)
        .accessibilityLabel("Set name")
      DSTextField(placeholder: "#tag #another", text: Binding(get: { tags }, set: { t in
        tags = t
        let parsed = t.split(whereSeparator: \.isWhitespace).map(String.init)
        if parsed != set.tags { set.tags = parsed }
      }), size: .sm)
      .accessibilityLabel("Hashtags")
      if isDefault { DSBadge("Default", style: .soft(.neutral)) }
      DSIconButton("trash", tooltip: "Delete set", size: .sm,
                   disabledReason: isDefault ? "Used by New clip defaults — remove it from Hashtag sets there first" : nil) {
        onDelete(set)
      }
    }
    .padding(.vertical, DS.space.xs)
    .onAppear { tags = set.tags.joined(separator: " ") }
    .onChange(of: set) { _, s in onSave(s) }
  }
}
