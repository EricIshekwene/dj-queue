import DJQCore
import SwiftUI

/// Edit (DESIGN-v2 §6.2, ref R2.EDIT issue cards) — job: finish scored clips, then send them to the Queue. Only Eric's
/// Send to Queue moves a clip on (the stage control, the bulk bar or the toolbar button); fixing the last issue doesn't.
///
/// Shared list header (round 4 S3): "Edit 9" · search (⌘F) · view toggle (Cards · Grid · Single · List) · primary
/// **Send to Queue with defaults** (the selection, else every clip shown; > 1 clip asks first) · status chips = what's
/// missing (`All 9 · No crop 4 · No text 6 · … · Nothing to fix 2`, from `issuesByVideo`) · Filters (Session · Kind ·
/// Score) · sort.
/// Cards show missing chips (warning), hard blocks (danger) with explicit fixes ("Trim for X", "Drop hashtags for
/// X", "Write an X caption"), up to three title suggestions (click = set Title, undoable), an "Add title" field when
/// there are none, "Ask an agent" when the title is ambiguous, a "Cover" badge, Open editor and ⋯. Hidden: dates,
/// platform post state, queue order.
struct EditView: View {
  @Bindable var model: AppModel
  private var prefs: ListPrefs { .shared }

  var body: some View {
    let all = model.editList
    let scope = model.listScope(.edit, all)
    let filters = Self.filters(scope, issues: model.issuesByVideo)
    let active = prefs[.edit].status.flatMap { id in filters.first { $0.filter.id == id }?.filter }
    let clean = scope.filter(nothingToFix)
    let cleanOnly = prefs[.edit].status == Self.nothingToFixId && !clean.isEmpty
    let list = model.listSorted(.edit, cleanOnly ? clean : active.map { f in scope.filter { f.matches(model.issuesByVideo[$0.id] ?? []) } } ?? scope)
    let ids = list.map(\.id)
    let mode = model.viewMode(.edit)
    let sel = model.selectedIds(.edit)
    let column = mode == .wide || mode == .list
    ScreenScaffold(model: model, screen: .edit, readingColumn: column) {
      ListHeader(page: .edit, title: "Edit", count: all.isEmpty ? nil : list.count, total: all.count,
                 filters: all.isEmpty ? [] : model.listFilterSections(.edit, all), readingColumn: column, showsSearch: !all.isEmpty) {
        PipelineViewModeSwitcher(mode: model.viewModeBinding(.edit))
      } chips: {
        if !all.isEmpty {
          DSStatusChips(options: (clean.isEmpty ? [] : [DSStatusChipOption(id: Self.nothingToFixId, title: "Nothing to fix", count: clean.count,
                                                                           tooltip: "Clips waiting for your Send to Queue")])
            + filters.map { f in
              DSStatusChipOption(id: f.filter.id, title: f.filter.title, count: f.count, tone: f.filter.kind.isBlock ? .danger : nil,
                                 tooltip: f.filter.help)
            },
          selection: prefs.statusBinding(.edit), allCount: scope.count, allTooltip: "Show every clip in Edit")
        }
      } sort: {
        if !all.isEmpty { ListSortMenu(page: .edit) }
      } trailing: {
        DSButton("Send to Queue with defaults", variant: sel.isEmpty ? .primary : .outline,
                 disabledReason: list.isEmpty ? "Nothing to edit" : nil,
                 tooltip: sel.isEmpty ? "Send \(AppModel.pipelineClips(ids.count)) shown to the Queue"
                   : "Send \(AppModel.pipelineClips(sel.count)) selected to the Queue") {
          makeReady(sel.isEmpty ? ids : sel)
        }
      }
    } content: {
      if !model.loaded {
        Color.clear
      } else if all.isEmpty {
        DSEmptyState(icon: "pencil", title: "Nothing to edit",
                     message: "Scored clips that still need a crop, text or caption show up here.",
                     actionTitle: "Open Queue") { model.screen = .queue }
      } else if list.isEmpty {
        ListNoMatches(model: model, page: .edit, title: "No clips match", message: "Nothing in Edit fits this search or these filters.") {
          model.clearListFilters(.edit)
          prefs.setStatus(.edit, nil)
        }
      } else {
        ClipCollection(model: model, screen: .edit, videos: list, mode: mode, clip: { v in clip(v, mode: mode) },
                       onOpen: { v in model.openEditor(v.id, in: ids) }) { v in
          EditClipActions(model: model, video: v, mode: mode, ids: ids)
        } contextMenu: { v in
          EditClipMenu(model: model, video: v, ids: ids)
        }
      }
    }
    .dsBulkBar(isPresented: !sel.isEmpty) {
      EditBulkBar(model: model, ids: sel) { makeReady(sel) }
    }
  }

