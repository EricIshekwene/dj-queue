import DJQCore
import SwiftUI

/// One explicit fix for a hard block on an Edit card ("Trim for X", "Drop hashtags for X", "Write an X caption").
/// Never a silent change: each is a button Eric clicks (DESIGN-v2 §6.2, north star #9).
struct EditFix: Identifiable {
  var id: String
  var title: String
  var icon: String
  var tooltip: String
  var disabledReason: String?
  var action: () -> Void
}

extension AppModel {
  /// The explicit fixes for a clip's blocking issues, in issue order.
  func editFixes(_ v: Video, ids: [String]) -> [EditFix] {
    var out: [EditFix] = []
    // A scored clip whose file went missing sits in Edit (round 4 S1): the one fix is to find the file again.
    if v.missing {
      out.append(EditFix(id: "relink", title: "Relink", icon: "magnifyingglass",
                         tooltip: "Look for the moved file now (intake finds it by fingerprint); Health › Doctor shows more",
                         disabledReason: nil) { [self] in
        runTick()
        show(DSToastModel(message: "Looking for missing files", detail: "Intake finds renamed or moved files by fingerprint", duration: 4))
      })
    }
    for i in issuesByVideo[v.id] ?? [] {
      guard let p = i.platform ?? (i.kind == .titleTooLong ? .youtube : nil) else { continue }
      let name = p.displayName
      switch i.kind {
      case .tooLong:
        let limit = i.limit.map { " (\(Validation.fmt($0)) max)" } ?? ""
        out.append(EditFix(id: "trim-\(p.rawValue)", title: "Trim for \(name)", icon: "scissors",
                           tooltip: "Open the editor with a \(name) trim lane cut at its limit\(limit)", disabledReason: nil) { [self] in
          openEditor(v.id, in: ids, trimPlatform: p)
        })
        let id = v.id
        out.append(EditFix(id: "skip-\(p.rawValue)", title: "Skip \(name)", icon: "forward",
                           tooltip: "Don't post this clip on \(name); the others keep the full length", disabledReason: nil) { [self] in
          pipelineBulk("Skip \(name) for this clip?", verb: "Skip \(name)", ids: [id], done: "\(name) skipped for this clip") { b, dry in
            try b.setPlatform([id], p, skipped: true, dryRun: dry)
          }
        })
      case .captionTooLong:
        let limit = i.limit.map { Int($0) }
        var why: String?
        if let bare = i.countWithoutHashtags, let limit, bare > limit {
          why = "Still too long without hashtags (\(bare)/\(limit)) — write an \(name) caption instead"
        } else if i.countWithoutHashtags == nil {
          why = "This caption has no hashtags to drop"
        }
        let id = v.id
        out.append(EditFix(id: "drop-\(p.rawValue)", title: "Drop hashtags for \(name)", icon: "number",
                           tooltip: "Post the caption without its hashtags on \(name) only", disabledReason: why) { [self] in
          pipelineBulk("Drop hashtags for \(name)?", verb: "Drop hashtags", ids: [id], done: "Hashtags dropped for \(name)") { b, dry in
            try b.dropHashtags([id], platform: p, dryRun: dry)
          }
        })
        out.append(EditFix(id: "write-\(p.rawValue)", title: "Write \(Self.article(p)) \(name) caption", icon: "square.and.pencil",
                           tooltip: "Open the editor to write a caption just for \(name)", disabledReason: nil) { [self] in
          openEditor(v.id, in: ids)
        })
      case .titleTooLong:
        out.append(EditFix(id: "yt-title", title: "Shorten YouTube title", icon: "textformat",
                           tooltip: "Open the editor to shorten the YouTube title (100 max)", disabledReason: nil) { [self] in
          openEditor(v.id, in: ids)
        })
      default:
        break
      }
    }
    return out
  }

  /// "an X caption", "an Instagram caption", "a TikTok caption".
  static func article(_ p: Platform) -> String { [.x, .instagram].contains(p) ? "an" : "a" }

  /// Titles help: no Title yet. `addTitle` = no suggestions either (show the inline field).
  func editTitleNeeds(_ v: Video) -> (addTitle: Bool, askAgent: Bool) {
    guard v.titleText == nil else { return (false, needsTitleHelp.contains(v.id)) }
    return ((suggestionsByVideo[v.id] ?? []).isEmpty, needsTitleHelp.contains(v.id))
  }
}

