import DJQCore
import SwiftUI

/// Calendar (B1–B13, DESIGN-v2 §6.4): the posts going out, in four views over one toolbar. A clip in the Queue is
/// approved; this page shows where it landed. No primary button and no status pill: Move, Post today and Unschedule
/// live on the clips.
///
/// ```
/// ┌ Calendar · 2 – 8 Nov ······ ‹ Today › · Day 3 Day Week Month · All platforms ▾ · Scheduled through Sat 7 Nov ┐
/// │ [Queue running low / problems / paused cards]                                                                │
/// │ Day: reading column, Next-up card + clips with one row per platform                                          │
/// │ 3 Day / Week: columns of clip cards · Month: the grid with thumb chips                                       │
/// └──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
/// ```
/// Keys D 3 W M T ← → work unless a text field or an overlay has them (`AppModel.handleCalendarKey`). The range loads
/// off-main with every refresh (`CalendarData`); `body` reads memory only.
struct CalendarView: View {
  @Bindable var model: AppModel

  var body: some View {
    let mode = model.calendarMode
    ScreenScaffold(model: model, screen: .calendar, subtitle: model.calendarRangeText, readingColumn: mode == .day) {
      toolbar(mode)
    } content: {
      content(mode)
    }
    .background { EditorKeyMonitor { model.handleCalendarKey($0) } }
    .overlay {
      if let t = model.calendarPinTarget {
        ZStack {
          DS.color.scrim.ignoresSafeArea().onTapGesture { model.calendarPinTarget = nil }
          QueuePinDialog(model: model, ids: t) { model.calendarPinTarget = nil }
        }
        .transition(.opacity)
      }
    }
    .dsAnimation(DS.motion.popover, value: model.calendarPinTarget)
    .onChange(of: model.calendarPinTarget == nil, initial: true) { _, closed in ListPrefs.shared.screenDialogOpen = !closed }
    .onDisappear { ListPrefs.shared.screenDialogOpen = false }
  }

  // MARK: Toolbar

  @ViewBuilder private func toolbar(_ mode: CalendarViewMode) -> some View {
    if mode == .day && model.calendarDay == model.todayKey && model.loaded && model.todayTotal > 0 { progress }
    HStack(spacing: 2) {
      DSIconButton("chevron.left", tooltip: "Show the previous \(mode.stepName)", size: .sm, shortcut: "←") { model.stepCalendar(-1) }
      DSButton("Today", variant: .ghost, size: .sm, tooltip: "Jump back to today", shortcut: "T") { model.calendarToday() }
      DSIconButton("chevron.right", tooltip: "Show the next \(mode.stepName)", size: .sm, shortcut: "→") { model.stepCalendar(1) }
    }
    DSSegmented(selection: Binding(get: { model.calendarMode }, set: { model.setCalendarMode($0) }),
                segments: CalendarViewMode.allCases.map { m in
                  DSSegment(value: m, title: m.title, tooltip: "\(m.title) view", shortcut: m.key)
                },
                size: .sm)
      .fixedSize()
    platformFilter
    RunwayChip(model: model)
  }

  private var progress: some View {
    let done = model.postedTodayCount, total = model.todayTotal
    return HStack(spacing: DS.space.xs) {
      DSProgressRing(value: Double(done) / Double(max(total, 1)), size: 22, lineWidth: 3, tone: .success)
      Text("\(done) of \(total) posted").font(DS.type.calloutMedium.monospacedDigit()).foregroundStyle(DS.color.textSecondary).lineLimit(1)
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(done) of \(total) posted today")
  }

  /// "All platforms ▾" (`C.F` Buffer's channels menu): one active platform narrows every view; remembered.
  private var platformFilter: some View {
    let f = model.calendarFilter
    return DSXMenuLabelButton(title: f?.displayName ?? "All platforms", icon: f?.dsSymbol ?? "square.stack.3d.up", variant: f == nil ? .ghost : .outline,
                              size: .sm, tooltip: "Show one platform") {
      Picker("Platform", selection: Binding(get: { model.calendarFilter }, set: { model.setCalendarPlatform($0) })) {
        Label("All platforms", systemImage: "square.stack.3d.up").tag(Platform?.none)
        ForEach(model.settings.activePlatforms) { p in
          Label(p.displayName, systemImage: p.dsSymbol).tag(Platform?.some(p))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
  }

  // MARK: Content

  @ViewBuilder private func content(_ mode: CalendarViewMode) -> some View {
    if !model.calendarLoaded {
      switch mode {
      case .day: CalendarDaySkeleton()
      case .threeDay: CalendarColumnsSkeleton(columns: 3)
      case .week, .month: CalendarColumnsSkeleton(columns: 7)
      }
    } else if nothingScheduled {
      DSEmptyState(icon: "calendar", title: "Nothing scheduled", message: "Clips you send to the Queue get a day here by themselves.",
                   actionTitle: "Go to Edit") { model.screen = .edit }
    } else if let f = model.calendarFilter, filteredOut(mode) {
      DSEmptyState(icon: f.dsSymbol, title: "Nothing on \(f.displayName) here", message: "No clip in this view posts to \(f.displayName).",
                   actionTitle: "Show all platforms") { model.setCalendarPlatform(nil) }
    } else {
      switch mode {
      case .day: CalendarDayView(model: model, day: model.calendarDay)
      case .threeDay: CalendarColumns(model: model, days: model.calendarDays, style: .threeDay)
      case .week: CalendarColumns(model: model, days: model.calendarDays, style: .week)
      case .month: CalendarMonthView(model: model, days: model.calendarDays)
      }
    }
  }

  /// No day anywhere and nothing waiting to get one.
  private var nothingScheduled: Bool {
    model.upcomingSlots.isEmpty && model.ordered.isEmpty && model.dueToday.isEmpty
      && !model.calendarDays.contains { model.calendarData.posts[$0] != nil || model.calendarData.slots[$0] != nil }
  }

  private func filteredOut(_ mode: CalendarViewMode) -> Bool {
    mode == .day ? model.calendarDayGroups(model.calendarDay).isEmpty : model.calendarFilterIsEmpty
  }
}
