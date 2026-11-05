import AppKit
import DJQCore
import SwiftUI

/// Calendar → Day (B4, DESIGN-v2 §6.4): the operational view, for any day. `C.D` Hootsuite day list + `R2.TODAY`
/// Todoist column; Next-up card after `R2.MENUBAR-alt` Lyssna; inline failures after `C.D-alt` Buffer.
///
/// ```
/// ┌            Next: TikTok · 7:00 PM · in 2h 21m ─────────────────────────────┐  (today, something to do)
/// │            ▮ Golden Hour Blend      [Copy caption] [Open upload page] [Mark posted] │
/// └────────────────────────────────────────────────────────────────────────────┘
/// ▮ Golden Hour Blend · Thu 5 Nov ············································ ⋯   clip header
///   7:00 PM  ♪ TikTok   ▮ ………………………………  Rendered   ⧉ T ⎘ ⌕ ✓ ⋯               one row per platform
/// ```
/// The only filled button is Mark posted on the Next-up card, and only while that post is due. Each row's thumb is
/// the file drag-out handle. Past days keep the same rows, which are read-only by state. Hidden: scores, queue order.
struct CalendarDayView: View {
  @Bindable var model: AppModel
  let day: String

  static let column: CGFloat = 720

  var body: some View {
    let groups = model.calendarDayGroups(day)
    if groups.isEmpty {
      empty
    } else {
      list(groups)
    }
  }

  private var isToday: Bool { day == model.todayKey }

  /// "Nothing going out" + the next post, with a way there.
  @ViewBuilder private var empty: some View {
    if let next = model.nextPostAfter(day) {
      let when = model.nextPostText(next)
      DSEmptyState(icon: "checkmark.circle", title: "Nothing going out", message: "Next \(when)", actionTitle: "Open that day") {
        model.openCalendarDay(model.dm.key(next.scheduledAt))
      }
    } else {
      DSEmptyState(icon: "checkmark.circle", title: "Nothing going out", message: "Clips in the Queue get a day by themselves.",
                   actionTitle: "Go to Edit") { model.screen = .edit }
    }
  }

  private func list(_ groups: [CalendarDayGroup]) -> some View {
    let next = isToday ? model.todayNextUp.flatMap { p in model.calendarFilter == nil || p.platform == model.calendarFilter ? p : nil } : nil
    return ScrollView {
      VStack(alignment: .leading, spacing: DS.space.xl) {
        if let next { NextUpCard(model: model, post: next) }
        ForEach(groups) { g in CalendarDayClip(model: model, group: g, day: day) }
        if let after = model.nextPostAfter(day) {
          Text("Next after this day: \(model.nextPostText(after))").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            .padding(.horizontal, DS.space.xs)
        }
      }
      .frame(maxWidth: Self.column)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, DS.space.xl)
      .padding(.top, DS.space.xs)
      .padding(.bottom, DS.space.xxl)
    }
  }
}

/// One clip on the Day view: a header (thumb · title · day · ⋯) and one row per platform, without repeating the title.
struct CalendarDayClip: View {
  @Bindable var model: AppModel
  let group: CalendarDayGroup
  let day: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if group.posts.isEmpty {
        // Scheduled, posts not made yet: where it will go, as chips.
        DSFlowLayout(spacing: 6) {
          ForEach(group.platforms, id: \.self) { p in
            DSXSlotChip(platform: p, time: planText(p), status: .planned)
          }
        }
        .padding(.horizontal, DS.space.xs)
        .padding(.vertical, DS.space.xs)
      }
      ForEach(Array(group.posts.enumerated()), id: \.element.id) { i, p in
        if i > 0 { DSSeparator() }
        TodayRow(model: model, post: p, day: day, showsTitle: false)
      }
    }
  }

  private var header: some View {
    HStack(spacing: DS.space.sm) {
      DSXThumb(model: model, video: group.video, width: 36, post: group.posts.first)
      VStack(alignment: .leading, spacing: 2) {
        Text(group.video.map(model.displayName) ?? "Missing clip").font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(2)
        HStack(spacing: 4) {
          if group.slot?.pinned == true {
            Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
              .dsTooltip(CalendarWords.pinned)
          }
          Text(Fmt.day(model.dm.date(day), tz: model.tz, style: "EEE d MMM")).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        }
      }
      Spacer(minLength: DS.space.xs)
      if let v = group.video {
        DSXMenuButton(tooltip: CalendarWords.moreHelp, size: .sm) {
          CalendarClipMenu(model: model, video: v, slot: group.slot, posts: Self.latest(group.posts), day: day)
        }
      }
    }
    .padding(.horizontal, DS.space.xs)
    .padding(.bottom, DS.space.xs)
    .contentShape(Rectangle())
    .contextMenu {
      if let v = group.video { CalendarClipMenu(model: model, video: v, slot: group.slot, posts: Self.latest(group.posts), day: day) }
    }
  }

  private static func latest(_ posts: [PlatformPost]) -> [Platform: PlatformPost] {
    Dictionary(posts.map { ($0.platform, $0) }, uniquingKeysWith: { a, b in a.attemptNo > b.attemptNo ? a : b })
  }

  private func planText(_ p: Platform) -> String {
    let at = model.dm.at(day, minutes: model.settings.slot(for: p) + (group.slot?.position ?? 0) * model.settings.secondPostOffsetMinutes)
    return AppModel.clockText(at, tz: model.tz)
  }
}

