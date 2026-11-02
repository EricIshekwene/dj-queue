import DJQCore
import SwiftUI

/// Quiet runway chip for Queue and Week toolbars (DESIGN-v2 §3): "Runway 5 d approved · 21 d ready", amber when
/// the approved runway is under its alert threshold. Click → popover with all three numbers explained.
struct RunwayChip: View {
  @Bindable var model: AppModel
  @State private var open = false
  @State private var hovering = false

  private var low: Bool { model.runway.approvedDays < model.settings.approvedRunwayAlertDays }

  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 6) {
        if low { DSStatusDot(tone: .warning, size: 6) }
        Text("Runway \(model.runway.approvedDays) d approved · \(model.runway.readyDays) d ready")
          .font(DS.type.captionMedium.monospacedDigit())
      }
      .foregroundStyle(low ? DS.color.warning : DS.color.textSecondary)
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(hovering ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(low ? DS.color.warning.opacity(0.5) : DS.color.border))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip("Runway: how many days of posts are covered")
    .accessibilityLabel("Runway: \(model.runway.approvedDays) days approved, \(model.runway.readyDays) ready, \(model.runway.totalDays) total")
    .dsPopover(isPresented: $open, width: 320) { RunwayDetail(model: model) }
  }
}

/// The three runway numbers with what each means (popover content).
struct RunwayDetail: View {
  @Bindable var model: AppModel
  var body: some View {
    let s = model.settings
    VStack(alignment: .leading, spacing: DS.space.md) {
      DSEyebrow("Runway")
      row(model.runway.approvedDays, "Approved", "Days covered by approved weeks. Alert under \(s.approvedRunwayAlertDays) d.",
          model.runway.approvedDays < s.approvedRunwayAlertDays)
      row(model.runway.readyDays, "Ready", "Ready clips not yet in an approved week, at \(s.postsPerDay) a day.", false)
      row(model.runway.totalDays, "Total", "Approved + ready + scored clips still in Edit. Record a new set under \(s.totalRunwayAlertDays) d.",
          model.runway.totalDays < s.totalRunwayAlertDays)
    }
    .padding(DS.space.sm)
  }

  private func row(_ d: Int, _ title: String, _ text: String, _ low: Bool) -> some View {
    HStack(alignment: .top, spacing: DS.space.sm) {
      Text("\(d) d").font(DS.type.score.monospacedDigit()).foregroundStyle(low ? DS.color.warning : DS.color.text)
        .frame(width: 60, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Text(text).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Toolbar kill switch (DESIGN-v2 §3 engine controls): a ghost pause button while posting runs (asks first), an
/// amber "Resume posting" capsule while paused.
struct PauseControl: View {
  @Bindable var model: AppModel

  var body: some View {
    if model.settings.paused {
      DSButton("Resume posting", icon: "play.fill", variant: .outline, size: .sm, tooltip: "Posting is paused — resume it") {
        model.setPaused(false)
      }
    } else {
      DSIconButton("pause.circle", tooltip: "Pause all posting", size: .sm) { model.confirmPause = true }
    }
  }
}
