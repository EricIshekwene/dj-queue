import AppKit
import DJQCore
import SwiftUI

/// One caption pass for the selected clips (round 12): a template, several hashtag groups, and the real caption each clip would
/// post, before anything is written. Groups show how the selection stands now: on for all, off, or on for some (a dash), so
/// picking DJ lovd never takes another group away. Apply is one batch with one Undo.
struct BulkCaptionDialog: View {
  @Bindable var model: AppModel
  let ids: [String]
  @State private var change = CaptionChange()
  @State private var use: GroupUse?
  @State private var previews: [CaptionPreview] = []
  @State private var index = 0
  @State private var job: Task<Void, Never>?
  /// Save as template: the form takes the dialog's place until it's saved or closed.
  @State private var form: Form?

  private struct Form: Equatable {
    var name = ""
    var template: String
  }

  private var counts: [String: Int] { use?.counts ?? [:] }
  private var total: Int { use?.total ?? 0 }

  var body: some View {
    DSDialog(form == nil ? "Caption for \(AppModel.pipelineClips(ids.count))" : "Save as template",
             description: form == nil ? "Pick a template, several hashtag groups, or both" : "It joins your templates here, in the editor and in Settings",
             icon: "text.alignleft", width: 560, onClose: { model.dismissCaptionDialog() }) {
      if form == nil {
        VStack(alignment: .leading, spacing: DS.space.md) {
          BulkVersionNote(model: model, ids: ids, scope: .captionsV1Only)
          templatePicker
          groups
          preview
          notes
        }
      } else {
        formFields
      }
    } footer: {
      if form == nil {
        DSButton("Cancel", variant: .ghost, shortcut: "esc", action: close)
          .keyboardShortcut(.cancelAction)
        DSButton(verb, variant: .primary, disabledReason: disabledReason, tooltip: "You can undo this", shortcut: "↩", action: apply)
          .keyboardShortcut(.defaultAction)
      } else {
        DSButton("Back", variant: .ghost, shortcut: "esc") { model.dismissCaptionDialog() }
          .keyboardShortcut(.cancelAction)
        DSButton("Save template", variant: .primary, disabledReason: formProblem, shortcut: "↩", action: saveForm)
          .keyboardShortcut(.defaultAction)
          .background(ScriptAnchor("Save template"))
      }
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .onAppear(perform: load)
    .onDisappear { model.captionDialogFormOpen = false }
    .onChange(of: change) { _, _ in refresh() }
    // Undo from the toast while the dialog is open: the clips moved under it.
    .onChange(of: model.undoHistory.entries.count) { _, _ in load() }
    // A saved template undone from the toast: the pick goes with it, so Apply can't fail on a template that's gone.
    .onChange(of: model.captionTemplates.map(\.id)) { _, list in
      if case .use(let id) = change.template, !list.contains(id) { change.template = .keep }
    }
    .onChange(of: form == nil) { _, closed in model.captionDialogFormOpen = !closed }
    .onChange(of: model.captionDialogFormOpen) { _, open in if !open { form = nil } }
  }

  private var changing: Int { previews.filter(\.changes).count }
  private var verb: String { "Apply to \(AppModel.pipelineClips(max(changing, change.isEmpty ? ids.count : 1)))" }

  private var disabledReason: String? {
    if change.isEmpty { return "Pick a template or a hashtag group first" }
    return changing == 0 ? "Nothing would change" : nil
  }

  // MARK: Template

  /// Chips, not a menu: Eric's templates stay in view, one click each, like the groups below them.
  private var templatePicker: some View {
    let def = model.captionTemplates.first { $0.id == model.settings.defaults.captionTemplateId }?.name ?? "Default"
    // The default's own name would be the same chip twice.
    let others = model.captionTemplates.filter { $0.id != model.settings.defaults.captionTemplateId }
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: DS.space.xs) {
        Text("Template").font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
        Spacer(minLength: 0)
        DSButton("Save as template", icon: "plus", variant: .ghost, size: .sm, tooltip: "Keep this template and these hashtags to use again", action: openForm)
          .background(ScriptAnchor("Save as template"))
      }
      DSFlowLayout(spacing: 5) {
        templateChip("Keep captions", .keep, help: "Each clip keeps its text. Only the hashtags change")
        templateChip("Default · \(def)", .useDefault, help: "Back to the default template")
        ForEach(others) { t in
          templateChip(t.name, .use(t.id), help: t.template.replacingOccurrences(of: "\n", with: " ⏎ "))
        }
      }
    }
  }

  private func templateChip(_ title: String, _ value: CaptionChange.Template, help: String) -> some View {
    DSChip(title, isSelected: change.template == value, size: .sm, tooltip: help) { change.template = value }
      .background(ScriptAnchor(title))
  }

  // MARK: Save as template

  /// The picked template (or text and hashtags, when none is picked) with the picked groups' tags typed in.
  private func openForm() {
    let id: String?
    switch change.template {
    case .keep: id = nil
    case .useDefault: id = model.settings.defaults.captionTemplateId
    case .use(let t): id = t
    }
    let base = model.captionTemplates.first { $0.id == id }?.template ?? "{text}\n\n{hashtags}"
    // Every group the preview shows for all these clips, in its order: a checked group is part of what's being saved.
    let tags = change.groups(from: use?.common ?? []).flatMap { g in model.hashtagSets.first { $0.id == g }?.tags ?? [] }
    form = Form(template: CaptionTemplates.template(from: base, carrying: tags))
  }

  private var formFields: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      DSTextField("Name", placeholder: "e.g. Mashup", text: Binding(get: { form?.name ?? "" }, set: { form?.name = $0 }), size: .sm, autoFocus: true, onSubmit: saveForm)
      DSTextArea("Template", placeholder: "{text}\n\n{hashtags}", text: Binding(get: { form?.template ?? "" }, set: { form?.template = $0 }),
                 hint: CaptionTemplates.hashtagHint, minHeight: 104, maxHeight: 200)
    }
  }

  private var formProblem: String? {
    guard let form else { return nil }
    return CaptionTemplates.problem(name: form.name, template: form.template, existing: model.captionTemplates)?.message
  }

  /// The new template is picked, and its typed tags stand in for the groups that were picked.
  private func saveForm() {
    guard let form, formProblem == nil else { return }
    let t = CaptionTemplates.make(name: form.name, template: form.template, existing: model.captionTemplates)
    do {
      let saved = try CaptionTemplates.create(t, store: model.store, bulk: model.bulk)
      model.groupEdited(saved.result, message: "“\(t.name)” saved")
      model.refreshNow()
      change = CaptionChange(template: .use(t.id), removeGroups: change.removeGroups)
      self.form = nil
    } catch {
      model.show(error.localizedDescription, error: true)
    }
  }

  // MARK: Groups

  private var groups: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      Text("Hashtag groups").font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
      let groups = HashtagGroups.pickable(model.hashtagSets)
      if groups.isEmpty {
        Text("No hashtag groups yet. Make one in Settings or in the editor.").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      } else {
        DSFlowLayout(spacing: 5) {
          ForEach(groups) { chip($0) }
        }
        Text("Tags you add go in the order you click, after each clip's other groups.").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      }
    }
  }

  private func chip(_ s: HashtagSet) -> some View {
    let n = counts[s.id] ?? 0
    let mark = change.mark(s.id, count: n, total: total)
    return DSChip(HashtagGroups.label(s), isSelected: mark == .all, isMixed: mark == .some,
                  disabledReason: use == nil ? "Checking these clips…" : nil, size: .sm, tooltip: help(s, mark, n)) {
      change.toggle(s.id, count: n, total: total)
    }
    .background(ScriptAnchor(HashtagGroups.label(s)))
  }

  private func help(_ s: HashtagSet, _ mark: CaptionChange.GroupMark, _ n: Int) -> String {
    let tags = s.tags.isEmpty ? "this group" : s.tags.joined(separator: " ")
    let mixed = n > 0 && n < total
    switch mark {
    case .all: return change.addGroups.contains(s.id) && mixed ? "Take \(tags) off all of these clips" : "Take \(tags) off these clips"
    case .some: return "\(tags) is on \(n) of \(total) clips. Click to add it to all"
    case .none: return change.removeGroups.contains(s.id) ? "Leave \(tags) as it was" : "Add \(tags) to these clips"
    }
  }

  // MARK: Preview

  @ViewBuilder private var preview: some View {
    if let p = current {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        HStack(spacing: DS.space.xxs) {
          Text(p.name).font(DS.type.captionMedium).foregroundStyle(DS.color.text).lineLimit(1)
          Spacer(minLength: DS.space.sm)
          if previews.count > 1 {
            Text("\(index + 1) of \(previews.count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
            DSIconButton("chevron.left", tooltip: "Previous clip", size: .sm, disabledReason: index == 0 ? "This is the first clip" : nil) { index -= 1 }
            DSIconButton("chevron.right", tooltip: "Next clip", size: .sm,
                         disabledReason: index == previews.count - 1 ? "This is the last clip" : nil) { index += 1 }
          }
        }
        Text(p.caption).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(8)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if let why = p.skipped { EditorHint(why, icon: "lock") }
      }
      .padding(DS.space.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    }
  }

  private var current: CaptionPreview? { previews.indices.contains(index) ? previews[index] : previews.first }

  /// What the preview alone doesn't say: only lines that are true now, so a plain pass shows none.
  @ViewBuilder private var notes: some View {
    let written = previews.filter(\.replacesWritten).count
    let skipped = previews.filter { $0.skipped != nil }.count
    let other = previews.filter { !$0.otherCaptions.isEmpty }
    let hidden = previews.filter(\.hidesGroups).count
    let long = previews.filter { !$0.tooLong.isEmpty }
    let leaving = previews.filter(\.leavesQueue).count
    VStack(alignment: .leading, spacing: 4) {
      if written > 0 {
        EditorHint("Replaces \(written == 1 ? "1 caption" : "\(written) captions") you wrote", icon: "exclamationmark.triangle.fill", tone: .warning)
      }
      if hidden > 0 {
        EditorHint("\(AppModel.pipelineClips(hidden)) won't show the groups: the template has no {hashtags}", icon: "exclamationmark.triangle.fill", tone: .warning)
      }
      if !long.isEmpty {
        EditorHint("\(AppModel.pipelineClips(long.count)) too long for \(names(long.flatMap(\.tooLong)))", icon: "exclamationmark.triangle.fill", tone: .warning)
      }
      if leaving > 0 { EditorHint("\(AppModel.pipelineClips(leaving)) go back to Edit until that's fixed", icon: "exclamationmark.triangle.fill", tone: .warning) }
      ForEach(current?.capNotes.filter { !$0.own } ?? []) { EditorHint($0.message, icon: "number") }
      if !other.isEmpty {
        EditorHint("\(AppModel.pipelineClips(other.count)) post\(other.count == 1 ? "s" : "") something else on \(names(other.flatMap(\.otherCaptions))), which stays", icon: "info.circle")
      }
      if skipped > 0 { EditorHint("\(skipped == 1 ? "1 clip stays" : "\(skipped) clips stay") as it is: \(skipReason)", icon: "lock") }
    }
  }

  private func names(_ list: [Platform]) -> String {
    let set = Set(list)
    return Platform.allCases.filter(set.contains).map(\.displayName).joined(separator: ", ")
  }

  private var skipReason: String {
    previews.allSatisfy { $0.skipped == nil || $0.skipped == BulkActions.captionHeldReason } ? "scheduled or posted posts" : "see each clip"
  }

  // MARK: Data

  private func load() {
    let b = model.bulk, ids = ids
    Task.detached(priority: .userInitiated) {
      let groups = try? b.groupUse(ids)
      await MainActor.run {
        use = groups ?? GroupUse()
        refresh()
      }
    }
  }

  /// The newest pick wins; an older answer never lands over it.
  private func refresh() {
    job?.cancel()
    let b = model.bulk, ids = ids, change = change
    job = Task.detached(priority: .userInitiated) {
      let list = (try? b.previewCaption(ids, change)) ?? []
      guard !Task.isCancelled else { return }
      await MainActor.run { if self.change == change { previews = list } }
    }
  }

  private func close() { model.captionDialogIds = nil }

  private func apply() {
    let b = model.bulk, ids = ids, change = change
    model.captionDialogIds = nil
    var r = BulkRequest(title: "", verb: "", ids: ids, doneMessage: "Caption set for \(AppModel.pipelineClips(changing))") { dry in
      try b.setCaption(ids, change, dryRun: dry)
    }
    r.versionScope = .captionsV1Only
    model.apply(r)
  }
}

/// Marks a control for the scripted runs (`BulkCaptionScript`): a view that takes no clicks, found by name, so a script clicks
/// where the control really is. SwiftUI buttons have no views of their own.
struct ScriptAnchor: NSViewRepresentable {
  static let prefix = "djq-anchor-"
  let name: String
  init(_ name: String) { self.name = name }

  final class Mark: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  func makeNSView(context: Context) -> Mark {
    let v = Mark()
    v.identifier = NSUserInterfaceItemIdentifier(Self.prefix + name)
    return v
  }

  func updateNSView(_ v: Mark, context: Context) {}
}