  static let nothingToFixId = "nothing-to-fix"
  static let nothingToFixHelp = "Nothing missing. Press Send to Queue when it's ready to post."

  /// Complete, and still here because only Send to Queue moves a clip on.
  private func nothingToFix(_ v: Video) -> Bool { !v.missing && (model.issuesByVideo[v.id] ?? []).isEmpty }

  /// Card model: the shared mapping, plus "Nothing to fix" and a "Cover" badge; suggestion chips keep only their text outside Single
  /// (the matched tracks would wrap a 132 pt card — Single's side panel and the editor show them). List rows have
  /// no chip row, so their second line lists what's missing instead of the session.
  private func clip(_ v: Video, mode: DSViewMode) -> DSClip {
    var c = model.dsClip(v, for: .edit)
    if mode != .single { c.suggestions = c.suggestions.map { DSTitleSuggestion(text: $0.text) } }
    // Grid tiles and list rows are narrow: blocks read "Too long for X" (the numbers are on Cards / Single).
    let short = c.blocks.map { $0.components(separatedBy: " · ").first ?? $0 }
    if mode == .grid { c.blocks = short }
    if mode == .list, !(short + c.issues).isEmpty { c.subtitle = (short + c.issues).joined(separator: " · ") }
    if nothingToFix(v) { c.tags.append(DSClipTag(text: "Nothing to fix", style: .soft(.success), icon: "checkmark", tooltip: Self.nothingToFixHelp)) }
    if model.coverIds.contains(v.id) { c.tags.append(DSClipTag(text: "Cover", style: .outline, icon: "photo",
                                                                           tooltip: "Cover frame chosen in the editor")) }
    return c
  }

  private func makeReady(_ ids: [String]) {
    model.pipelineBulk("Send \(AppModel.pipelineClips(ids.count)) to the Queue?", verb: "Send to Queue", ids: ids,
                       changes: [.init(field: "Held clips", value: "Released: clips you sent back go to the Queue too"),
                                 .init(field: "Crop", value: "Default anchor, confirmed where missing"),
                                 .init(field: "Text, caption, cover", value: "Keep following New clip defaults"),
                                 .init(field: "Title", value: "Not set by this — clips without one still need text")]) { b, dry in
      try b.makeReadyWithDefaults(ids, dryRun: dry)
    }
  }

  /// Filter chips with counts, in a stable order (missing pieces, then hard blocks).
  static func filters(_ list: [Video], issues: [String: [ValidationIssue]]) -> [(filter: EditFilter, count: Int)] {
    var counts: [EditFilter: Int] = [:]
    for v in list {
      let fs = Set((issues[v.id] ?? []).map { EditFilter(kind: $0.kind, platform: $0.platform) })
      for f in fs { counts[f, default: 0] += 1 }
    }
    return counts.map { ($0.key, $0.value) }.sorted {
      ($0.filter.order, Platform.allCases.firstIndex(of: $0.filter.platform ?? .tiktok) ?? 0)
        < ($1.filter.order, Platform.allCases.firstIndex(of: $1.filter.platform ?? .tiktok) ?? 0)
    }
  }
}

