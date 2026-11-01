import DJQCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
  case platforms, schedule, queue, alerts, rendering, text, engine
  var id: String { rawValue }
  var title: String {
    switch self {
    case .platforms: "Platforms"
    case .schedule: "Schedule"
    case .queue: "Queue"
    case .alerts: "Alerts"
    case .rendering: "Rendering"
    case .text: "Text & captions"
    case .engine: "Engine"
    }
  }

  var symbol: String {
    switch self {
    case .platforms: "square.stack.3d.up"
    case .schedule: "clock"
    case .queue: "list.number"
    case .alerts: "bell.badge"
    case .rendering: "film"
    case .text: "textformat"
    case .engine: "gearshape.2"
    }
  }
}

/// S.L (Linear preferences ref): section sidebar + grouped forms. Every change saves immediately.
struct SettingsView: View {
  @Bindable var model: AppModel
  @State var section: SettingsSection

  init(model: AppModel, initial: SettingsSection) {
    self.model = model
    _section = State(initialValue: initial)
  }

  var body: some View {
    NavigationSplitView {
      List(SettingsSection.allCases, selection: Binding<SettingsSection?>(get: { section }, set: { if let s = $0 { section = s } })) { s in
        Label(s.title, systemImage: s.symbol).tag(s)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    } detail: {
      Group {
        switch section {
        case .platforms: PlatformsSettings(model: model)
        case .schedule: ScheduleSettings(model: model)
        case .queue: QueueSettings(model: model)
        case .alerts: AlertsSettings(model: model)
        case .rendering: RenderingSettings(model: model)
        case .text: TextSettings(model: model)
        case .engine: EngineSettings(model: model)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(section.title)
    }
    .frame(minWidth: 760, minHeight: 520)
  }
}

/// Binding into a Settings key path that saves on set.
extension AppModel {
  func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { self.settings[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
  }
}

struct SettingRow<Content: View>: View {
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var content: Content
  var body: some View {
    LabeledContent {
      content
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let subtitle { Text(subtitle).font(DS.Font.secondary).foregroundStyle(.secondary) }
      }
    }
  }
}

// MARK: S.S1 Platforms

struct PlatformsSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Platforms") {
        ForEach(Platform.allCases.sorted()) { p in
          HStack(spacing: 10) {
            PlatformGlyph(platform: p, size: 22)
            VStack(alignment: .leading, spacing: 1) {
              Text(p.displayName)
              Link(p.uploadURL.host ?? "", destination: p.uploadURL).font(DS.Font.secondary)
            }
            Spacer()
            Toggle("Paused", isOn: Binding(get: { model.settings.pausedPlatforms.contains(p) }, set: { model.setPlatformPaused(p, $0) }))
              .toggleStyle(.checkbox)
              .disabled(!model.settings.enabledPlatforms.contains(p))
            Toggle("On", isOn: Binding(get: { model.settings.enabledPlatforms.contains(p) }, set: { on in
              model.update { if on { $0.enabledPlatforms.insert(p) } else { $0.enabledPlatforms.remove(p) } }
            }))
            .toggleStyle(.switch).labelsHidden()
          }
        }
      }
      Section {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          GridRow {
            Text("Platform").gridColumnAlignment(.leading)
            Text("Max length (s)")
            Text("Max size (MB)")
            Text("Caption chars")
            Text("Title chars")
          }
          .font(DS.Font.secondaryStrong).foregroundStyle(.secondary)
          ForEach(Platform.allCases.sorted()) { p in
            GridRow {
              Text(p.displayName)
              numberField(limit(p, \.maxDuration).map { Int($0) }) { v in setLimit(p) { $0.maxDuration = Double(v) } }
              numberField(limit(p, \.maxBytes).map { Int($0 / 1_000_000) }) { v in setLimit(p) { $0.maxBytes = Int64(v) * 1_000_000 } }
              numberField(limit(p, \.captionLimit)) { v in setLimit(p) { $0.captionLimit = v } }
              if p == .youtube {
                numberField(model.settings.limits[p]?.titleLimit) { v in setLimit(p) { $0.titleLimit = v } }
              } else {
                Text("—").foregroundStyle(.tertiary)
              }
            }
          }
        }
      } header: {
        Text("Limits")
      } footer: {
        Text("Used by validation (\"Too long for X\") and caption trimming.").font(DS.Font.secondary).foregroundStyle(.secondary)
      }
      Section("Publishing") {
        SettingRow(title: "Publisher", subtitle: "Phase 1: you post from the Mac browser; the app prepares file + caption.") {
          Text("Manual").foregroundStyle(.secondary)
        }
        SettingRow(title: "Postiz API key", subtitle: "Phase 2 — stored in the Keychain") {
          SecureField("Not available yet", text: .constant("")).frame(width: 200).disabled(true)
        }
      }
    }
  }

  private func limit<T>(_ p: Platform, _ kp: KeyPath<PlatformLimits, T>) -> T? { model.settings.limits[p]?[keyPath: kp] }

  private func setLimit(_ p: Platform, _ change: @escaping (inout PlatformLimits) -> Void) {
    model.update { s in
      var l = s.limits[p] ?? PlatformLimits.defaults[p]!
      change(&l)
      s.limits[p] = l
    }
  }

  private func numberField(_ value: Int?, _ set: @escaping (Int) -> Void) -> some View {
    TextField("", value: Binding(get: { value ?? 0 }, set: set), format: .number)
      .textFieldStyle(.roundedBorder)
      .multilineTextAlignment(.trailing)
      .frame(width: 90)
  }
}

