import DJQCore
import SwiftUI

/// Queue (DESIGN-v2 §6.3, ref R2.QUEUE Hootsuite cards) — job: keep complete clips in posting order.
///
/// Shared list header (round 4 S3): "Queue 41 · next Thu 5 Nov" · search (⌘F) · view toggle · runway chip ·
/// status chips `All · Has a day · No day yet` · Filters (Session · Kind · Score) · sort ("Worst → best ▾",
/// tie rule inside, writes `Settings.sort`). No filled primary: the primary act is direct manipulation.
/// Order = the upcoming plan (date order) then the backlog in sort order; search and filters narrow it without
/// renumbering. Cards: position · ⋮⋮ on hover · thumb · title + meta · score · next-date chip · platform icons only
/// when planned/posted · pin glyph. Hover actions: stage control (‹ Back to Edit · Schedule ›), Post today, Pin to
/// date…, ⋯. Drag a card onto a planned clip to take its day (pinned); the backlog itself follows the sort. Bulk:
/// Pin to days… · Post today · More · **Add to week**. Hidden: Score/Edit clips, excluded clips, versions.
struct QueueView: View {
  @Bindable var model: AppModel
  @State private var pinTarget: [String]?
  private var prefs: ListPrefs { .shared }

  var body: some View {
    let all = model.queueClips
    let scope = model.listScope(.queue, all)
    let status = prefs[.queue].status.flatMap { ["scheduled", "unscheduled"].contains($0) ? $0 : nil }
    let list = scope.filter { status == nil || isScheduled($0) == (status == "scheduled") }
    let ids = list.map(\.id)
    let mode = model.viewMode(.queue)
    let sel = model.selectedIds(.queue)
    let positions = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0 + 1) })
    let column = mode == .wide || mode == .list
    ScreenScaffold(model: model, screen: .queue, readingColumn: column) {
      ListHeader(page: .queue, title: "Queue", count: all.isEmpty ? nil : list.count, total: all.count, detail: nextText,
                 filters: all.isEmpty ? [] : model.listFilterSections(.queue, all), readingColumn: column, showsSearch: !all.isEmpty) {
        PipelineViewModeSwitcher(mode: model.viewModeBinding(.queue))
      } chips: {
        if !all.isEmpty { statusChips(scope) }
      } sort: {
        if !all.isEmpty { QueueSortMenu(model: model) }
      } trailing: {
        RunwayChip(model: model)
      }
    } content: {
      if !model.loaded {
        Color.clear
      } else if all.isEmpty {
        DSEmptyState(icon: "list.bullet", title: "The Queue is empty", message: "Clips arrive here once they're scored and finished in Edit.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else if list.isEmpty {
        ListNoMatches(model: model, page: .queue, title: "No clips match", message: "Nothing in the Queue fits this search or these filters.") {
          model.clearListFilters(.queue)
          prefs.setStatus(.queue, nil)
        }
      } else if mode == .wide {
        QueueCardList(model: model, videos: list, positions: positions, onPin: { pinTarget = $0 })
      } else {
        ClipCollection(model: model, screen: .queue, videos: list, mode: mode, clip: { v in
          var c = model.dsClip(v, for: .queue)
          c.position = positions[v.id]
          // Grid tiles have no date chip of their own: the next day rides as a tag (only when scheduled).
          if mode == .grid, let d = c.dateText, d != "Not scheduled" {
            c.tags.append(DSClipTag(text: d, style: .outline, icon: c.isPinned ? "pin.fill" : "calendar",
                                    tooltip: c.isPinned ? "Pinned to this day — the plan works around it" : "Next planned post day"))
          }
          return c
        }, onOpen: { v in model.openEditor(v.id, in: ids) }) { v in
          QueueClipActions(model: model, video: v, mode: mode, ids: ids, onPin: { pinTarget = [v.id] })
        } contextMenu: { v in
          QueueClipMenu(model: model, video: v, ids: ids, onPin: { pinTarget = $0 })
        }
      }
    }
    .dsBulkBar(isPresented: !sel.isEmpty && pinTarget == nil) {
      QueueBulkBar(model: model, ids: sel, onPin: { pinTarget = sel })
    }
    .overlay {
      if let t = pinTarget {
        ZStack {
          DS.color.scrim.ignoresSafeArea().onTapGesture { pinTarget = nil }
          QueuePinDialog(model: model, ids: t) { pinTarget = nil }
        }
        .transition(.opacity)
      }
    }
    .dsAnimation(DS.motion.popover, value: pinTarget)
    .onChange(of: pinTarget == nil, initial: true) { _, closed in ListPrefs.shared.screenDialogOpen = !closed }
    .onDisappear { ListPrefs.shared.screenDialogOpen = false }
  }

  /// Has a day in the plan (an approved or a draft week): the card's date chip shows it.
  private func isScheduled(_ v: Video) -> Bool { model.nextSlotByVideo[v.id] != nil }

  private func statusChips(_ scope: [Video]) -> some View {
    let n = scope.filter(isScheduled).count
    return DSStatusChips(options: [
      DSStatusChipOption(id: "scheduled", title: "Has a day", count: n,
                         tooltip: "Clips with a day in the plan (a draft or an approved week)"),
      DSStatusChipOption(id: "unscheduled", title: "No day yet", count: scope.count - n, tooltip: "Clips still waiting for a day"),
    ], selection: prefs.statusBinding(.queue), allCount: scope.count, allTooltip: "Every clip in the Queue")
  }

  /// "next Thu 5 Nov" / "next today".
  private var nextText: String? {
    let next = model.upcomingSlots.first.flatMap { model.video($0.videoId) }.map { model.dateText($0) }
      .map { $0 == "Today" ? "today" : $0 }
    return next.map { "next \($0)" }
  }
}

