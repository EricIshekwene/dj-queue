import DJQCore
import SwiftUI

/// Score (DESIGN-v2 §6.1) — job: give every new clip a score from 0 to 100, fast.
///
/// Shared list header (round 4 S3): "Score 12" · search (⌘F) · view toggle (Single · Grid) · status chips = one
/// per session (`All 12 · Nov 1 set 8 · …`) · Filters (Kind) · sort. No primary (↩ is the primary).
/// - **Single** (default): progress strip, the large autoplaying player with ‹ ›, a floating control pill (score
///   field · Save & next ↩ · Skip), the 280 pt side panel (title, session, length, Kind, notes, Exclude) and the
///   key-hint line. Keys: digits, ↩ save & next, ⇥ skip, ←/→ previous/next, ⌘⌫ exclude.
/// - **Grid**: tiles with an inline score field under each (⇥ moves on); typing selects the tile; the bulk bar
///   offers Set score… · Kind ▾ · Exclude · More (±1/±10 on typed scores) · **Save scores**.
/// Hidden: platforms, dates, captions, versions, editor controls.
struct ScoreView: View {
  @Bindable var model: AppModel
  @State private var index = 0
  private var ui: PipelineUIState { .shared }
  private var prefs: ListPrefs { .shared }

  var body: some View {
    let all = model.scoreList
    let pending = all.filter { !ui.scoreHidden.contains($0.id) }
    let scope = model.listScope(.score, pending)
    let session = prefs[.score].status.flatMap { id in scope.contains { $0.sessionId == id } ? id : nil }
    let list = model.listSorted(.score, scope.filter { session == nil || $0.sessionId == session })
    let mode: DSViewMode = model.viewMode(.score) == .grid ? .grid : .single
    let sel = model.selectedIds(.score)
    ScreenScaffold(model: model, screen: .score) {
      ListHeader(page: .score, title: "Score", count: pending.isEmpty ? nil : list.count, total: pending.count,
                 filters: pending.isEmpty ? [] : model.listFilterSections(.score, pending), showsSearch: !pending.isEmpty) {
        PipelineViewModeSwitcher(mode: Binding(get: { mode }, set: { model.setViewMode($0, for: .score) }), modes: [.single, .grid],
                                 tips: [.single: "Score one clip at a time by keyboard", .grid: "Score many clips, typing under each"])
      } chips: {
        if !pending.isEmpty { sessionChips(scope) }
      } sort: {
        if !pending.isEmpty { ListSortMenu(page: .score) }
      }
    } content: {
      if !model.loaded {
        Color.clear
      } else if pending.isEmpty {
        DSEmptyState(icon: "checkmark.circle", title: "Everything is scored", message: "New clips land here after intake.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else if list.isEmpty {
        DSEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No clips match",
                     message: "Nothing to score fits this search or these filters.", actionTitle: "Clear filters") {
          model.clearListFilters(.score)
          prefs.setStatus(.score, nil)
        }
      } else if mode == .single {
        ScoreSingleView(model: model, videos: list, index: $index, progress: progress(all),
                        onSave: save, onExclude: exclude)
      } else {
        ScoreGridView(model: model, videos: list)
      }
    }
    .onChange(of: all.map(\.id)) { _, ids in
      // Saved clips leave the list once the refresh lands; forget them so an Undo brings them back.
      let live = Set(ids)
      ui.scoreHidden = ui.scoreHidden.filter { live.contains($0) }
      ui.typedScores = ui.typedScores.filter { live.contains($0.key) }
    }
    .dsBulkBar(isPresented: mode == .grid && !sel.isEmpty) {
      ScoreBulkBar(model: model, ids: sel)
    }
  }

  /// One chip per session with clips to score (newest set first), counted inside the search + filters scope.
  private func sessionChips(_ scope: [Video]) -> some View {
    let counts = Dictionary(grouping: scope, by: \.sessionId).mapValues(\.count)
    let sessions = model.sessions.filter { counts[$0.id] != nil }.sorted { ($0.date ?? "", $0.name) > ($1.date ?? "", $1.name) }
    return DSStatusChips(options: sessions.map { s in
      DSStatusChipOption(id: s.id, title: Captions.setName(s.name), count: counts[s.id], tooltip: "Score only this set")
    }, selection: prefs.statusBinding(.score), allCount: scope.count, allTooltip: "Score every set")
  }

  /// "17 of 29 scored": clips in the sets that still have something to score (short, not excluded or missing).
  private func progress(_ toScore: [Video]) -> (done: Int, total: Int) {
    let sessions = Set(toScore.map(\.sessionId))
    let pool = model.videos.filter { $0.type == .short && !$0.excluded && !$0.missing && sessions.contains($0.sessionId) }
    let done = pool.filter { $0.score != nil || ui.scoreHidden.contains($0.id) }.count
    return (done, max(pool.count, done))
  }

