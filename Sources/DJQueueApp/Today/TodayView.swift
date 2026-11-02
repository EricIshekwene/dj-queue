import AppKit
import DJQCore
import SwiftUI

/// Today (DESIGN-v2 §6.5, `R2.TODAY` Todoist centred column; Next-up card after `R2.MENUBAR-alt` Lyssna).
/// Job: post what's due, by hand, and mark it posted.
///
/// ```
/// ┌ Today · Sun 1 Nov ······················································ ◔ 3 of 6 posted ┐
/// │            ┌ Next: TikTok · 7:00 PM · in 2h 21m ─────────────────────────────┐           │
/// │            │ ▮ Golden Hour Blend      [Copy caption] [Open upload page] [Mark posted] │  │
/// │            └─────────────────────────────────────────────────────────────────┘           │
/// │            7:00 PM  ♪ TikTok   ▮ title …………  Ready   ⧉ T ⎘ ⌕ ✓ ⋯   (64 pt rows)       │
/// └────────────────────────────────────────────────────────────────────────────────────────┘
/// ```
/// The only filled button is Mark posted on the Next-up card, and only while that post is due. The thumb is the
/// file drag-out handle. Hidden: scores, queue order, editor controls.
struct TodayView: View {
  @Bindable var model: AppModel

  static let column: CGFloat = 720

  var body: some View {
    ScreenScaffold(model: model, screen: .today, subtitle: Fmt.day(model.now, tz: model.tz, style: "EEE d MMM"), readingColumn: true) {
      if model.loaded && model.todayTotal > 0 { progress }
    } content: {
      if !model.loaded {
        TodaySkeleton()
      } else if model.todayPosts.isEmpty {
        DSEmptyState(icon: "checkmark.circle", title: "Nothing due today",
                     message: model.nextAfterTodayText.map { "Next \($0)" } ?? "No posts planned — approve a week to plan some.",
                     actionTitle: "Open Week") { model.screen = .week }
      } else {
        list
      }
    }
  }

  private var progress: some View {
    let done = model.postedTodayCount, total = model.todayTotal
    return HStack(spacing: DS.space.xs) {
      DSProgressRing(value: Double(done) / Double(max(total, 1)), size: 22, lineWidth: 3, tone: .success)
      Text("\(done) of \(total) posted").font(DS.type.calloutMedium.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(done) of \(total) posted today")
  }

  private var list: some View {
    let posts = model.todayPosts
    let next = model.todayNextUp
    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let next { NextUpCard(model: model, post: next).padding(.bottom, DS.space.xl) }
        ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
          TodayRow(model: model, post: p)
          if i < posts.count - 1 { DSSeparator() }
        }
        if let after = model.nextAfterTodayText {
          Text("Next after today: \(after)").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            .padding(.top, DS.space.md).padding(.horizontal, DS.space.xs)
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
            DSButton("Copy caption", icon: "text.quote", variant: .outline, size: .sm) { model.copyCaptionNamed(post) }
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

/// 64 pt row: time (mono) · glyph + platform · thumb (file drag-out) · title · status pill · ghost actions.
struct TodayRow: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var hovering = false
  @State private var showMetrics = false

  private var video: Video? { model.video(post.videoId) }

  var body: some View {
    let status = model.postStatus(post)
    HStack(spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 0) {
        if model.dm.key(post.scheduledAt) != model.todayKey {
          Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE")).font(DS.type.micro).foregroundStyle(DS.color.warning)
        }
        Text(AppModel.clockText(post.scheduledAt, tz: model.tz)).font(DS.type.mono).foregroundStyle(DS.color.textSecondary)
      }
      .frame(width: 66, alignment: .leading)
      DSPlatformIcon(platform: post.platform, size: 20, showsLabel: false)
      Text(post.platform.dsxCompactName).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        .frame(width: 66, alignment: .leading).lineLimit(1)
      FileDragThumb(model: model, post: post, width: 27)
      Text(video.map(model.displayName) ?? "Missing clip").font(DS.type.bodyMedium).foregroundStyle(DS.color.text).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      DSBadge(status.text, style: status.badgeStyle, icon: status.badgeIcon)
        .dsTooltip(statusHelp(status))
      actions(status)
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: 64)
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
    case .ready: "File ready — it's due at \(AppModel.clockText(post.scheduledAt, tz: model.tz))"
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
        DSButton("Skip platform", variant: .ghost, size: .sm, tooltip: "Don't post this clip on \(post.platform.displayName)") {
          model.resolve(post, .skipPlatform)
        }
        DSButton("Accept", variant: .ghost, size: .sm, tooltip: "Keep it as it is (e.g. muted)") { model.resolve(post, .accept) }
        more
      case .failed:
        DSButton("Fix…", variant: .ghost, size: .sm, tooltip: "Open the editor to fix it") { model.openEditor(post.videoId, fixPostId: post.id) }
        DSButton("Re-queue", variant: .ghost, size: .sm, disabledReason: model.heldReason(post.videoId),
                 tooltip: "The cause is fixed: try again on the next day's slot") { model.fixed(post.id) }
        more
      case .posted:
        if let u = post.url, let url = URL(string: u) {
          DSIconButton("arrow.up.right.square", tooltip: "Open the post", size: .sm) { NSWorkspace.shared.open(url) }
        }
        DSButton(post.metrics?.views.map { "\($0) views" } ?? "Metrics", icon: "chart.bar", variant: .ghost, size: .sm,
                 tooltip: "Views and likes after 72 h") { showMetrics = true }
          .popover(isPresented: $showMetrics) { MetricsPopover(model: model, post: post) }
        more
      case .skipped:
        more
      default:
        DSIconButton("text.quote", tooltip: "Copy caption", size: .sm) { model.copyCaptionNamed(post) }
        if post.platform == .youtube {
          DSIconButton("textformat", tooltip: "Copy title for YouTube", size: .sm) { model.copyTitleNamed(post) }
        }
        DSIconButton("doc.on.doc", tooltip: "Copy file", size: .sm) { model.copyFile(post) }
        DSIconButton("folder", tooltip: "Reveal in Finder", size: .sm) { model.revealFile(post) }
        DSIconButton("checkmark.circle", tooltip: "Mark posted…", size: .sm) { model.markPostedTarget = post }
        more
      }
    }
  }

  private var more: some View {
    DSXMenuButton(tooltip: "More", size: .sm) {
      if !post.state.isTerminal || post.state == .posted {
        Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
      }
      if !post.state.isTerminal {
        Button("Open upload page", systemImage: "arrow.up.right") { model.openUploadPage(post) }
      }
      if post.state == .overdue {
        Button("Post now", systemImage: "bolt") { model.postNow(post) }
          .disabled(model.heldReason(post.videoId) != nil).help(model.heldReason(post.videoId) ?? "Due now on today's slot")
        Button("Shift plan", systemImage: "calendar.badge.clock") { model.shiftPlan(post) }
          .disabled(model.heldReason(post.videoId) != nil).help(model.heldReason(post.videoId) ?? "Next free slot")
      }
      if model.canReset(post) || model.canSkip(post) { Divider() }
      if model.canReset(post) { Button("Reset", systemImage: "arrow.counterclockwise") { model.reset(post) } }
      if model.canSkip(post) { Button("Skip this platform", systemImage: "forward") { model.skip(post) } }
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
    DSXThumb(model: model, video: model.video(post.videoId), width: width)
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
struct TodaySkeleton: View {
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
    .frame(maxWidth: TodayView.column)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, DS.space.xl)
    .padding(.top, DS.space.xs)
  }
}
