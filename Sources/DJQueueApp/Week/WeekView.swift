import DJQCore
import SwiftUI

/// Week (DESIGN-v2 §6.4, `R2.WEEK` Hootsuite week with media cards). Job: check and approve the next week.
///
/// ```
/// ┌ Week of 2 Nov · Next week ········ ‹ Today › · Draft · Runway · ⋯ · [Approve week ⌘↩] ┐
/// │ Mon 2   Tue 3   Wed 4   Thu 5   Fri 6   Sat 7   Sun 8        (today = near-black pill) │
/// │ ┌────┐  ┌────┐  ┌────┐  ┌╌╌╌╌┐ …  one day card: 9:16 cover, title, score, slot chips  │
/// │ └────┘  └────┘  └────┘  └╌╌╌╌┘     empty day = dashed "Drop a clip" / Add from queue   │
/// │ ˄ Next up · 6                                       backlog drawer (drag onto a day)   │
/// └────────────────────────────────────────────────────────────────────────────────────────┘
/// ```
/// Drag a day card onto another day to swap (or move to an empty day); drop a backlog clip on a planned day to
/// replace it (asks first). Past days are 50 % and fixed. Hidden: captions, editor controls, history.
struct WeekView: View {
  @Bindable var model: AppModel

  private var ws: String { model.shownWeek }
  private var days: [String] { model.dm.weekDays(ws) }
  /// Loaded off-main by the model's refresh for `model.weekStart` (no DB work in body).
  private var slots: [PlanSlot] { model.weekSlots.filter { $0.weekStart == ws } }

  var body: some View {
    let slots = self.slots
    ScreenScaffold(model: model, screen: .week, title: model.weekTitle(ws), subtitle: model.weekContext(ws)) {
      toolbar(slots)
    } content: {
      VStack(spacing: 0) {
        if !model.loaded {
          WeekSkeleton()
        } else if slots.isEmpty && model.ordered.isEmpty && model.upcomingSlots.isEmpty {
          DSEmptyState(icon: "calendar", title: "Nothing to plan yet", message: "Clips show up here once they reach the Queue.",
                       actionTitle: "Go to Edit") { model.screen = .edit }
        } else {
          WeekGrid(model: model, days: days, slots: slots, approved: model.weekStates[ws] == .approved)
          BacklogDrawer(model: model, expanded: $model.weekBacklogExpanded)
        }
      }
      .overlay { replaceDialog }
    }
  }

  // MARK: Toolbar

  @ViewBuilder private func toolbar(_ slots: [PlanSlot]) -> some View {
    let status = model.weekStatus(ws)
    let past = model.dm.addDays(ws, 6) < model.todayKey
    HStack(spacing: 2) {
      DSIconButton("chevron.left", tooltip: "Show the previous week", size: .sm) { model.weekStart = model.dm.addDays(ws, -7) }
      DSButton("This week", variant: .ghost, size: .sm, disabledReason: ws == model.thisWeek ? "Already showing this week" : nil,
               tooltip: "Jump back to this week") {
        model.weekStart = model.thisWeek
      }
      DSIconButton("chevron.right", tooltip: "Show the next week", size: .sm) { model.weekStart = model.dm.addDays(ws, 7) }
    }
    if !slots.isEmpty, let status { statusPill(status) }
    RunwayChip(model: model)
    let proposeBlocker: String? = past ? "this week is over" : (status == .approved || status == .locked) ? "week already approved" : nil
    DSXMenuButton(tooltip: "Rebuild, push or propose this week's plan") {
      // Rebuild and Push ask first inside AppModel (and are undoable); disabled items carry the reason in the title.
      Button(past ? "Rebuild week — this week is over" : "Rebuild week…", systemImage: "arrow.clockwise") { model.rebuildWeek(ws) }
        .disabled(past)
      Button("Push whole plan by a day…", systemImage: "calendar.badge.clock") { model.pushPlan(days: 1) }
      Divider()
      Button(proposeBlocker.map { "Propose week — \($0)" } ?? "Propose week (fill empty days)", systemImage: "square.grid.3x1.below.line.grid.1x2") {
        model.proposeWeek(ws)
      }
      .disabled(proposeBlocker != nil)
    }
    DSButton("Approve week", icon: "checkmark", variant: .primary, disabledReason: approveBlocker(slots, status: status, past: past),
             tooltip: "Approve: the engine prepares these posts", shortcut: "⌘↩") {
      model.approveWeek(ws)
    }
    .keyboardShortcut(.return, modifiers: .command)
  }

