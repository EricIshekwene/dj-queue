import AppKit
import DJQCore
import SwiftUI

/// Caption (round 7, WYSIWYG): the field holds the real caption that posts — template filled, hashtags included — and
/// stays editable at any length (it grows, then scrolls). Typing makes it Custom (↺ back to the template); choosing a
/// template rewrites it (⌘Z undoes); hashtag groups and extra tags swap the hashtags inside it in place. ONE length
/// line, warnings only for platforms near or over their limit, YouTube title from a template (then editable), and
/// per-platform captions. Nothing is shortened silently (#9).
struct EditorCaptionSection: View {
  @ObservedObject var model: EditorModel
  @State private var extra = ""
  @State private var extraTask: Task<Void, Never>?
  @State private var showOwn = false
  /// Where the keyboard was when the group form opened; Cancel gives it back.
  @State private var focusMemo = EditorFocusMemo()

  var body: some View {
    let r = model.resolved
    EditorSectionView(.caption) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        template(r)
        // The field is the hero; the chips that change it sit directly under it.
        VStack(alignment: .leading, spacing: DS.space.sm) {
          caption(r)
          parts
        }
        hashtags(r)
        if !model.isPhoto { youtube(r) }  // round 21 (D8): a photo post never goes to YouTube
        ownCaptions(r)
      }
    }
    .onAppear { syncDrafts() }
    .onChange(of: model.versionNo) { _, _ in syncDrafts() }
    .onChange(of: model.videoId) { _, _ in syncDrafts() }
    .onChange(of: model.resolved.extraHashtags) { _, tags in
      // Reset / version switch / undo: re-sync the field unless it already says the same thing.
      if parse(extra) != tags { extra = tags.joined(separator: " ") }
    }
    .onChange(of: model.openPlatformCaption) { _, p in if p != nil { showOwn = true } }
  }

  private func syncDrafts() {
    let r = model.resolved
    extra = r.extraHashtags.joined(separator: " ")
    showOwn = !r.platformCaptions.isEmpty
  }

  // MARK: Template

  private static let customValue = "\u{1}custom"

  private func template(_ r: ResolvedVersion) -> some View {
    let def = model.templates.first { $0.id == model.defaults.captionTemplateId }?.name ?? model.defaults.captionTemplateId
    let written = model.captionIsWritten
    var options: [DSSelectOption<String>] = []
    if written { options.append(DSSelectOption(value: Self.customValue, title: "Your own text", icon: "pencil")) }
    options.append(DSSelectOption(value: "", title: "Default · \(def)"))
    options += model.templates.map { DSSelectOption(value: $0.id, title: $0.name) }
    if let id = r.captionTemplateId, !model.templates.contains(where: { $0.id == id }) {
      options.append(DSSelectOption(value: id, title: "Missing template", icon: "exclamationmark.triangle"))
    }
    let inherited = model.captionInheritedFrom
    return EditorField(label: "Template", help: "Fills the caption below; pick another to start over from it (⌘Z undoes)",
                       isCustom: !r.isDefault("captionTemplateId"),
                       inheritedFrom: model.source(of: "captionTemplateId"), resetHelp: "Back to the default template",
                       onReset: model.ownsField(["captionTemplateId"]) ? { model.setCaptionTemplate(nil) } : nil) {
      VStack(alignment: .leading, spacing: DS.space.xxs) {
        HStack(alignment: .top, spacing: DS.space.xxs) {
          DSSelect(selection: Binding(get: { written ? Self.customValue : (r.captionTemplateId ?? "") },
                                      set: { id in if id != Self.customValue { model.setCaptionTemplate(id) } }),
                   options: options,
                   hint: written && inherited == nil ? "The caption is your own text. Picking a template rewrites it." : nil,
                   size: .sm,
                   disabledReason: inherited.map { "v\($0)'s written caption is used — edit it below; v\($0) can go back to a template" })
          if model.templateForm == nil { templateMenu }
        }
        if let form = model.templateForm {
          EditorTemplateFormView(model: model, form: form).id(form.id)
        }
      }
    }
  }

  /// Everything you can do with templates, in one place beside the field. A read-only clip says why on hover.
  private var templateMenu: some View {
    let selected = model.selectedTemplate, off = model.groupsOffReason
    return DSXMenuButton(tooltip: off ?? "Template actions", size: .sm) {
      if let t = model.defaultCandidate {
        Button("Set “\(t.name)” as default") { model.setDefaultTemplate(t.id) }
          .disabled(off != nil)
      }
      Button("New template…") { dsWithAnimation { model.openTemplateForm() } }
        .disabled(off != nil)
      Button("Save caption as template…") { dsWithAnimation { model.openSaveAsTemplate() } }
        .disabled(off != nil)
      if let selected {
        Divider()
        Button("Edit “\(selected.name)”…") { dsWithAnimation { model.openTemplateForm(selected) } }
          .disabled(off != nil)
        let blocked = CaptionTemplates.blocker(of: selected.id, settings: model.settings)
        Button(blocked == nil ? "Delete “\(selected.name)”…" : "Delete “\(selected.name)”: it's a default template", role: .destructive) {
          model.onDeleteTemplate?(selected)
        }
        .disabled(off != nil || blocked != nil || model.onDeleteTemplate == nil)
      }
      Divider()
      Button("Manage in Settings") { WindowManager.shared.showSettings(section: .captions) }
    }
  }

  // MARK: Caption + length line + warnings

  private func caption(_ r: ResolvedVersion) -> some View {
    let written = model.captionIsWritten
    return EditorField(label: "Caption", isCustom: written, inheritedFrom: model.source(of: "caption"),
                       resetHelp: "Use the template again (rewrites the caption; ⌘Z undoes)",
                       onReset: written && model.ownsField(["caption"]) ? { model.resetCaptionToTemplate() } : nil) {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        EditorCaptionText(model: model, platform: nil, placeholder: "Type the caption, or pick a template above",
                          minHeight: 120, maxHeight: 340)
        lengthLine(r)
        ForEach(model.captionIssues) { i in
          EditorHint(i.message, icon: "exclamationmark.triangle.fill", tone: .warning)
        }
        let other = model.platformsWithOtherCaption
        if !other.isEmpty {
          EditorHint("\(other.map(\.editorShortName).joined(separator: ", ")) post\(other.count == 1 ? "s" : "") a different caption — see Captions for one platform below",
                     icon: "info.circle")
        }
        ForEach(model.capNotes) { n in
          if n.own, !n.scheduled {
            EditorHint(n.message, icon: "exclamationmark.triangle.fill", tone: .warning)
          } else {
            Text(n.message).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).fixedSize(horizontal: false, vertical: true)
          }
        }
        ForEach(model.captionWarnings) { w in warning(w) }
      }
    }
  }

  private func lengthLine(_ r: ResolvedVersion) -> some View {
    let n = model.mainCaption.count
    return HStack(spacing: 5) {
      Text(model.captionIsWritten ? "Your own text" : "From the template")
      Spacer(minLength: 0)
      Text("\(n) characters").monospacedDigit()
      Image(systemName: "info.circle").font(.system(size: 11))
    }
    .font(DS.type.caption)
    .foregroundStyle(DS.color.textTertiary)
    .contentShape(Rectangle())
    .dsTooltip(breakdownShort)
    .accessibilityElement(children: .combine)
    .accessibilityHint(breakdown)
  }

  /// Full per-platform breakdown for the tooltip ("TikTok 182 / 4000 …").
  private var breakdown: String {
    let lines = model.postingPlatforms.map { p in
      let n = model.caption(for: p).count
      let own = model.resolved.platformCaptions[p] != nil ? " (own caption)" : ""
      return "\(p.displayName): \(n) / \(model.captionLimit(p))\(own)"
    }
    return lines.isEmpty ? "Not posting anywhere" : lines.joined(separator: "\n")
  }

  /// Compact one-paragraph form for the hover bubble ("TikTok 182/4000 · Instagram 182/2200 …").
  private var breakdownShort: String {
    let items = model.postingPlatforms.map { p in
      "\(p.editorShortName) \(model.caption(for: p).count)/\(model.captionLimit(p))\(model.resolved.platformCaptions[p] != nil ? " (own)" : "")"
    }
    return items.isEmpty ? "Not posting anywhere" : items.joined(separator: " · ")
  }

  private func warning(_ w: EditorCaptionWarning) -> some View {
    let name = w.platform.displayName
    let dropReason: String? = {
      guard let bare = w.countWithoutHashtags else { return "\(name)'s caption has no hashtags to drop" }
      return bare > w.limit ? "Still \(bare)/\(w.limit) without hashtags — write a shorter \(name) caption" : nil
    }()
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: 6) {
        Image(systemName: w.over ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
          .font(.system(size: 11, weight: .semibold))
        (Text(w.over ? "Too long for \(name)" : "Close to the \(name) limit").font(DS.type.captionMedium)
          + Text("  \(w.count)/\(w.limit)").font(DS.type.caption.monospacedDigit()))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .foregroundStyle(w.over ? DS.color.warning : DS.color.textSecondary)
      if w.over {
        DSFlowLayout(spacing: 6) {
          DSButton("Drop hashtags for \(name)", variant: .outline, size: .sm, disabledReason: dropReason,
                   tooltip: "Give \(name) the same caption without hashtags (\(w.countWithoutHashtags ?? 0) characters)") {
            model.dropHashtags(w.platform)
          }
          DSButton("Write a\(name.first.map { "AEIOUX".contains($0) } == true ? "n" : "") \(name) caption", variant: .ghost, size: .sm,
                   tooltip: "Start a caption just for \(name) from this one") { model.writePlatformCaption(w.platform) }
        }
      }
    }
    .padding(.horizontal, DS.space.sm).padding(.vertical, DS.space.xs)
    .background(w.over ? DS.color.warningTint : DS.color.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  // MARK: Parts

  /// Chips like the hashtag groups, but they change the text: on means it's in the caption right now.
  @ViewBuilder private var parts: some View {
    if let values = model.partValues {
      EditorField(label: "Parts", help: "Add or remove a part of the caption, in the text itself. You can still edit it freely") {
        DSFlowLayout(spacing: 5) {
          ForEach(CaptionPart.allCases) { p in
            let on = CaptionParts.isOn(p, in: model.mainCaption, values), value = values.value(p)
            let why = model.partsOffReason ?? (on ? nil : CaptionParts.offReason(p, values))
            DSChip(p.label, isSelected: on, disabledReason: why, size: .sm,
                   tooltip: on ? "Take “\(value)” out of the caption" : "Add “\(value)” to the caption") { model.togglePart(p) }
          }
        }
      }
    }
  }

  // MARK: Hashtag groups + extra hashtags

  private var groups: [HashtagSet] { HashtagGroups.pickable(model.sets) }

  private var categories: [String] {
    var seen = Set<String>()
    return groups.map(\.category).filter { seen.insert($0).inserted }
  }

  private func hashtags(_ r: ResolvedVersion) -> some View {
    VStack(alignment: .leading, spacing: DS.space.md) {
      EditorField(label: "Hashtag groups", help: model.isPhoto ? "Your own groups, shared by every clip and photo post. Right-click one to edit or delete it"
                                                        : "Your own groups, shared by every clip. Right-click one to edit or delete it",
                  isCustom: !r.isDefault("hashtagSetIds"), inheritedFrom: model.source(of: "hashtagSetIds"),
                  resetHelp: "Back to the default groups (New clip defaults)",
                  onReset: model.ownsField(["hashtagSetIds"]) ? { model.setHashtagSets(model.fallback(\.hashtagSetIds, \.hashtagSetIds)) } : nil) {
        VStack(alignment: .leading, spacing: DS.space.xs) {
          if groups.isEmpty {
            Text("No hashtag groups yet").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
          } else {
            ForEach(categories, id: \.self) { cat in
              VStack(alignment: .leading, spacing: 4) {
                if categories.count > 1 { Text(cat).font(DS.type.micro).foregroundStyle(DS.color.textTertiary) }
                DSFlowLayout(spacing: 5) {
                  ForEach(groups.filter { $0.category == cat }) { s in groupChip(s, r) }
                }
              }
            }
          }
          if let form = model.groupForm {
            EditorGroupFormView(model: model, form: form, focusMemo: focusMemo).id(form.id)
              .id(EditorInspector.groupFormAnchor)
          } else {
            groupActions
          }
        }
        .background(EditorFocusMemoAnchor(memo: focusMemo))
      }
      EditorField(label: "Extra hashtags", help: "Added after the groups, separated by spaces",
                  isCustom: !r.isDefault("extraHashtags"), inheritedFrom: model.source(of: "extraHashtags"),
                  resetHelp: "Back to the default extra hashtags",
                  onReset: model.ownsField(["extraHashtags"]) ? { model.setExtraHashtags(model.fallback(\.extraHashtags, \.extraHashtags)) } : nil) {
        DSTextField(placeholder: "e.g. #afrohouse #djlovd", text: $extra, size: .sm, onSubmit: commitExtra)
          .onChange(of: extra) { _, _ in scheduleExtra() }
          .dsTooltip("Goes into the caption with the groups' hashtags, separated by spaces", shortcut: "↩")
      }
    }
  }

  /// New group is the main path; Settings stays one click away for managing them all.
  private var groupActions: some View {
    HStack(spacing: DS.space.xxs) {
      DSButton("New group", icon: "plus", variant: .ghost, size: .sm, disabledReason: model.groupsOffReason,
               tooltip: "Make a group and turn it on for this \(model.noun)") {
        focusMemo.remember()
        dsWithAnimation { model.openGroupForm() }
      }
      DSButton("Manage in Settings", variant: .ghost, size: .sm, tooltip: "Open Settings → Captions & titles") {
        WindowManager.shared.showSettings(section: .captions)
      }
    }
  }

  private func groupChip(_ s: HashtagSet, _ r: ResolvedVersion) -> some View {
    let on = r.hashtagSetIds.contains(s.id)
    return DSChip(HashtagGroups.label(s), isSelected: on, size: .sm) { model.setGroup(s.id, on: !on) }
      .background(ScriptAnchor("Group \(s.id)"))
      .dsTooltip(s.tags.isEmpty ? "This group has no hashtags yet — right-click it to add some"
                 : on ? "Take \(s.tags.joined(separator: " ")) out of the caption"
                 : "Add \(s.tags.joined(separator: " ")) to the caption")
      .contextMenu {
        if model.groupsOffReason == nil {
          Button("Edit group…") {
            focusMemo.remember()
            dsWithAnimation { model.openGroupForm(s) }
          }
          if let delete = model.onDeleteGroup {
            Button("Delete group…", role: .destructive) { delete(s) }
          }
        }
      }
  }

  private func parse(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).map(String.init)
  }

  /// Extra tags go into the caption once typing pauses (or on ↩), not on every keystroke.
  private func scheduleExtra() {
    extraTask?.cancel()
    extraTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      commitExtra()
    }
  }

  private func commitExtra() {
    extraTask?.cancel()
    let tags = parse(extra)
    guard tags != model.resolved.extraHashtags else { return }
    model.setExtraHashtags(tags)
  }

  // MARK: YouTube title

  /// Round 7: pick a template, then edit the real title (typing → Custom, ↺ back to the template). F1: YouTube allows
  /// 100 characters; a typed title over the limit is an error (core's `.titleTooLong` keeps the clip in Edit), a
  /// template title that had to be shortened is a notice with what goes out (core `TitleCheck`).
  private func youtube(_ r: ResolvedVersion) -> some View {
    let lim = min(model.settings.limits[.youtube]?.titleLimit ?? PostizPayload.youtubeTitleMax, PostizPayload.youtubeTitleMax)
    let typed = r.youtubeTitle
    let checks = model.video.map { PostizPayload.titleChecks(video: $0, version: r, settings: model.settings) } ?? []
    let defName = model.youtubeTitleTemplates.first { $0.id == model.defaults.youtubeTitleTemplateId }?.name ?? "Default"
    var options = [DSSelectOption(value: "", title: "Default · \(defName)")]
    options += model.youtubeTitleTemplates.map { DSSelectOption(value: $0.id, title: $0.name, detail: $0.template) }
    if !typed.isEmpty { options.insert(DSSelectOption(value: Self.customValue, title: "Your own title", icon: "pencil"), at: 0) }
    let n = model.youtubeTitle.count
    return EditorField(label: "YouTube title", help: "The Shorts title (YouTube shows it under the handle)",
                       value: "\(n)/\(lim)", isCustom: !typed.isEmpty || !r.isDefault("youtubeTitleTemplateId"),
                       inheritedFrom: model.source(of: "youtubeTitle") ?? model.source(of: "youtubeTitleTemplateId"),
                       resetHelp: typed.isEmpty ? "Back to the default template" : "Use the template's title again (⌘Z undoes)",
                       onReset: model.ownsField(["youtubeTitle", "youtubeTitleTemplateId"])
                         ? { model.setYouTubeTitleTemplate(typed.isEmpty ? nil : r.youtubeTitleTemplateId) } : nil) {
      VStack(alignment: .leading, spacing: 6) {
        DSSelect(selection: Binding(get: { typed.isEmpty ? (r.youtubeTitleTemplateId ?? "") : Self.customValue },
                                    set: { id in if id != Self.customValue { model.setYouTubeTitleTemplate(id) } }),
                 options: options, size: .sm)
          .background(ScriptAnchor("YouTube title template"))
        EditorYouTubeTitleField(model: model,
                                error: typed.count > lim && model.posting(.youtube)
                                  ? "\(typed.count - lim) over YouTube's \(lim) — shorten it; the clip stays in Edit until it fits" : nil)
        if !model.posting(.youtube) {
          EditorHint("Not posting on YouTube Shorts.")
        } else {
          ForEach(checks.filter { $0.message != nil && ($0.platform != .youtube || typed.count <= lim) }, id: \.platform) { c in
            // Same numbers as the header (what is sent): "template title is 120 characters — shortened to 99 to fit 100".
            EditorHint("\(c.platform == .youtube ? "The template's" : "\(c.platform.displayName)'s") title is \(c.full.count) characters — it goes out shortened to \(c.title.count) to fit \(c.limit): “\(c.title)”",
                       icon: "scissors", tone: .warning)
          }
        }
      }
    }
  }

  // MARK: Per-platform captions

  private func ownCaptions(_ r: ResolvedVersion) -> some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      Button { dsWithAnimation { showOwn.toggle() } } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showOwn ? 90 : 0))
          Text("Captions for one platform").font(DS.type.calloutMedium)
          if !r.platformCaptions.isEmpty { DSBadge("\(r.platformCaptions.count)", style: .soft(.neutral), size: .sm, help: r.platformCaptions.count == 1 ? "1 platform has its own caption" : "\(r.platformCaptions.count) platforms have their own caption") }
          Spacer(minLength: 0)
        }
        .foregroundStyle(DS.color.text)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .dsTooltip(showOwn ? "Hide the per-platform captions" : "Give a platform its own caption")
      if showOwn {
        VStack(alignment: .leading, spacing: DS.space.sm) {
          EditorHint("A platform with its own caption keeps it as written — groups and extra hashtags don't change it.")
          ForEach(model.postingPlatforms) { p in ownRow(p, r) }
        }
        .padding(.top, 4)
      }
    }
  }

  @ViewBuilder private func ownRow(_ p: Platform, _ r: ResolvedVersion) -> some View {
    let on = r.platformCaptions[p] != nil
    VStack(alignment: .leading, spacing: 6) {
      DSToggle(p.displayName, isOn: Binding(get: { on }, set: { v in
        model.setPlatformCaption(p, v ? model.caption(for: p) : nil)
      }), size: .sm)
      .dsTooltip(on ? "Delete \(p.displayName)'s own caption; use the shared one" : "Write a caption just for \(p.displayName)")
      if on {
        EditorCaptionText(model: model, platform: p, placeholder: "Caption for \(p.displayName)",
                          limit: model.captionLimit(p), minHeight: 72, maxHeight: 240)
      }
    }
  }
}