// MARK: S.S2 Schedule (Buffer posting-slots ref)

struct ScheduleSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Posting") {
        SettingRow(title: "Posts per day", subtitle: "Each video goes to every enabled platform") {
          Stepper("\(model.settings.postsPerDay)", value: model.binding(\.postsPerDay), in: 1...5).fixedSize()
        }
        SettingRow(title: "Second post offset", subtitle: "Extra posts per day use the same slots, shifted") {
          Stepper("+\(model.settings.secondPostOffsetMinutes / 60) h", value: Binding(
            get: { model.settings.secondPostOffsetMinutes / 60 }, set: { v in model.update { $0.secondPostOffsetMinutes = v * 60 } }), in: 1...6).fixedSize()
        }
        SettingRow(title: "Post early", subtitle: "Allow posting any time on the day (decision Q3)") {
          Toggle("", isOn: model.binding(\.allowEarlyPosting)).labelsHidden().toggleStyle(.switch)
        }
        SettingRow(title: "Time zone") { Text(model.settings.timeZone).foregroundStyle(.secondary) }
      }
      Section("Slot times") {
        HStack(alignment: .top, spacing: 0) {
          ForEach(model.settings.activePlatforms) { p in
            VStack(spacing: 8) {
              PlatformGlyph(platform: p, size: 24)
              Text(p.displayName).font(DS.Font.secondary).lineLimit(1)
              DatePicker("", selection: timeBinding(p), displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.field)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            if p != model.settings.activePlatforms.last { Divider() }
          }
        }
        Button("Reset to defaults") {
          model.update { s in for p in Platform.allCases { s.slotMinutes[p] = p.defaultSlotMinutes } }
        }
        .buttonStyle(.link)
      }
      Section("Week") {
        SettingRow(title: "Week starts on") {
          Picker("", selection: model.binding(\.weekStartsOn)) {
            Text("Monday").tag(2)
            Text("Sunday").tag(1)
          }
          .labelsHidden().fixedSize()
        }
        SettingRow(title: "Approval reminder", subtitle: "Notification if next week isn't approved") {
          HStack {
            Picker("", selection: model.binding(\.approvalReminderWeekday)) {
              ForEach(1...7, id: \.self) { d in Text(Calendar(identifier: .gregorian).weekdaySymbols[d - 1]).tag(d) }
            }
            .labelsHidden().fixedSize()
            DatePicker("", selection: minutesBinding(\.approvalReminderMinutes), displayedComponents: .hourAndMinute).labelsHidden()
          }
        }
        SettingRow(title: "Repost cooldown", subtitle: "Days before the same video reposts on a platform") {
          Stepper("\(model.settings.repostCooldownDays) days", value: model.binding(\.repostCooldownDays), in: 1...90).fixedSize()
        }
        SettingRow(title: "Late grace", subtitle: "Still due this long after the slot; then the plan shifts") {
          Stepper("\(Int(model.settings.lateGraceHours)) h", value: model.binding(\.lateGraceHours), in: 1...12).fixedSize()
        }
        SettingRow(title: "Retry stagger", subtitle: "Re-queued failures post this long after the day's slot") {
          Stepper("\(Int(model.settings.retryStaggerHours)) h", value: model.binding(\.retryStaggerHours), in: 1...8).fixedSize()
        }
      }
    }
  }

  private func timeBinding(_ p: Platform) -> Binding<Date> {
    Binding(get: { Fmt.wallClock(model.now, minutes: model.settings.slot(for: p), calendar: model.dm.calendar) }, set: { d in
      model.update { $0.slotMinutes[p] = Fmt.minutesOfDay(d, calendar: model.dm.calendar) }
    })
  }

  private func minutesBinding(_ kp: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
    Binding(get: { Fmt.wallClock(model.now, minutes: model.settings[keyPath: kp], calendar: model.dm.calendar) }, set: { d in
      model.update { $0[keyPath: kp] = Fmt.minutesOfDay(d, calendar: model.dm.calendar) }
    })
  }
}

