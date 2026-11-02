import DJQCore
import SwiftUI

/// 7-day awake chart (DESIGN-v2 §6.8): r.lg card, 160 pt chart. One bar per day across 24 h; green = Mac awake
/// (engine heartbeats), grey = asleep or off, red ticks = missed slots; the future is left blank.
struct AwakeChartCard: View {
  @Bindable var model: AppModel
  let awake: [DateInterval]
  let missed: [PlatformPost]

  private let rowHeight: CGFloat = 12
  private let rowGap: CGFloat = 8
  private let labelWidth: CGFloat = 52

  var body: some View {
    let days = (0..<7).map { model.dm.addDays(model.todayKey, $0 - 6) }
    let hours = awake.reduce(0.0) { $0 + $1.duration } / 3600
    VStack(alignment: .leading, spacing: DS.space.md) {
      HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
        Text("Mac awake").font(DS.type.headline).foregroundStyle(DS.color.text)
        Text("Last 7 days · \(Int(hours.rounded())) h awake · \(missed.count) missed").font(DS.type.caption.monospacedDigit())
          .foregroundStyle(DS.color.textSecondary)
        Spacer(minLength: DS.space.sm)
        legend(DS.color.success, "Awake")
        legend(DS.color.selected, "Asleep / off")
        legend(DS.color.danger, "Missed slot")
      }
      VStack(alignment: .leading, spacing: rowGap) {
        ForEach(days, id: \.self) { day in
          HStack(spacing: DS.space.sm) {
            Text(Fmt.day(model.dm.date(day), tz: model.tz, style: "EEE d"))
              .font(day == model.todayKey ? DS.type.captionMedium : DS.type.caption)
              .foregroundStyle(day == model.todayKey ? DS.color.text : DS.color.textSecondary)
              .frame(width: labelWidth, alignment: .leading)
            AwakeDayBar(model: model, day: day, awake: awake, missed: missed.filter { model.dm.key($0.scheduledAt) == day })
              .frame(height: rowHeight)
          }
        }
        HStack(spacing: 0) {
          Color.clear.frame(width: labelWidth + DS.space.sm, height: 1)
          ForEach(["12 AM", "6 AM", "12 PM", "6 PM"], id: \.self) { h in
            Text(h).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(height: 160, alignment: .top)
    }
    .padding(DS.space.md)
    .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous).strokeBorder(DS.color.border) }
    .dsElevation(DS.elevation.e1)
  }

  private func legend(_ c: Color, _ t: String) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2, style: .continuous).fill(c).frame(width: 10, height: 10)
      Text(t).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
    }
    .padding(.leading, DS.space.xs)
  }
}

/// One day: awake periods as green spans over a grey track, missed slots as red ticks (tooltips name them).
struct AwakeDayBar: View {
  @Bindable var model: AppModel
  let day: String
  let awake: [DateInterval]
  let missed: [PlatformPost]

  var body: some View {
    GeometryReader { g in
      let start = model.dm.date(day)
      let end = start.addingTimeInterval(86400)
      let w = g.size.width
      let h = g.size.height
      let nowX = model.now < end ? max(0, w * model.now.timeIntervalSince(start) / 86400) : w
      ZStack(alignment: .leading) {
        // Past part of the day = asleep/off track; future stays blank.
        Capsule().fill(DS.color.surfaceSunken).frame(width: w, height: h)
        Capsule().fill(DS.color.selected).frame(width: max(0, nowX), height: h)
        ForEach(Array(spans(start: start, end: min(end, model.now)).enumerated()), id: \.offset) { _, s in
          let x0 = w * s.start.timeIntervalSince(start) / 86400
          let x1 = w * s.end.timeIntervalSince(start) / 86400
          RoundedRectangle(cornerRadius: h / 2, style: .continuous).fill(DS.color.success)
            .frame(width: max(2, x1 - x0), height: h).offset(x: x0)
            .dsTooltip("Awake \(AppModel.clockText(s.start, tz: model.tz)) – \(AppModel.clockText(s.end, tz: model.tz))")
        }
        ForEach(missed) { p in
          let x = w * p.scheduledAt.timeIntervalSince(start) / 86400
          RoundedRectangle(cornerRadius: 1).fill(DS.color.danger).frame(width: 3, height: h + 8).offset(x: x - 1.5)
            .dsTooltip("Missed: \(p.platform.displayName) \(AppModel.clockText(p.scheduledAt, tz: model.tz))")
        }
      }
      .frame(width: w, height: h, alignment: .leading)
    }
  }

  private func spans(start: Date, end: Date) -> [DateInterval] {
    guard end > start else { return [] }
    return awake.compactMap { a in
      let s = max(a.start, start), e = min(a.end, end)
      return e > s ? DateInterval(start: s, end: e) : nil
    }
  }
}