/// Where the keyboard was before the group form took it. Only a real text view counts: the field editor is shared, so
/// by the time the form closes it belongs to the form.
@MainActor
final class EditorFocusMemo {
  weak var anchor: NSView?
  private weak var previous: NSTextView?

  func remember() {
    let t = anchor?.window?.firstResponder as? NSTextView
    previous = t?.isFieldEditor == false ? t : nil
  }

  /// Cancel: straight back to the caption Eric was typing in. After Save nothing keeps the keyboard, so ⌘Z takes the
  /// group back off and Space plays (a focused text field would take ⌘Z for its own typing).
  func close(restoring: Bool) {
    let window = anchor?.window, target = restoring ? previous : nil
    previous = nil
    DispatchQueue.main.async { window?.makeFirstResponder(target) }
  }
}

/// Fills the groups area: the memo finds the window from it, and the live script finds the buttons.
final class EditorGroupsAnchorView: NSView {}

struct EditorFocusMemoAnchor: NSViewRepresentable {
  let memo: EditorFocusMemo
  func makeNSView(context: Context) -> NSView {
    let v = EditorGroupsAnchorView()
    memo.anchor = v
    return v
  }
  func updateNSView(_ v: NSView, context: Context) { memo.anchor = v }
}

/// New / edit hashtag group, inline under the chips so the caption stays in view. It owns its text while Eric types.
/// ↩ moves from Name to Hashtags and saves from there; Esc or Cancel discards.
struct EditorGroupFormView: View {
  @ObservedObject var model: EditorModel
  let form: EditorGroupForm
  let focusMemo: EditorFocusMemo
  @State private var name: String
  @State private var tags: String
  @State private var focusTags = 0

