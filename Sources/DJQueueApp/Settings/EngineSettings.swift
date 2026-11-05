import AppKit
import DJQCore
import SwiftUI

/// Engine: LaunchAgent install/stop (+ the last install error), engine heartbeat, wake, auto-update, folders, log,
/// backups.
struct EngineSettings: View {
  @Bindable var model: AppModel
  let ui: SettingsUIState
  @State private var loaded: Bool?

  var body: some View {
    if let err = model.agentError {
      VStack(alignment: .leading, spacing: 0) {
        DSAttentionCard(title: "Background engine not installed", tone: .danger, actionTitle: "Reinstall engine…", action: { confirmInstall() })
        SettingsNote(err, icon: "exclamationmark.circle")
      }
      .padding(.top, DS.space.lg)
    }
    SettingsGroupHeader("Background engine", first: model.agentError == nil)
    SettingsRow("Run at login", description: "Starts DJ Queue at login; the engine keeps running with the window closed.") {
      HStack(spacing: DS.space.xs) {
        agentBadge
        DSButton(loaded == true ? "Reinstall…" : "Install…", variant: .outline, size: .sm,
                 tooltip: loaded == true ? "Reinstall and reload the background engine" : "Install the engine to run at login") { confirmInstall() }
        DSButton("Stop…", variant: .ghost, size: .sm, disabledReason: loaded == true ? nil : "The background engine isn't loaded.",
                 tooltip: "Stop the engine and remove it from login") { confirmStop() }
      }
    }
    SettingsRow("Engine", description: model.engineInProcess ? "Running in this app." : "Running in another process.") {
      HStack(spacing: DS.space.xs) {
        DSStatusDot(tone: model.engineRunning ? .success : .danger)
        Text(model.lastHeartbeat.map { "Last tick \(Fmt.relative($0.at, now: model.now))" } ?? "No heartbeat")
          .font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        DSButton("Tick now", variant: .outline, size: .sm, tooltip: "Prepare due posts and reminders now") { model.runTick() }
      }
    }
    SettingsRow("Wake before first slot", description: "Schedules a Mac wake with pmset (needs an admin password).") {
      DSSwitch(isOn: model.toggleBinding(\.wakeBeforeFirstSlot, "Wake before first slot")).accessibilityLabel("Wake before first slot")
    }
    SettingsRow("Engine log", description: model.store.paths.engineLog.path, isPath: true) {
      DSButton("Open log", variant: .outline, size: .sm,
               disabledReason: FileManager.default.fileExists(atPath: model.store.paths.engineLog.path) ? nil : "No log written yet.") {
        NSWorkspace.shared.open(model.store.paths.engineLog)
      }
    }

    AutoUpdateSettings(model: model)

    SettingsGroupHeader("Folders")
    folder("DJ Video", model.store.paths.root)
    folder("App data", model.store.paths.appSupport)
    folder("Logs", model.store.paths.logs)
    folder("Backups", model.store.paths.backups)

    SettingsGroupHeader("Backups")
    SettingsRow("Daily backup", description: "Keeps 14 copies of the database.") {
      DSButton("Back up now", variant: .outline, size: .sm, tooltip: "Copy the database to Backups now") {
        var made: URL?
        if model.perform(nil, { made = try Backup.runIfDue(store: model.store) }) {
          model.show(made == nil ? "Today's backup already exists" : "Backup saved")
        }
      }
    }
    Color.clear.frame(height: 0)
      .task {
        let frozen = model.frozen
        loaded = await Task.detached { frozen ? true : LaunchAgent.isLoaded() }.value
      }
  }

  @ViewBuilder private var agentBadge: some View {
    switch loaded {
    case true?: DSBadge("Loaded", style: .soft(.success), help: "The background engine is loaded and runs on its own")
    case false?: DSBadge("Not loaded", style: .soft(.danger), help: "The background engine isn't loaded")
    case nil: DSSpinner(size: 12, color: DS.color.textTertiary)
    }
  }

  private func confirmInstall() {
    ui.confirm = SettingsConfirm(
      title: loaded == true ? "Reinstall the background engine?" : "Install the background engine?",
      message: "Writes the LaunchAgent for this copy of DJ Queue and loads it. The background copy takes over the engine and this window reopens there.",
      confirmTitle: loaded == true ? "Reinstall and load" : "Install and load", icon: "gearshape.2") {
        AppHost.shared.installLaunchAgent()
      }
  }