// MARK: S.S3 Queue

struct QueueSettings: View {
  @Bindable var model: AppModel
  var body: some View {
    Form {
      Section("Order") {
        SettingRow(title: "Sort", subtitle: "Reorders only the unplanned backlog") {
          Picker("", selection: model.binding(\.sort)) {
            ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        SettingRow(title: "Ties", subtitle: "Equal scores: older session first, then the night's order (part, start)") {
          Text("Older first").foregroundStyle(.secondary)
        }
      }
      Section("Per-platform sort") {
        ForEach(model.settings.activePlatforms) { p in
          SettingRow(title: p.displayName) {
            Picker("", selection: Binding<SortDirection?>(get: { model.settings.sortOverrides[p] }, set: { v in model.update { $0.sortOverrides[p] = v } })) {
              Text("Same as global").tag(SortDirection?.none)
              ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag(SortDirection?.some($0)) }
            }
            .labelsHidden().fixedSize()
          }
        }
      }
      Section("Spacing") {
        SettingRow(title: "Avoid overlapping clips", subtitle: "Off by default — your scores decide") {
          Toggle("", isOn: model.binding(\.avoidOverlap)).labelsHidden().toggleStyle(.switch)
        }
        SettingRow(title: "Within") {
          Stepper("\(model.settings.avoidOverlapDays) days", value: model.binding(\.avoidOverlapDays), in: 1...14).fixedSize()
        }
        .disabled(!model.settings.avoidOverlap)
      }
    }
  }
}

// MARK: S.S4 Alerts

struct AlertsSettings: View {
  @Bindable var model: AppModel
  var body: some View {
    Form {
      Section("Runway alerts") {
        SettingRow(title: "Approve next week", subtitle: "Banner + notification when approved runway is below") {
          Stepper("\(model.settings.approvedRunwayAlertDays) days", value: model.binding(\.approvedRunwayAlertDays), in: 1...14).fixedSize()
        }
        SettingRow(title: "Record a new set", subtitle: "When total runway is below") {
          Stepper("\(model.settings.totalRunwayAlertDays) days", value: model.binding(\.totalRunwayAlertDays), in: 3...60).fixedSize()
        }
      }
      Section("Always on") {
        SettingRow(title: "Copyright and failed posts", subtitle: "Red banner on every screen, red badge on the menu-bar icon") {
          StatusPill(text: "Loud", tint: .red, loud: true)
        }
        SettingRow(title: "Slot reminders", subtitle: "One notification per slot; silent if already posted") {
          StatusPill(text: "On", tint: .green)
        }
      }
    }
  }
}

// MARK: S.S5 Rendering

struct RenderingSettings: View {
  @Bindable var model: AppModel
  @State private var deleteDays = 30

