import Charts
import DJQCore
import SwiftUI

// The Analytics screen's cards (round 39). Chart rules (data-viz method): one axis per chart (posts and views by week
// are two aligned charts, never a dual axis), thin marks, a legend whenever a chart has two or more series, recessive
// grid, platform colour follows the platform, a hover tooltip on every plot, and a table behind the main chart.

private func date(_ dm: DayMath, _ key: String) -> Date { dm.date(key) }

// MARK: - Metric tabs

struct AnalyticsKPIRow: View {
  let report: AnalyticsReport
  @Binding var selection: AnalyticsReport.KPIId

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: DS.space.sm)], spacing: DS.space.sm) {
      ForEach(report.kpis) { k in
        AnalyticsKPITile(kpi: k, range: report.range, isSelected: selection == k.id) { selection = k.id }
      }
    }
  }
}

struct AnalyticsKPITile: View {
  let kpi: AnalyticsReport.KPI
  let range: AnalyticsRange
  let isSelected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        Text(kpi.title).font(DS.type.captionMedium).foregroundStyle(isSelected ? DS.color.text : DS.color.textSecondary)
        Text(AnalyticsFmt.value(kpi.value, unit: kpi.unit))
          .font(.system(size: 24, weight: .semibold, design: .rounded))
          .foregroundStyle(DS.color.text)
          .lineLimit(1).minimumScaleFactor(0.7)
        HStack(spacing: 4) {
          if let c = AnalyticsFmt.change(kpi) {
            Image(systemName: c.icon).font(.system(size: 9, weight: .bold))
            Text(c.text).font(DS.type.micro.monospacedDigit())
          } else {
            Text(range == .all ? "All time" : "No earlier period").font(DS.type.micro)
          }
        }
        .foregroundStyle(AnalyticsFmt.change(kpi)?.tone.color ?? DS.color.textTertiary)
        AnalyticsSparkline(values: kpi.spark, color: isSelected ? DS.chart.accent : DS.color.textTertiary)
          .frame(height: 26)
      }
      .padding(DS.space.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isSelected ? DS.color.selected : hovering ? DS.color.hover.opacity(0.5) : DS.color.surface,
                  in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
          .strokeBorder(isSelected ? DS.color.text : hovering ? DS.color.borderStrong : DS.color.border, lineWidth: isSelected ? 2 : 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
      .background(ScriptAnchor("Analytics tab \(kpi.title)"))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip("\(kpi.title): \(kpi.note ?? "")\(kpi.change == nil ? "" : " · change vs the \(range == .all ? "" : "same length ")period before") · click to chart it")
    .accessibilityLabel("\(kpi.title) \(AnalyticsFmt.value(kpi.value, unit: kpi.unit))")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

struct AnalyticsSparkline: View {
  let values: [Double]
  var color: Color = DS.chart.accent
  var body: some View {
    Chart {
      ForEach(Array(values.enumerated()), id: \.offset) { i, v in
        AreaMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color.opacity(0.12)).interpolationMethod(.monotone)
        LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5))
          .interpolationMethod(.monotone)
      }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .accessibilityHidden(true)
  }
}

// MARK: - Main chart

