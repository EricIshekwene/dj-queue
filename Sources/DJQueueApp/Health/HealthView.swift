import DJQCore
import SwiftUI

/// H.L: status tiles · 7-day awake timeline (incident.io ref) · Doctor findings (Customer.io ref).
struct HealthView: View {
  @Bindable var model: AppModel
  @State private var agentLoaded: Bool?
  @State private var disk: Int64?
  @State private var lastBackup: Date?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        tiles
        AwakeTimeline(model: model)
        doctor
      }
      .padding(DS.Space.xl)
      .frame(maxWidth: 1180)
      .frame(maxWidth: .infinity)
    }
    .task {
      if model.doctorReport == nil { model.runDoctor() }
      let paths = model.store.paths
      let frozen = model.frozen
      let r = await Task.detached { () -> (Bool, Int64?, Date?) in
        let loaded = frozen ? true : LaunchAgent.isLoaded()
        let free = (try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
          .volumeAvailableCapacityForImportantUsage
        let backups = (try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let last = backups.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        return (loaded, free, last)
      }.value
      agentLoaded = r.0
      disk = r.1
      lastBackup = r.2
    }
  }

  private var tiles: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
      Tile(title: "Engine", value: model.engineRunning ? "Running" : "Stopped", tint: model.engineRunning ? .green : .red,
           symbol: model.engineRunning ? "checkmark.circle.fill" : "xmark.octagon.fill",
           sub: agentLoaded == nil ? "Checking agent…" : (agentLoaded! ? "LaunchAgent loaded" : "LaunchAgent not loaded"))
      Tile(title: "Last tick", value: model.lastHeartbeat.map { Fmt.relative($0.at, now: model.now) } ?? "Never",
           tint: model.engineRunning ? .primary : .orange, symbol: "clock",
           sub: model.engine?.lastTick.map { "\($0.steps.count) steps\($0.errors.isEmpty ? "" : " · \($0.errors.count) errors")" } ?? model.lastHeartbeat?.kind.rawValue.capitalized)
      Tile(title: "Render queue", value: "\(model.renderQueue)", tint: .primary, symbol: "gearshape.2",
           sub: (model.engine?.isRendering ?? false) ? "Rendering" : "Idle")
      Tile(title: "Disk free", value: disk.map { Fmt.bytes($0) } ?? "—", tint: (disk ?? .max) < 50_000_000_000 ? .orange : .primary,
           symbol: "internaldrive", sub: (disk ?? .max) < 50_000_000_000 ? "Under 50 GB" : "OK")
      Tile(title: "Last backup", value: lastBackup.map { Fmt.relative($0, now: model.now) } ?? "None yet",
           tint: lastBackup.map { model.now.timeIntervalSince($0) < 2 * 86400 } ?? false ? .primary : .orange,
           symbol: "externaldrive.badge.timemachine", sub: "Daily, keeps 14")
      Tile(title: "ffmpeg", value: Tools.ffmpeg == nil ? "Missing" : "Installed", tint: Tools.ffmpeg == nil ? .red : .primary,
           symbol: "film.stack", sub: Tools.ffprobe == nil ? "ffprobe missing" : "ffprobe OK")
    }
  }

  private var doctor: some View {
    Card(padding: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Doctor").font(DS.Font.title)
            Text(model.doctorReport.map { "Checked \(Fmt.relative($0.generatedAt, now: model.now)) · \($0.passed.count) passed" } ?? "Not run yet")
              .font(DS.Font.secondary).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Open log", systemImage: "doc.text") { model.openLog() }
          Button("Run again", systemImage: "arrow.clockwise") { model.runDoctor() }.disabled(model.doctorRunning)
          Button("Copy report", systemImage: "doc.on.clipboard") { model.copyDoctorReport() }
            .buttonStyle(.borderedProminent).disabled(model.doctorReport == nil)
        }
        .padding(DS.Space.l)
        Divider()
        if model.doctorRunning && model.doctorReport == nil {
          ProgressView().frame(maxWidth: .infinity).padding(30)
        } else if let r = model.doctorReport {
          if r.findings.isEmpty {
            Label("Everything is running smoothly", systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(DS.Space.l)
          }
          ForEach(r.findings.sorted { $0.severity > $1.severity }) { f in
            FindingRow(finding: f)
            Divider()
          }
          if !r.passed.isEmpty {
            HStack(spacing: 8) {
              StatusPill(text: "OK", tint: .green, icon: "checkmark")
              Text(r.passed.joined(separator: " · ")).font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 12)
          }
        }
      }
    }
  }
}

struct Tile: View {
  let title: String
  let value: String
  var tint: Color = .primary
  var symbol: String
  var sub: String?