  private func statusPill(_ s: AppModel.WeekStatus) -> some View {
    let (text, style, icon, help): (String, DSBadgeStyle, String, String) = switch s {
    case .draft: ("Draft", .soft(.warning), "pencil", "Draft: nothing posts until you approve the week")
    case .approved: ("Approved", .soft(.success), "checkmark.seal", "Approved: these posts will be prepared and handed to you")
    case .locked: ("Locked", .soft(.neutral), "lock", "The week has started: past days are fixed; future days can still change")
    }
    return DSBadge(text, style: style, icon: icon).dsTooltip(help)
  }

  private func approveBlocker(_ slots: [PlanSlot], status: AppModel.WeekStatus?, past: Bool) -> String? {
    if past { return "This week is over" }
    if status == .approved || status == .locked { return "This week is already approved" }
    if !slots.contains(where: { $0.date >= model.todayKey }) {
      return "Nothing planned yet — drop clips on days or use ⋯ → Propose week"
    }
    return nil
  }

  // MARK: Replace confirmation (backlog clip dropped on a planned day)

  @ViewBuilder private var replaceDialog: some View {
    if let r = model.pendingReplace {
      let replaced = model.video(r.replaced).map(model.displayName) ?? "the planned clip"
      let incoming = model.video(r.videoId).map(model.displayName) ?? "this clip"
      ModalHost(onDismiss: { model.pendingReplace = nil }) {
        DSDialog("Replace the planned clip?",
                 description: "“\(incoming)” takes \(Fmt.day(model.dm.date(r.day), tz: model.tz, style: "EEE d MMM")). “\(replaced)” goes back to the backlog.",
                 icon: "arrow.left.arrow.right", onClose: { model.pendingReplace = nil }) {
          EmptyView()
        } footer: {
          DSButton("Cancel", variant: .ghost) { model.pendingReplace = nil }
            .keyboardShortcut(.cancelAction)
          DSButton("Replace", variant: .primary) {
            model.pin(r.videoId, dayKey: r.day)
            model.pendingReplace = nil
          }
          .keyboardShortcut(.defaultAction)
        }
        .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
      }
    }
  }
}

// MARK: - Grid

/// 7 equal columns, 12 pt gaps, screen gutters. Day headers stay put; the cards scroll.
struct WeekGrid: View {
  @Bindable var model: AppModel
  let days: [String]
  let slots: [PlanSlot]
  let approved: Bool
  @Environment(\.screenGutter) private var gutter