struct AnalyticsMainChart: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  let metric: AnalyticsReport.KPIId
  @State private var hovered: String?
  @State private var asTable = false

  private var kpi: AnalyticsReport.KPI? { report.kpis.first { $0.id == metric } }
  private var stacked: Bool { [.views, .likes, .posts, .followers].contains(metric) }
  private var unit: Calendar.Component { report.bucket == "week" ? .weekOfYear : .day }

  private func value(_ b: AnalyticsReport.Bucket, _ p: Platform) -> Double {
    switch metric {
    case .views: b.views[p.rawValue] ?? 0
    case .likes: b.likes[p.rawValue] ?? 0
    case .posts: Double(b.posts[p.rawValue] ?? 0)
    case .followers: b.followers[p.rawValue] ?? 0
    default: 0
    }
  }

  private func single(_ b: AnalyticsReport.Bucket) -> Double? {
    switch metric {
    case .engagement: b.engagement
    case .viewsPerPost: b.viewsPerPost
    default: nil
    }
  }

  private var shownPlatforms: [Platform] {
    DS.chart.order.filter { p in report.platforms.contains(p) && report.timeline.contains { value($0, p) != 0 } }
  }

  var body: some View {
    AnalyticsCard("\(kpi?.title ?? "") over time",
                  description: "\(report.range.longLabel) · per \(report.bucket)\(caption.map { " · \($0)" } ?? "")") {
      DSSegmented(selection: $asTable, segments: [
        DSSegment(value: false, icon: "chart.bar.xaxis", tooltip: "Show as a chart"),
        DSSegment(value: true, icon: "tablecells", tooltip: "Show as a table"),
      ], size: .sm)
    } content: {
      if asTable { table } else { chart }
      if stacked && !shownPlatforms.isEmpty && !asTable { AnalyticsLegend(platforms: shownPlatforms) }
    }
  }

  private var caption: String? {
    switch metric {
    case .views, .likes: "spread evenly between pulls; before a post's first pull, along a typical early-heavy curve"
    case .followers: kpi?.note
    case .engagement: "likes, comments, shares and saves per view, each day"
    case .viewsPerPost: "median views of the posts that went out that \(report.bucket)"
    case .posts: "posts that went out"
    }
  }

  @ViewBuilder private var chart: some View {
    let dm = model.dm
    let hasData = stacked ? !shownPlatforms.isEmpty : report.timeline.contains { single($0) != nil }
    if !hasData {
      AnalyticsNote(icon: "hourglass", text: metric == .followers ? (kpi?.note ?? "No follower numbers") :
                      "Nothing to show for this period yet. Numbers arrive 12 hours after a post goes out.")
        .frame(height: 260)
    } else {
      Chart {
        ForEach(report.timeline) { b in
          if stacked {
            ForEach(shownPlatforms) { p in
              BarMark(x: .value("Day", date(dm, b.start), unit: unit), y: .value(kpi?.title ?? "", value(b, p)))
                .foregroundStyle(by: .value("Platform", p.displayName))
                .cornerRadius(2)
            }
          } else if let v = single(b) {
            LineMark(x: .value("Day", date(dm, b.start), unit: unit), y: .value(kpi?.title ?? "", v))
              .foregroundStyle(DS.chart.accent).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
            PointMark(x: .value("Day", date(dm, b.start), unit: unit), y: .value(kpi?.title ?? "", v))
              .foregroundStyle(DS.chart.accent).symbolSize(18)
          }
        }
        if let h = hovered, let b = report.timeline.first(where: { $0.start == h }) {
          RuleMark(x: .value("Day", date(dm, b.start), unit: unit))
            .foregroundStyle(DS.color.borderStrong)
            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
              tooltip(b)
            }
        }
      }
      .chartForegroundStyleScale(domain: shownPlatforms.map(\.displayName), range: shownPlatforms.map(DS.chart.color))
      .chartLegend(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
          AxisGridLine().foregroundStyle(DS.chart.grid)
          AxisValueLabel { Text(v.as(Double.self).map { metric == .engagement ? String(format: "%.0f%%", $0) : AnalyticsFmt.count($0) } ?? "") }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 7)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
      .chartOverlay { proxy in
        GeometryReader { g in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let pt):
                guard let plot = proxy.plotFrame else { return }
                let x = pt.x - g[plot].origin.x
                if let d: Date = proxy.value(atX: x) { hovered = nearest(d) }
              case .ended: hovered = nil
              }
            }
        }
      }
      .frame(height: 280)
      .accessibilityLabel("\(kpi?.title ?? "") per \(report.bucket), \(report.range.longLabel)")
    }
  }

  private func nearest(_ d: Date) -> String? {
    let dm = model.dm
    return report.timeline.min { abs(date(dm, $0.start).timeIntervalSince(d)) < abs(date(dm, $1.start).timeIntervalSince(d)) }?.start
  }

  private func tooltip(_ b: AnalyticsReport.Bucket) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label(b)).font(DS.type.captionSemibold)
      if stacked {
        let total = shownPlatforms.reduce(0) { $0 + value(b, $1) }
        Text("\(AnalyticsFmt.count(total)) \(kpi?.title.lowercased() ?? "")").font(DS.type.caption)
        ForEach(shownPlatforms.filter { value(b, $0) != 0 }) { p in
          HStack(spacing: 5) {
            Circle().fill(DS.chart.color(p)).frame(width: 7, height: 7)
            Text("\(p.displayName) \(AnalyticsFmt.count(value(b, p)))").font(DS.type.caption)
          }
        }
      } else {
        Text(single(b).map { AnalyticsFmt.value($0, unit: metric == .engagement ? "percent" : "count") } ?? "–").font(DS.type.caption)
      }
    }
    .foregroundStyle(DS.color.inverseText)
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(DS.color.inverseSurface, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
  }

  private func label(_ b: AnalyticsReport.Bucket) -> String {
    let d = date(model.dm, b.start)
    return report.bucket == "week" ? "Week of \(Fmt.day(d, tz: model.tz, style: "d MMM"))" : Fmt.day(d, tz: model.tz, style: "EEE d MMM")
  }

  private var table: some View {
    let cols = stacked ? shownPlatforms : []
    return ScrollView {
      Grid(alignment: .leading, horizontalSpacing: DS.space.md, verticalSpacing: 6) {
        GridRow {
          Text(report.bucket == "week" ? "Week" : "Day")
          ForEach(cols) { Text($0.shortName) }
          Text(stacked ? "Total" : kpi?.title ?? "")
        }
        .font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
        Divider().gridCellUnsizedAxes(.horizontal)
        ForEach(report.timeline.reversed()) { b in
          GridRow {
            Text(label(b))
            ForEach(cols) { p in Text(AnalyticsFmt.count(value(b, p))).monospacedDigit() }
            Text(stacked ? AnalyticsFmt.count(cols.reduce(0) { $0 + value(b, $1) })
                 : single(b).map { AnalyticsFmt.value($0, unit: metric == .engagement ? "percent" : "count") } ?? "–")
              .monospacedDigit().fontWeight(.medium)
          }
          .font(DS.type.caption).foregroundStyle(DS.color.text)
        }
      }
    }
    .frame(height: 280)
  }
}

