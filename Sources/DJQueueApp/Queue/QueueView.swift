import DJQCore
import SwiftUI

/// Queue (DESIGN-v2 §6.3, ref R2.QUEUE Hootsuite cards) — job: keep complete clips in posting order.
///
/// Shared list header (round 4 S3): "Queue 41 · next Thu 5 Nov" · search (⌘F) · view toggle · runway chip ·
/// status chips `All · Has a day · No day yet` · Filters (Session · Kind · Score) · sort ("Worst → best ▾",
/// tie rule inside, writes `Settings.sort`). No filled primary: the primary act is direct manipulation.
/// Order = the Calendar (date order) then the clips waiting, in sort order; search and filters narrow it without
/// renumbering. A clip here schedules itself: being in the Queue is Eric's approval. Cards: position · ⋮⋮ on hover ·
/// thumb · title + meta · score · date chip · platform icons only when scheduled/posted · pin glyph. Hover actions:
/// ‹ Back to Edit, Post today, Pin to date…, ⋯. Drag a card onto a clip with a day to take that day (pinned); the rest
/// follows the sort. Bulk: Post today · More · **Pin to days…**. Hidden: Score/Edit clips, excluded clips, versions.
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
        DSEmptyState(icon: "list.bullet", title: "The Queue is empty", message: "Clips arrive here when you send them from Edit.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else if list.isEmpty {
        DSEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No clips match",
                     message: "Nothing in the Queue fits this search or these filters.", actionTitle: "Clear filters") {
          model.clearListFilters(.queue)
          prefs.setStatus(.queue, nil)
        }
      } else if mode == .wide {
        QueueCardList(model: model, videos: list, positions: positions, onPin: { pinTarget = $0 })
      } else {
        ClipCollection(model: model, screen: .queue, videos: list, mode: mode, clip: { v in
          var c = model.dsClip(v, for: .queue)
          c.position = positions[v.id]
          // Grid tiles have no date chip of their own: the day rides as a tag.
          if mode == .grid, let d = c.dateText {
            c.tags.append(DSClipTag(text: d, style: .outline, icon: c.isPinned ? "pin.fill" : "calendar",
                                    tooltip: c.isPinned ? "Pinned to this day; the rest flows around it" : "The day it goes out"))
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

  /// Has a day on the Calendar: the card's date chip shows it.
  private func isScheduled(_ v: Video) -> Bool { model.nextSlotByVideo[v.id] != nil }

  private func statusChips(_ scope: [Video]) -> some View {
    let n = scope.filter(isScheduled).count
    return DSStatusChips(options: [
      DSStatusChipOption(id: "scheduled", title: "Has a day", count: n,
                         tooltip: "Clips with a day on the Calendar"),
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

/// The Queue's sort (Settings › Queue sort: the order clips get their days) with the tie rule explained inside.
struct QueueSortMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    DSSortMenu(options: SortDirection.allCases.map { DSSortOption(id: $0.rawValue, title: $0.displayName) },
               selection: Binding(get: { model.settings.sort.rawValue }, set: { new in
                 if let d = SortDirection(rawValue: new), d != model.settings.sort { model.update { $0.sort = d } }
               }),
               tooltip: "Order the Queue by score",
               notes: ["Ties: the older set first, then part, then start time",
                       "Re-lays the calendar; pinned days stay"])
  }
}

/// Queue bulk bar (DESIGN-v2 §5, fitted to the 720 pt bar): Post today · More (Back to Edit, Skip platform ▸, Exclude,
/// post on a platform again, Kind, re-render) · **Pin to days…**.
private struct QueueBulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  let onPin: () -> Void

  var body: some View {
    let n = AppModel.pipelineClips(ids.count)
    ScreenBulkBar(model: model, screen: .queue) {
      Button("Post today", systemImage: "bolt") {
        let ids = ids
        model.pipelineBulk("Post \(n) today?", verb: "Post today", ids: ids,
                           changes: [.init(field: "Day", value: "Today · the rest of the Calendar moves a day later")]) { b, dry in
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
      Divider()
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
      DSButton("Pin to days…", variant: .primary, size: .sm, tooltip: "Pin to consecutive days, in order shown") { onPin() }
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
               : "The clip posts on this day and stays there.",
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