  private func confirmStop() {
    ui.confirm = SettingsConfirm(
      title: "Stop the background engine?",
      message: "Posts won't be prepared and reminders won't arrive until DJ Queue is opened again or the engine is reinstalled.",
      confirmTitle: "Stop and remove from login", destructive: true) {
        model.perform("Background engine stopped") { try LaunchAgent.uninstall(paths: model.store.paths, unload: true) }
        loaded = false
      }
  }

  private func folder(_ title: String, _ url: URL) -> some View {
    SettingsRow(title, description: url.path, isPath: true) {
      DSButton("Reveal", variant: .ghost, size: .sm, tooltip: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
  }
}

/// Settings → Engine → Auto-update (round 4 S5): the "Install updates from main" switch (config + watcher), what's
/// installed and what the last run did, Check now and the log. Rollback stays a CLI command on purpose.
struct AutoUpdateSettings: View {
  @Bindable var model: AppModel
  var updates = AutoUpdateUI.shared
  static let anchor = "autoupdate"

  var body: some View {
    SettingsGroupHeader("Auto-update").id(Self.anchor)
    SettingsRow("Install updates from main",
                description: "Builds and tests each new commit on main, backs up your data, then installs it when the window is closed.") {
      DSSwitch(isOn: Binding(get: { updates.enabled }, set: { updates.setEnabled($0) }))
        .dsTooltip(updates.enabled ? "Stop installing new commits (the app stays as it is)" : "Install each new commit on main once its tests pass")
        .accessibilityLabel("Install updates from main")
    }
    if let err = updates.settingsError {
      SettingsNote(err, icon: "exclamationmark.circle")
    }
    SettingsRow(installedLabel, description: statusLine, anchor: SettingsAnchor.row("Installed build")) {
      HStack(spacing: DS.space.xs) {
        statusBadges
        DSButton("Check now", variant: .outline, size: .sm, disabledReason: updates.checkBlockedReason,
                 tooltip: "Look for a new commit on main now (builds and tests it in the background)") {
          updates.checkNow()
          model.show("Checking for updates")
        }
      }
    }
    SettingsRow("Update log", description: "Every check, install and block is logged. To go back to the previous build, run djq autoupdate rollback in Terminal.") {
      DSButton("Open log", variant: .outline, size: .sm, disabledReason: updates.logURL == nil ? "No update log written yet." : nil,
               tooltip: "Open the auto-update log") { updates.openLog() }
    }
    Color.clear.frame(height: 0)
      .task {
        updates.attach(model.store.paths)
        updates.refresh()
      }
  }

  /// "Installed 0.5.0 (4f2c9a1)".
  private var installedLabel: String {
    guard let i = updates.state.installed ?? BundleInfo.build(Bundle.main.bundleURL) else { return "Installed build" }
    return "Installed \(i.version) (\(i.shortCommit))"
  }

  /// Now: the runner's phase; else what the last run did.
  private var statusLine: String {
    let s = updates.state
    if updates.isWorking || s.isRunning { return "Now: \(updates.workingLabel)." }
    if let last = s.last { return "Last check \(Fmt.relative(last.at, now: Date())): \(last.message)" }
    return updates.enabled ? "No check yet." : "Auto-update is off."
  }

  @ViewBuilder private var statusBadges: some View {
    let s = updates.state
    if updates.isWorking || s.isRunning {
      DSSpinner(size: 12, color: DS.color.textTertiary)
    }
    if let r = s.ready {
      DSBadge("\(r.version) ready", style: .soft(.info), size: .sm,
              help: "Installs when you close the window, or now with Restart & update in the banner")
    } else if let b = updates.problem {
      DSBadge(b.afterInstall ? "\(b.version) failed checks" : "\(b.version) blocked", style: .soft(.warning), size: .sm,
              help: b.afterInstall ? "\(b.reason) It's still installed; `djq autoupdate rollback --restore-db` goes back." : "\(b.reason) Nothing was installed.")
    }
  }
}