// MARK: - Consistency

struct AnalyticsConsistencyCard: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  private let cell: CGFloat = 17, gap: CGFloat = 4

  var body: some View {
    let c = report.consistency
    AnalyticsCard("Consistency", description: "Every day posts went out, against the target of \(c.targetPerDay) a day (\(model.settings.postsPerDay) per platform × \(max(1, c.targetPerDay / max(1, model.settings.postsPerDay))) platforms)") {
      EmptyView()
    } content: {
      HStack(alignment: .top, spacing: DS.space.xxl) {
        Grid(alignment: .leading, horizontalSpacing: DS.space.xl, verticalSpacing: DS.space.md) {
          GridRow {
            stat("\(c.currentStreak)", "day streak", "Days in a row with at least one post, up to today")
            stat("\(c.longestStreak)", "longest streak", "The most days in a row with at least one post")
          }
          GridRow {
            stat("\(c.activeDays)/\(c.rangeDays)", "days posted", "Days in the period with at least one post")
            stat("\(c.daysOnTarget)/\(c.daysTracked)", "days on target", "Days since the first post that met the target of \(c.targetPerDay) posts")
          }
          GridRow {
            stat("\(c.missedInRange)", "missed", "Posts in the period whose slot never went out: failed with no retry coming, or missed (a skipped platform isn't a miss)", tone: c.missedInRange > 0 ? .warning : nil)
          }
        }
        .fixedSize()
        heatmap
        Spacer(minLength: 0)
      }
    }
  }

  private func stat(_ v: String, _ l: String, _ tip: String, tone: DSTone? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(v).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tone?.color ?? DS.color.text)
      HStack(spacing: 4) {
        if let tone { Image(systemName: tone.symbol).font(.system(size: 10)).foregroundStyle(tone.color) }
        Text(l).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      }
    }
    .dsTooltip(tip)
  }

  private func level(_ d: AnalyticsReport.DayCell) -> Int {
    guard d.posts > 0 else { return 0 }
    let t = max(1, report.consistency.targetPerDay)
    if d.posts >= t { return 5 }
    return min(4, max(1, Int((Double(d.posts) / Double(t) * 4).rounded(.up))))
  }

  private var heatmap: some View {
    let days = report.consistency.days
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min(days.count, $0 + 7)]) }
    let dm = model.dm
    return VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: gap) {
          VStack(alignment: .trailing, spacing: gap) {
            Color.clear.frame(height: 14)
            ForEach(0..<7, id: \.self) { i in
              let wd = (dm.calendar.firstWeekday - 1 + i) % 7
              Text(i % 2 == 0 ? dm.calendar.shortWeekdaySymbols[wd] : "").font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
                .frame(height: cell)
            }
          }
          .frame(width: 28)
          ForEach(Array(weeks.enumerated()), id: \.offset) { i, w in
            VStack(spacing: gap) {
              Text(monthLabel(w, i, weeks)).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).fixedSize().frame(width: cell, height: 14, alignment: .leading)
              ForEach(w) { d in dayCell(d) }
            }
          }
        }
      }
      HStack(spacing: 4) {
        Text("Less").font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
        ForEach(0..<DS.chart.heat.count, id: \.self) { i in
          RoundedRectangle(cornerRadius: 3, style: .continuous).fill(DS.chart.heat[i]).frame(width: 11, height: 11)
        }
        Text("More (target and above)").font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
        Circle().fill(DS.color.danger).frame(width: 6, height: 6).padding(.leading, DS.space.sm)
        Text("A post was missed").font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
        Spacer(minLength: 0)
      }
    }
  }

  private func monthLabel(_ w: [AnalyticsReport.DayCell], _ i: Int, _ weeks: [[AnalyticsReport.DayCell]]) -> String {
    guard let first = w.first else { return "" }
    let d = model.dm.date(first.day)
    let m = model.dm.calendar.component(.month, from: d)
    if i > 0, let prev = weeks[i - 1].first, model.dm.calendar.component(.month, from: model.dm.date(prev.day)) == m { return "" }
    return Fmt.day(d, tz: model.tz, style: "MMM")
  }

  private func dayCell(_ d: AnalyticsReport.DayCell) -> some View {
    let lv = level(d)
    let when = Fmt.day(model.dm.date(d.day), tz: model.tz, style: "EEE d MMM")
    let tip = d.isFuture
      ? "\(when) · \(d.planned) planned"
      : "\(when) · \(d.posts) post\(d.posts == 1 ? "" : "s") of \(report.consistency.targetPerDay)\(d.missed > 0 ? " · \(d.missed) missed" : "")"
    return RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(d.isFuture ? Color.clear : DS.chart.heat[lv])
      .overlay {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .strokeBorder(d.day == model.todayKey ? DS.color.text : d.isFuture ? DS.color.border : .clear, lineWidth: 1)
      }
      .overlay(alignment: .topTrailing) {
        if d.missed > 0 { Circle().fill(DS.color.danger).frame(width: 5, height: 5).offset(x: 1, y: -1) }
      }
      .frame(width: cell, height: cell)
      .dsTooltip(tip)
      .accessibilityLabel(tip)
  }
}