  init(model: EditorModel, form: EditorGroupForm, focusMemo: EditorFocusMemo) {
    self.model = model
    self.form = form
    self.focusMemo = focusMemo
    _name = State(initialValue: form.name)
    _tags = State(initialValue: form.tags)
  }

  private var parsed: [String] { HashtagGroups.parseTags(tags) }
  private var problem: HashtagGroups.Problem? {
    HashtagGroups.problem(name: name, tags: parsed, existing: model.sets, editing: form.editing)
  }
  private var duplicate: String? {
    if case .duplicateName = problem { return problem?.message }
    return nil
  }
  private var isNew: Bool { form.editing == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      DSTextField("Name", placeholder: "e.g. Piano", text: $name, error: duplicate, size: .sm, autoFocus: true) {
        if parsed.isEmpty { focusTags += 1 } else { save() }
      }
      DSTextField("Hashtags", placeholder: "#amapiano #piano", text: $tags,
                  hint: parsed.isEmpty ? "Spaces between them; the # is optional" : "Saves as \(parsed.joined(separator: " "))",
                  size: .sm, focusToken: focusTags, onSubmit: save)
      if isNew {
        EditorHint(model.isPhoto ? "Saved for every clip and photo post, and on for this one." : "Saved for every clip, and on for this one.")
      } else if let reach = form.impact {
        EditorHint(reach.editSummary, icon: "info.circle")
      }
      HStack(spacing: DS.space.xxs) {
        Spacer(minLength: 0)
        DSButton("Cancel", variant: .ghost, size: .sm, tooltip: "Close without saving", shortcut: "esc", action: cancel)
          .keyboardShortcut(.cancelAction)
        DSButton(isNew ? "Save group" : "Save changes", variant: .outline, size: .sm,
                 disabledReason: problem?.message, shortcut: "↩", action: save)
      }
    }
    .padding(DS.space.sm)
    .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  private func save() {
    guard problem == nil else { return }
    var ok = false
    dsWithAnimation { ok = model.saveGroup(name: name, tags: tags) }
    if ok { focusMemo.close(restoring: false) }
  }

