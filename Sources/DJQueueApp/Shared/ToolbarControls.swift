import DJQCore
import SwiftUI

/// Quiet schedule chip for Queue and Calendar (DESIGN-v2 §3): "Scheduled through Sat 7 Nov", amber when the Queue is
/// running low. Click → popover with the numbers explained.
struct RunwayChip: View {
  @Bindable var model: AppModel
  @State private var open = false
  @State private var hovering = false

  private var low: Bool { model.queueRunningLow }
  private var text: String { model.scheduledText }

  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 6) {
        if low { DSStatusDot(tone: .warning, size: 6) }
        Text(text).font(DS.type.captionMedium.monospacedDigit()).lineLimit(1)
      }
      .foregroundStyle(low ? DS.color.warning : DS.color.textSecondary)
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(hovering ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(low ? DS.color.warning.opacity(0.5) : DS.color.border))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .onHover { hovering = $0 }
    .dsTooltip("See how many days are covered")
    .accessibilityLabel("\(text): \(model.runway.approvedDays) days scheduled, \(model.runway.readyDays) waiting in the Queue, \(editDays) in Edit")
    .dsPopover(isPresented: $open, width: 320) { RunwayDetail(model: model) }
  }

  private var editDays: Int { RunwayDetail.editDays(model.runway) }
}

/// The three numbers with what each means (popover content).
struct RunwayDetail: View {
  @Bindable var model: AppModel

  /// Days' worth of clips still in Edit.
  static func editDays(_ r: Runway) -> Int { max(0, r.totalDays - r.approvedDays - r.readyDays) }

  var body: some View {
    let s = model.settings
    VStack(alignment: .leading, spacing: DS.space.md) {
      DSEyebrow("Schedule")
      row(model.runway.approvedDays, "Scheduled", "Days in a row with a clip going out. Alert under \(s.approvedRunwayAlertDays) d.", model.queueRunningLow)
      row(model.runway.readyDays, "Queue waiting", "Queue clips with no day yet, at \(s.postsPerDay) a day.", false)
      row(Self.editDays(model.runway), "Edit left", "Scored clips still in Edit, at \(s.postsPerDay) a day. Record a new set when the total is under \(s.totalRunwayAlertDays) d.",
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
