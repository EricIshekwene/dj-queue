import DJQCore
import SwiftUI

/// Calendar → 3 Day and Week (B5, B6): one column per day, day headers fixed, cards scrolling. `C.W` TikTok Studio
/// scheduler (9:16 covers in columns) + Hootsuite week cards (image card, time, state).
///
/// ```
/// Week                                                3 Day
/// Mon 2   Tue 3   Wed 4   Thu 5   Fri 6 …             Thu 5              Fri 6              Sat 7
/// ┌────┐  ┌────┐  ┌────┐  ┌╌╌╌╌┐                      ┌───┬────────────┐ ┌───┬────────────┐ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
/// │9:16│  │    │  │    │  ╎Open╎                      │9:16 title      │ │    title       │ ╎ Open           ╎
/// └────┘  └────┘  └────┘  └╌╌╌╌┘                      │    ♪ 7:00 PM ● │ │    ♪ 7:00 PM ● │ ╎ Next from the  ╎
/// title · 12:30 PM – 7 PM · ⓣⓘⓕⓨⓣⓧ                    └───┴────────────┘ └───┴────────────┘ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
/// ```
/// Drag a card onto another day to move it (a full day swaps); past days are 50 % and refuse drops.
///
/// Round 21 (Buffer's week cards, Klaviyo's time cards): a set-time item shows its own clock time with a clock mark and
/// sits among the day's cards by that time; a photo post shows its first photo at the post's shape with "Photo" or
/// "Carousel · N", and nothing about it plays.
struct CalendarColumns: View {
  enum Style { case threeDay, week }

  @Bindable var model: AppModel
  let days: [String]
  let style: Style
  @Environment(\.screenGutter) private var gutter

  var body: some View {
    let gap = DS.space.sm
    let clips = days.flatMap { model.calendarClips($0).map(\.video) }
    let ids = clips.map(\.id)
    // A photo post has nothing to play: it never asks for a proxy.
    let playable = clips.filter { !$0.isPhoto }.map(\.id)
    GeometryReader { g in
      let n = CGFloat(days.count)
      let colW = max(96, (g.size.width - 2 * gutter - (n - 1) * gap) / n)
      VStack(spacing: 0) {
        HStack(spacing: gap) {
          ForEach(days, id: \.self) { d in WeekDayHeader(model: model, day: d).frame(width: colW) }
        }
        .padding(.horizontal, gutter)
        .padding(.bottom, gap)
        ScrollView {
          HStack(alignment: .top, spacing: gap) {
            ForEach(days, id: \.self) { d in
              CalendarDayColumn(model: model, day: d, style: style, width: colW).frame(width: colW)
            }
          }
          .padding(.horizontal, gutter)
          .padding(.bottom, DS.space.xl)
        }
        .scrollIndicators(.automatic)
      }
    }
    .task(id: ids.joined(separator: ",") + "|\(model.playback.autoplay)|\(model.playback.loop.rawValue)") {
      for id in ids { if let v = model.video(id) { model.requestPoster(v) } }
      guard model.playback.autoplay else { return }
      model.requestProxies(playable)
    }
  }
}

/// "Thu 5" (callout semibold); today in a near-black capsule; awake strip under past days and today. A click opens
/// the day.
struct WeekDayHeader: View {
  @Bindable var model: AppModel
  let day: String

