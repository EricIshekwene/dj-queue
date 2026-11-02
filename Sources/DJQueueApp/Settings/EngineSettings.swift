import AppKit
import DJQCore
import SwiftUI

/// Engine: LaunchAgent install/stop (+ the last install error), engine heartbeat, wake, folders, log, backups.
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
    case true?: DSBadge("Loaded", style: .soft(.success), help: "The background engine is installed and running")
    case false?: DSBadge("Not loaded", style: .soft(.danger), help: "The background engine isn't running")
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