  var body: some View {
    let bySlotDate = Dictionary(grouping: slots, by: \.date)
    let ids = slots.map(\.videoId)
    GeometryReader { g in
      let colW = max(96, (g.size.width - 2 * gutter - 6 * DS.space.sm) / 7)
      VStack(spacing: 0) {
        HStack(spacing: DS.space.sm) {
          ForEach(days, id: \.self) { d in WeekDayHeader(model: model, day: d).frame(width: colW) }
        }
        .padding(.horizontal, gutter)
        .padding(.bottom, DS.space.sm)
        ScrollView {
          HStack(alignment: .top, spacing: DS.space.sm) {
            ForEach(days, id: \.self) { day in
              WeekDayColumn(model: model, day: day, slots: (bySlotDate[day] ?? []).sorted { $0.position < $1.position },
                            approved: approved, weekSlots: slots, width: colW)
                .frame(width: colW)
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
      model.requestProxies(ids)
    }
  }
}

/// "Thu 5" (callout semibold); today in a near-black capsule; awake strip under past days and today.
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
      if isPast || isToday {
        AwakeStrip(model: model, day: day, awake: model.weekAwake)
      } else {
        Color.clear.frame(height: 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isToday ? "Today, \(text)" : text)
  }
}

/// One day: its card(s), reposts/retries, or the dashed drop placeholder. Drops: a day card swaps (or moves to an
/// empty day); a backlog clip pins (asks before replacing a planned clip). Past days refuse drops.
struct WeekDayColumn: View {
  @Bindable var model: AppModel
  let day: String
  let slots: [PlanSlot]
  let approved: Bool
  let weekSlots: [PlanSlot]
  let width: CGFloat
  @State private var targeted = false

  private var isPast: Bool { day < model.todayKey }

  /// Reposts and re-queued attempts that land on this day (no plan slot).
  private var extraPosts: [PlatformPost] {
    model.posts.filter { $0.planSlotId == nil && model.dm.key($0.scheduledAt) == day }.sorted { $0.scheduledAt < $1.scheduledAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      ForEach(slots) { s in
        if let v = model.video(s.videoId) {
          WeekDayCard(model: model, slot: s, video: v, approved: approved, isPast: isPast, weekSlots: weekSlots, width: width)
        }
      }
      ForEach(extraPosts) { p in ExtraPostChip(model: model, post: p) }
      if slots.isEmpty { placeholder }
    }
    .opacity(isPast ? 0.5 : 1)
    .frame(maxWidth: .infinity, alignment: .top)
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first else { return false }
      return drop(item)
    } isTargeted: { targeted = $0 && !isPast }
  }

  @ViewBuilder private var placeholder: some View {
    let backlog = model.weekBacklog
    VStack(spacing: DS.space.xs) {
      Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.color.textTertiary)
      Text(isPast ? "Nothing posted" : "Drop a clip").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      if !isPast {
        DSButton("Add from queue", variant: .ghost, size: .sm,
                 disabledReason: backlog.isEmpty ? "Nothing in the Queue is waiting for a day" : nil,
                 tooltip: backlog.first.map { "Pin “\(model.displayName($0))” here (next in queue)" }) {
          if let v = backlog.first { model.pin(v.id, dayKey: day) }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: width * 16 / 9)
    .background(targeted ? DS.color.hover : .clear, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
        .strokeBorder(targeted ? DS.color.text.opacity(0.5) : DS.color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
  }

  /// Same-day and past-day drops are refused; a backlog clip dropped on a planned day asks before replacing.
  private func drop(_ item: String) -> Bool {
    guard !isPast else { model.show("Past days can't be changed", error: true); return false }
    if item.hasPrefix("slot:") {
      let id = String(item.dropFirst(5))
      guard let src = weekSlots.first(where: { $0.id == id }) ?? model.upcomingSlots.first(where: { $0.id == id }), src.date != day
      else { return false }
      guard src.date >= model.todayKey else { model.show("That clip already went out", error: true); return false }
      if let target = slots.first { model.swap(id, target.id) } else { model.move(id, to: day) }
    } else if item.hasPrefix("video:") {
      let vid = String(item.dropFirst(6))
      if let occupied = slots.first(where: { !$0.pinned }) ?? slots.first {
        guard occupied.videoId != vid else { return false }
        model.pendingReplace = (vid, day, occupied.videoId)
      } else {
        model.pin(vid, dayKey: day)
      }
    }
    return true
  }
}

/// The day card (r.md, e1): 9:16 cover at full column width (muted autoplay from the proxy, poster fallback),
/// score capsule on the cover, title, then one slot chip per platform.
struct WeekDayCard: View {
  @Bindable var model: AppModel
  let slot: PlanSlot
  let video: Video
  let approved: Bool
  let isPast: Bool
  let weekSlots: [PlanSlot]
  let width: CGFloat
  @State private var hovering = false

  private var posts: [Platform: PlatformPost] { model.slotPosts(slot.id) }
  /// The slot's post decides the version shown (all platforms of a slot share it); no post yet → version 1.
  private var firstPost: PlatformPost? { posts.values.min { $0.platform.rawValue < $1.platform.rawValue } }
  private var preview: ClipPreview { firstPost.flatMap { model.clipPreview(post: $0) } ?? model.clipPreview(video) }
  private func requestPreview() {
    if let p = firstPost { model.requestPreview(post: p) } else { model.requestPreview(video) }
  }
  private var hasProblem: Bool { posts.values.contains { model.postStatus($0).isProblem } }
  private var anyPosted: Bool { posts.values.contains { $0.state == .posted } }

  var body: some View {
    let p = model.playback
    // The post's version as it will post (round 4 S6): its text, and the render's cover when the render is current.
    let pv = preview
    VStack(alignment: .leading, spacing: 0) {
      DSVideoPreview(url: pv.proxyURL, poster: pv.cover,
                     isActive: p.autoplay && !isPast && (!p.focusOnly || hovering), loopRange: pv.loopRange,
                     unmuteOnHover: p.hoverSound && !isPast, isHovered: hovering, muteAlignment: .bottomTrailing,
                     overlay: pv.overlay, textWindow: pv.textWindow, isUpdating: pv.isUpdating, updatingStyle: .label)
        .task(id: pv.stamp) { requestPreview() }
        .frame(width: width, height: width * 16 / 9)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: DS.radius.md, topTrailingRadius: DS.radius.md, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if let s = video.score {
            Text("\(s)").font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
              .padding(.horizontal, 7).frame(height: 20)
              .background(Color.black.opacity(0.55), in: Capsule())
              .padding(DS.space.xs)
              .dsTooltip("Score \(s)")
          }
        }
        .overlay(alignment: .topLeading) {
          HStack(spacing: 4) {
            if slot.pinned {
              Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.black.opacity(0.55), in: Circle())
                .dsTooltip("Pinned: stays here when the week is rebuilt")
            }
            if hasProblem {
              DSBadge("Needs you", style: .soft(.danger), icon: "exclamationmark", size: .sm).background(DS.color.surface, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { model.screen = .posts }
                .dsTooltip("Open Posts: a post failed or is late")
                .accessibilityAddTraits(.isButton)
            }
          }
          .padding(DS.space.xs)
        }
        .overlay(alignment: .bottomLeading) {
          if (hovering || SnapshotHover.id == video.id) && !isPast {
            HStack(spacing: 4) {
              DSXMenuButton(tooltip: "Swap, remove, pin or skip this clip", size: .sm, variant: .secondary) { WeekCardMenu(model: model, slot: slot, video: video,
                                                                                                  approved: approved, isPast: isPast,
                                                                                                  weekSlots: weekSlots, posts: posts) }
              Spacer(minLength: 0)
              StageControl(model: model, video: video, compact: true)
                .padding(2)
                .background(DS.color.surface.opacity(0.92), in: Capsule())
            }
            .padding(DS.space.xs)
            .transition(.opacity)
          }
        }
      VStack(alignment: .leading, spacing: DS.space.xs) {
        Text(model.displayName(video))
          .font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        VStack(spacing: 2) {
          ForEach(chipPlatforms, id: \.self) { pl in chip(pl) }
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, DS.space.xs)
    }
    .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.border))
    .dsElevation(DS.elevation.e1)
    .contentShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    .onHover { h in dsWithAnimation(DS.motion.hover) { hovering = h } }
    .onTapGesture(count: 2) { model.openEditor(video.id) }
    .modifier(SlotDrag(enabled: !isPast && !anyPosted, id: slot.id, poster: model.poster(video)))
    .contextMenu { WeekCardMenu(model: model, slot: slot, video: video, approved: approved, isPast: isPast, weekSlots: weekSlots, posts: posts) }
    .dsTooltip(isPast || anyPosted ? "Double-click to edit" : "Double-click to edit · drag to swap days")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(model.displayName(video)), score \(video.score.map(String.init) ?? "none")")
  }

  /// Platforms with a post (approved), else the platforms the draft would post to.
  private var chipPlatforms: [Platform] {
    let withPosts = Set(posts.keys)
    let active = model.settings.activePlatforms
    return withPosts.isEmpty ? active : active.filter(withPosts.contains) + withPosts.subtracting(active).sorted()
  }

  private func chip(_ pl: Platform) -> some View {
    let post = posts[pl]
    let time = post.map { AppModel.clockText($0.scheduledAt, tz: model.tz) }
      ?? AppModel.clockText(model.dm.at(slot.date, minutes: model.settings.slot(for: pl) + slot.position * model.settings.secondPostOffsetMinutes),
                            tz: model.tz)
    let status: DSXPostStatus = post.map { model.postStatus($0) } ?? (approved ? .planned : .draft)
    return DSXSlotChip(platform: pl, time: time, status: status, paused: model.settings.pausedPlatforms.contains(pl), hasActions: post != nil)
      .contextMenu { if let post { PostContextMenu(model: model, post: post) } }
  }
}

/// Drag source for a day card (only future, not-yet-posted slots).
private struct SlotDrag: ViewModifier {
  let enabled: Bool
  let id: String
  let poster: NSImage?
  func body(content: Content) -> some View {
    if enabled {
      content.draggable("slot:\(id)") {
        DSVideoPreview(url: nil, poster: poster, showsMuteButton: false, cornerRadius: DS.radius.sm).frame(width: 54, height: 96)
      }
    } else {
      content
    }
  }
}

/// Day card actions (context menu + hover ⋯). Past days are fixed: swap/remove/pin only on future slots.
struct WeekCardMenu: View {
  @Bindable var model: AppModel
  let slot: PlanSlot
  let video: Video
  let approved: Bool
  let isPast: Bool
  let weekSlots: [PlanSlot]
  let posts: [Platform: PlatformPost]

  var body: some View {
    Menu(isPast ? "Swap with — past days are fixed" : "Swap with") {
      ForEach(weekSlots.filter { $0.id != slot.id && $0.date >= model.todayKey }) { o in
        Button("\(Fmt.day(model.dm.date(o.date), tz: model.tz, style: "EEE d")) · \(model.video(o.videoId).map(model.displayName) ?? "")") {
          model.swap(slot.id, o.id)
        }
      }
    }
    .disabled(isPast)
    Button(isPast ? "Remove from week — past days are fixed" : "Remove from week (day stays empty)", systemImage: "minus.circle") {
      model.removeSlot(slot.id)
    }
    .disabled(isPast)
    Button(slot.pinned ? "Pinned to this day" : isPast ? "Pin to this day — past days are fixed" : "Pin to this day (keeps it on rebuild)",
           systemImage: "pin") { model.pin(video.id, dayKey: slot.date) }
      .disabled(slot.pinned || isPast)
    let skippable = posts.values.filter { !$0.state.isTerminal }
    Menu(!approved ? "Skip platform — approve the week first" : skippable.isEmpty ? "Skip platform — nothing left to skip" : "Skip platform") {
      ForEach(skippable.sorted { $0.platform < $1.platform }) { p in
        Button("Skip \(p.platform.displayName)") { model.skip(p) }
      }
    }
    .disabled(!approved || skippable.isEmpty)
    Divider()
    StageMenuItems(model: model, video: video, targets: [video.id])
    let removeBlocker = isPast ? "this day has passed" : model.removeFromQueueBlocker(video).map { _ in "already posted" }
    Button(removeBlocker.map { "Back to Edit — \($0)" } ?? "Back to Edit (out of the plan)", systemImage: "arrow.uturn.backward") {
      model.removeFromQueue([video.id])
    }
    .disabled(removeBlocker != nil)
    Divider()
    Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id) }
    Button("Preview", systemImage: "play.rectangle") { model.previewVideo = video }
    Button("Show in Queue", systemImage: "list.bullet") { model.setSelection([video.id], screen: .queue); model.screen = .queue }
  }
}

/// Repost / retry that isn't part of a plan slot: "↻ X 8:00 PM · Retry ●".
struct ExtraPostChip: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let status = model.postStatus(post)
    HStack(spacing: 5) {
      Image(systemName: post.kind == .repost ? "arrow.uturn.forward" : "arrow.clockwise")
        .font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.color.textSecondary)
      Image(systemName: post.platform.dsSymbol).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DS.color.textSecondary)
      Text("\(post.platform.dsxCompactName) \(AppModel.clockText(post.scheduledAt, tz: model.tz))")
        .font(DS.type.microCompact).foregroundStyle(DS.color.text).lineLimit(1).minimumScaleFactor(0.9)
      Spacer(minLength: 2)
      if let dot = status.dot { Circle().fill(dot).frame(width: 6, height: 6) }
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(DS.color.surfaceSunken, in: Capsule())
    .dsTooltip(post.kind == .repost ? "Repost of \(model.video(post.videoId).map(model.displayName) ?? "a clip") (new version)"
               : "Re-queued attempt #\(post.attemptNo) of \(model.video(post.videoId).map(model.displayName) ?? "a clip")")
    .contextMenu { PostContextMenu(model: model, post: post) }
  }
}