// MARK: - Posts and views by week (two aligned charts, one axis each)

struct AnalyticsCadenceCard: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  @State private var hovered: String?

  var body: some View {
    let weeks = report.consistency.weeks
    let dm = model.dm
    let domain = (weeks.first.map { date(dm, $0.weekStart) } ?? Date())...(weeks.last.map { dm.date(dm.addDays($0.weekStart, 7)) } ?? Date())
    AnalyticsCard("Posting and views by week",
                  description: "Does posting more pay off? Posts each week (dashed line: the target) above the views gained that week.") {
      EmptyView()
    } content: {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        Text("Posts").font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
        Chart {
          ForEach(weeks) { w in
            BarMark(x: .value("Week", date(dm, w.weekStart), unit: .weekOfYear), y: .value("Posts", w.posts))
              .foregroundStyle(DS.chart.accent).cornerRadius(2)
          }
          if let t = weeks.first?.target, t > 0 {
            RuleMark(y: .value("Target", t)).foregroundStyle(DS.color.textTertiary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          }
          hoverRule(weeks)
        }
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis { axis }
        .chartOverlay { hoverLayer($0, weeks) }
        .frame(height: 110)
        Text("Views gained").font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
        Chart {
          ForEach(weeks) { w in
            AreaMark(x: .value("Week", date(dm, w.weekStart), unit: .weekOfYear), y: .value("Views", w.views))
              .foregroundStyle(DS.chart.accent.opacity(0.12)).interpolationMethod(.monotone)
            LineMark(x: .value("Week", date(dm, w.weekStart), unit: .weekOfYear), y: .value("Views", w.views))
              .foregroundStyle(DS.chart.accent).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
          }
          hoverRule(weeks)
        }
        .chartXScale(domain: domain)
        .chartYAxis { axis }
        .chartXAxis {
          AxisMarks(values: weeks.map { date(model.dm, $0.weekStart) }.enumerated().filter { $0.offset % max(1, weeks.count / 8) == 0 }.map(\.element)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
          }
        }
        .chartOverlay { hoverLayer($0, weeks) }
        .frame(height: 130)
      }
    }
  }

  private var axis: some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
      AxisGridLine().foregroundStyle(DS.chart.grid)
      AxisValueLabel {
        Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "").frame(width: 34, alignment: .trailing)
      }
    }
  }

  @ChartContentBuilder private func hoverRule(_ weeks: [AnalyticsReport.WeekStat]) -> some ChartContent {
    if let h = hovered, let w = weeks.first(where: { $0.weekStart == h }) {
      RuleMark(x: .value("Week", date(model.dm, w.weekStart), unit: .weekOfYear))
        .foregroundStyle(DS.color.borderStrong)
        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
          Text("Week of \(Fmt.day(model.dm.date(w.weekStart), tz: model.tz, style: "d MMM")) · \(w.posts) posts · \(AnalyticsFmt.count(w.views)) views")
            .font(DS.type.caption).foregroundStyle(DS.color.inverseText)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(DS.color.inverseSurface, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
        }
    }
  }

  private func hoverLayer(_ proxy: ChartProxy, _ weeks: [AnalyticsReport.WeekStat]) -> some View {
    GeometryReader { g in
      Rectangle().fill(.clear).contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let pt):
            guard let plot = proxy.plotFrame, let d: Date = proxy.value(atX: pt.x - g[plot].origin.x) else { return }
            hovered = weeks.last { model.dm.date($0.weekStart) <= d }?.weekStart
          case .ended: hovered = nil
          }
        }
    }
  }
}