  var body: some View {
    let isToday = day == model.todayKey
    let isPast = day < model.todayKey
    let text = Fmt.day(model.dm.date(day), tz: model.tz, style: "EEE d")
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(DS.type.calloutSemibold.monospacedDigit())
        .foregroundStyle(isToday ? DS.color.primaryText : isPast ? DS.color.textTertiary : DS.color.text)
        .padding(.horizontal, isToday ? 10 : 0)
        .frame(height: 24)
        .background(isToday ? DS.color.primary : .clear, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture { model.openCalendarDay(day) }
        .dsTooltip("Open this day")
      if isToday || (isPast && day >= model.calendarAwakeLimit) {
        AwakeStrip(model: model, day: day, awake: model.calendarData.awake)
      } else {
        Color.clear.frame(height: 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isToday ? "Today, \(text)" : text)
  }
}

/// One day: its cards, retries and reposts, or the quiet "Open" placeholder.
struct CalendarDayColumn: View {
  @Bindable var model: AppModel
  let day: String
  let style: CalendarColumns.Style
  let width: CGFloat
  @State private var targeted = false

  private var isPast: Bool { day < model.todayKey }

  var body: some View {
    let clips = model.calendarClips(day)
    let extras = model.calendarExtras(day)
    VStack(alignment: .leading, spacing: DS.space.xs) {
      ForEach(clips) { c in
        switch style {
        case .week: CalendarWeekCard(model: model, clip: c, isPast: isPast, width: width)
        case .threeDay: CalendarThreeDayCard(model: model, clip: c, isPast: isPast)
        }
      }
      ForEach(extras) { p in ExtraPostChip(model: model, post: p).opacity(isPast ? 0.5 : 1) }
      if clips.isEmpty {
        CalendarOpenDay(model: model, day: day, targeted: targeted, height: style == .week ? width * 16 / 9 : CalendarCover.smallHeight + 2 * DS.space.xs)
          .opacity(isPast ? 0.5 : 1)
      } else if !isPast, model.calendarFilter == nil, clips.allSatisfy({ $0.slot.isExact }), model.calendarDayCanFill(day) {
        // Only set-time items here: they take none of the day's regular places, so the day is still open (D12).
        CalendarOpenDay(model: model, day: day, targeted: targeted, height: 72)
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .background {
      if targeted { RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).fill(DS.color.hover).padding(-DS.space.xxs) }
    }
    .overlay {
      if targeted {
        RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
          .strokeBorder(DS.color.text.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).padding(-DS.space.xxs)
      }
    }
    .dropDestination(for: String.self) { items, _ in CalendarDrop.accept(items, on: day, model: model) } isTargeted: { targeted = $0 && !isPast }
  }
}

/// What a drop on a day does in every view: "slot:<id>" moves that clip. Past days refuse, in words.
@MainActor
enum CalendarDrop {
  static func accept(_ items: [String], on day: String, model: AppModel) -> Bool {
    guard let item = items.first, item.hasPrefix("slot:") else { return false }
    return model.calendarMove(slotId: String(item.dropFirst(5)), to: day)
  }
}

/// The dashed day with no card, saying what will fill it, and only what's true: a day the filter emptied isn't open,
/// and today stops promising once no position has time left. Past days only say nothing went out.
struct CalendarOpenDay: View {
  @Bindable var model: AppModel
  let day: String
  let targeted: Bool
  let height: CGFloat

  var body: some View {
    let f = model.calendarFilter
    VStack(spacing: DS.space.xxs) {
      if let f, model.calendarDayIsTaken(day) {
        Text("Nothing on \(f.dsxCompactName)").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      } else if day < model.todayKey {
        Text("Nothing posted").font(DS.type.calloutMedium).foregroundStyle(DS.color.textTertiary)
      } else if !model.calendarDayCanFill(day) {
        Text("Nothing going out").font(DS.type.calloutMedium).foregroundStyle(DS.color.textTertiary)
      } else {
        Text("Open").font(DS.type.calloutMedium).foregroundStyle(DS.color.textTertiary)
        if model.settings.paused {
          Text("Posting paused").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        } else if !model.schedulable.isEmpty {
          Text("Next from the Queue").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        } else {
          Text("Queue is empty").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
          DSButton("Go to Edit", variant: .ghost, size: .sm, tooltip: "Send more clips to the Queue") { model.screen = .edit }
        }
      }
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, DS.space.xxs)
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .background(targeted ? DS.color.hover : .clear, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
        .strokeBorder(targeted ? DS.color.text.opacity(0.5) : DS.color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
  }
}

/// A clip's 9:16 cover: the post's version as it will post. A small preview, so it plays only while hovered, and
/// muted because the Calendar is an overview (its mute button plays the sound). With "play on hover only" off, past
/// days still wait for the pointer.
struct CalendarCover: View {
  /// 3 Day's cover.
  static let smallWidth: CGFloat = 96
  static let smallHeight: CGFloat = 171

  @Bindable var model: AppModel
  let clip: CalendarClip
  let isPast: Bool
  let hovering: Bool
  let width: CGFloat

  private var firstPost: PlatformPost? { clip.posts.values.min { $0.platform.rawValue < $1.platform.rawValue } }

  var body: some View {
    if clip.video.isPhoto {
      CalendarPhotoCover(model: model, clip: clip, width: width)
    } else {
      player
    }
  }

  private var player: some View {
    let p = model.playback
    let pv = firstPost.flatMap { model.clipPreview(post: $0) } ?? model.clipPreview(clip.video)
    return DSVideoPreview(url: pv.proxyURL, poster: pv.cover,
                   isActive: PreviewPlayback.plays(p, layout: .grid, hovered: hovering, focused: false) && (hovering || !isPast),
                   isPriority: hovering, loopRange: pv.loopRange, unmuteOnHover: false, isHovered: hovering, muteAlignment: .bottomTrailing,
                   overlays: pv.overlays, isUpdating: pv.isUpdating, updatingStyle: .label,
                   needsOverlay: pv.overlayMissing, onNeedsOverlay: { model.reloadOverlay(clip.video.id, version: pv.version) })
      .task(id: pv.stamp) { if let f = firstPost { model.requestPreview(post: f) } else { model.requestPreview(clip.video) } }
      .frame(width: width, height: width * 16 / 9)
  }
}

/// A photo post's cover: its first photo as it posts, at the post's own shape (4:5 by default), never taller than a
/// clip's cover. A still picture: no player, no hover playback, no proxy.
struct CalendarPhotoCover: View {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let width: CGFloat

  private var firstPost: PlatformPost? { clip.posts.values.min { $0.platform.rawValue < $1.platform.rawValue } }

  var body: some View {
    let img = firstPost.flatMap { model.clipPreview(post: $0)?.cover } ?? model.poster(clip.video)
    // Width over height of the picture as it posts; 4:5 until it has loaded.
    let ratio = img.flatMap { $0.size.height > 0 ? $0.size.width / $0.size.height : nil } ?? 0.8
    let height = min(width / max(ratio, 0.1), width * 16 / 9)
    Group {
      if let img {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        DSPosterPlaceholder()
      }
    }
    .frame(width: width, height: height)
    .clipped()
    .overlay(alignment: .bottomTrailing) { CalendarPhotoMark(video: clip.video).padding(DS.space.xxs) }
    .task(id: firstPost.map { model.previewStamp($0.videoId, version: $0.versionNo) } ?? model.previewStamp(clip.video.id)) {
      if let f = firstPost { model.requestPreview(post: f) } else { model.requestPoster(clip.video) }
    }
    .accessibilityLabel(clip.video.photoLabel ?? "Photo")
  }
}

/// "Photo" / "Carousel · 3" on a cover, in the dark capsule the pin and clock marks use on media.
struct CalendarPhotoMark: View {
  let video: Video

  var body: some View {
    if let label = video.photoLabel {
      HStack(spacing: 3) {
        Image(systemName: video.isCarousel ? "square.on.square" : "photo").font(.system(size: 8.5, weight: .semibold))
        Text(label).font(DS.type.microCompact).lineLimit(1)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(Color.black.opacity(0.55), in: Capsule())
      .dsTooltip(video.isCarousel ? "A carousel of \(video.photoCount) photos — the first is the cover" : "A photo post")
      .accessibilityLabel(label)
      .background(ScriptAnchor("Photo mark \(video.id)"))
    }
  }
}

/// The set-time mark beside a card's time: a small clock and the exact minute ("3:15 PM"), with what it means on hover.
struct CalendarSetTimeMark: View {
  @Bindable var model: AppModel
  let slot: PlanSlot
  /// The day the card shows on, when it can differ from the slot's (Day view): the mark then names the weekday.
  var day: String? = nil

  var body: some View {
    if let exact = slot.exactAt {
      let other = day.map { $0 != slot.date } ?? false
      HStack(spacing: 3) {
        Image(systemName: "clock").font(.system(size: 9.5, weight: .semibold))
        Text((other ? Fmt.day(exact, tz: model.tz, style: "EEE") + " " : "") + AppModel.clockText(exact, tz: model.tz))
          .font(DS.type.captionMedium.monospacedDigit()).lineLimit(1)
      }
      .foregroundStyle(DS.color.text)
      .contentShape(Rectangle())
      .dsTooltip(model.setTimeHelp(slot))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.setTimeHelp(slot) ?? "Set time")
      .background(ScriptAnchor("Set time mark \(slot.id)"))
    }
  }
}

/// Pin glyph and "1 failed" on a cover's top-left corner; hover ⋯ on its bottom-left.
private struct CoverBadges: ViewModifier {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let isPast: Bool
  let hovering: Bool

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topLeading) {
        HStack(spacing: 4) {
          if clip.slot.isExact {
            // A set time is always pinned; the clock says the stronger thing.
            Image(systemName: "clock.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
              .frame(width: 20, height: 20).background(Color.black.opacity(0.55), in: Circle())
              .dsTooltip(model.setTimeHelp(clip.slot))
          } else if clip.slot.pinned {
            Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
              .frame(width: 20, height: 20).background(Color.black.opacity(0.55), in: Circle())
              .dsTooltip(CalendarWords.pinned)
          }
          if let problem = model.calendarProblem(clip) {
            DSBadge(problem.text, style: .soft(problem.tone), icon: "exclamationmark", size: .sm)
              .background(DS.color.surface, in: Capsule())
              .contentShape(Capsule())
              .onTapGesture { model.reviewProblems() }
              .dsTooltip("Open Posts to fix this")
              .accessibilityAddTraits(.isButton)
          }
        }
        .padding(DS.space.xxs)
      }
      .overlay(alignment: .bottomLeading) {
        if (hovering || SnapshotHover.id == clip.video.id) && !isPast {
          DSXMenuButton(tooltip: CalendarWords.moreHelp, size: .sm, variant: .secondary) {
            CalendarClipMenu(model: model, video: clip.video, slot: clip.slot, posts: clip.posts)
          }
          .padding(DS.space.xxs)
          .transition(.opacity)
        }
      }
  }
}

/// What every clip card shares: drag, double-click to edit, right-click menu, tooltip.
private struct CardBehaviour: ViewModifier {
  @Bindable var model: AppModel
  let clip: CalendarClip
  @Binding var hovering: Bool
  @Binding var pointerOn: Bool

  func body(content: Content) -> some View {
    let blocker = model.calendarMoveBlocker(clip.slot, posts: clip.posts)
    content
      .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.border))
      .dsElevation(DS.elevation.e1)
      .contentShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
      .onHover { h in dsWithAnimation(DS.motion.hover) { hovering = h } }
      .dsPlaybackHover { pointerOn = $0 && !clip.video.isPhoto }  // a photo post has nothing to play
      .onTapGesture(count: 2) { model.openEditor(clip.video.id) }
      .modifier(SlotDrag(enabled: blocker == nil, id: clip.slot.id, poster: model.poster(clip.video)))
      .contextMenu { CalendarClipMenu(model: model, video: clip.video, slot: clip.slot, posts: clip.posts) }
      .dsTooltip(blocker.map { "\($0) · double-click to edit" } ?? (clip.slot.isExact ? "Double-click to edit · drag to another day, same time"
                                                                     : "Double-click to edit · drag to another day"))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(model.displayName(clip.video)), \(clip.slot.isExact ? "set time " : "")\(model.calendarTimeRange(clip))")
  }
}

/// Week card (r.md, e1): full-width 9:16 cover, title (2 lines), time range, platform icons with their state.
struct CalendarWeekCard: View {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let isPast: Bool
  let width: CGFloat
  @State private var hovering = false
  /// The pointer is really on the card (playback); `hovering` drives its ⋯ button.
  @State private var pointerOn = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CalendarCover(model: model, clip: clip, isPast: isPast, hovering: pointerOn, width: width)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: DS.radius.md, topTrailingRadius: DS.radius.md, style: .continuous))
        .opacity(isPast ? 0.5 : 1)  // the card dims, its "1 failed" doesn't
        .modifier(CoverBadges(model: model, clip: clip, isPast: isPast, hovering: hovering))
      VStack(alignment: .leading, spacing: DS.space.xxs) {
        Text(model.displayName(clip.video))
          .font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if clip.slot.isExact {
          CalendarSetTimeMark(model: model, slot: clip.slot)
        } else {
          Text(model.calendarTimeRange(clip)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        }
        if let retry = model.calendarRetryNote(clip) {
          Text(retry).font(DS.type.caption).foregroundStyle(DS.color.info).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        DSFlowLayout(spacing: 3, lineSpacing: 3) {
          ForEach(clip.platforms, id: \.self) { p in CalendarPlatformGlyph(model: model, clip: clip, platform: p) }
        }
        .padding(.top, 2)
      }
      .opacity(isPast ? 0.5 : 1)
      .padding(.horizontal, 6)
      .padding(.vertical, DS.space.xs)
    }
    .modifier(CardBehaviour(model: model, clip: clip, hovering: $hovering, pointerOn: $pointerOn))
  }
}