// MARK: - Backlog drawer

/// Collapsed bar at the bottom ("Next up 6"); expanded = the shared list header (compact: search ⌘F · Filters ·
/// sort, applied filters as chips) over the Queue clips still waiting for a day, draggable onto a day.
struct BacklogDrawer: View {
  @Bindable var model: AppModel
  @Binding var expanded: Bool
  @Environment(\.screenGutter) private var gutter

  var body: some View {
    let backlog = model.weekBacklog
    let list = model.listSorted(.backlog, model.listScope(.backlog, backlog))
    VStack(spacing: 0) {
      DSSeparator()
      HStack(spacing: DS.space.xs) {
        DSIconButton(expanded ? "chevron.down" : "chevron.up", tooltip: expanded ? "Hide the backlog" : "Show the Queue clips waiting for a day",
                     size: .sm) { toggle() }
        ListHeader(page: .backlog, title: "Next up", count: backlog.isEmpty ? 0 : list.count, total: backlog.count,
                   filters: expanded && !backlog.isEmpty ? model.listFilterSections(.backlog, backlog) : [], compact: true,
                   showsSearch: expanded && !backlog.isEmpty) {
          EmptyView()
        } sort: {
          if expanded && !backlog.isEmpty { ListSortMenu(page: .backlog, size: .sm) }
        } trailing: {
          if expanded && !backlog.isEmpty {
            Text("Drag a clip onto a day").font(DS.type.caption).foregroundStyle(DS.color.textTertiary).padding(.leading, DS.space.xs)
          }
        }
      }
      .padding(.horizontal, gutter - 4)
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .onTapGesture { if !expanded { toggle() } }
      .accessibilityLabel("Next up, \(backlog.count) clips waiting for a day")
      if expanded {
        if backlog.isEmpty {
          Text("Nothing in the Queue is waiting for a day").font(DS.type.callout).foregroundStyle(DS.color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, gutter).frame(height: 60)
        } else if list.isEmpty {
          HStack(spacing: DS.space.xs) {
            Text("No clips match").font(DS.type.callout).foregroundStyle(DS.color.textTertiary)
            DSButton("Clear filters", variant: .ghost, size: .sm, tooltip: "Remove every filter and the search") {
              model.clearListFilters(.backlog)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, gutter).frame(height: 60)
        } else {
          ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DS.space.md) {
              ForEach(list.prefix(40)) { v in BacklogTile(model: model, video: v) }
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, DS.space.md)
          }
          .scrollIndicators(.never)
          .frame(height: 176)
          .transition(.dsMove(.bottom))
        }
      }
    }
    .background(DS.color.background)
  }

  private func toggle() { dsWithAnimation { expanded.toggle() } }
}