// MARK: - How posts grow

struct AnalyticsCurvesCard: View {
  let report: AnalyticsReport
  @State private var hoveredAge: Double?
  private let maxAge: Double = 30

  var body: some View {
    let one = report.platforms.count == 1
    let medians = report.curves.medians.filter { report.platforms.contains($0.platform) }
    let posts = one ? report.curves.posts.filter { $0.platform == report.platforms[0] }.prefix(80) : []
    AnalyticsCard("How posts grow", description: one
                  ? "Each \(report.platforms[0].displayName) post (grey) and the median (blue), views by days after posting"
                  : "Median views by days after posting, per platform. Pick one platform to see every post.") {
      EmptyView()
    } content: {
      if medians.isEmpty {
        AnalyticsNote(icon: "chart.line.uptrend.xyaxis", text: "Builds up as numbers come in: each post is asked at 12 hours, then 1, 3, 7, 14 and 30 days.")
          .frame(height: 220)
      } else {
        Chart {
          ForEach(Array(posts)) { c in
            ForEach(c.points.filter { $0.age <= maxAge }, id: \.age) { p in
              LineMark(x: .value("Days", p.age), y: .value("Views", p.views), series: .value("Post", c.postId))
                .foregroundStyle(DS.chart.context).lineStyle(StrokeStyle(lineWidth: 1))
            }
          }
          ForEach(medians) { m in
            ForEach(m.points.filter { $0.age <= maxAge }, id: \.age) { p in
              LineMark(x: .value("Days", p.age), y: .value("Views", p.views), series: .value("Median", m.platform.displayName))
                .foregroundStyle(one ? DS.chart.accent : DS.chart.color(m.platform))
                .lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
            }
          }
          if let a = hoveredAge {
            RuleMark(x: .value("Days", a)).foregroundStyle(DS.color.borderStrong)
              .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(a < 1 ? "12 hours after posting" : "Day \(Int(a)) after posting").font(DS.type.captionSemibold)
                  ForEach(medians) { m in
                    if let p = m.points.first(where: { $0.age == a }) {
                      Text("\(m.platform.displayName) \(AnalyticsFmt.count(p.views)) (median of \(p.n))").font(DS.type.caption)
                    }
                  }
                }
                .foregroundStyle(DS.color.inverseText)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(DS.color.inverseSurface, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
              }
          }
        }
        .chartXScale(domain: 0...maxAge)
        .chartXAxis {
          AxisMarks(values: [0, 3, 7, 14, 21, 30]) { v in
            AxisGridLine().foregroundStyle(DS.chart.grid)
            AxisValueLabel { Text(v.as(Double.self).map { "\(Int($0))d" } ?? "") }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(DS.chart.grid)
            AxisValueLabel { Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "") }
          }
        }
        .chartOverlay { proxy in
          GeometryReader { g in
            Rectangle().fill(.clear).contentShape(Rectangle())
              .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                  guard let plot = proxy.plotFrame, let x: Double = proxy.value(atX: pt.x - g[plot].origin.x) else { return }
                  hoveredAge = report.curves.ages.filter { $0 <= maxAge }.min { abs($0 - x) < abs($1 - x) }
                case .ended: hoveredAge = nil
                }
              }
          }
        }
        .frame(height: 220)
        if !one { AnalyticsLegend(platforms: medians.map(\.platform)) }
      }
    }
  }
}