// MARK: - Next-up card

/// "Next: TikTok · 7:00 PM · in 2h 21m" + thumb + title + [Copy caption] [Open upload page] [Mark posted].
struct NextUpCard: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let v = model.video(post.videoId)
    let due = model.isActionableNow(post)
    DSCard(variant: .outline, padding: DS.space.md) {
      HStack(alignment: .center, spacing: DS.space.md) {
        FileDragThumb(model: model, post: post, width: 54)
        VStack(alignment: .leading, spacing: DS.space.xs) {
          HStack(spacing: 6) {
            Image(systemName: post.platform.dsSymbol).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.textSecondary)
            Text(headline(due: due)).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          }
          Text(v.map(model.displayName) ?? "Missing clip").font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(2)
          HStack(spacing: DS.space.xs) {
            DSButton("Copy caption", icon: "text.quote", variant: .outline, size: .sm,
                     tooltip: "Copy the \(post.platform.displayName) caption") { model.copyCaptionNamed(post) }
            if post.platform == .youtube {
              DSButton("Copy title", icon: "textformat", variant: .ghost, size: .sm, tooltip: "Copy the YouTube title") { model.copyTitleNamed(post) }
            }
            DSButton("Open upload page", icon: "arrow.up.right", variant: .ghost, size: .sm,
                     tooltip: "Open the \(post.platform.displayName) upload page in your browser") { model.openUploadPage(post) }
            Spacer(minLength: DS.space.xs)
            DSButton("Mark posted", icon: "checkmark", variant: due ? .primary : .outline, size: .md,
                     tooltip: due ? "Paste the post URL" : "Not due yet — you can still mark it posted early") {
              model.markPostedTarget = post
            }
          }
          .padding(.top, 4)
        }
      }
    }
    .task(id: AppModel.prepStamp(post)) { await model.prepareIfRendered(post) }
  }

  private func headline(due: Bool) -> String {
    if model.postizState(post) == .inbox { return "TikTok · In your TikTok inbox — finish it there, then Mark posted" }
    let time = AppModel.clockText(post.scheduledAt, tz: model.tz)
    let when: String
    switch model.postStatus(post) {
    case .late(let t): when = "late \(t)"
    case .dueNow: when = "due now"
    default: when = post.scheduledAt > model.now ? "in \(AppModel.countdown(to: post.scheduledAt, now: model.now))" : "due now"
    }
    let day = model.dm.key(post.scheduledAt) == model.todayKey ? "" : "\(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE")) "
    return "Next: \(post.platform.displayName) · \(day)\(time) · \(when)"
  }
}

// MARK: - Row