  private func cancel() {
    dsWithAnimation { model.groupForm = nil }
    focusMemo.close(restoring: true)
  }
}

/// A caption field that owns its text while Eric types (no cursor jumps, cheap keystrokes): it hands each change to
/// `EditorModel.typeCaption` (applied once typing pauses) and re-reads the model whenever anything else changes the
/// caption (`fieldRevision`: a template, a group, extra tags, ↺, ⌘Z, another version).
struct EditorCaptionText: View {
  @ObservedObject var model: EditorModel
  var platform: Platform?
  var placeholder: String
  var limit: Int? = nil
  var minHeight: CGFloat
  var maxHeight: CGFloat
  @State private var text = ""
  @State private var synced = ""

  private var source: String {
    if let p = platform { return model.resolved.platformCaptions[p] ?? "" }
    return model.mainCaption
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      DSTextArea(placeholder: placeholder, text: $text, limit: limit, minHeight: minHeight, maxHeight: maxHeight)
        .accessibilityIdentifier(platform.map { "editor.caption.\($0.rawValue)" } ?? "editor.caption")
        .background(ScriptAnchor(platform.map { "Caption field \($0.rawValue)" } ?? "Caption field"))
      if platform == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !synced.isEmpty {
        EditorHint("Empty — the template's caption posts until you type one")
      }
    }
    .onAppear { sync() }
    .onChange(of: model.fieldRevision) { _, _ in sync() }
    .onChange(of: text) { _, t in
      guard t != synced else { return }
      synced = t
      model.typeCaption(t, platform: platform)
    }
  }

  private func sync() {
    let s = source
    guard s != text else { synced = s; return }
    synced = s
    text = s
  }
}

