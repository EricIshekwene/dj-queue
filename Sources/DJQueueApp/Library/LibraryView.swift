import DJQCore
import SwiftUI

/// Library (DESIGN-v2 §6.6, refs R2.LIBRARY Frame.io tiles + R2.VIEWMODES Arcade filters). Job: find any clip in
/// any state.
///
/// Toolbar "Library · 63 clips" · capsule search · view toggle (Grid default, all four modes, remembered).
/// Sub-toolbar: filter pills with counts (All · Posted · Excluded · Missing · Long-form), Session ▾, Kind ▾,
/// Score ▾, sort menu. Short clips go through the shared ClipCollection with a state chip; long-form clips get their
/// own 16:9 section (tiles, or rows in List view) with **Mark posted**. Click: short → editor; long-form, missing or
/// removed-from-videos.json → quick look. Bulk bar: Score… · Kind ▾ · Exclude/Include · Mark long-form posted ·
/// More (Copy agent prompt, Re-render, Apply defaults).
struct LibraryView: View {
  @Bindable var model: AppModel
  @Bindable private var ui = BrowseUI.shared
  @FocusState private var keyFocus: Bool

  var body: some View {
    let all = model.libraryAll
    let shown = visible(all)
    let shorts = shown.filter { $0.type == .short }
    let longs = shown.filter { $0.type == .long }
    let mode = model.viewMode(.library)
    let sel = model.selectedIds(.library)
    ZStack {
      ScreenScaffold(model: model, screen: .library, subtitle: subtitle(all: all.count, shown: shown.count),
                     readingColumn: mode == .wide || mode == .list) {
        if !all.isEmpty {
          DSTextField(placeholder: "Search clips", text: $ui.search, isSearch: true).frame(width: 220)
          DSViewModeSwitcher(mode: model.viewModeBinding(.library))
        }
      } subToolbar: {
        if !all.isEmpty { filterBar(all) }
      } content: {
        content(all: all, shorts: shorts, longs: longs, mode: mode)
      }
      .dsBulkBar(isPresented: !sel.isEmpty) { bulkBar(sel) }
      overlays
    }
    .background {
      // Space = quick look, digits = score the selected short clips (round-1 Library keys), when no field has focus.
      Color.clear
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onKeyPress(.space) {
          guard let v = model.selectedIds(.library).first.flatMap(model.video) else { return .ignored }
          quickLook(v)
          return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
          let ids = Set(model.selectedIds(.library).filter { model.video($0)?.type == .short })
          guard !ids.isEmpty else { return .ignored }
          model.typeDigit(press.characters, ids: ids)
          return .handled
        }
    }
    .onAppear { if !model.frozen { keyFocus = true } }
  }

  // MARK: Filtering

  /// Session / kind / score / search scope (the pills' counts are computed inside this scope).
  private func scoped(_ all: [Video]) -> [Video] {
    let q = ui.search.trimmingCharacters(in: .whitespaces)
    return all.filter { v in
      (model.librarySession == nil || v.sessionId == model.librarySession)
        && (ui.kind == .any || (ui.kind == .talking) == (v.kind == .talking))
        && (ui.score == .any || (v.type == .short && ui.score.matches(v.score)))
        && (q.isEmpty || model.displayName(v).localizedCaseInsensitiveContains(q) || v.tag.localizedCaseInsensitiveContains(q)
            || v.name.localizedCaseInsensitiveContains(q))
    }
  }

  private func matches(_ v: Video, _ f: LibraryFilter) -> Bool {
    switch f {
    case .all: true
    case .posted: v.state == .posted || v.state == .partial || (v.type == .long && v.longformURL != nil)
    case .excluded: v.excluded
    case .missing: model.libraryIsMissing(v) || model.libraryIsRemoved(v)
    case .longform: v.type == .long
    }
  }

  private func visible(_ all: [Video]) -> [Video] {
    sorted(scoped(all).filter { matches($0, ui.filter) })
  }