/// One post, 64 pt: time (mono) · glyph + platform · thumb (file drag-out) · title · status pill · ghost actions. Under a
/// Day view clip header `showsTitle` is false: the row is 52 pt and keeps only the Postiz line.
struct TodayRow: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  /// The day the list is showing: a post from another day (an overdue leftover) names its weekday.
  let day: String
  var showsTitle = true
  @State private var hovering = false
  @State private var showMetrics = false

  private var video: Video? { model.video(post.videoId) }

  var body: some View {
    let status = model.postStatus(post)
    let pz = model.postizState(post)
    HStack(spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 0) {
        if model.dm.key(post.scheduledAt) != day {
          Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE")).font(DS.type.micro).foregroundStyle(DS.color.warning)
        }
        Text(AppModel.clockText(post.scheduledAt, tz: model.tz)).font(DS.type.mono).foregroundStyle(DS.color.textSecondary)
      }
      .frame(width: 66, alignment: .leading)
      DSPlatformIcon(platform: post.platform, size: 20, showsLabel: false)
      Text(post.platform.dsxCompactName).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        .frame(width: 66, alignment: .leading).lineLimit(1)
      FileDragThumb(model: model, post: post, width: showsTitle ? 27 : 20)
      VStack(alignment: .leading, spacing: 2) {
        if showsTitle {
          Text(video.map(model.displayName) ?? "Missing clip").font(DS.type.bodyMedium).foregroundStyle(DS.color.text).lineLimit(1)
        }
        if let pz { PostizLine(model: model, post: post, state: pz) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if model.isTestRun(post) { TestRunBadge() }
      if let pz {
        PostizBadge(model: model, post: post, state: pz)
      } else {
        DSBadge(status.text, style: status.badgeStyle, icon: status.badgeIcon)
          .dsTooltip(statusHelp(status))
      }
      if let pz, pz.isHeld { postizActions(pz) } else { actions(status) }
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: showsTitle ? 64 : 52)
    .background(rowFill(status), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .onHover { hovering = $0 }
    .contextMenu { PostContextMenu(model: model, post: post) }
    // Only rows whose render already exists get a file; nothing renders on display.
    .task(id: AppModel.prepStamp(post)) { await model.prepareIfRendered(post) }
  }

  private func rowFill(_ s: DSXPostStatus) -> Color {
    if post.id == model.highlightPostId { return DS.color.selected }
    if let t = s.problemTone, t == .danger { return DS.color.tint(.danger) }
    return hovering ? DS.color.hover.opacity(0.6) : .clear
  }

  private func statusHelp(_ s: DSXPostStatus) -> String {
    switch s {
    case .rendering: "The engine is preparing the file"
    case .ready: "Rendered — it's due at \(AppModel.clockText(post.scheduledAt, tz: model.tz))"
    case .dueNow: "Post it now, then mark it posted"
    case .late: "Past its time — post it now or shift the plan"
    case .copyright: post.errorMessage ?? "Copyright problem"
    case .failed: post.errorMessage ?? "Upload failed"
    default: s.text
    }
  }

  @ViewBuilder private func actions(_ s: DSXPostStatus) -> some View {
    HStack(spacing: 2) {
      switch s {
      case .resolved:
        more
      case .copyright:
        ReuploadMenu(model: model, post: post)
        DSButton("Skip \(post.platform.dsxCompactName)", variant: .ghost, size: .sm,
                 tooltip: "Don't post this clip on \(post.platform.displayName)") {
          model.resolve(post, .skipPlatform)
        }
        DSButton("Accept claim", variant: .ghost, size: .sm, tooltip: "Leave the post as it is (e.g. muted)") { model.resolve(post, .accept) }
        more
      case .failed:
        DSButton("Fix in editor", variant: .ghost, size: .sm,
                 tooltip: "Edit it; closing the editor re-queues it") { model.openEditor(post.videoId, fixPostId: post.id) }
        DSButton("Re-queue", variant: .ghost, size: .sm, disabledReason: model.heldReason(post.videoId),
                 tooltip: "Try again on the next day's slot") { model.fixed(post.id) }
        more
      case .posted:
        if let u = post.url, let url = URL(string: u) {
          DSIconButton("arrow.up.right.square", tooltip: "Open the live post in your browser", size: .sm) { NSWorkspace.shared.open(url) }
        }
        DSButton(post.metrics?.views.map { "\($0) views" } ?? "Metrics", icon: "chart.bar", variant: .ghost, size: .sm,
                 tooltip: "Enter views and likes after 72 h") { showMetrics = true }
          .popover(isPresented: $showMetrics) { MetricsPopover(model: model, post: post) }
        more
      case .skipped:
        more
      default:
        DSIconButton("text.quote", tooltip: "Copy the \(post.platform.displayName) caption", size: .sm) { model.copyCaptionNamed(post) }
        if post.platform == .youtube {
          DSIconButton("textformat", tooltip: "Copy the YouTube title", size: .sm) { model.copyTitleNamed(post) }
        }
        DSIconButton("doc.on.doc", tooltip: "Copy the video file to paste in upload", size: .sm) { model.copyFile(post) }
        DSIconButton("folder", tooltip: "Show the video file in Finder", size: .sm) { model.revealFile(post) }
        DSIconButton("checkmark.circle", tooltip: "Paste the post URL to mark it posted", size: .sm) { model.markPostedTarget = post }
        more
      }
    }
  }

  /// Postiz holds it: no task actions, only a draft's Release and the usual menu.
  @ViewBuilder private func postizActions(_ s: PostizPostState) -> some View {
    HStack(spacing: 2) {
      if s == .draft {
        DSButton("Release", icon: "paperplane", variant: .ghost, size: .sm,
                 tooltip: "Let Postiz post this draft at its time") { model.releaseDraft(post) }
      }
      more
    }
  }

  private var more: some View {
    DSXMenuButton(tooltip: "Report, reschedule, reset or skip", size: .sm) {
      if !post.state.isTerminal || post.state == .posted {
        Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
      }
      if !post.state.isTerminal {
        Button("Open upload page", systemImage: "arrow.up.right") { model.openUploadPage(post) }
      }
      if post.state == .overdue {
        // Disabled native menu items can't show a tooltip: the reason goes in the title.
        let held = model.heldReason(post.videoId) != nil
        Button(held ? "Post now — sent back to Edit" : "Post now (make it due today)", systemImage: "bolt") { model.postNow(post) }
          .disabled(held)
        Button(held ? "Shift to next free slot — sent back to Edit" : "Shift to next free \(post.platform.dsxCompactName) slot",
               systemImage: "calendar.badge.clock") { model.shiftPlan(post) }
          .disabled(held)
      }
      if model.canReset(post) || model.canSkip(post) { Divider() }
      if model.canReset(post) { Button("Reset to Planned", systemImage: "arrow.counterclockwise") { model.reset(post) } }
      if model.canSkip(post) { Button("Skip \(post.platform.dsxCompactName)", systemImage: "forward") { model.skip(post) } }
      if let v = video {
        Divider()
        Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(v.id) }
      }
    }
  }
}