struct BacklogTile: View {
  @Bindable var model: AppModel
  let video: Video

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .topTrailing) {
        DSXThumb(model: model, video: video, width: 66)
        if let s = video.score {
          Text("\(s)").font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(height: 16)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(4)
        }
      }
      Text(model.displayName(video)).font(DS.type.caption).foregroundStyle(DS.color.text).lineLimit(2)
        .frame(width: 92, alignment: .leading)
    }
    .frame(width: 92, alignment: .leading)
    .contentShape(Rectangle())
    .draggable("video:\(video.id)") { DSXThumb(model: model, video: video, width: 54) }
    .contextMenu { VideoContextMenu(model: model, video: video) }
    .dsTooltip("Drag onto a day to plan it")
  }
}

/// Loading placeholder shaped like the grid.
struct WeekSkeleton: View {
  @Environment(\.screenGutter) private var gutter
  var body: some View {
    GeometryReader { g in
      let colW = max(96, (g.size.width - 2 * gutter - 6 * DS.space.sm) / 7)
      HStack(alignment: .top, spacing: DS.space.sm) {
        ForEach(0..<7, id: \.self) { _ in
          VStack(alignment: .leading, spacing: DS.space.xs) {
            DSSkeleton(width: 48, height: 14)
            DSSkeleton(width: colW, height: colW * 16 / 9, radius: DS.radius.md)
            DSSkeleton(width: colW * 0.7, height: 12)
          }
        }
      }
      .padding(.horizontal, gutter)
    }
    .accessibilityLabel("Loading the week")
  }
}