/// The screen-owned slot of an Edit card, per view mode:
/// - Cards: a right column — title help (Add title field / Ask an agent), up to two fixes, Open editor + ⋯.
/// - Grid: round media buttons on hover (Open editor, Ask an agent).
/// - List: Open editor + ⋯ on hover.
/// - Single: the side panel's full action stack.
struct EditClipActions: View {
  @Bindable var model: AppModel
  let video: Video
  let mode: DSViewMode
  let ids: [String]

  var body: some View {
    let needs = model.editTitleNeeds(video)
    let fixes = model.editFixes(video, ids: ids)
    switch mode {
    case .wide:
      VStack(alignment: .trailing, spacing: 6) {
        if needs.addTitle || needs.askAgent {
          HStack(spacing: 6) {
            if needs.addTitle { EditAddTitleField(model: model, videoId: video.id).frame(width: 170) }
            if needs.askAgent { askAgent(size: .sm) }
          }
        }
        if !fixes.isEmpty {
          // Two fixes per line; a second "Trim for X · Skip X" pair (too long for two platforms) gets its own line
          // when there's room (no title help on the card).
          let shown = needs.addTitle || needs.askAgent ? min(2, fixes.count) : Self.visibleFixes(fixes)
          ForEach(Array(stride(from: 0, to: shown, by: 2)), id: \.self) { i in
            HStack(spacing: 6) { ForEach(fixes[i..<min(i + 2, shown)]) { fixButton($0) } }
          }
        }
        HStack(spacing: 2) {
          StageControl(model: model, video: video)
          DSButton("Open editor", variant: .ghost, size: .sm, tooltip: Self.openHelp) { open() }
          PipelineMoreMenu(tooltip: Self.moreHelp) {
            EditClipMenu(model: model, video: video, ids: ids, extraFixes: Array(fixes.dropFirst(needs.addTitle || needs.askAgent ? 2 : Self.visibleFixes(fixes))))
          }
        }
      }
      .fixedSize()
    case .grid:
      // Grid hover buttons render icon-only (DSMediaActionButton): each one names its consequence in a tooltip.
      let fwd = model.stageBlocker(video, .forward)
      DSMediaActionButton(model.stageForwardTitle(video), systemImage: "chevron.right", tooltip: model.stageForwardTitle(video),
                          disabledReason: fwd) {
        if let fwd { model.show(fwd, error: true) } else { model.stageForward([video.id]) }
      }
      DSMediaActionButton("Open editor", systemImage: "slider.horizontal.below.rectangle", tooltip: Self.openHelp) { open() }
      if needs.askAgent {
        DSMediaActionButton("Ask an agent", systemImage: "sparkles", tooltip: Self.askAgentHelp) { model.copyAgentPrompt([video.id]) }
      }
    case .list:
      StageControl(model: model, video: video, compact: true)
      DSIconButton("slider.horizontal.below.rectangle", tooltip: Self.openHelp, size: .sm) { open() }
      PipelineMoreMenu(tooltip: "Show fixes, kind, defaults and more") {
        EditClipMenu(model: model, video: video, ids: ids, extraFixes: fixes)
      }
    case .single:
      VStack(alignment: .leading, spacing: DS.space.sm) {
        if needs.addTitle { EditAddTitleField(model: model, videoId: video.id, label: "Title") }
        if needs.askAgent { askAgent(size: .md) }
        ForEach(fixes) { fixButton($0, size: .md) }
        StageControl(model: model, video: video, size: .md)
        HStack(spacing: 4) {
          DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .outline, tooltip: Self.openHelp) { open() }
          PipelineMoreMenu(tooltip: Self.moreHelp) { EditClipMenu(model: model, video: video, ids: ids) }
        }
      }
    }
  }

  static let askAgentHelp = "Copy a title prompt for your agent"
  /// 2, or 4 when the 3rd and 4th fixes are another platform's Trim/Skip pair.
  static func visibleFixes(_ fixes: [EditFix]) -> Int {
    guard fixes.count >= 4, fixes[2].id.hasPrefix("trim-"), fixes[3].id.hasPrefix("skip-") else { return min(2, fixes.count) }
    return 4
  }

  static let openHelp = "Edit crop, text, caption, cover, platforms"
  static let moreHelp = "Show kind, caption, defaults and more"

  private func askAgent(size: DSButtonSize) -> some View {
    DSButton("Ask an agent", icon: "sparkles", variant: .ghost, size: size, tooltip: Self.askAgentHelp) {
      model.copyAgentPrompt([video.id])
    }
  }

  private func fixButton(_ f: EditFix, size: DSButtonSize = .sm) -> some View {
    DSButton(f.title, icon: f.icon, variant: .ghost, size: size, disabledReason: f.disabledReason, tooltip: f.tooltip, action: f.action)
  }

  private func open() { model.openEditor(video.id, in: ids) }
}