// MARK: - Comparisons

struct AnalyticsCompareCard: View {
  let report: AnalyticsReport
  enum Mode: String { case repost, version, weekday }
  @State private var mode: Mode = .repost

  var body: some View {
    AnalyticsCard("What does better", description: "Median views after 7 days (posts at least a week old)") {
      DSSegmented(selection: $mode, segments: [
        DSSegment(value: .repost, title: "Reposts", tooltip: "First post of a clip vs its reposts, per platform"),
        DSSegment(value: .version, title: "Versions", tooltip: "v1 vs v2 vs v3 of the same clips"),
        DSSegment(value: .weekday, title: "Weekday", tooltip: "The day of the week a post went out"),
      ], size: .sm)
    } content: {
      switch mode {
      case .repost: repost
      case .version: groups(report.versions, empty: "No version has posts a week old yet.")
      case .weekday: groups(report.weekdays.filter { $0.posts > 0 }, empty: "No posts a week old yet.")
      }
    }
  }

  @ViewBuilder private var repost: some View {
    let rows = report.repostCompare.filter { $0.first.median != nil || $0.repost.median != nil }
    if rows.isEmpty {
      AnalyticsNote(icon: "arrow.2.squarepath", text: "No posts a week old with numbers yet.").frame(height: 220)
    } else {
      Chart {
        ForEach(rows) { r in
          ForEach([r.first, r.repost]) { g in
            if let m = g.median {
              BarMark(x: .value("Platform", r.platform.shortName), y: .value("Views", m))
                .position(by: .value("Post", g.label))
                .foregroundStyle(by: .value("Post", g.label))
                .cornerRadius(2)
                .annotation(position: .top, spacing: 2) {
                  Text(AnalyticsFmt.count(m)).font(DS.type.micro).foregroundStyle(DS.color.textSecondary)
                }
            }
          }
        }
      }
      .chartForegroundStyleScale(domain: ["First post", "Repost"], range: [DS.chart.accent, DS.chart.second])
      .chartLegend(position: .bottom, alignment: .leading)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
          AxisGridLine().foregroundStyle(DS.chart.grid)
          AxisValueLabel { Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "") }
        }
      }
      .frame(height: 220)
      Text(rows.map { "\($0.platform.shortName): \($0.first.posts) first, \($0.repost.posts) reposts" }.joined(separator: " · "))
        .font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
    }
  }

  @ViewBuilder private func groups(_ gs: [AnalyticsReport.GroupStat], empty: String) -> some View {
    if gs.allSatisfy({ $0.median == nil }) {
      AnalyticsNote(icon: "square.stack", text: empty).frame(height: 220)
    } else {
      Chart {
        ForEach(gs) { g in
          if let m = g.median {
            BarMark(x: .value("Group", g.label), y: .value("Views", m))
              .foregroundStyle(DS.chart.accent).cornerRadius(2)
              .annotation(position: .top, spacing: 2) {
                Text("\(AnalyticsFmt.count(m)) · \(g.posts)").font(DS.type.micro).foregroundStyle(DS.color.textSecondary)
              }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
          AxisGridLine().foregroundStyle(DS.chart.grid)
          AxisValueLabel { Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "") }
        }
      }
      .frame(height: 220)
      Text("Labels: median views · posts counted").font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
    }
  }
}