  var body: some View {
    Form {
      Section("Audio") {
        SettingRow(title: "Loudness target", subtitle: "Integrated LUFS") {
          Stepper(String(format: "%.0f LUFS", model.settings.loudnessTarget), value: model.binding(\.loudnessTarget), in: -24 ... -8).fixedSize()
        }
        SettingRow(title: "True peak") {
          Stepper(String(format: "%.1f dBTP", model.settings.truePeak), value: model.binding(\.truePeak), in: -3...0, step: 0.5).fixedSize()
        }
        SettingRow(title: "Loudness range") {
          Stepper(String(format: "%.0f LU", model.settings.lra), value: model.binding(\.lra), in: 5...20).fixedSize()
        }
      }
      Section("Video") {
        SettingRow(title: "Bitrate") {
          Stepper("\(model.settings.videoBitrateKbps / 1000) Mbps", value: Binding(
            get: { model.settings.videoBitrateKbps / 1000 }, set: { v in model.update { $0.videoBitrateKbps = v * 1000 } }), in: 4...40).fixedSize()
        }
        SettingRow(title: "Render ahead", subtitle: "Approved posts are rendered this far ahead") {
          Stepper("\(model.settings.renderHorizonDays) days", value: model.binding(\.renderHorizonDays), in: 1...14).fixedSize()
        }
      }
      Section("Posted renders") {
        SettingRow(title: "Cleanup", subtitle: "What happens to renders once every platform is done") {
          Picker("", selection: Binding<Bool>(get: { if case .keep = model.settings.cleanup { true } else { false } }, set: { keep in
            model.update { $0.cleanup = keep ? .keep : .deleteAfter(days: deleteDays) }
          })) {
            Text("Keep forever").tag(true)
            Text("Delete after…").tag(false)
          }
          .labelsHidden().fixedSize()
        }
        if case .deleteAfter(let d) = model.settings.cleanup {
          SettingRow(title: "Delete after") {
            Stepper("\(d) days", value: Binding(get: { d }, set: { v in deleteDays = v; model.update { $0.cleanup = .deleteAfter(days: v) } }), in: 1...365).fixedSize()
          }
        }
      }
    }
  }
}

// MARK: S.S7 Engine

struct EngineSettings: View {
  @Bindable var model: AppModel
  @State private var loaded: Bool?
  @State private var confirmReinstall = false

  var body: some View {
    Form {
      Section("Background engine") {
        SettingRow(title: "LaunchAgent", subtitle: "Starts DJ Queue at login and keeps the engine running") {
          HStack {
            if let loaded { StatusPill(text: loaded ? "Loaded" : "Not loaded", tint: loaded ? .green : .red) } else { ProgressView().controlSize(.small) }
            Button("Reinstall…") { confirmReinstall = true }
          }
        }
        SettingRow(title: "Engine", subtitle: model.engineInProcess ? "Running in this app" : "Running in another process") {
          HStack {
            StateDot(tint: model.engineRunning ? .green : .red)
            Text(model.lastHeartbeat.map { "Last tick \(Fmt.relative($0.at, now: model.now))" } ?? "No heartbeat").foregroundStyle(.secondary)
            Button("Tick now") { model.runTick() }.disabled(model.engine == nil)
          }
        }
        SettingRow(title: "Wake before first slot", subtitle: "Schedules a Mac wake with pmset (needs admin). Off by default.") {
          Toggle("", isOn: model.binding(\.wakeBeforeFirstSlot)).labelsHidden().toggleStyle(.switch)
        }
      }
      Section("Folders") {
        folder("DJ Video", model.store.paths.root)
        folder("App data", model.store.paths.appSupport)
        folder("Logs", model.store.paths.logs)
        folder("Backups", model.store.paths.backups)
      }
      Section("Backups") {
        SettingRow(title: "Daily backup", subtitle: "Keeps 14 copies of the database") {
          Button("Back up now") {
            model.perform("Backup done") { _ = try Backup.runIfDue(store: model.store) }
          }
        }
      }
    }
    .task {
      let frozen = model.frozen
      loaded = await Task.detached { frozen ? true : LaunchAgent.isLoaded() }.value
    }
    .confirmationDialog("Reinstall the LaunchAgent?", isPresented: $confirmReinstall) {
      Button("Reinstall") {
        model.perform("LaunchAgent installed") { try LaunchAgent.install(appPath: Bundle.main.bundlePath, paths: model.store.paths) }
      }
    } message: {
      Text("Points ~/Library/LaunchAgents/com.djlovd.queue.engine.plist at \(Bundle.main.bundlePath).")
    }
  }

  private func folder(_ title: String, _ url: URL) -> some View {
    SettingRow(title: title, subtitle: url.path) {
      Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
  }
}
