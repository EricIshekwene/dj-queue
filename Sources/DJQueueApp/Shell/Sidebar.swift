import DJQCore
import SwiftUI

/// ChatGPT-style sidebar (DESIGN-v2 §3, `R2.NAV`): flat `DS.color.sidebar`, no List. Header (traffic lights ·
/// "DJ Queue" · collapse), "Search clips ⌘K", the pipeline rows without a header, "Browse" rows, then the footer
/// engine line (menu) and Settings. `compact` = 76 pt icon rail (under 1200 pt or collapsed by Eric).
struct AppSidebar: View {
  @Bindable var model: AppModel
  var compact = false
  static let compactWidth: CGFloat = 76

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      VStack(alignment: .leading, spacing: 2) {
        SidebarRow(title: "Search clips", icon: "magnifyingglass", hint: "⌘K", shortcut: "⌘K", tooltip: "Search clips and commands",
                   compact: compact) { model.showPalette = true }
          .padding(.bottom, DS.space.xs)
        ForEach(Screen.allCases.filter(\.isPipeline)) { s in row(s) }
        if compact {
          DSSeparator().padding(.vertical, DS.space.xs).padding(.horizontal, 10)
        } else {
          DSEyebrow("Browse").padding(.leading, 10).padding(.top, DS.space.lg).padding(.bottom, DS.space.xxs)
        }
        ForEach(Screen.allCases.filter { !$0.isPipeline }) { s in row(s) }
      }
      .padding(.horizontal, DS.space.xs)
      Spacer(minLength: DS.space.md)
      VStack(alignment: .leading, spacing: 2) {
        if model.postizTestRun {
          SidebarRow(title: "Test run", icon: "testtube.2", hint: compact ? nil : "On", tooltip: TestRunBadge.help,
                     compact: compact) {
            WindowManager.shared.showSettings(section: .publishing)
          }
        }
        EngineLine(model: model, compact: compact)
        SidebarRow(title: "Settings", icon: "gearshape", hint: compact ? nil : "⌘,", shortcut: "⌘,", tooltip: "Open Settings",
                   compact: compact) {
          WindowManager.shared.showSettings()
        }
      }
      .padding(.horizontal, DS.space.xs)
      .padding(.bottom, DS.space.sm)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(DS.color.sidebar)
    .overlay(alignment: .trailing) { DSSeparator(vertical: true) }
  }

  /// 52 pt row level with the screen toolbars; the window's traffic lights sit at its left.
  private var header: some View {
    HStack(spacing: DS.space.xs) {
      if !compact {
        Text("DJ Queue").font(DS.type.headline).foregroundStyle(DS.color.text).padding(.leading, 78)
        Spacer(minLength: 0)
        DSIconButton("sidebar.left", tooltip: "Collapse sidebar to icons", size: .sm) { model.sidebarCollapsed = true }
      } else {
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: DS.size.toolbar)
    .background { WindowDragArea() }
    .overlay(alignment: .bottom) {
      if compact && model.sidebarCollapsed {
        DSIconButton("sidebar.left", tooltip: "Expand sidebar", size: .sm) { model.sidebarCollapsed = false }
          .offset(y: 20)
      }
    }
    .padding(.bottom, compact && model.sidebarCollapsed ? 28 : 0)
  }

  private func row(_ s: Screen) -> some View {
    let count = model.sidebarCount(s)
    return SidebarRow(title: s.title, icon: s.symbol, count: s == .health ? nil : count, countStyle: model.sidebarCountStyle(s),
                      dot: s == .health ? model.healthTone : nil, hint: nil, shortcut: "⌘\(s.key.character)",
                      tooltip: rowTooltip(s, count: count), isSelected: model.screen == s, compact: compact) {
      model.screen = s
    }
  }

  /// Expanded: what the screen is for, plus what its count or dot means ("Score new clips · 13 to score"). Compact
  /// (no visible title): the screen's name with the same meaning ("Score · 13 to score"). ⌘1…⌘7 ride as keycaps.
  private func rowTooltip(_ s: Screen, count: Int?) -> String {
    let n = count.map { "\($0) " } ?? ""
    let (purpose, meaning): (String, String?) = switch s {
    case .score: ("Score new clips", count == nil ? nil : "\(n)to score")
    case .edit: ("Finish clips for posting", count == nil ? nil : "\(n)in Edit")
    case .queue: ("See Queue clips in posting order", count == nil ? nil : "\(n)in the Queue")
    case .calendar: ("See the posts going out", count == nil ? nil : "\(n)due")
    case .library: ("Browse every clip, posted or not", nil)
    case .posts: ("See every post", count == nil ? nil : "\(n)need attention")
    case .health: ("Check engine and schedule", healthMeaning)
    }
    return [compact ? s.title : purpose, meaning].compactMap { $0 }.joined(separator: " · ")
  }

  /// Why the Health dot has its colour.
  private var healthMeaning: String {
    switch model.healthTone {
    case .danger: model.loadError != nil ? "database error" : "engine stopped"
    case .warning:
      model.settings.paused ? "posting paused" : !model.settings.pausedPlatforms.isEmpty ? "a platform paused" : "Queue running low"
    default: "all good"
    }
  }
}