  private func sorted(_ vs: [Video]) -> [Video] {
    switch ui.sort {
    case .session:
      return vs.sorted { a, b in
        let sa = model.sessionById[a.sessionId]?.date ?? "", sb = model.sessionById[b.sessionId]?.date ?? ""
        return (sb, a.part ?? 0, a.start ?? 0, a.id) < (sa, b.part ?? 0, b.start ?? 0, b.id)
      }
    case .newest: return vs.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    case .scoreHigh: return vs.sorted { ($0.score ?? -1, $1.id) > ($1.score ?? -1, $0.id) }
    case .scoreLow: return vs.sorted { ($0.score ?? 101, $0.id) < ($1.score ?? 101, $1.id) }
    case .title:
      return vs.sorted { model.displayName($0).localizedCaseInsensitiveCompare(model.displayName($1)) == .orderedAscending }
    }
  }

  private func subtitle(all: Int, shown: Int) -> String? {
    guard model.loaded, all > 0 else { return nil }
    let noun = all == 1 ? "clip" : "clips"
    return shown == all ? "\(all) \(noun)" : "\(shown) of \(all) \(noun)"
  }

  // MARK: Sub-toolbar

  @ViewBuilder private func filterBar(_ all: [Video]) -> some View {
    let scope = scoped(all)
    ForEach(LibraryFilter.allCases) { f in
      let n = scope.filter { matches($0, f) }.count
      DSChip(f.title, isSelected: ui.filter == f, tone: f == .missing && n > 0 && ui.filter != f ? .danger : nil, count: n,
             showsCheck: false) { ui.filter = f }
        .dsTooltip(tooltip(f))
    }
    DSSeparator(vertical: true).frame(height: 18).padding(.horizontal, DS.space.xxs)
    BrowseFilterMenu(placeholder: "Session", selection: $model.librarySession, anyValue: nil,
                     options: [(nil, "All sessions")] + model.sessions.sorted { ($0.date ?? "") > ($1.date ?? "") }
                       .map { (Optional($0.id), Captions.setName($0.name)) },
                     tooltip: "Show one session")
    BrowseFilterMenu(placeholder: "Kind", selection: $ui.kind, anyValue: .any,
                     options: LibraryKindFilter.allCases.map { ($0, $0.title) }, tooltip: "DJ vid or Talking")
    BrowseFilterMenu(placeholder: "Score", selection: $ui.score, anyValue: .any,
                     options: LibraryScoreFilter.allCases.map { ($0, $0.title) }, tooltip: "Filter short clips by score")
    if ui.libraryFiltered || model.librarySession != nil {
      DSButton("Clear", variant: .ghost, size: .sm, tooltip: "Show every clip") { clearFilters() }
    }
    Spacer(minLength: DS.space.xs)
    BrowseFilterMenu(placeholder: LibrarySort.session.title, selection: $ui.sort, anyValue: .session,
                     options: LibrarySort.allCases.map { ($0, $0.title) }, tooltip: "Sort clips")
  }

  private func tooltip(_ f: LibraryFilter) -> String {
    switch f {
    case .all: "Every clip in every state"
    case .posted: "Posted on at least one platform (long-form: on YouTube)"
    case .excluded: "Clips you excluded from posting"
    case .missing: "File missing, or removed from videos.json"
    case .longform: "Long-form parts for YouTube"
    }
  }

  private func clearFilters() {
    ui.clearLibraryFilters()
    model.librarySession = nil
  }

  // MARK: Content

