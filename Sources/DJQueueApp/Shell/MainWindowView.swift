import AppKit
import DJQCore
import SwiftUI

/// APP.L: sidebar + content (+ right inspector per screen); full-window takeovers for the editor and Score mode.
struct MainWindowView: View {
  @Bindable var model: AppModel

  var body: some View {
    ZStack {
      if let ed = model.editor {
        EditorView(store: model.store, videoId: ed.videoId, videoIds: ed.videoIds, onDone: { model.closeEditor() })
          .transition(.opacity)
      } else if model.scoreMode {
        ScoreModeView(model: model).transition(.opacity)
      } else {
        split
      }
      if model.showPalette {
        CommandPalette(model: model).transition(.opacity)
      }
    }
    .overlay(alignment: .bottom) { ToastView(model: model) }
    .background { ShortcutButtons(model: model) }
    .sheet(item: $model.markPostedTarget) { p in MarkPostedSheet(model: model, post: p) }
    .sheet(item: $model.reportTarget) { p in ReportProblemSheet(model: model, post: p) }
    .sheet(item: $model.longformTarget) { v in LongformPostedSheet(model: model, video: v) }
    .sheet(item: $model.previewVideo) { v in PreviewSheet(model: model, video: v) }
    .sheet(isPresented: $model.showShortcuts) { ShortcutSheet(model: model) }
    .sheet(isPresented: $model.offerLaunchAgent) { LaunchAgentOffer(model: model) }
    .confirmationDialog("Pause all posting?", isPresented: $model.confirmPause) {
      Button("Pause all posting", role: .destructive) { model.setPaused(true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Nothing is handed to you or posted until you resume. The plan stays as it is.")
    }
    .frame(minWidth: 1100, minHeight: 700)
  }

  private var split: some View {
    NavigationSplitView {
      Sidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: DS.sidebarWidth, max: 260)
    } detail: {
      VStack(spacing: 0) {
        BannerStack(model: model)
        Group {
          switch model.screen {
          case .queue: QueueView(model: model)
          case .week: WeekView(model: model)
          case .today: TodayView(model: model)
          case .library: LibraryView(model: model)
          case .posts: PostsView(model: model)
          case .health: HealthView(model: model)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle(model.screen.title)
      .toolbar { MainToolbar(model: model) }
      .background(WindowTitle(title: model.screen.title))
    }
  }
}

/// First run of the installed app (decision Q28): run in the background at login? Default Yes.
struct LaunchAgentOffer: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Run DJ Queue in the background at login?", systemImage: "menubar.rectangle").font(DS.Font.title)
      Text("The menu-bar item and the engine keep running when the window is closed, so posts are prepared and reminders arrive on time.")
        .font(DS.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Not now") {
          UserDefaults.standard.set(true, forKey: "djq.askedLaunchAgent")
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Run at login") {
          dismiss()
          AppHost.shared.installLaunchAgent()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 440)
  }
}

// MARK: - Sidebar

struct Sidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    List(selection: Binding<Screen?>(get: { model.screen }, set: { if let s = $0 { model.screen = s } })) {
      ForEach(Screen.allCases) { s in
        HStack(spacing: 8) {
          Label(s.title, systemImage: s.symbol)
          Spacer(minLength: 4)
          trailing(s)
        }
        .tag(s)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 0) {
        Divider()
        Button { WindowManager.shared.showSettings() } label: {
          Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
      }
    }
  }

  @ViewBuilder private func trailing(_ s: Screen) -> some View {
    switch s {
    case .today:
      if model.dueBadge > 0 { CountBadge(n: model.dueBadge, tint: .secondary) }
    case .posts:
      if !model.problems.isEmpty { CountBadge(n: model.problems.count, tint: .red, loud: true) }
    case .queue:
      if model.unscoredCount > 0 { CountBadge(n: model.unscoredCount, tint: .secondary) }
    case .health:
      StateDot(tint: model.engineRunning ? DS.Status.posted : DS.Status.error).help(model.engineRunning ? "Engine running" : "Engine stopped")
    default: EmptyView()
    }
  }
}

struct CountBadge: View {
  let n: Int
  var tint: Color = .secondary
  var loud = false
  var body: some View {
    Text("\(n)")
      .font(.system(size: 11, weight: .semibold).monospacedDigit())
      .foregroundStyle(loud ? Color.white : Color.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(loud ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
  }
}

// MARK: - Toolbar (APP.TB)

struct MainToolbar: ToolbarContent {
  @Bindable var model: AppModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      RunwayTrio(model: model)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      PostsPerDayControl(model: model)
      PauseSwitch(model: model)
      Button { model.showPalette = true } label: {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
          Text("⌘K").font(DS.Font.secondary)
        }
      }
      .help("Command palette (⌘K)")
      .accessibilityLabel("Command palette")
    }
  }
}