// MARK: - Top clips

struct AnalyticsTopClipsCard: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  @State private var showAll = false

  var body: some View {
    let rows = showAll ? report.topClips : Array(report.topClips.prefix(8))
    AnalyticsCard("Top clips", description: "Views gained in the period, every post of the clip on the chosen platforms. Click a clip to open it.") {
      if report.topClips.count > 8 {
        DSButton(showAll ? "Show fewer" : "Show \(report.topClips.count)", variant: .ghost, size: .sm,
                 tooltip: showAll ? "Show the top 8" : "Show every clip with numbers") { showAll.toggle() }
      }
    } content: {
      if rows.isEmpty {
        AnalyticsNote(icon: "film.stack", text: "No clip has numbers in this period yet.")
      } else {
        Grid(alignment: .leading, horizontalSpacing: DS.space.md, verticalSpacing: 0) {
          GridRow {
            Text("Clip").gridColumnAlignment(.leading)
            Text("Best on")
            Text("Posts").gridColumnAlignment(.trailing)
            Text("Views").gridColumnAlignment(.trailing)
            Text("Likes").gridColumnAlignment(.trailing)
            Text("Engagement").gridColumnAlignment(.trailing)
            Text("All-time views").gridColumnAlignment(.trailing)
            Text("Trend")
          }
          .font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
          .padding(.bottom, 6)
          ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
            Divider().gridCellUnsizedAxes(.horizontal)
            AnalyticsClipRow(model: model, rank: i + 1, clip: c)
          }
        }
      }
    }
  }
}

struct AnalyticsClipRow: View {
  @Bindable var model: AppModel
  let rank: Int
  let clip: AnalyticsReport.ClipStat
  @State private var hovering = false