/// The Queue's sort (Settings › Queue sort: the backlog order the planner uses) with the tie rule explained inside.
struct QueueSortMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    DSSortMenu(options: SortDirection.allCases.map { DSSortOption(id: $0.rawValue, title: $0.displayName) },
               selection: Binding(get: { model.settings.sort.rawValue }, set: { new in
                 if let d = SortDirection(rawValue: new), d != model.settings.sort { model.update { $0.sort = d } }
               }),
               tooltip: "Order the clips waiting for a day by score",
               notes: ["Ties: the older set first, then part, then start time",
                       "Clips with a day keep it; this orders the ones waiting"])
  }
}

/// Queue bulk bar (DESIGN-v2 §5, fitted to the 720 pt bar): Pin to days… · Post today · More (Back to Edit,
/// Back / Forward a stage, Skip platform ▸, Exclude, post on a platform again, Kind, re-render) · **Add to week**.
private struct QueueBulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  let onPin: () -> Void

  var body: some View {
    let n = AppModel.pipelineClips(ids.count)
    ScreenBulkBar(model: model, screen: .queue) {
      Button("Pin to days…", systemImage: "pin") { onPin() }
        .dsTooltip("Pin to consecutive days, in order shown")
      Button("Post today", systemImage: "bolt") {
        let ids = ids
        model.pipelineBulk("Post \(n) today?", verb: "Post today", ids: ids,
                           changes: [.init(field: "Day", value: "Today · the rest of the plan moves a day later")]) { b, dry in
          try b.postToday(ids, dryRun: dry)
        }
      }
      .dsTooltip("Post these today; extras are skipped")
    } more: {
      // Native items show no tooltip: titles carry the consequence (or why not); each asks first and can be undone.
      let removeWhy = model.removeFromQueueBlocker(ids)
      Button("Back to Edit" + AppModel.menuReason(removeWhy), systemImage: "arrow.uturn.backward") {
        model.removeFromQueue(ids)
      }
      .disabled(removeWhy != nil)
      Button("Back a stage (Scheduled → Queue, Queue → Edit)", systemImage: "chevron.left") { model.stageBack(ids) }
      Button("Forward a stage (Queue → Scheduled on open days)", systemImage: "chevron.right") { model.stageForward(ids) }
      Divider()
      Button("Caption…", systemImage: "text.alignleft") { model.captionDialogIds = ids }
      Menu("Skip platform") {
        ForEach(model.settings.activePlatforms) { p in Button(p.displayName) { setPlatform(p, skipped: true) } }
      }
      Button("Exclude", systemImage: "minus.circle") {
        let ids = ids
        model.pipelineBulk("Exclude \(n)?", verb: "Exclude", ids: ids,
                           changes: [.init(field: "Excluded", value: "Yes · they leave the queue and never post")]) { b, dry in
          try b.setExcluded(ids, true, dryRun: dry)
        }
      }
      Menu("Turn a skipped platform back on") {
        ForEach(model.settings.activePlatforms) { p in Button(p.displayName) { setPlatform(p, skipped: false) } }
      }
      Menu("Kind") {
        ForEach(Kind.allCases, id: \.self) { k in
          Button(k.displayName) {
            let ids = ids
            model.pipelineBulk("Set \(n) to \(k.displayName)?", verb: "Set kind", ids: ids,
                               changes: [.init(field: "Kind", value: k.displayName)]) { b, dry in try b.setKind(ids, k, dryRun: dry) }
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
      DSButton("Add to week", variant: .primary, size: .sm, tooltip: "Pin to free days of the next open week") { addToWeek() }
    }
  }

  private func addToWeek() {
    let ids = ids
    let week = model.pipelineWeekWithRoom()
    let label = Fmt.day(model.dm.date(week), tz: model.tz, style: "d MMM")
    model.pipelineBulk("Add \(AppModel.pipelineClips(ids.count)) to the week of \(label)?", verb: "Add to week", ids: ids,
                       changes: [.init(field: "Plan", value: "First free days of the week of \(label), pinned")]) { b, dry in
      try b.addToWeek(ids, week: week, dryRun: dry)
    }
  }

  private func setPlatform(_ p: Platform, skipped: Bool) {
    let ids = ids
    let n = AppModel.pipelineClips(ids.count)
    model.pipelineBulk(skipped ? "Skip \(p.displayName) for \(n)?" : "Post \(n) on \(p.displayName) again?",
                       verb: skipped ? "Skip \(p.displayName)" : "Turn on \(p.displayName)", ids: ids,
                       changes: [.init(field: p.displayName, value: skipped ? "Skipped" : "Posts again")]) { b, dry in
      try b.setPlatform(ids, p, skipped: skipped, dryRun: dry)
    }
  }
}

/// "Pin to date…" (one clip) / "Pin to days…" (several, consecutive days in the order shown): an in-screen
/// dialog with a graphical calendar. Goes through BulkActions.pinConsecutive (confirmation for > 1, undo toast).
struct QueuePinDialog: View {
  @Bindable var model: AppModel
  let ids: [String]
  let onClose: () -> Void
  @State private var date: Date?

  var body: some View {
    let start = model.dm.date(model.todayKey)
    let pick = date ?? model.nextSlotByVideo[ids.first ?? ""].map { model.dm.date($0.date) } ?? start
    let multi = ids.count > 1
    DSDialog(multi ? "Pin \(AppModel.pipelineClips(ids.count)) to days" : "Pin to date",
             description: multi ? "The first clip goes on the day you pick, the next on the day after, in the order shown."
               : "The clip posts on this day and the planner won't move it.",
             icon: "pin", width: 380, onClose: onClose) {
      DatePicker("Date", selection: Binding(get: { pick }, set: { date = $0 }), in: start..., displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    } footer: {
      DSButton("Cancel", variant: .ghost, shortcut: "esc") { onClose() }
        .keyboardShortcut(.cancelAction)
      DSButton(multi ? "Pin \(ids.count)" : "Pin", variant: .primary,
               tooltip: multi ? "Pin them one a day from this day" : "Pin it to this day", shortcut: "↩") { pin(pick) }
        .keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func pin(_ d: Date) {
    let ids = ids
    let day = model.dm.key(d)
    let first = Fmt.day(d, tz: model.tz)
    let last = Fmt.day(model.dm.date(model.dm.addDays(day, ids.count - 1)), tz: model.tz)
    onClose()
    model.pipelineBulk("Pin \(AppModel.pipelineClips(ids.count)) to \(first) – \(last)?", verb: "Pin", ids: ids,
                       changes: [.init(field: "Days", value: ids.count == 1 ? first : "\(first) – \(last), one a day")],
                       done: ids.count == 1 ? "Pinned to \(first)" : nil) { b, dry in
      try b.pinConsecutive(ids, from: day, dryRun: dry)
    }
  }
}