struct RunwayTrio: View {
  @Bindable var model: AppModel
  @State private var showInfo = false

  var body: some View {
    Button { showInfo.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: "calendar.badge.checkmark").foregroundStyle(approvedTint)
        Text("\(model.runway.approvedDays)d").font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
          .foregroundStyle(approvedTint)
        Text("·").foregroundStyle(.tertiary)
        Text("\(model.runway.readyDays)d").font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
        Text("·").foregroundStyle(.tertiary)
        Text("\(model.runway.totalDays)d").font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
    }
    .buttonStyle(.plain)
    .help("Runway: approved · ready · total")
    .accessibilityLabel("Runway: \(model.runway.approvedDays) days approved, \(model.runway.readyDays) ready, \(model.runway.totalDays) total")
    .popover(isPresented: $showInfo, arrowEdge: .bottom) { RunwayPopover(model: model) }
  }

  private var approvedTint: Color { model.runwayTint(model.runway.approvedDays, threshold: model.settings.approvedRunwayAlertDays) }
}

struct RunwayPopover: View {
  @Bindable var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Eyebrow("Runway")
      row(model.runway.approvedDays, "Approved", "Days covered by approved weeks. Alert under \(model.settings.approvedRunwayAlertDays)d.",
          model.runwayTint(model.runway.approvedDays, threshold: model.settings.approvedRunwayAlertDays))
      row(model.runway.readyDays, "Ready", "Ready videos not yet in an approved week, at \(model.settings.postsPerDay)/day.", .primary)
      row(model.runway.totalDays, "Total", "Approved + ready + scored needing edits. Record a new set under \(model.settings.totalRunwayAlertDays)d.",
          model.runwayTint(model.runway.totalDays, threshold: model.settings.totalRunwayAlertDays))
    }
    .padding(16)
    .frame(width: 300)
  }

  private func row(_ d: Int, _ title: String, _ text: String, _ tint: Color) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(d)d").font(DS.Font.runway).foregroundStyle(tint).frame(width: 64, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.Font.bodyStrong)
        Text(text).font(DS.Font.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct PostsPerDayControl: View {
  @Bindable var model: AppModel
  var body: some View {
    HStack(spacing: 4) {
      Text("\(model.settings.postsPerDay)/day").font(DS.Font.body.monospacedDigit()).padding(.leading, 6)
      Stepper("Posts per day", value: Binding(get: { model.settings.postsPerDay }, set: { v in model.update { $0.postsPerDay = v } }), in: 1...5)
        .labelsHidden()
    }
    .help("Posts per day (1–5)")
  }
}

struct PauseSwitch: View {
  @Bindable var model: AppModel
  var body: some View {
    HStack(spacing: 6) {
      Text(model.settings.paused ? "Paused" : "Pause").font(DS.Font.body).foregroundStyle(model.settings.paused ? Color.orange : .primary)
        .padding(.leading, 6)
      Toggle("Pause all posting", isOn: Binding(get: { model.settings.paused }, set: { on in
        if on { model.confirmPause = true } else { model.setPaused(false) }
      }))
      .toggleStyle(.switch)
      .controlSize(.small)
      .labelsHidden()
      .tint(.orange)
    }
    .help("Pause all posting (kill switch)")
  }
}

// MARK: - Banners (APP.ERR / APP.WARN / paused)

struct BannerStack: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.problems.isEmpty {
        let s = model.problemSummary
        Banner(kind: .error, text: s.title, detail: s.detail, actionTitle: "Review", action: { model.reviewProblems() })
      }
      if model.settings.paused {
        Banner(kind: .paused, text: "Posting paused", detail: "Nothing is handed to you until you resume.", actionTitle: "Resume", action: { model.setPaused(false) })
      }
      ForEach(model.warnings) { w in
        Banner(kind: .warning, text: w.text, actionTitle: w.action, action: w.run, onDismiss: { model.dismissWarning(w.id) })
      }
      if let e = model.loadError {
        Banner(kind: .error, text: "Database error", detail: e, actionTitle: "Health", action: { model.screen = .health })
      }
    }
  }
}

