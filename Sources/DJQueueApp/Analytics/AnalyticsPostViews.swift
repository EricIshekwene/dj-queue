import Charts
import DJQCore
import SwiftUI

/// Round 39: one clip's numbers inside its quick look (Library) and preview (⌘K, Queue): views and likes so far per
/// post, and a way into Analytics. Nothing shows for a clip that hasn't posted.
struct ClipPerformanceSummary: View {
  @Bindable var model: AppModel
  let videoId: String

  var body: some View {
    let c = try? ClipAnalytics.build(store: model.store, videoId: videoId, now: model.now)
    if let c, !c.posts.isEmpty {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
          Text("Performance").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          Text("\(AnalyticsFmt.count(c.totalViews)) views · \(AnalyticsFmt.count(c.totalLikes)) likes · \(c.posts.count) post\(c.posts.count == 1 ? "" : "s")")
            .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          Spacer(minLength: 0)
          DSButton("Open Analytics", icon: "chart.xyaxis.line", variant: .ghost, size: .sm,
                   tooltip: "See how this clip compares over time") {
            model.previewVideo = nil
            BrowseUI.shared.quickLook = nil
            model.screen = .analytics
          }
        }
        let byPlatform = Dictionary(grouping: c.posts, by: \.platform)
        HStack(spacing: DS.space.md) {
          ForEach(DS.chart.order.filter { byPlatform[$0] != nil }) { p in
            let ps = byPlatform[p] ?? []
            let v = ps.compactMap(\.views).reduce(0, +)
            HStack(spacing: 5) {
              Circle().fill(DS.chart.color(p)).frame(width: 7, height: 7)
              Text("\(p.shortName) \(ps.contains { $0.views != nil } ? AnalyticsFmt.count(v) : "–")")
                .font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.text)
            }
            .dsTooltip("\(p.displayName): \(ps.count) post\(ps.count == 1 ? "" : "s")\(ps.contains { $0.views != nil } ? ", \(AnalyticsFmt.count(v)) views" : p == .x ? " (Postiz gives no numbers for X)" : ", no numbers yet")")
          }
          Spacer(minLength: 0)
        }
      }
      .padding(DS.space.sm)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .background(ScriptAnchor("Clip performance"))
    }
  }
}

/// Round 39: one post's views over time (each pull is a dot), when it was last asked and when it's asked next. In the
/// Posts inspector and the Calendar's numbers popover, above the fields for typing numbers in by hand.
struct PostNumbersHistory: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let c = try? ClipAnalytics.build(store: model.store, videoId: post.videoId, now: model.now)
    let line = c?.posts.first { $0.postId == post.id }
    let snaps = (line?.snapshots ?? []).filter { $0.views != nil }
    VStack(alignment: .leading, spacing: 6) {
      if snaps.count >= 2, let at = post.postedAt {
        Chart {
          ForEach(snaps, id: \.takenAt) { s in
            LineMark(x: .value("Days", s.takenAt.timeIntervalSince(at) / 86400), y: .value("Views", s.views ?? 0))
              .foregroundStyle(DS.chart.color(post.platform)).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
            PointMark(x: .value("Days", s.takenAt.timeIntervalSince(at) / 86400), y: .value("Views", s.views ?? 0))
              .foregroundStyle(DS.chart.color(post.platform)).symbolSize(16)
          }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in AxisValueLabel { Text(v.as(Double.self).map { "\(Int($0))d" } ?? "") } } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in AxisValueLabel { Text(v.as(Double.self).map(AnalyticsFmt.count) ?? "") } } }
        .frame(height: 70)
        .background(ScriptAnchor("Post numbers chart"))
        .dsTooltip("Views at each pull, by days after posting")
      }
      Text(caption(line, snaps)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func caption(_ line: ClipAnalytics.PostLine?, _ snaps: [PostSnapshot]) -> String {
    var parts: [String] = []
    if let last = snaps.last {
      let interactions = last.interactions.map { " · \(AnalyticsFmt.count($0)) interactions" } ?? ""
      parts.append("\(AnalyticsFmt.count(last.views)) views\(interactions), \(last.source == "manual" ? "typed in" : "from Postiz") \(Fmt.relative(last.takenAt, now: model.now))")
    } else if post.platform == .x && post.publisher == "postiz" {
      parts.append("Postiz gives no numbers for X; type them in if you want them here")
    } else if post.publisher != "postiz" {
      parts.append("Posted by hand: type its numbers in to see them in Analytics")
    } else {
      parts.append("No numbers yet")
    }
    if let n = line?.nextPull { parts.append("next pull \(n <= model.now ? "soon" : Fmt.relative(n, now: model.now))") }
    return parts.joined(separator: " · ")
  }
}
