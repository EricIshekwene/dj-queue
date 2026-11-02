import DJQCore
import SwiftUI

/// Health (DESIGN-v2 §6.8, refs R2.HEALTH OpenAI service health + R2.HEALTH-alt Vanta OK / needs attention). Job:
/// prove the engine is running, and give Eric a report to paste.
///
/// Centred 880 column: header "● All systems running" (or "2 checks need attention", amber/red) with **Copy report**
/// and Run again · 7-day awake chart card · collapsible 48 pt check rows (Engine, Last tick, Render queue, Disk,
/// Backup, ffmpeg, LaunchAgent, Proxies) · Doctor findings (severity icon, what, where, fix). The toolbar ⋯ keeps
/// Run tick, Open log and Run Doctor.
struct HealthView: View {
  @Bindable var model: AppModel
  @Bindable private var probe = HealthProbe.shared
  @State private var expanded: Set<String> = []

  var body: some View {
    let checks = model.healthChecks(probe.current)
    ScreenScaffold(model: model, screen: .health, subtitle: model.doctorReport.map { "Checked \(Fmt.relative($0.generatedAt, now: model.now))" },
                   readingColumn: true) {
      Menu {
        Button("Run engine tick now", systemImage: "bolt.horizontal.circle") { model.runTick() }
        Button("Open engine log", systemImage: "doc.text") { model.openLog() }
        Button("Run Doctor again", systemImage: "stethoscope") { runAgain() }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
      }
      .menuStyle(.button)
      .buttonStyle(DSButtonStyle(variant: .ghost, size: .md, iconOnly: true))
      .menuIndicator(.hidden)
      .fixedSize()
      .dsTooltip("Engine tick, log, Doctor")
    } content: {
      ScrollView {
        VStack(alignment: .leading, spacing: DS.space.xl) {
          header(checks)
          AwakeChartCard(model: model, awake: probe.awake, missed: probe.missed)
          checkList(checks)
          doctor
        }
        .frame(maxWidth: DS.size.readingColumn)
        .frame(maxWidth: .infinity)
        .modifier(BrowseGutter())
        .padding(.top, DS.space.xxs)
        .padding(.bottom, DS.space.xxxl)
      }
    }
    .task {
      if model.doctorReport == nil && !model.frozen { model.runDoctor() }
      await probe.refresh(model)
      // Open the rows that need Eric, so their fix is visible at once.
      expanded.formUnion(model.healthChecks(probe.current).filter(\.needsAttention).map(\.id))
    }
  }

  private func runAgain() {
    model.runDoctor()
    Task { await probe.refresh(model) }
  }

  // MARK: Header

  /// Checks + Doctor warnings/errors that need Eric.
  private func attention(_ checks: [HealthCheck]) -> (count: Int, title: String, tone: DSTone) {
    let bad = checks.filter(\.needsAttention)
    let findings = (model.doctorReport?.findings ?? []).filter { $0.severity != .info }
    let n = bad.count + findings.count
    let danger = bad.contains { $0.tone == .danger } || findings.contains { $0.severity == .error }
    func plural(_ k: Int, _ w: String) -> String { "\(k) \(w)\(k == 1 ? "" : "s")" }
    let title: String
    switch (bad.count, findings.count) {
    case (0, 0): title = "All systems running"
    case (let c, 0): title = "\(plural(c, "check")) need\(c == 1 ? "s" : "") attention"
    case (0, let f): title = "\(plural(f, "Doctor finding")) need\(f == 1 ? "s" : "") attention"
    case (let c, let f): title = "\(plural(c, "check")) and \(plural(f, "finding")) need attention"
    }
    return (n, title, n == 0 ? .success : danger ? .danger : .warning)
  }

  private func header(_ checks: [HealthCheck]) -> some View {
    let a = attention(checks)
    return HStack(spacing: DS.space.sm) {
      Image(systemName: a.count == 0 ? "checkmark.circle.fill" : a.tone.symbol)
        .font(.system(size: 18, weight: .semibold)).foregroundStyle(a.tone.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(a.title)
          .font(DS.type.headline).foregroundStyle(DS.color.text)
        Text(summaryLine).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      }
      Spacer(minLength: DS.space.sm)
      DSButton("Run again", icon: "arrow.clockwise", variant: .outline, isLoading: model.doctorRunning || probe.loading,
               tooltip: "Check everything again") { runAgain() }
      DSButton("Copy report", icon: "doc.on.clipboard", variant: .primary,
               disabledReason: model.doctorReport == nil ? "Doctor is still checking" : nil,
               tooltip: "Copy the checks and Doctor findings as Markdown to paste to an agent") {
        model.copy(model.healthReportMarkdown(checks))
        model.show(DSToastModel(message: "Report copied", detail: "Paste it to your agent", tone: .success, duration: 4))
      }
    }
    .padding(.top, DS.space.xs)
  }

  private var summaryLine: String {
    var parts: [String] = [model.engineLine.text]
    if let r = model.doctorReport { parts.append("Doctor: \(r.passed.count) passed") }
    return parts.joined(separator: " · ")
  }

  // MARK: Checks