/// Edit bulk bar (DESIGN-v2 §5, fitted to the 720 pt bar): Top title · Caption (template + several hashtag groups) · Crop (one offset, checked clip by clip) ·
/// More (Back to Score, agent prompt, apply defaults per section, skip platform, re-render) ·
/// **Send to Queue** (with defaults).
private struct EditBulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  let makeReady: () -> Void

  var body: some View {
    let n = AppModel.pipelineClips(ids.count)
    ScreenBulkBar(model: model, screen: .edit) {
      let noSuggestions = !ids.contains { !(model.suggestionsByVideo[$0] ?? []).isEmpty }
      let noTitlesWhy = "No title suggestions yet — More › Copy agent prompt asks your agent"
      // Soft-disabled (dimmed, still hoverable so the tooltip can say why; a click says it again).
      Button("Top title", systemImage: "text.badge.checkmark") {
        if noSuggestions { model.show(noTitlesWhy, error: true); return }
        let ids = ids
        model.pipelineBulk("Accept the top title for \(n)?", verb: "Accept titles", ids: ids,
                           changes: [.init(field: "Title", value: "Top suggestion from metadata (clips without a title)")]) { b, dry in
          try b.acceptTopTitleSuggestion(ids, dryRun: dry)
        }
      }
      .opacity(noSuggestions ? 0.45 : 1)
      .dsTooltip("Use each clip's top suggested title", disabledReason: noSuggestions ? noTitlesWhy : nil)
      Button("Caption", systemImage: "text.alignleft") { model.captionDialogIds = ids }
        .dsTooltip("Set a template and hashtag groups for the selected clips")
        .background(ScriptAnchor("Caption"))
      Button("Crop", systemImage: "crop") { model.cropDialogIds = ids }
        .dsTooltip("Move the crop for the selected clips and check each one")
        .background(ScriptAnchor("Crop"))
    } more: {
      // Native items show no tooltip: titles carry the consequence.
      Button("Back to Score (clears their scores)", systemImage: "chevron.left") { model.stageBack(ids) }
      Divider()
      Menu("Kind") {
        ForEach(Kind.allCases, id: \.self) { k in
          Button(k.displayName) {
            let ids = ids
            model.pipelineBulk("Set \(n) to \(k.displayName)?", verb: "Set kind", ids: ids,
                               changes: [.init(field: "Kind", value: k.displayName)]) { b, dry in try b.setKind(ids, k, dryRun: dry) }
          }
        }
      }
      Button("Copy agent prompt for \(n)", systemImage: "doc.on.clipboard") { model.copyAgentPrompt(ids) }
      EditApplyDefaultsMenu(model: model, ids: ids)
      Menu("Skip platform") {
        ForEach(model.settings.activePlatforms) { p in
          Button(p.displayName) {
            let ids = ids
            model.pipelineBulk("Skip \(p.displayName) for \(n)?", verb: "Skip \(p.displayName)", ids: ids,
                               changes: [.init(field: p.displayName, value: "Skipped — these clips won't post there")],
                               versionScope: .every) { b, dry in
              try b.setPlatform(ids, p, skipped: true, dryRun: dry)
            }
          }
        }
      }
      Button("Re-render (make the post videos again)", systemImage: "arrow.triangle.2.circlepath") {
        let ids = ids
        model.pipelineBulk("Re-render \(n)?", verb: "Re-render", ids: ids,
                           changes: [.init(field: "Renders", value: "Made again on the next engine tick")]) { b, dry in
          try b.reRender(ids, dryRun: dry)
        }
      }
    } primary: {
      DSButton("Send to Queue", variant: .primary, size: .sm,
               tooltip: "Send \(n) selected to the Queue", action: makeReady)
    }
  }
}

/// "Reset to New clip defaults ▸" — clears the overrides of one section (or all) so the clips follow New clip defaults.
struct EditApplyDefaultsMenu: View {
  @Bindable var model: AppModel
  let ids: [String]

  var body: some View {
    // The title says what happens: the section's own edits go and New clip defaults apply (asks for > 1, undoable).
    Menu("Reset to New clip defaults") {
      ForEach(BulkSection.allCases, id: \.self) { s in Button(Self.title(s)) { apply([s]) } }
      Divider()
      Button("Every section") { apply(Set(BulkSection.allCases)) }
    }
  }

  static func title(_ s: BulkSection) -> String {
    switch s {
    case .frame: "Frame"
    case .trim: "Trim"
    case .text: "Text"
    case .cover: "Cover"
    case .caption: "Caption"
    case .platforms: "Platforms"
    }
  }

  private func apply(_ sections: Set<BulkSection>) {
    let ids = ids
    let what = sections.count == BulkSection.allCases.count ? "every section"
      : BulkSection.allCases.filter(sections.contains).map { Self.title($0).lowercased() }.joined(separator: ", ")
    model.pipelineBulk("Apply defaults (\(what)) to \(AppModel.pipelineClips(ids.count))?", verb: "Apply defaults", ids: ids,
                       changes: BulkSection.allCases.filter(sections.contains).map { .init(field: Self.title($0), value: "Default") },
                       done: "Defaults applied", versionScope: .of(sections), keepsWords: sections.contains(.text)) { b, dry in
      try b.applyDefaults(ids, sections: sections, dryRun: dry)
    }
  }
}