/// Inline "Add title" (empty — never prefilled). It rests as a quiet field-shaped box and becomes a real text field
/// on click (so the window never auto-focuses a card's field); ↩ sets the Title through BulkActions.setTitle
/// (undo toast), esc or clicking away with nothing typed puts it back.
struct EditAddTitleField: View {
  @Bindable var model: AppModel
  let videoId: String
  var label: String?
  @State private var text = ""
  @State private var editing = false
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    DSFieldFrame(label: label, hint: label == nil ? nil : "No suggestions in metadata · ↩ saves") {
      HStack(spacing: 8) {
        Image(systemName: "character.cursor.ibeam").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.color.textTertiary)
        if editing {
          TextField("Add title", text: $text)
            .textFieldStyle(.plain)
            .font(DS.type.callout)
            .foregroundStyle(DS.color.text)
            .focused($focused)
            .onSubmit(save)
            .onExitCommand { cancel() }
        } else {
          Text("Add title").font(DS.type.callout).foregroundStyle(DS.color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: DS.size.controlSm)
      .modifier(DSFieldBox(focused: editing && focused, hovering: hovering, error: false, disabled: false))
      .contentShape(Rectangle())
      .onTapGesture { begin() }
      .onHover { hovering = $0 }
    }
    .onChange(of: focused) { _, f in if !f && text.trimmingCharacters(in: .whitespaces).isEmpty { editing = false } }
    .dsTooltip(label == nil ? "Type a title; ↩ saves (undoable)" : nil)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Add title")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { begin() }
  }

  private func begin() {
    editing = true
    DispatchQueue.main.async { focused = true }
  }

  private func cancel() {
    text = ""
    editing = false
  }

  private func save() {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { cancel(); return }
    let id = videoId
    cancel()
    model.pipelineBulk("Set title?", verb: "Set title", ids: [id], done: "Title set") { b, dry in try b.setTitle([id], t, dryRun: dry) }
  }
}

/// ⋯ and right-click menu of an Edit card (native items): Open editor · Back to Score / Send to queue · fixes · Kind ▸ · Caption… ·
/// Copy agent prompt · Reset to New clip defaults ▸ · Exclude. Acts on the selection when the clip is part of it.
struct EditClipMenu: View {
  @Bindable var model: AppModel
  let video: Video
  let ids: [String]
  var extraFixes: [EditFix] = []

  var body: some View {
    let sel = model.selectedIds(.edit)
    let targets = sel.count > 1 && sel.contains(video.id) ? sel : [video.id]
    let n = AppModel.pipelineClips(targets.count)
    Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id, in: ids) }
    StageMenuItems(model: model, video: video, targets: targets)
    if !extraFixes.isEmpty {
      Divider()
      // Native items show no tooltip: a disabled fix says why in its title.
      ForEach(extraFixes) { f in
        let why = f.disabledReason.map { ($0.components(separatedBy: " — ").first ?? $0).lowercased() }
        Button(why.map { "\(f.title) — \($0)" } ?? f.title, systemImage: f.icon, action: f.action).disabled(why != nil)
      }
    }
    Divider()
    Menu("Kind") {
      ForEach(Kind.allCases, id: \.self) { k in
        Button {
          model.pipelineBulk("Set \(n) to \(k.displayName)?", verb: "Set kind", ids: targets,
                             changes: [.init(field: "Kind", value: k.displayName)]) { b, dry in try b.setKind(targets, k, dryRun: dry) }
        } label: {
          if targets.count == 1 && video.kind == k { Label(k.displayName, systemImage: "checkmark") } else { Text(k.displayName) }
        }
      }
    }
    Button("Caption…", systemImage: "text.alignleft") { model.captionDialogIds = targets }
    Button("Crop…", systemImage: "crop") { model.cropDialogIds = targets }
    Button(targets.count == 1 ? "Copy agent prompt" : "Copy agent prompt for \(n)", systemImage: "doc.on.clipboard") {
      model.copyAgentPrompt(targets)
    }
    EditApplyDefaultsMenu(model: model, ids: targets)
    Divider()
    Button(targets.count == 1 ? "Exclude" : "Exclude \(n)", systemImage: "minus.circle") {
      model.pipelineBulk("Exclude \(n)?", verb: "Exclude", ids: targets,
                         changes: [.init(field: "Excluded", value: "Yes · they leave Edit and never post")], done: "Excluded") { b, dry in
        try b.setExcluded(targets, true, dryRun: dry)
      }
    }
  }
}
