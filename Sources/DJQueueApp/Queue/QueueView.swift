import DJQCore
import SwiftUI

/// Queue (DESIGN-v2 §6.3, ref R2.QUEUE Hootsuite cards) — job: keep ready clips in posting order.
///
/// Toolbar "Queue · 41 ready · next Thu 5 Nov" · runway chip · sort menu ("Worst → best ▾", tie rule inside,
/// writes `Settings.sort`) · view toggle. No filled primary: the primary act is direct manipulation.
/// Order = the upcoming plan (date order) then the ready backlog in sort order. Cards: position · ⋮⋮ on hover ·
/// thumb · title + meta · score · next-date chip · platform icons only when planned/posted · pin glyph. Hover
/// actions: Post today, Pin to date…, ⋯ (Skip next, Exclude, Open editor). Drag a card onto a planned clip to take
/// its day (pinned); the backlog itself follows the sort. Bulk: Pin to days… · Post today · Skip platform ▾ ·
/// Exclude · More · **Add to week**. Hidden: unscored / not-ready / excluded clips, versions.
struct QueueView: View {
  @Bindable var model: AppModel
  @State private var pinTarget: [String]?

  var body: some View {
    let list = model.queueList
    let ids = list.map(\.id)
    let mode = model.viewMode(.queue)
    let sel = model.selectedIds(.queue)
    let positions = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0 + 1) })
    ScreenScaffold(model: model, screen: .queue, subtitle: subtitle(list), readingColumn: mode == .wide || mode == .list) {
      RunwayChip(model: model)
      QueueSortMenu(model: model)
      DSViewModeSwitcher(mode: model.viewModeBinding(.queue))
    } content: {
      if !model.loaded {
        Color.clear
      } else if list.isEmpty {
        DSEmptyState(icon: "list.bullet", title: "Nothing ready yet", message: "Clips appear here once they're scored and edited.",
                     actionTitle: "Go to Edit") { model.screen = .edit }
      } else if mode == .wide {
        QueueCardList(model: model, videos: list, positions: positions, onPin: { pinTarget = [$0] })
      } else {
        ClipCollection(model: model, screen: .queue, videos: list, mode: mode, clip: { v in
          var c = model.dsClip(v, for: .queue)
          c.position = positions[v.id]
          // Grid tiles have no date chip of their own: the next day rides as a tag (only when scheduled).
          if mode == .grid, let d = c.dateText, d != "Not scheduled" {
            c.tags.append(DSClipTag(text: d, style: .outline, icon: c.isPinned ? "pin.fill" : "calendar"))
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
  }

  private func subtitle(_ list: [Video]) -> String? {
    guard !list.isEmpty else { return nil }
    let next = model.upcomingSlots.first.flatMap { model.video($0.videoId) }.map { model.dateText($0) }
      .map { $0 == "Today" ? "today" : $0 }
    return "\(list.count) ready" + (next.map { " · next \($0)" } ?? "")
  }
}

/// "Worst → best ▾": the backlog order (Settings.sort) with the tie rule explained inside.
struct QueueSortMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    let current = model.settings.sort
    Menu {
      ForEach(SortDirection.allCases, id: \.self) { d in
        Button {
          if d != current { model.update { $0.sort = d } }
        } label: {
          if d == current { Label(d.displayName, systemImage: "checkmark") } else { Text(d.displayName) }
        }
      }
      Divider()
      Text("Ties: the older set first, then part, then start time")
      Text("Planned clips keep their days; this orders the ready backlog")
    } label: {
      HStack(spacing: 5) {
        Text(current.displayName)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
      }
    }
    .menuStyle(.button)
    .buttonStyle(DSButtonStyle(variant: .ghost, size: .sm))
    .menuIndicator(.hidden)
    .fixedSize()
    .dsTooltip("Order of the ready backlog by score")
  }
}

/// Queue bulk bar (DESIGN-v2 §5, fitted to the 720 pt bar): Pin to days… · Post today · More (Remove from queue,
/// Back / Forward a stage, Skip platform ▸, Exclude, post on a platform again, Kind, re-render) · **Add to week**.
private struct QueueBulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  let onPin: () -> Void

  var body: some View {
    let n = AppModel.pipelineClips(ids.count)
    ScreenBulkBar(model: model, screen: .queue) {
      Button("Pin to days…", systemImage: "pin") { onPin() }
        .dsTooltip("Pin the selected clips to consecutive days, in the order shown")
      Button("Post today", systemImage: "bolt") {
        let ids = ids
        model.pipelineBulk("Post \(n) today?", verb: "Post today", ids: ids,
                           changes: [.init(field: "Day", value: "Today · the rest of the plan moves a day later")]) { b, dry in
          try b.postToday(ids, dryRun: dry)
        }
      }
      .dsTooltip("Put the selected clips on today (clips beyond today's free slots are skipped)")
    } more: {
      Button("Remove from queue", systemImage: "arrow.uturn.backward") { model.removeFromQueue(ids) }
        .help(AppModel.removeFromQueueHelp)
      Button("Back a stage", systemImage: "chevron.left") { model.stageBack(ids) }
        .help("Planned clips go back to the Queue (unposted days removed); ready ones go back to Edit")
      Button("Forward a stage", systemImage: "chevron.right") { model.stageForward(ids) }
        .help("Ready clips go on the next open days, pinned; planned clips are skipped — mark them posted on Today")
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
      Menu("Post on a platform again") {
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
      Button("Re-render", systemImage: "arrow.triangle.2.circlepath") {
        let ids = ids
        model.pipelineBulk("Re-render \(n)?", verb: "Re-render", ids: ids,
                           changes: [.init(field: "Renders", value: "Made again on the next engine tick")]) { b, dry in
          try b.reRender(ids, dryRun: dry)
        }
      }
    } primary: {
      DSButton("Add to week", variant: .primary, size: .sm, tooltip: "Plan the selected clips on the first free days") { addToWeek() }
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
      DSButton("Cancel", variant: .ghost) { onClose() }
        .keyboardShortcut(.cancelAction)
      DSButton(multi ? "Pin \(ids.count)" : "Pin", variant: .primary) { pin(pick) }
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