  private func save(_ v: Video, _ n: Int) {
    dsWithAnimation(DS.motion.fade) { _ = ui.scoreHidden.insert(v.id) }
    let id = v.id
    model.pipelineBulk("Save score?", verb: "Save", ids: [id], done: "Scored \(n)") { b, dry in try b.setScore([id], n, dryRun: dry) }
  }

  private func exclude(_ v: Video) {
    dsWithAnimation(DS.motion.fade) { _ = ui.scoreHidden.insert(v.id) }
    let id = v.id
    model.pipelineBulk("Exclude clip?", verb: "Exclude", ids: [id], done: "Excluded") { b, dry in try b.setExcluded([id], true, dryRun: dry) }
  }
}

/// Grid bulk bar: Set score… · Kind ▾ · Exclude · More (±1 / ±10 on typed scores) · Save scores (only when typed).
private struct ScoreBulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  @State private var setScoreOpen = false
  @State private var scoreText = ""
  private var ui: PipelineUIState { .shared }

  var body: some View {
    let typed = ui.typedScores.compactMapValues { PipelineUIState.score($0) }
    let typedSelected = ids.filter { typed[$0] != nil }
    ScreenBulkBar(model: model, screen: .score) {
      Button("Set score…", systemImage: "number") { setScoreOpen = true }
        .dsTooltip("Give every selected clip the same score")
        .dsPopover(isPresented: $setScoreOpen, width: 240) { setScorePopover }
      PipelineBulkMenu("Kind", tooltip: "Set DJ vid or Talking for the selected clips") {
        ForEach(Kind.allCases, id: \.self) { k in
          Button(k.displayName) {
            let ids = ids
            model.pipelineBulk("Set \(AppModel.pipelineClips(ids.count)) to \(k.displayName)?", verb: "Set kind", ids: ids,
                               changes: [.init(field: "Kind", value: k.displayName)]) { b, dry in try b.setKind(ids, k, dryRun: dry) }
          }
        }
      }
      Button("Exclude", systemImage: "minus.circle") {
        let ids = ids
        model.pipelineBulk("Exclude \(AppModel.pipelineClips(ids.count))?", verb: "Exclude", ids: ids,
                           changes: [.init(field: "Excluded", value: "Yes · they leave Score and never post")]) { b, dry in
          try b.setExcluded(ids, true, dryRun: dry)
        }
      }
      .dsTooltip("Never post these (Library → Excluded)")
    } more: {
      // Nudges the typed (unsaved) scores of the selected tiles; disabled items say why in their title.
      ForEach([1, -1, 10, -10], id: \.self) { d in
        Button("\(d > 0 ? "+" : "−")\(abs(d)) on typed scores\(typedSelected.isEmpty ? " — type scores under the tiles first" : "")") {
          adjust(d, typedSelected)
        }
        .disabled(typedSelected.isEmpty)
      }
    } primary: {
      if !typed.isEmpty {
        DSButton(typed.count == 1 ? "Save score" : "Save scores", variant: .primary, size: .sm,
                 tooltip: "Save \(typed.count == 1 ? "the score" : "all \(typed.count) scores") typed under the tiles") {
          let t = typed
          ui.typedScores = [:]
          model.clearSelection(.score)
          model.pipelineSaveScores(t)
        }
      }
    }
  }

  private var setScorePopover: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      DSTextField("Score for \(AppModel.pipelineClips(ids.count))", placeholder: "0–100", text: $scoreText,
                  hint: "Replaces any score typed under these tiles", size: .md, onSubmit: applySetScore)
      HStack {
        Spacer()
        DSButton("Set score", variant: .primary, size: .sm,
                 disabledReason: PipelineUIState.score(scoreText) == nil ? "Type a score from 0 to 100" : nil, action: applySetScore)
      }
    }
    .padding(DS.space.xs)
  }

  private func applySetScore() {
    guard let n = PipelineUIState.score(scoreText) else { return }
    setScoreOpen = false
    let ids = ids
    for id in ids { ui.typedScores[id] = nil }
    model.pipelineBulk("Score \(AppModel.pipelineClips(ids.count)) \(n)?", verb: "Set score", ids: ids,
                       changes: [.init(field: "Score", value: "\(n)")], done: "Scored \(AppModel.pipelineClips(ids.count))") { b, dry in
      try b.setScore(ids, n, dryRun: dry)
    }
  }

  private func adjust(_ d: Int, _ ids: [String]) {
    for id in ids {
      if let n = PipelineUIState.score(ui.typedScores[id]) { ui.typedScores[id] = String(min(100, max(0, n + d))) }
    }
  }
}