/// A platform on a Week card: icon + state dot, "TikTok · 7:00 PM · Rendered" on hover, post actions on right-click.
struct CalendarPlatformGlyph: View {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let platform: Platform

  var body: some View {
    DSPlatformIcon(platform: platform, state: model.calendarIconState(clip, platform), size: 20,
                   tooltip: model.calendarPlatformHelp(clip, platform))
      .contentShape(Circle())
      .contextMenu { if let post = clip.dayPosts[platform] { PostContextMenu(model: model, post: post) } }
  }
}

/// 3 Day card: cover on the left; title and the full per-platform list on the right.
struct CalendarThreeDayCard: View {
  @Bindable var model: AppModel
  let clip: CalendarClip
  let isPast: Bool
  @State private var hovering = false
  /// The pointer is really on the card (playback); `hovering` drives its ⋯ button.
  @State private var pointerOn = false

  var body: some View {
    HStack(alignment: .top, spacing: DS.space.sm) {
      CalendarCover(model: model, clip: clip, isPast: isPast, hovering: pointerOn, width: CalendarCover.smallWidth)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        .opacity(isPast ? 0.5 : 1)
        .modifier(CoverBadges(model: model, clip: clip, isPast: isPast, hovering: hovering))
      VStack(alignment: .leading, spacing: DS.space.xs) {
        Text(model.displayName(clip.video))
          .font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if clip.slot.isExact { CalendarSetTimeMark(model: model, slot: clip.slot).padding(.leading, DS.space.xxs) }
        VStack(spacing: 2) {
          ForEach(clip.platforms, id: \.self) { p in chip(p) }
        }
      }
      .opacity(isPast ? 0.5 : 1)
    }
    .padding(DS.space.xs)
    .modifier(CardBehaviour(model: model, clip: clip, hovering: $hovering, pointerOn: $pointerOn))
  }