/// DSSidebarItem anatomy (36 pt, r.sm, 16 pt symbol, callout label, right count/dot) plus an optional right-aligned
/// key hint ("⌘K") and a compact icon-only form with a tooltip.
struct SidebarRow: View {
  let title: String
  let icon: String
  var count: Int? = nil
  var countStyle: DSCount.Style = .plain
  var dot: DSTone? = nil
  var hint: String? = nil
  var shortcut: String? = nil
  /// Hover text (expanded and compact). nil = the title, shown only in the compact rail.
  var tooltip: String? = nil
  var isSelected = false
  var compact = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon).font(.system(size: 14, weight: .regular)).frame(width: 18)
          .foregroundStyle(DS.color.text)
          .overlay(alignment: .topTrailing) {
            if compact, let dot { DSStatusDot(tone: dot, size: 6).offset(x: 4, y: -2) }
            if compact, count != nil, countStyle != .plain {
              DSStatusDot(tone: countStyle == .danger ? .danger : .neutral, size: 6).offset(x: 4, y: -2)
            }
          }
        if !compact {
          Text(title).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
          Spacer(minLength: 4)
          if let count { DSCount(count: count, style: countStyle) }
          if let dot { DSStatusDot(tone: dot, size: 7) }
          if let hint { Text(hint).font(DS.type.caption).foregroundStyle(DS.color.textTertiary) }
        }
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
      .frame(height: DS.size.sidebarItem)
      .background(isSelected ? DS.color.selected : hovering ? DS.color.hover : .clear,
                  in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip(tooltip ?? (compact ? title : nil), shortcut: shortcut, side: .trailing)
    .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// Sidebar footer — the posting status everywhere except Posts (which also has the paused card) and its control:
/// "● Running · next 7:00 PM TikTok" / amber "⏸ Posting paused" / red "Engine stopped". Click → menu: Resume all
/// posting (or Pause all posting…, which asks first), Pause or resume one platform ▸ (Pause X / Resume X), Open Health.
struct EngineLine: View {
  @Bindable var model: AppModel
  var compact = false
  @State private var open = false
  @State private var hovering = false

  var body: some View {
    let line = model.engineLine
    let paused = model.settings.paused && model.engineRunning
    Button { open.toggle() } label: {
      HStack(spacing: 10) {
        Group {
          if paused {
            Image(systemName: "pause.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.color.warning)
          } else {
            DSStatusDot(tone: line.tone, size: 8, pulse: line.tone == .success)
          }
        }
        .frame(width: 18)
        if !compact {
          Text(line.text).font(paused ? DS.type.calloutMedium : DS.type.callout)
            .foregroundStyle(paused ? DS.color.warning : DS.color.text).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
        }
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
      .frame(height: DS.size.sidebarItem)
      .background(hovering || open ? DS.color.hover : paused ? DS.color.warning.opacity(0.10) : .clear,
                  in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip(compact ? line.text : paused ? "Resume posting or open Health" : "Pause or resume posting, or open Health",
               side: .trailing)
    .accessibilityLabel("Engine: \(line.text)")
    .dsPopover(isPresented: $open, edge: .top, width: 260) { EngineMenu(model: model) { open = false } }
  }
}

/// The engine menu (DSMenuList). "Pause or resume one platform" swaps to a second page: one item per platform whose
/// title says what a click does ("Pause TikTok" / "Resume X (paused)"). Every change is undoable (toast · ⌘Z).
struct EngineMenu: View {
  @Bindable var model: AppModel
  var close: () -> Void
  @State private var platforms = false

  var body: some View {
    if platforms {
      DSMenuList(items: [DSMenuItem(title: "Back", icon: "chevron.left") { platforms = false }, .separator,
                         .label("One platform (the others keep posting)")]
        + model.settings.activePlatforms.map { p in
          let paused = model.settings.pausedPlatforms.contains(p)
          return DSMenuItem(title: paused ? "Resume \(p.displayName) (paused)" : "Pause \(p.displayName)", icon: p.dsSymbol) {
            model.setPlatformPaused(p, !paused)
          }
        })
    } else {
      let paused = model.settings.paused
      DSMenuList(items: [
        .label(model.engineLine.text),
        paused
          ? DSMenuItem(title: "Resume all posting", icon: "play.circle") { close(); model.setPaused(false) }
          : DSMenuItem(title: "Pause all posting…", icon: "pause.circle") { close(); model.confirmPause = true },
        DSMenuItem(title: "Pause or resume one platform", icon: "pause", shortcut: "›") { platforms = true },
        .separator,
        DSMenuItem(title: "Open Health", icon: "heart") { close(); model.screen = .health },
      ])
    }
  }
}

/// "Test run" (Settings → Publishing): quiet, always visible while the switch is on; also on every affected post.
struct TestRunBadge: View {
  static let help = "Test run: TikTok to inbox, YouTube unlisted, rest as drafts"
  var size: DSBadgeSize = .sm
  var body: some View {
    DSBadge("Test run", style: .outline, icon: "testtube.2", size: size, help: Self.help)
  }
}