struct ToastView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let t = model.toast {
      HStack(spacing: 8) {
        Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(t.isError ? Color.red : Color.green)
        Text(t.text).font(DS.Font.body).lineLimit(2)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
      .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
      .padding(.bottom, 20)
      .id(t.id)
    }
  }
}

// MARK: - Keyboard shortcuts (APP.KB)

struct ShortcutButtons: View {
  @Bindable var model: AppModel
  var body: some View {
    ZStack {
      ForEach(Screen.allCases) { s in
        Button("") { model.screen = s; model.scoreMode = false }.keyboardShortcut(s.key, modifiers: .command)
      }
      Button("") { model.showPalette.toggle() }.keyboardShortcut("k", modifiers: .command)
      Button("") { model.showShortcuts.toggle() }.keyboardShortcut("/", modifiers: .command)
      Button("") { if let v = model.focusedVideo { model.openEditor(v.id, in: model.selectedVideoIds) } }
        .keyboardShortcut("e", modifiers: .command)
      Button("") { model.scoreMode = true }.keyboardShortcut("s", modifiers: [.command, .shift])
      Button("") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
      Button("") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct ShortcutSheet: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss

  private let groups: [(String, [(String, String)])] = [
    ("Everywhere", [("⌘K", "Command palette"), ("⌘/", "This cheat sheet"), ("⌘1 – ⌘6", "Queue · Week · Today · Library · Posts · Health"),
                    ("⌘,", "Settings"), ("⌘R", "Refresh"), ("⌥⌘I", "Show / hide inspector")]),
    ("Queue and Library", [("0–9", "Type a score on the selected row"), ("↑ / ↓", "±1 while editing a score"),
                           ("⇧↑ / ⇧↓", "±10 while editing a score"), ("⌘E", "Edit the selected video"),
                           ("Space", "Preview the clip"), ("⇧⌘S", "Score mode")]),
    ("Score mode", [("0–100 ↩", "Save and jump to the next unscored"), ("← / →", "Previous / next clip"), ("Esc", "Exit")]),
    ("Week", [("⌘↩", "Approve week"), ("Drag", "Move or swap days")]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Keyboard shortcuts").font(DS.Font.title)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(alignment: .top, spacing: 32) {
        VStack(alignment: .leading, spacing: 18) { group(groups[0]); group(groups[3]) }
        VStack(alignment: .leading, spacing: 18) { group(groups[1]); group(groups[2]) }
      }
    }
    .padding(24)
    .frame(width: 680)
  }

  private func group(_ g: (String, [(String, String)])) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Eyebrow(g.0)
      ForEach(g.1, id: \.0) { k in
        HStack {
          Text(k.1).font(DS.Font.body)
          Spacer(minLength: 16)
          KeyHint(k.0)
        }
        .frame(width: 290)
      }
    }
  }
}

/// Keeps the hosting window's title in step with the current screen.
struct WindowTitle: NSViewRepresentable {
  let title: String
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ v: NSView, context: Context) {
    DispatchQueue.main.async { v.window?.title = title }
  }
}