  @ViewBuilder private func content(all: [Video], shorts: [Video], longs: [Video], mode: DSViewMode) -> some View {
    if !model.loaded {
      Color.clear
    } else if all.isEmpty {
      DSEmptyState(icon: "film.stack", title: "No clips yet",
                   message: "Add a session folder with a videos.json. New clips show here after the next check.",
                   actionTitle: "Check for new clips", actionIcon: "arrow.clockwise") { model.runTick() }
    } else if shorts.isEmpty && longs.isEmpty {
      DSEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No clips match",
                   message: "Nothing fits these filters\(ui.search.isEmpty ? "" : " and “\(ui.search)”").",
                   actionTitle: "Clear filters") { clearFilters() }
    } else if shorts.isEmpty {
      // Only long-form clips: their own section in every view mode.
      ScrollView {
        LongformSection(model: model, videos: longs, mode: mode == .list ? .list : mode == .wide ? .wide : .grid, showsHeader: false,
                        onOpen: quickLook)
          .frame(maxWidth: mode == .grid || mode == .single ? .infinity : DS.size.readingColumn)
          .frame(maxWidth: .infinity)
          .modifier(BrowseGutter())
          .padding(.bottom, ScreenMetrics.bulkBarInset)
      }
    } else {
      let shortIds = shorts.filter { !model.libraryIsMissing($0) }.map(\.id)
      ClipCollection(model: model, screen: .library, videos: shorts, mode: mode, clip: { v in libraryClip(v, mode: mode) },
                     onOpen: { v in open(v, among: shortIds) }) { v in
        actions(v, mode: mode)
      } contextMenu: { v in
        contextMenu(v)
      } header: {
        if mode != .single && !longs.isEmpty {
          LongformSection(model: model, videos: longs, mode: mode, showsHeader: true, onOpen: quickLook)
          LibrarySectionLabel(title: "Short clips", count: shorts.count)
        }
      }
    }
  }

  /// The card model: shared mapping + a state chip; Library cards don't list issues (the chip says Needs edit).
  private func libraryClip(_ v: Video, mode: DSViewMode) -> DSClip {
    var c = model.dsClip(v, for: .library)
    c.issues = []
    c.blocks = []
    c.isMissing = model.libraryIsMissing(v)
    c.status = c.isMissing ? nil : model.libraryStateChip(v)
    c.dateText = model.nextDateLabel(v)
    if mode == .list && !c.isMissing {
      // List rows have one badge slot (the kind's): show the state there, which is what Library is for.
      c.kind = [c.kind, c.status?.text].compactMap { $0 }.joined(separator: " · ")
    }
    return c
  }

  @ViewBuilder private func actions(_ v: Video, mode: DSViewMode) -> some View {
    if mode == .grid {
      Button { quickLook(v) } label: { Label("Quick look", systemImage: "eye") }.dsTooltip("Quick look", shortcut: "Space")
    } else if mode == .single {
      HStack(spacing: DS.space.xs) {
        DSButton("Quick look", icon: "eye", variant: .outline, size: .sm) { quickLook(v) }
        DSButton(v.excluded ? "Include" : "Exclude", variant: .ghost, size: .sm) { model.setExcluded([v.id], !v.excluded) }
      }
    } else {
      DSIconButton("eye", tooltip: "Quick look", size: .sm, shortcut: "Space") { quickLook(v) }
    }
  }

  @ViewBuilder private func contextMenu(_ v: Video) -> some View {
    Button("Quick look", systemImage: "eye") { quickLook(v) }
    if model.libraryIsMissing(v) {
      Button("Look for the file", systemImage: "magnifyingglass") { relink() }
    }
    if model.libraryIsRemoved(v) {
      Button("Keep posting it", systemImage: "checkmark.circle") { model.keepRemoved(v.id) }
    }
    Divider()
    VideoContextMenu(model: model, video: v, ids: model.selectedIds(.library))
  }

  private func open(_ v: Video, among ids: [String]) {
    if model.libraryIsMissing(v) || model.libraryIsRemoved(v) {
      quickLook(v)
    } else {
      model.openEditor(v.id, in: ids.contains(v.id) ? ids : [v.id])
    }
  }

  private func quickLook(_ v: Video) {
    dsWithAnimation(DS.motion.fade) { ui.quickLook = v }
  }

  private func relink() {
    model.runTick()
    model.show(DSToastModel(message: "Looking for missing files", detail: "Intake finds renamed or moved files by fingerprint", duration: 4))
  }

  // MARK: Bulk bar (DESIGN-v2 §5: Score… · Kind ▾ · Exclude/Include · Mark long-form posted · More)

  private func bulkBar(_ sel: [String]) -> some View {
    let vids = sel.compactMap(model.video)
    let shorts = vids.filter { $0.type == .short }.map(\.id)
    let unpostedLongs = vids.filter { $0.type == .long && $0.longformURL == nil }
    let allExcluded = !vids.isEmpty && vids.allSatisfy(\.excluded)
    return ScreenBulkBar(model: model, screen: .library) {
      if !shorts.isEmpty {
        bulkButton("Score…", icon: "number", why: nil, tooltip: "Give the selected short clips one score") {
          ui.scoreTargets = shorts
        }
      }
      Menu {
        ForEach(Kind.allCases, id: \.self) { k in
          Button(k.displayName) { setKind(sel, k) }
        }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "tag").font(.system(size: 13))
          Text("Kind")
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.color.textTertiary)
        }
        .fixedSize()
      }
      .menuStyle(.button)
      .buttonStyle(DSBulkActionStyle())
      .menuIndicator(.hidden)
      .fixedSize()
      .dsTooltip("Set the kind")
      Button { setExcluded(sel, !allExcluded) } label: {
        Label(allExcluded ? "Include" : "Exclude", systemImage: allExcluded ? "plus.circle" : "minus.circle").lineLimit(1).fixedSize()
      }
      .dsTooltip(allExcluded ? "Put these clips back into the pipeline" : "Keep these clips out of the plan")
      if shorts.isEmpty {
        bulkButton("Mark long-form posted", icon: "checkmark.circle",
                   why: unpostedLongs.isEmpty ? "These long-form clips are already posted" : nil,
                   tooltip: "Paste each YouTube link; the files move to Posted/Longform") {
          ui.longformTargets = unpostedLongs
        }
      }
    } more: {
      if !shorts.isEmpty && !unpostedLongs.isEmpty {
        Button("Mark \(unpostedLongs.count) long-form posted…") { ui.longformTargets = unpostedLongs }
        Divider()
      }
      Button("Copy agent prompt for \(shorts.count) clip\(shorts.count == 1 ? "" : "s")") { model.copyAgentPrompt(shorts) }
        .disabled(shorts.isEmpty)
      Button("Re-render \(sel.count) clip\(sel.count == 1 ? "" : "s")") { reRender(sel) }
      Button("Apply defaults to \(shorts.count) clip\(shorts.count == 1 ? "" : "s")…") { applyDefaults(shorts) }
        .disabled(shorts.isEmpty)
    }
  }

  /// Bulk bar action that stays visible but disabled (with the reason as a tooltip) when it doesn't apply.
  private func bulkButton(_ title: String, icon: String, why: String?, tooltip: String? = nil,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) { Label(title, systemImage: icon).lineLimit(1).fixedSize() }
      .disabled(why != nil)
      .browseHelp(why ?? tooltip)
  }

  private func setKind(_ ids: [String], _ k: Kind) {
    let bulk = model.bulk
    model.requestBulk(BulkRequest(title: "Set \(ids.count) clip\(ids.count == 1 ? "" : "s") to \(k.displayName)?", verb: "Set kind",
                                  ids: ids, changes: [.init(field: "Kind", value: k.displayName)]) { dry in
      try bulk.setKind(ids, k, dryRun: dry)
    })
  }

  private func setExcluded(_ ids: [String], _ ex: Bool) {
    let bulk = model.bulk
    let n = ids.count
    model.requestBulk(BulkRequest(title: "\(ex ? "Exclude" : "Include") \(n) clip\(n == 1 ? "" : "s")?", verb: ex ? "Exclude" : "Include",
                                  ids: ids, changes: [.init(field: "Posting", value: ex ? "Excluded" : "Included")]) { dry in
      try bulk.setExcluded(ids, ex, dryRun: dry)
    })
  }

  private func reRender(_ ids: [String]) {
    let bulk = model.bulk
    model.requestBulk(BulkRequest(title: "Re-render \(ids.count) clip\(ids.count == 1 ? "" : "s")?", verb: "Re-render", ids: ids,
                                  changes: [.init(field: "Renders", value: "Made again on the next engine tick")]) { dry in
      try bulk.reRender(ids, dryRun: dry)
    })
  }

  private func applyDefaults(_ ids: [String]) {
    let bulk = model.bulk
    model.requestBulk(BulkRequest(title: "Apply defaults to \(ids.count) clip\(ids.count == 1 ? "" : "s")?", verb: "Apply defaults",
                                  ids: ids, changes: [.init(field: "Frame, trim, text, cover, caption, platforms", value: "Default")]) { dry in
      try bulk.applyDefaults(ids, dryRun: dry)
    })
  }

  // MARK: Overlays (in-screen dialogs)

  @ViewBuilder private var overlays: some View {
    if let v = ui.quickLook {
      BrowseModal(onDismiss: { ui.quickLook = nil }) {
        LibraryQuickLook(model: model, video: v)
      }
    }
    if !ui.longformTargets.isEmpty {
      BrowseModal(onDismiss: { ui.longformTargets = [] }) {
        LongformPostedDialog(model: model, videos: ui.longformTargets)
      }
    }
    if !ui.scoreTargets.isEmpty {
      BrowseModal(onDismiss: { ui.scoreTargets = [] }) {
        LibraryScoreDialog(model: model, ids: ui.scoreTargets)
      }
    }
  }
}

