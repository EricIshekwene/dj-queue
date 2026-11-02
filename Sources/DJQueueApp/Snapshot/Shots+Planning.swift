import DJQCore
import SwiftUI

/// PLANNING leaf shots (prefix 2x): Week, Today, menu bar (window + icon states).
///
/// The shared sample model is left as it was (other leaves render after us); states that need different data
/// (next week approved, nothing due today) come from a sandbox copy (`SampleData.planningSandbox`).
extension SnapshotShots {
  static func planning(_ c: SnapshotContext) -> [Shot] {
    let model = c.model
    let sandbox = SampleData.planningSandbox(c)
    var shots: [Shot] = [
      // This week has started, so it reads "Locked": past days 50 %, today in the near-black pill, hatched Mac-off.
      c.main("20-week-current-locked") { m in m.screen = .week },
      c.main("21-week-next-draft-backlog") { m in
        m.screen = .week
        m.weekStart = m.dm.addDays(m.planner.weekStart(for: m.now), 7)
        m.weekBacklogExpanded = true
      },
      c.main("23-week-empty") { m in
        m.screen = .week
        m.weekStart = m.dm.addDays(m.planner.weekStart(for: m.now), 14)
        m.weekBacklogExpanded = false
      },
      c.main("24-week-no-clips", c.empty) { m in m.screen = .week },
      c.main("25-today") { m in
        m.weekBacklogExpanded = false
        m.screen = .today
      },
      c.main("26-today-mark-posted") { m in
        m.screen = .today
        m.markPostedTarget = m.todayNextUp
      },
      c.main("28-today-loading") { m in
        m.markPostedTarget = nil
        m.screen = .today
        m.loaded = false
      },
      c.view("29-menubar-normal", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .normal))) },
      c.view("29-menubar-due-now", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .due))) },
      c.view("29-menubar-problems", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .problems))) },
      c.view("29-menubar-engine-off", width: 320) { AnyView(MenuBarContent(model: model, state: menuState(model, .engineOff))) },
      c.view("29-menubar-icons", width: 420) { AnyView(MenuBarIconSheet()) },
    ]
    if let sandbox {
      shots.append(c.main("22-week-approved", sandbox) { m in
        m.screen = .week
        m.weekStart = m.dm.addDays(m.planner.weekStart(for: m.now), 7)
      })
      shots.append(c.main("27-today-empty", sandbox) { m in m.screen = .today })
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
