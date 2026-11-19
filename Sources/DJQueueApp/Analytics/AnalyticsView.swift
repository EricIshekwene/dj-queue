import Charts
import DJQCore
import SwiftUI

/// Analytics (round 39, DECISIONS-R39.md; refs: TikTok Studio overview, X account overview, Base44 activity grid).
/// Job: show how DJ Lovd's posting is doing over time, and whether posting consistently pays off.
///
/// Toolbar: period (7D · 30D · 90D · All) and Refresh numbers. Sub-toolbar: platform chips (their colour dots are the
/// legend for every chart). Then: metric tabs (KPI tiles with a sparkline and the change from the period before) that
/// pick what the main chart shows · Consistency (streaks, posting heatmap, posts and views per week) · How posts grow
/// (median views by age) · First post vs repost, by version, by weekday · Top clips · Each platform's own numbers ·
/// What each platform gives.
struct AnalyticsView: View {
  @Bindable var model: AppModel
  @Bindable private var probe = AnalyticsProbe.shared

  var body: some View {
    ScreenScaffold(model: model, screen: .analytics, subtitle: subtitle) {
      DSSegmented(selection: $probe.range, segments: AnalyticsRange.allCases.map {
        DSSegment(value: $0, title: $0.label, tooltip: $0.longLabel)
      }, size: .sm)
      DSButton("Refresh numbers", icon: "arrow.clockwise", variant: .secondary, size: .sm, isLoading: probe.refreshing,
               tooltip: "Ask Postiz for the numbers that are due now (uses spare Postiz budget, never posts anything)") {
        probe.pullNow(model)
      }
    } subToolbar: {
      platformChips
    } content: {
      ScrollView {
        VStack(alignment: .leading, spacing: DS.space.xl) {
          if let r = probe.report {
            if r.tracking.postsPublished == 0 && r.tracking.snapshots == 0 {
              DSEmptyState(icon: "chart.xyaxis.line", title: "No numbers yet",
                           message: "Once posts go out, DJ Queue asks Postiz for their views and likes 12 hours later, then at 1, 3, 7, 14 and 30 days, and keeps each answer so trends build up.",
                           actionTitle: "Refresh numbers", actionIcon: "arrow.clockwise") { probe.pullNow(model) }
                .frame(maxWidth: .infinity)
            } else {
              AnalyticsBoard(model: model, report: r)
            }
          } else {
            DSSkeleton(height: 120)
            DSSkeleton(height: 320)
          }
        }
        .frame(maxWidth: 1240)
        .frame(maxWidth: .infinity)
        .modifier(BrowseGutter())
        .padding(.top, DS.space.xxs)
        .padding(.bottom, DS.space.xxxl)
      }
    }
    .task(id: loadKey) { await probe.load(model) }
  }

  /// Rebuilds when the app reloads (new snapshots, posts) or a choice changes.
  private var loadKey: String {
    "\(model.lastRefresh.timeIntervalSince1970)|\(probe.range.rawValue)|\(probe.platforms.map(\.rawValue).sorted())"
  }

  private var subtitle: String? {
    guard let t = probe.report?.tracking else { return nil }
    guard let last = t.lastSnapshot else { return "No numbers pulled yet" }
    return "Numbers from \(Fmt.relative(last, now: model.now)) · \(t.postsWithNumbers) of \(t.postsPublished) posts"
  }

  private var platformChips: some View {
    HStack(spacing: DS.space.xs) {
      DSChip("All platforms", isSelected: probe.platforms.isEmpty, showsCheck: false, size: .sm,
             tooltip: "Show every platform") { probe.platforms = [] }
      ForEach(DS.chart.order) { p in
        AnalyticsPlatformChip(platform: p, isSelected: probe.platforms.contains(p)) { probe.togglePlatform(p) }
      }
      Spacer(minLength: 0)
    }
  }
}