/// "Long-form · 1" / "Short clips · 62" label above a Library section.
struct LibrarySectionLabel: View {
  let title: String
  let count: Int
  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
      Text("\(count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
      Spacer(minLength: 0)
    }
    .padding(.top, DS.space.xs)
    .padding(.bottom, DS.space.xxs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Library state

/// The state chip on Library tiles (DESIGN-v2 §6.6).
enum LibraryClipState {
  case unscored, needsEdit, ready, planned, posted, excluded, missing, removed
}

extension AppModel {
  /// File missing on disk (danger chip "File missing · Relink", no autoplay).
  func libraryIsMissing(_ v: Video) -> Bool { v.missing || v.state == .missingFile }
  /// Gone from videos.json and not kept by Eric (L.S5: Keep / Exclude).
  func libraryIsRemoved(_ v: Video) -> Bool { !v.inManifest && !keptRemoved.contains(v.id) }

  func libraryState(_ v: Video) -> LibraryClipState {
    if libraryIsMissing(v) { return .missing }
    if v.excluded { return .excluded }
    if libraryIsRemoved(v) { return .removed }
    if v.type == .long { return v.longformURL == nil ? .ready : .posted }
    if v.score == nil { return .unscored }
    switch v.state {
    case .needsEdit: return .needsEdit
    case .ready: return .ready
    case .planned, .posting: return .planned
    case .posted, .partial: return .posted
    case .excluded: return .excluded
    case .missingFile: return .missing
    }
  }

  func libraryStateChip(_ v: Video) -> DSClipTag {
    switch libraryState(v) {
    case .unscored: DSClipTag(text: "Unscored", style: .outline)
    case .needsEdit: DSClipTag(text: "Needs edit", style: .soft(.warning))
    case .ready: DSClipTag(text: "Ready", style: .soft(.neutral))
    case .planned: DSClipTag(text: "Planned", style: .soft(.info))
    case .posted: DSClipTag(text: "Posted", style: .soft(.success))
    case .excluded: DSClipTag(text: "Excluded", style: .outline)
    case .missing: DSClipTag(text: "Missing", style: .soft(.danger))
    case .removed: DSClipTag(text: "Not in videos.json", style: .soft(.warning))
    }
  }
}

/// FOUNDATION compile shim (selection lives in `AppModel.selection`); kept for any round-1 caller.
extension AppModel {
  var librarySelection: Set<String> {
    get { selection[.library] ?? [] }
    set { selection[.library] = newValue }
  }
}
