import DJQCore
import SwiftUI

/// PLANNING leaf shots (prefix 2x, `calendar-*`): the Calendar in every view, then the menu bar (window + icon states).
///
/// The shared sample model is left as it was (other leaves render after us); states that need different data come
/// from sandbox copies: nothing going out today, and two clips a day for the fuller views.
extension SnapshotShots {
  static func planning(_ c: SnapshotContext) -> [Shot] {
    let model = c.model
    let sandbox = SampleData.planningSandbox(c)
    let dense = SampleData.denseCalendarSandbox(c)
    func calendar(_ m: AppModel, _ mode: CalendarViewMode, anchor: String = "") {
      m.calendarMode = mode
      m.calendarAnchor = anchor
      m.screen = .calendar
    }
    var shots: [Shot] = [
      c.main("calendar-day-today") { m in calendar(m, .day) },
      c.main("calendar-day-future") { m in calendar(m, .day, anchor: m.dm.addDays(m.todayKey, 2)) },
      c.main("calendar-day-past") { m in calendar(m, .day, anchor: m.dm.addDays(m.todayKey, -2)) },
      c.main("calendar-3day") { m in calendar(m, .threeDay) },
      c.main("calendar-week") { m in calendar(m, .week) },
      c.main("calendar-week-narrow", size: Shot.narrow) { m in calendar(m, .week) },
      c.main("calendar-3day-narrow", size: Shot.narrow) { m in calendar(m, .threeDay) },
      c.main("calendar-month") { m in calendar(m, .month) },
      c.main("calendar-month-narrow", size: Shot.narrow) { m in calendar(m, .month) },
      c.main("calendar-day-narrow", size: Shot.narrow) { m in calendar(m, .day) },
      c.main("calendar-filtered") { m in
        calendar(m, .week)
        m.calendarPlatform = .youtube
      },
      c.main("calendar-filtered-empty") { m in
        calendar(m, .week)
        m.calendarPlatform = m.settings.activePlatforms.last
        m.calendarAnchor = m.dm.addDays(m.todayKey, 70)
      },
      c.main("calendar-empty", c.empty) { m in calendar(m, .week) },
      c.main("calendar-open-days") { m in calendar(m, .week, anchor: m.dm.addDays(m.todayKey, 70)) },
      c.main("calendar-paused") { m in
        m.update { $0.paused = true }; m.toast = nil  // setup, not an action shown in the shot
        calendar(m, .week)
      },
      c.main("calendar-mark-posted") { m in
        m.update { $0.paused = false }; m.toast = nil  // setup, not an action shown in the shot
        calendar(m, .day)
        m.markPostedTarget = m.todayNextUp
      },
      c.main("calendar-loading") { m in
        m.markPostedTarget = nil
        calendar(m, .day)
        m.loaded = false
      },
      c.main("edit-nothing-to-fix") { m in  // B16: complete, and waiting for Send to Queue
        m.setViewMode(.wide, for: .edit)
        if !m.editList.contains(where: { (m.issuesByVideo[$0.id] ?? []).isEmpty }), let v = m.editList.first { m.issuesByVideo[v.id] = [] }
        ListPrefs.shared.setStatus(.edit, EditView.nothingToFixId)
        m.screen = .edit
      },
      c.main("calendar-move-dialog") { m in
        calendar(m, .week)
        m.calendarPinTarget = m.calendarClips(m.dm.addDays(m.todayKey, 1)).first.map { [$0.video.id] }
      },
      c.main("calendar-unschedule-confirm") { m in
        m.calendarPinTarget = nil
        calendar(m, .week)
        if let id = m.calendarClips(m.dm.addDays(m.todayKey, 1)).first?.video.id {
          m.calendarUnschedule(id)
          m.pendingBulk?.preview = try? m.bulk.back([id], dryRun: true)
        }
      },
      c.main("calendar-hover-card") { m in
        m.cancelPendingBulk()
        calendar(m, .week)
        SnapshotHover.id = m.calendarClips(m.dm.addDays(m.todayKey, 1)).first?.video.id
      },
      c.main("calendar-after-hover") { m in  // leaves the shared sample as other shots expect it
        SnapshotHover.id = nil
        calendar(m, .month)
      },
      c.view("29-menubar-normal", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .normal))) },
      c.view("29-menubar-due-now", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .due))) },
      c.view("29-menubar-problems", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .problems))) },
      c.view("29-menubar-engine-off", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .engineOff))) },
      c.view("29-menubar-icons", width: 420) { AnyView(MenuBarIconSheet()) },
    ]
    if let sandbox {
      shots.append(c.main("calendar-day-empty", sandbox) { m in calendar(m, .day) })
      shots.append(c.main("calendar-queue-low", sandbox) { m in
        calendar(m, .week)
        m.dismissedWarnings = [:]
      })
    }
    if let dense {
      shots.append(c.main("calendar-week-dense", dense) { m in calendar(m, .week) })
      shots.append(c.main("calendar-3day-dense", dense) { m in calendar(m, .threeDay) })
      shots.append(c.main("calendar-month-dense", dense) { m in calendar(m, .month) })
      shots.append(c.main("calendar-month-dense-narrow", dense, size: Shot.narrow) { m in calendar(m, .month) })
      shots.append(c.main("calendar-day-dense", dense) { m in calendar(m, .day, anchor: m.dm.addDays(m.todayKey, 1)) })
    }
    return shots
  }

  enum MenuVariant { case normal, due, problems, engineOff }

  /// Menu-bar window variants from the sample model's real posts.
  static func menuState(_ m: AppModel, _ v: MenuVariant) -> MenuBarState {
    var s = MenuBarState(model: m)
    let upcoming = m.nextPost
    switch v {
    case .normal:
      s.next = upcoming
      s.due = []
      s.problems = []
    case .due:
      s.problems = []
    case .problems:
      s.next = upcoming
      s.due = []
    case .engineOff:
      s.next = upcoming
      s.due = []
      s.problems = []
      s.engineRunning = false
      s.lastTick = m.now.addingTimeInterval(-3 * 3600)
    }
    return s
  }
}

/// MB.ICON states side by side on a light and a dark menu-bar strip (the real status item lives in the system bar).
struct MenuBarIconSheet: View {
  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.md) {
      DSEyebrow("Menu-bar icon states")
      HStack(alignment: .top, spacing: DS.space.md) {
        column("Light menu bar", dark: false)
        column("Dark menu bar", dark: true)
      }
    }
    .padding(DS.space.md)
  }

  private let states: [(String, NSImage)] = [
    ("Running", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: false)),
    ("Needs attention", MenuBarIcon.image(days: 5, errors: 2, engineOn: true, paused: false)),
    ("Paused", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: true)),
    ("Engine stopped", MenuBarIcon.image(days: 1, errors: 0, engineOn: false, paused: false)),
  ]

  private func column(_ title: String, dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      Text(title).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      ForEach(states, id: \.0) { name, img in
        HStack(spacing: DS.space.sm) {
          Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original)
            .foregroundStyle(dark ? Color.white : Color.black)
            .frame(width: 64, height: 24)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: DS.radius.xs))
            .environment(\.colorScheme, dark ? .dark : .light)
          Text(name).font(DS.type.callout).foregroundStyle(DS.color.text)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