  private func chip(_ p: Platform) -> some View {
    let post = clip.dayPosts[p]
    let pz = post.flatMap { model.postizRowState($0) }
    // A failed post with a retry coming says when, not when it failed.
    let time = pz?.isRetrying == true ? pz?.text ?? "" : AppModel.clockText(model.calendarTime(clip, p), tz: model.tz)
    return DSXSlotChip(platform: p, time: time, status: model.calendarStatus(clip, p),
                       paused: model.settings.pausedPlatforms.contains(p), hasActions: post != nil,
                       postiz: pz,
                       testRun: post.map(model.isTestRun) ?? false)
      .contextMenu { if let post { PostContextMenu(model: model, post: post) } }
  }
}

/// Loading placeholder shaped like the columns.
struct CalendarColumnsSkeleton: View {
  let columns: Int
  @Environment(\.screenGutter) private var gutter

  var body: some View {
    GeometryReader { g in
      let n = CGFloat(columns)
      let colW = max(96, (g.size.width - 2 * gutter - (n - 1) * DS.space.sm) / n)
      let coverW = min(colW, CalendarCover.smallWidth * 2)
      HStack(alignment: .top, spacing: DS.space.sm) {
        ForEach(0..<columns, id: \.self) { _ in
          VStack(alignment: .leading, spacing: DS.space.xs) {
            DSSkeleton(width: 48, height: 14)
            DSSkeleton(width: coverW, height: coverW * 16 / 9, radius: DS.radius.md)
            DSSkeleton(width: coverW * 0.7, height: 12)
          }
          .frame(width: colW, alignment: .leading)
        }
      }
      .padding(.horizontal, gutter)
    }
    .accessibilityLabel("Loading the calendar")
  }
}
