import DJQCore
import SwiftUI

/// Calendar → Month (B7, DESIGN-v2 §6.4): `C.M` Buffer's month chips (thumb + time) with `C.M-alt` Cofounder's platform
/// dots. Whole weeks from `weekStartsOn`, 5 or 6 rows filling the height, days outside the month dimmed. A click on a
/// day's number or its empty area opens Day; chips drag to another day.
///
/// ```
/// Mon    Tue    Wed    Thu    Fri …
/// ┌──────┬──────┬──────┬──────┐
/// │ 2    │ 3    │ 4    │ (5)  │  today in the near-black capsule
/// │ ▮ title     │ ▮ title     │  chip: 16 × 28 thumb · one line of title · platform dots (glyphs at ≥ 150 pt)
/// │ ▮ ●●●●●●    │ +2 more     │  "+N more" opens Day
/// └──────┴──────┴──────┴──────┘
///                       12 in Queue waiting
/// ```
struct CalendarMonthView: View {
  @Bindable var model: AppModel
  let days: [String]
  @Environment(\.screenGutter) private var gutter

  private let headerHeight: CGFloat = 26

  var body: some View {
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    let month = Fmt.day(model.dm.date(model.calendarDay), tz: model.tz, style: "yyyy-MM")
    let waiting = model.calendarBacklog.count
    VStack(spacing: DS.space.xxs) {
      GeometryReader { g in
        let cellW = g.size.width / 7
        let cellH = max(44, (g.size.height - headerHeight) / CGFloat(max(1, weeks.count)))
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            ForEach(days.prefix(7), id: \.self) { d in
              Text(Fmt.day(model.dm.date(d), tz: model.tz, style: "EEE")).font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
                .padding(.leading, DS.space.xs)
                .frame(width: cellW, height: headerHeight, alignment: .leading)
            }
          }
          DSSeparator()
          ForEach(weeks, id: \.self) { w in
            HStack(spacing: 0) {
              ForEach(w, id: \.self) { d in
                CalendarMonthCell(model: model, day: d, inMonth: d.hasPrefix(month), width: cellW, height: cellH)
                  .overlay(alignment: .trailing) { if d != w.last { DSSeparator(vertical: true) } }
              }
            }
            .overlay(alignment: .bottom) { if w != weeks.last { DSSeparator() } }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.border))
      if waiting > 0 {
        Text("\(waiting) in Queue waiting").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .frame(height: 18)
          .dsTooltip("They get days as the \(AppModel.calendarHorizonDays)-day schedule moves on")
      }
    }
    .padding(.horizontal, gutter)
    .padding(.bottom, DS.space.sm)
  }
}

/// One day. As many chips as fit, then "+N more".
struct CalendarMonthCell: View {
  @Bindable var model: AppModel
  let day: String
  let inMonth: Bool
  let width: CGFloat
  let height: CGFloat
  @State private var targeted = false

  private static let chipHeight: CGFloat = 30
  private static let chipGap: CGFloat = 2
  private static let top: CGFloat = 28
  private static let moreHeight: CGFloat = 16

  var body: some View {
    let isToday = day == model.todayKey
    let isPast = day < model.todayKey
    let clips = model.calendarClips(day)
    let extras = model.calendarExtras(day)
    let total = clips.count + extras.count
    let room = max(0, Int((height - Self.top - 4 + Self.chipGap) / (Self.chipHeight + Self.chipGap)))
    let fits = total <= room ? total : max(0, Int((height - Self.top - 4 - Self.moreHeight) / (Self.chipHeight + Self.chipGap)))
    let shown = Array(clips.prefix(fits))
    let shownExtras = Array(extras.prefix(max(0, fits - shown.count)))
    VStack(alignment: .leading, spacing: Self.chipGap) {
      Text(Fmt.day(model.dm.date(day), tz: model.tz, style: "d"))
        .font(DS.type.captionMedium.monospacedDigit())
        .foregroundStyle(isToday ? DS.color.primaryText : inMonth ? DS.color.text : DS.color.textTertiary)
        .frame(minWidth: 22, minHeight: 22)
        .background(isToday ? DS.color.primary : .clear, in: Capsule())
        .frame(height: Self.top - Self.chipGap - 2, alignment: .center)
        .dsTooltip("Open this day")
      ForEach(shown) { c in CalendarMonthChip(model: model, clip: c, glyphs: width >= 150).opacity(isPast ? 0.6 : 1) }
      ForEach(shownExtras) { p in ExtraPostChip(model: model, post: p).frame(height: Self.chipHeight, alignment: .center) }
      if total > fits {
        Button("+\(total - fits) more") { model.openCalendarDay(day) }
          .buttonStyle(.plain)
          .font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
          .frame(height: Self.moreHeight)
          .padding(.leading, DS.space.xxs)
          .dsTooltip("Open this day")
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DS.space.xxs)
    .padding(.top, 2)
    .frame(width: width, height: height, alignment: .topLeading)
    .background(targeted ? DS.color.hover : inMonth ? .clear : DS.color.surfaceSunken.opacity(0.6))
    .contentShape(Rectangle())
    .onTapGesture { model.openCalendarDay(day) }
    .dropDestination(for: String.self) { items, _ in CalendarDrop.accept(items, on: day, model: model) } isTargeted: { targeted = $0 && !isPast }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Fmt.day(model.dm.date(day), tz: model.tz, style: "EEE d MMM"))
  }
}

/// 16 × 28 thumb · title · one dot per platform (a glyph once the cell is ≥ 150 pt wide).
struct CalendarMonthChip: View {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let glyphs: Bool
  @State private var hovering = false

  var body: some View {
    let blocker = model.calendarMoveBlocker(clip.slot, posts: clip.posts)
    HStack(spacing: DS.space.xxs + 1) {
      DSXThumb(model: model, video: clip.video, width: 16, post: clip.posts.values.min { $0.platform.rawValue < $1.platform.rawValue })
      VStack(alignment: .leading, spacing: 1) {
        Text(model.displayName(clip.video)).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.text).lineLimit(1)
        HStack(spacing: glyphs ? 3 : 2) {
          ForEach(clip.platforms, id: \.self) { p in mark(p) }
          if clip.slot.pinned {
            Image(systemName: "pin.fill").font(.system(size: 7, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
              .dsTooltip(CalendarWords.pinned)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 2)
    .frame(height: 30)
    .background(hovering ? DS.color.hover : .clear, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { model.openCalendarDay(clip.slot.date) }
    .modifier(SlotDrag(enabled: blocker == nil, id: clip.slot.id, poster: model.poster(clip.video)))
    .contextMenu { CalendarClipMenu(model: model, video: clip.video, slot: clip.slot, posts: clip.posts) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(model.displayName(clip.video)), \(model.calendarTimeRange(clip))")
  }

  @ViewBuilder private func mark(_ p: Platform) -> some View {
    let status = model.calendarStatus(clip, p)
    Group {
      if glyphs {
        Image(systemName: p.dsSymbol).font(.system(size: 8.5, weight: .medium))
          .foregroundStyle(status.problemTone != nil ? (status.dot ?? DS.color.textSecondary) : status == .posted ? DS.color.success : DS.color.textSecondary)
          .frame(width: 11, height: 11)
      } else {
        Circle().fill(status.dot ?? DS.color.textTertiary).frame(width: 6, height: 6).frame(width: 7, height: 11)
      }
    }
    .contentShape(Rectangle())
    .dsTooltip(model.calendarPlatformHelp(clip, p))
    .contextMenu { if let post = clip.posts[p] { PostContextMenu(model: model, post: post) } }
  }
}