/// The thumb doubles as the file drag-out handle (decision Q4): drag the rendered file into the browser upload
/// page. Until the render exists the thumb is a plain cover with a "Rendering" tooltip.
struct FileDragThumb: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  var width: CGFloat = 27

  var body: some View {
    let ready = model.preparedPost(post.id)
    DSXThumb(model: model, video: model.video(post.videoId), width: width, post: post)
      .overlay(alignment: .bottomTrailing) {
        if ready != nil {
          Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: width > 40 ? 9 : 7, weight: .bold)).foregroundStyle(.white)
            .frame(width: width > 40 ? 18 : 13, height: width > 40 ? 18 : 13)
            .background(Color.black.opacity(0.6), in: Circle())
            .padding(2)
        }
      }
      .onDrag {
        guard let url = model.preparedPost(post.id)?.fileURL else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
      }
      .dsTooltip(ready.map { "Drag \($0.fileURL.lastPathComponent) into the upload page" }
                 ?? (model.isRenderable(post) ? "Preparing the file…" : "The file is still rendering"))
      .accessibilityLabel(ready == nil ? "Clip cover, file not ready" : "Drag the file")
  }
}

/// Loading placeholder shaped like the Next-up card and the rows.
struct CalendarDaySkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: DS.space.md) {
        DSSkeleton(width: 54, height: 96, radius: DS.radius.xs)
        VStack(alignment: .leading, spacing: DS.space.xs) {
          DSSkeleton(width: 220, height: 12)
          DSSkeleton(width: 300, height: 16)
          HStack { DSSkeleton(width: 110, height: 28, radius: 14); DSSkeleton(width: 140, height: 28, radius: 14) }
        }
        Spacer()
      }
      .padding(DS.space.md)
      .dsSurface(DS.color.surface, radius: DS.radius.lg, border: DS.color.border)
      .padding(.bottom, DS.space.xl)
      SkeletonRows(count: 6, height: 64)
    }
    .frame(maxWidth: CalendarDayView.column)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, DS.space.xl)
    .padding(.top, DS.space.xs)
  }
}