/// The YouTube title as it goes out — the template's title until Eric types (then Custom). Same draft rule as the
/// caption field.
struct EditorYouTubeTitleField: View {
  @ObservedObject var model: EditorModel
  var error: String?
  @State private var text = ""
  @State private var synced = ""

  var body: some View {
    DSTextField(placeholder: "Type a title, or pick a template", text: $text, error: error, size: .sm)
      .accessibilityIdentifier("editor.youtubeTitle")
      .onAppear { sync() }
      .onChange(of: model.fieldRevision) { _, _ in sync() }
      .onChange(of: text) { _, t in
        guard t != synced else { return }
        synced = t
        model.typeYouTubeTitle(t)
      }
  }

  private func sync() {
    let s = model.youtubeTitle
    guard s != text else { synced = s; return }
    synced = s
    text = s
  }
}

/// Name and text for a caption template, in the Template field: the same pattern as the New group form.
struct EditorTemplateFormView: View {
  @ObservedObject var model: EditorModel
  let form: EditorTemplateForm
  @State private var name: String
  @State private var template: String

  init(model: EditorModel, form: EditorTemplateForm) {
    self.model = model
    self.form = form
    _name = State(initialValue: form.name)
    _template = State(initialValue: form.template)
  }

  private var problem: CaptionTemplates.Problem? {
    CaptionTemplates.problem(name: name, template: template, existing: model.templates, editing: form.editing)
  }
  private var duplicate: String? {
    if case .duplicateName = problem { return problem?.message }
    return nil
  }
  private var isNew: Bool { form.editing == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      DSTextField("Name", placeholder: "e.g. Full set plug", text: $name, error: duplicate, size: .sm, autoFocus: true, onSubmit: save)
      DSTextArea("Template", placeholder: "{text}\n\n{hashtags}", text: $template, hint: CaptionTemplates.hashtagHint, minHeight: 88, maxHeight: 180)
      if let reach = form.impact {
        EditorHint(reach.templateEditSummary, icon: "info.circle")
      } else if isNew, model.clipHasPosts {
        EditorHint("This \(model.noun) keeps its caption: it has scheduled or posted posts", icon: "info.circle")
      }
      HStack(spacing: DS.space.xxs) {
        DSXMenuButton(icon: "curlybraces", tooltip: "Add a token to the template", size: .sm) {
          ForEach(CaptionTemplates.tokens, id: \.token) { t in
            Button("\(t.label)  \(t.token)") { template = CaptionTemplates.adding(t.token, to: template) }
          }
        }
        Spacer(minLength: 0)
        DSButton("Cancel", variant: .ghost, size: .sm, tooltip: "Close without saving", shortcut: "esc") {
          dsWithAnimation { model.templateForm = nil }
        }
        .keyboardShortcut(.cancelAction)
        DSButton(isNew ? "Save template" : "Save changes", variant: .outline, size: .sm, disabledReason: problem?.message,
                 tooltip: !isNew ? nil : model.clipHasPosts ? "Saved for every \(model.isPhoto ? "clip and photo post" : "clip")"
                   : "Saved for every \(model.isPhoto ? "clip and photo post" : "clip"), and on for this one", action: save)
      }
    }
    .padding(DS.space.sm)
    .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  private func save() {
    guard problem == nil else { return }
    dsWithAnimation { _ = model.saveTemplate(name: name, template: template) }
  }
}