  var body: some View {
    Card(padding: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Label(title, systemImage: symbol).font(DS.Font.secondary).foregroundStyle(.secondary)
        Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        Text(sub ?? " ").font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

struct FindingRow: View {
  let finding: DoctorFinding
  @State private var expanded = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      StatusPill(text: finding.severity.rawValue.capitalized, tint: finding.severity.tint, icon: finding.severity.symbol)
        .frame(width: 86, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text(finding.title).font(DS.Font.bodyStrong)
        Text(finding.detail).font(DS.Font.body).foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("Fix").font(DS.Font.secondaryStrong).foregroundStyle(.secondary)
          Text(finding.fix).font(DS.Font.secondary)
        }
        if !finding.where_.isEmpty {
          DisclosureGroup(isExpanded: $expanded) {
            Text(finding.where_.joined(separator: "\n")).font(DS.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          } label: {
            Text("\(finding.where_.count) item\(finding.where_.count == 1 ? "" : "s")").font(DS.Font.secondary).foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
      Text(finding.id).font(DS.Font.mono).foregroundStyle(.tertiary)
    }
    .padding(.horizontal, DS.Space.l)
    .padding(.vertical, 12)
  }
}

/// H.S2: last 7 days, one bar per day; green = awake, grey = asleep/off, red tick = missed slot.
struct AwakeTimeline: View {
  @Bindable var model: AppModel

  var body: some View {
    let start = model.dm.date(model.dm.addDays(model.todayKey, -6))
    let awake = (try? Health.awakePeriods(store: model.store, since: start)) ?? []
    let missed = (try? Health.missedSlots(store: model.store, since: start)) ?? []
    let awakeHours = awake.reduce(0.0) { $0 + $1.duration } / 3600
    return Card {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Mac awake").font(DS.Font.title)
          Text("Last 7 days").font(DS.Font.body).foregroundStyle(.secondary)
          Spacer()
          legend(.green, "Awake")
          legend(Color.secondary.opacity(0.3), "Asleep / off")
          legend(.red, "Missed slot")
          Text(String(format: "%.0f h awake", awakeHours)).font(DS.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
        }
        ForEach(0..<7, id: \.self) { i in
          let day = model.dm.addDays(model.todayKey, i - 6)
          HStack(spacing: 10) {
            Text(Fmt.day(model.dm.date(day), tz: model.tz, style: "EEE d")).font(DS.Font.secondary.monospacedDigit())
              .foregroundStyle(day == model.todayKey ? Color.accentColor : .secondary).frame(width: 52, alignment: .leading)
            DayBar(model: model, day: day, awake: awake, missed: missed.filter { model.dm.key($0.scheduledAt) == day })
              .frame(height: 16)
            Text("\(missed.filter { model.dm.key($0.scheduledAt) == day }.count)").font(DS.Font.secondary.monospacedDigit())
              .foregroundStyle(missed.contains { model.dm.key($0.scheduledAt) == day } ? Color.red : Color.clear).frame(width: 14)
          }
        }
        HStack(spacing: 0) {
          Spacer().frame(width: 62)
          ForEach(["12a", "6a", "12p", "6p"], id: \.self) { h in
            Text(h).font(DS.Font.secondary).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
          }
          Spacer().frame(width: 24)
        }
      }
    }
  }

  private func legend(_ c: Color, _ t: String) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
      Text(t).font(DS.Font.secondary).foregroundStyle(.secondary)
    }
    .padding(.trailing, 6)
  }
}

struct DayBar: View {
  @Bindable var model: AppModel
  let day: String
  let awake: [DateInterval]
  let missed: [PlatformPost]

  var body: some View {
    GeometryReader { g in
      let start = model.dm.date(day)
      let w = g.size.width
      let segments = 96
      let segW = w / CGFloat(segments)
      ZStack(alignment: .leading) {
        // incident.io-style segmented bar: one tick per 15 minutes.
        HStack(spacing: 0) {
          ForEach(0..<segments, id: \.self) { i in
            let t0 = start.addingTimeInterval(Double(i) * 900)
            let future = t0 > model.now
            let on = !future && awake.contains { $0.start < t0.addingTimeInterval(900) && $0.end > t0 }
            RoundedRectangle(cornerRadius: 1)
              .fill(future ? Color.primary.opacity(0.04) : (on ? Color.green.opacity(0.8) : Color.secondary.opacity(0.25)))
              .frame(width: max(1, segW - 1.5))
              .frame(width: segW)
          }
        }
        ForEach(missed) { p in
          let x = w * p.scheduledAt.timeIntervalSince(start) / 86400
          RoundedRectangle(cornerRadius: 1).fill(Color.red).frame(width: 3, height: 20).offset(x: x - 1.5)
            .help("Missed: \(p.platform.displayName) \(Fmt.shortTime(p.scheduledAt, tz: model.tz))")
        }
      }
    }
  }
}