  var body: some View {
    GridRow {
      Button {
        if let v = model.videoById[clip.videoId] { model.previewVideo = v }
      } label: {
        HStack(spacing: DS.space.xs) {
          Text("\(rank)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary).frame(width: 18, alignment: .trailing)
          Text(clip.title).font(DS.type.callout).foregroundStyle(hovering ? DS.color.accent : DS.color.text).lineLimit(1)
        }
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(ScriptAnchor("Analytics clip \(rank)"))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .dsTooltip("Open \(clip.title)")
      Group {
        if let p = clip.bestPlatform {
          HStack(spacing: 5) {
            Circle().fill(DS.chart.color(p)).frame(width: 7, height: 7)
            Text(p.shortName).font(DS.type.caption)
          }
          .dsTooltip("Most views on \(p.displayName)")
        } else { Text("–") }
      }
      Text("\(clip.posts)").monospacedDigit()
      Text(AnalyticsFmt.count(clip.views)).monospacedDigit().fontWeight(.medium)
      Text(AnalyticsFmt.count(clip.likes)).monospacedDigit()
      Text(clip.engagement.map { String(format: "%.1f%%", $0) } ?? "–").monospacedDigit()
      Text(AnalyticsFmt.count(clip.totalViews)).monospacedDigit()
      AnalyticsSparkline(values: clip.spark).frame(width: 80, height: 22)
    }
    .font(DS.type.callout)
    .foregroundStyle(DS.color.text)
    .padding(.vertical, 6)
  }
}

// MARK: - Each platform's own numbers

struct AnalyticsChannelsCard: View {
  @Bindable var model: AppModel
  let report: AnalyticsReport
  @Bindable private var probe = AnalyticsProbe.shared

  var body: some View {
    let byPlatform = Dictionary(grouping: report.channels, by: \.platform)
    let platforms = DS.chart.order.filter { report.platforms.contains($0) }
    AnalyticsCard("Each platform's own numbers",
                  description: "What each account reports through Postiz. Daily numbers are the platform's own; where it only gives a total (TikTok), DJ Queue keeps one a day so the line grows over time.") {
      EmptyView()
    } content: {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.space.md)], spacing: DS.space.md) {
        ForEach(platforms) { p in tile(p, byPlatform[p] ?? []) }
      }
    }
  }

  private func tile(_ p: Platform, _ trends: [AnalyticsReport.ChannelTrend]) -> some View {
    let chosen = probe.channelMetric[p].flatMap { l in trends.first { $0.label == l } }
      ?? trends.min { ($0.priority, $0.kind == "daily" ? 0 : 1, $0.label) < ($1.priority, $1.kind == "daily" ? 0 : 1, $1.label) }
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: 6) {
        Circle().fill(DS.chart.color(p)).frame(width: 8, height: 8)
        Text(p.displayName).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Spacer(minLength: 0)
        if trends.count > 1, let chosen {
          DSSelect(selection: Binding(get: { chosen.label }, set: { probe.channelMetric[p] = $0 }),
                   options: trends.map { DSSelectOption(value: $0.label, title: $0.label + ($0.kind == "total" ? " (total)" : "")) },
                   size: .sm, fullWidth: false)
        }
      }
      if let t = chosen, !t.points.isEmpty {
        Text(t.kind != "daily" ? "\(AnalyticsFmt.count(t.headline)) as of the last pull"
             : t.isAverage ? "\(t.headline.map { String(format: "%.1f", $0) } ?? "–") on average a day" : "\(AnalyticsFmt.count(t.headline)) in the period")
          .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        Chart {
          ForEach(t.points, id: \.date) { pt in
            if let d = Self.day(pt.date) {
              AreaMark(x: .value("Day", d, unit: .day), y: .value(t.label, pt.value))
                .foregroundStyle(DS.chart.color(p).opacity(0.14)).interpolationMethod(.monotone)
              LineMark(x: .value("Day", d, unit: .day), y: .value(t.label, pt.value))
                .foregroundStyle(DS.chart.color(p)).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
              if t.points.count == 1 { PointMark(x: .value("Day", d, unit: .day), y: .value(t.label, pt.value)).foregroundStyle(DS.chart.color(p)) }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
            AxisGridLine().foregroundStyle(DS.chart.grid)
            AxisValueLabel { Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "") }
          }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
        .frame(height: 120)
        .dsTooltip("\(t.label), \(t.kind == "daily" ? "per day" : "the platform's running total, one per day DJ Queue asked")")
      } else {
        Text(AnalyticsAvailability.base(p).note).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
      }
    }
    .padding(DS.space.sm)
    .background(DS.color.surfaceSunken.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
  }

  static func day(_ key: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: key)
  }
}

// MARK: - What each platform gives

struct AnalyticsAvailabilityCard: View {
  let report: AnalyticsReport

  var body: some View {
    AnalyticsCard("What each platform gives",
                  description: "Through Postiz, checked on DJ Lovd's channels \(AnalyticsAvailability.checkedOn). DJ Queue adds its own records to every platform: when each post went out, version, repost number, missed slots and score.") {
      EmptyView()
    } content: {
      Grid(alignment: .topLeading, horizontalSpacing: DS.space.md, verticalSpacing: 0) {
        GridRow {
          Text("Platform")
          Text("Per post")
          Text("Account, per day")
          Text("Account, totals only")
          Text("Followers")
        }
        .font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary).padding(.bottom, 6)
        ForEach(DS.chart.order.compactMap { p in report.availability.first { $0.platform == p } }) { a in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            HStack(spacing: 6) {
              Circle().fill(DS.chart.color(a.platform)).frame(width: 7, height: 7)
              Text(a.platform.displayName).font(DS.type.calloutMedium)
            }
            cell(a.postMetrics)
            cell(a.channelDaily)
            cell(a.channelTotals)
            Text(a.followers ?? "Not given").foregroundStyle(a.followers == nil ? DS.color.textTertiary : DS.color.text)
          }
          .font(DS.type.caption)
          .padding(.vertical, 6)
          GridRow {
            Color.clear.frame(height: 0)
            Text(a.note).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).gridCellColumns(4)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.bottom, 6)
        }
      }
    }
  }

  private func cell(_ xs: [String]) -> some View {
    Text(xs.isEmpty ? "Nothing" : xs.joined(separator: ", "))
      .foregroundStyle(xs.isEmpty ? DS.color.textTertiary : DS.color.text)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 220, alignment: .leading)
  }
}