  private func checkList(_ checks: [HealthCheck]) -> some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      DSSectionHeader("Checks")
      VStack(spacing: 0) {
        ForEach(checks) { c in
          HealthCheckRow(check: c, expanded: expanded.contains(c.id)) {
            dsWithAnimation { if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) } }
          } perform: { perform($0) }
          if c.id != checks.last?.id { DSSeparator() }
        }
      }
      .padding(.horizontal, DS.space.md)
      .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous).strokeBorder(DS.color.border) }
      .dsElevation(DS.elevation.e1)
    }
  }

  private func perform(_ a: HealthCheck.Action) {
    switch a {
    case .runTick: model.runTick()
    case .openLog: model.openLog()
    case .runDoctor: runAgain()
    case .openEngineSettings:
      model.settingsSection = SettingsSection(rawValue: "engine") ?? model.settingsSection
      model.showSettings = true
    }
  }

  // MARK: Doctor

  private var doctor: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      DSSectionHeader("Doctor findings", count: model.doctorReport.map { $0.findings.count },
                      description: "Read-only checks of files, plan, renders and posts. Each finding has a safe fix.")
      if model.doctorReport == nil {
        HStack(spacing: DS.space.xs) {
          DSSpinner()
          Text("Doctor is checking…").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        }
        .padding(.vertical, DS.space.md)
      } else if let r = model.doctorReport {
        if r.findings.isEmpty {
          HStack(spacing: DS.space.xs) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.color.success)
            Text("No findings — every check passed").font(DS.type.callout).foregroundStyle(DS.color.text)
          }
          .padding(.vertical, DS.space.sm)
        } else {
          VStack(spacing: 0) {
            ForEach(r.findings.sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }) { f in
              DoctorFindingRow(finding: f)
              if f.id != r.findings.last?.id { DSSeparator() }
            }
          }
        }
        if !r.passed.isEmpty {
          Text("Passed: " + r.passed.joined(separator: " · ")).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            .padding(.top, DS.space.xs)
        }
      }
    }
  }
}

/// 48 pt check row with chevron; expanded → detail, suggested fix and its action.
struct HealthCheckRow: View {
  let check: HealthCheck
  let expanded: Bool
  let toggle: () -> Void
  let perform: (HealthCheck.Action) -> Void
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: DS.space.sm) {
          Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(check.tone.color).frame(width: 18)
          Text(check.title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).frame(width: 120, alignment: .leading)
          Text(check.value).font(DS.type.callout).foregroundStyle(check.needsAttention ? check.tone.color : DS.color.textSecondary)
            .lineLimit(1)
          Spacer(minLength: DS.space.xs)
          Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .frame(height: 48)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .dsTooltip(expanded ? "Hide details" : "Show details and fix")
      if expanded {
        VStack(alignment: .leading, spacing: DS.space.xs) {
          Text(check.detail).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
          if let fix = check.fix {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("Fix").font(DS.type.captionMedium).foregroundStyle(DS.color.text)
              Text(fix).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).textSelection(.enabled)
            }
          }
          if let a = check.action {
            DSButton(a.title, variant: .outline, size: .sm) { perform(a.1) }.padding(.top, 2)
          }
        }
        .padding(.leading, 30)
        .padding(.bottom, DS.space.md)
        .transition(.opacity)
      }
    }
  }

  private var icon: String {
    switch check.tone {
    case .success: "checkmark.circle.fill"
    case .neutral: "circle.dashed"
    default: check.tone.symbol
    }
  }
}

/// A Doctor finding: severity icon · what · where · fix · id.
struct DoctorFindingRow: View {
  let finding: DoctorFinding
  @State private var showAll = false

  var body: some View {
    HStack(alignment: .top, spacing: DS.space.sm) {
      Image(systemName: finding.severity.dsSymbol).font(.system(size: 15, weight: .semibold))
        .foregroundStyle(finding.severity.dsTone.color).frame(width: 18).padding(.top, 1)
        .dsTooltip(finding.severity.rawValue.capitalized)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(finding.title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          Spacer(minLength: DS.space.xs)
          Text(finding.id).font(DS.type.mono).foregroundStyle(DS.color.textTertiary).textSelection(.enabled)
        }
        Text(finding.detail).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        if !finding.where_.isEmpty {
          let shown = showAll ? finding.where_ : Array(finding.where_.prefix(3))
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, w in
              Text(w).font(DS.type.mono).foregroundStyle(DS.color.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if finding.where_.count > 3 {
              Button(showAll ? "Show fewer" : "Show all \(finding.where_.count)") { dsWithAnimation { showAll.toggle() } }
                .buttonStyle(.plain).font(DS.type.captionMedium).foregroundStyle(DS.color.accent)
            }
          }
          .padding(DS.space.xs)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("Fix").font(DS.type.captionMedium).foregroundStyle(DS.color.text)
          Text(finding.fix).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, DS.space.sm)
  }
}

extension Severity {
  var dsTone: DSTone {
    switch self {
    case .info: .info
    case .warning: .warning
    case .error: .danger
    }
  }

  var dsSymbol: String {
    switch self {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }
}