/// Every card, top to bottom (also drawn whole for the README still, `Shots+Analytics`).
struct AnalyticsBoard: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  @Bindable private var probe = AnalyticsProbe.shared

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xl) {
      AnalyticsKPIRow(report: report, selection: $probe.metric)
      AnalyticsMainChart(model: model, report: report, metric: probe.metric)
      AnalyticsConsistencyCard(model: model, report: report)
      AnalyticsCadenceCard(model: model, report: report)
      HStack(alignment: .top, spacing: DS.space.md) {
        AnalyticsCurvesCard(report: report).frame(maxWidth: .infinity)
        AnalyticsCompareCard(report: report).frame(maxWidth: .infinity)
      }
      AnalyticsTopClipsCard(model: model, report: report)
      AnalyticsChannelsCard(model: model, report: report)
      AnalyticsAvailabilityCard(report: report)
    }
  }
}

/// A platform chip whose dot is that platform's chart colour (the legend for every chart on the screen).
struct AnalyticsPlatformChip: View {
  let platform: Platform
  let isSelected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Circle().fill(DS.chart.color(platform)).frame(width: 8, height: 8)
        Text(platform.displayName).font(DS.type.caption.weight(.medium))
          .foregroundStyle(isSelected || hovering ? DS.color.text : DS.color.textSecondary)
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(isSelected ? DS.color.selected : hovering ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(isSelected ? DS.color.borderStrong : DS.color.border))
      .contentShape(Capsule())
      .background(ScriptAnchor("Analytics platform \(platform.displayName)"))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip(isSelected ? "Stop filtering to \(platform.displayName)" : "Show only \(platform.displayName) (pick more to compare)")
    .accessibilityLabel(platform.displayName)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Number formatting

enum AnalyticsFmt {
  static func count(_ v: Double?) -> String {
    guard let v else { return "–" }
    let a = abs(v)
    if a >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if a >= 10_000 { return String(format: "%.0fK", v / 1000) }
    if a >= 1000 { return String(format: "%.1fK", v / 1000).replacingOccurrences(of: ".0K", with: "K") }
    return String(Int(v.rounded()))
  }

  static func value(_ v: Double?, unit: String) -> String {
    guard let v else { return "–" }
    return unit == "percent" ? String(format: "%.1f%%", v) : count(v)
  }

  static func change(_ k: AnalyticsReport.KPI) -> (text: String, tone: DSTone, icon: String)? {
    guard let c = k.change, c.isFinite else { return nil }
    let up = c >= 0
    let text = k.unit == "percent" ? String(format: "%+.1f pts", c) : String(format: "%+.0f%%", c)
    return (text, abs(c) < 0.05 ? .neutral : up ? .success : .danger, up ? "arrow.up.right" : "arrow.down.right")
  }
}

// MARK: - Card shell

/// One analytics card: headline title, optional one-line description, trailing slot, content.
struct AnalyticsCard<Trailing: View, Content: View>: View {
  let title: String
  var description: String? = nil
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var content: Content

  init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
       @ViewBuilder content: () -> Content) {
    self.title = title
    self.description = description
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.md) {
      HStack(alignment: .top, spacing: DS.space.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
          if let description {
            Text(description).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: DS.space.sm)
        trailing
      }
      content
    }
    .padding(DS.space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous).strokeBorder(DS.color.border) }
    .dsElevation(DS.elevation.e1)
  }
}

/// "Not enough yet" inside a card.
struct AnalyticsNote: View {
  let icon: String
  let text: String
  var body: some View {
    HStack(spacing: DS.space.xs) {
      Image(systemName: icon).font(.system(size: 13)).foregroundStyle(DS.color.textTertiary)
      Text(text).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 80)
  }
}

/// Legend: a colour dot and the platform's name per platform shown (identity is never colour alone).
struct AnalyticsLegend: View {
  let platforms: [Platform]
  var body: some View {
    HStack(spacing: DS.space.sm) {
      ForEach(DS.chart.order.filter(platforms.contains)) { p in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2, style: .continuous).fill(DS.chart.color(p)).frame(width: 10, height: 10)
          Text(p.displayName).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        }
      }
    }
  }
}
