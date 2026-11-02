import DJQCore
import SwiftUI

/// W.L: header (week picker, Draft/Approved, Approve week) · 7-column grid · backlog drawer.
struct WeekView: View {
  @Bindable var model: AppModel

  private var ws: String { model.weekStart.isEmpty ? model.planner.weekStart(for: model.now) : model.weekStart }
  private var days: [String] { model.dm.weekDays(ws) }
  /// Loaded off-main by the model's refresh for `model.weekStart` (no DB work in body).
  private var slots: [PlanSlot] { model.weekSlots.filter { $0.weekStart == ws } }
  private var state: WeekState? { model.weekStates[ws] }

  var body: some View {
    // FOUNDATION: round-1 body inside the shared scaffold until the Planning leaf rewrites this screen.
    ScreenScaffold(model: model, screen: .week, content: { legacyBody })
  }

  @ViewBuilder private var legacyBody: some View {
    let slots = self.slots
    VStack(spacing: 0) {
      header(slots)
      Divider()
      if slots.isEmpty && model.ordered.isEmpty {
        EmptyState(symbol: "calendar.badge.exclamationmark", title: "Nothing ready to plan",
                   subtitle: "Edit and score videos to make them ready.", buttonTitle: "Open Queue") { model.screen = .queue }
      } else {
        grid(slots)
      }
      BacklogDrawer(model: model, expanded: $model.weekBacklogExpanded, weekDays: days)
    }
    .confirmationDialog("Replace the planned video?", isPresented: Binding(get: { model.pendingReplace != nil },
                                                                          set: { if !$0 { model.pendingReplace = nil } })) {
      Button("Replace") {
        if let r = model.pendingReplace { model.pin(r.videoId, dayKey: r.day) }
        model.pendingReplace = nil
      }
      Button("Cancel", role: .cancel) { model.pendingReplace = nil }
    } message: {
      Text("“\(model.pendingReplace.map { r in model.video(r.replaced).map(model.displayName) ?? "" } ?? "")” goes back to the backlog.")
    }
  }

  // MARK: W.S1 header (Assembly ref)

  private func header(_ slots: [PlanSlot]) -> some View {
    let start = model.dm.date(ws), end = model.dm.date(model.dm.addDays(ws, 6))
    let thisWeek = model.planner.weekStart(for: model.now)
    let label = ws == thisWeek ? "This week" : (ws == model.dm.addDays(thisWeek, 7) ? "Next week" : (ws < thisWeek ? "Past week" : "Later"))
    return HStack(spacing: 10) {
      HStack(spacing: 2) {
        Button { model.weekStart = model.dm.addDays(ws, -7) } label: { Image(systemName: "chevron.left") }
        Button("Today") { model.weekStart = thisWeek }
        Button { model.weekStart = model.dm.addDays(ws, 7) } label: { Image(systemName: "chevron.right") }
      }
      .buttonStyle(.borderless)
      Text("\(Fmt.day(start, tz: model.tz, style: "d MMM")) – \(Fmt.day(end, tz: model.tz, style: "d MMM"))")
        .font(.system(size: 17, weight: .semibold))
      Text(label).font(DS.Font.body).foregroundStyle(.secondary)
      if !slots.isEmpty, let l = model.weekLabel(ws) {
        StatusPill(text: l.text, tint: l.tint, icon: l.icon)
          .help(l.text == "Locked" ? "The week has started: past days are fixed; future days can still change." : "")
      }
      if model.settings.paused { StatusPill(text: "Paused", tint: .orange, icon: "pause.fill") }
      Spacer()
      Menu {
        Button("Propose open days", systemImage: "wand.and.stars") { model.proposeWeek(ws) }
          .disabled(state == .approved || ws < thisWeek)
        Button("Rebuild week", systemImage: "arrow.clockwise") { model.rebuildWeek(ws) }
        Button("Push plan by a day", systemImage: "calendar.badge.clock") { model.pushPlan(days: 1) }
      } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().help("Rebuild · Push a day")
      if slots.isEmpty && ws >= thisWeek {
        Button("Propose week") { model.proposeWeek(ws) }
          .buttonStyle(.borderedProminent).controlSize(.large)
      } else if state != .approved {
        Button {
          model.approveWeek(ws)
        } label: { Label("Approve week", systemImage: "checkmark.seal") }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(slots.isEmpty)
          .help("⌘↩")
      }
    }
    .padding(.horizontal, DS.Space.l)
    .frame(height: 56)
  }

  // MARK: W.S2 grid (Hootsuite ref)

  private func grid(_ slots: [PlanSlot]) -> some View {
    let bySlotDate = Dictionary(grouping: slots, by: \.date)
    let awake = model.weekAwake
    return GeometryReader { g in
      let colW = (g.size.width - 6) / 7
      ScrollView {
        HStack(alignment: .top, spacing: 0) {
          ForEach(Array(days.enumerated()), id: \.element) { i, day in
            DayColumn(model: model, day: day, slots: (bySlotDate[day] ?? []).sorted { $0.position < $1.position },
                      approved: state == .approved, awake: awake, otherSlots: slots)
              .frame(width: colW)
              .frame(minHeight: g.size.height, alignment: .top)
            if i < 6 { Divider() }
          }
        }
      }
    }
  }
}

struct DayColumn: View {
  @Bindable var model: AppModel
  let day: String
  let slots: [PlanSlot]
  let approved: Bool
  let awake: [DateInterval]
  let otherSlots: [PlanSlot]
  @State private var targeted = false

  private var isToday: Bool { day == model.todayKey }
  private var isPast: Bool { day < model.todayKey }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      dayHeader
      ForEach(slots) { s in
        if let v = model.video(s.videoId) {
          WeekCard(model: model, slot: s, video: v, approved: approved, isPast: isPast, otherSlots: otherSlots)
        }
      }
      ForEach(extraPosts) { p in ExtraChip(model: model, post: p) }
      if slots.isEmpty && !isPast {
        RoundedRectangle(cornerRadius: DS.Radius.card)
          .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .foregroundStyle(targeted ? Color.accentColor : Color.primary.opacity(0.15))
          .frame(height: 120)
          .overlay(Text("Drop a video").font(DS.Font.secondary).foregroundStyle(.tertiary))
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(isPast ? Color.primary.opacity(0.035) : (targeted ? Color.accentColor.opacity(0.06) : .clear))
    .overlay(alignment: .top) { if isToday { Rectangle().fill(Color.accentColor).frame(height: 2) } }
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first else { return false }
      return drop(item)
    } isTargeted: { targeted = $0 && !isPast }
  }

  /// Reposts and re-queued failures that land on this day (W.S5).
  private var extraPosts: [PlatformPost] {
    model.posts.filter { $0.planSlotId == nil && model.dm.key($0.scheduledAt) == day }
  }

  private var dayHeader: some View {
    let d = model.dm.date(day)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(Fmt.day(d, tz: model.tz, style: "EEE").uppercased()).font(DS.Font.eyebrow).foregroundStyle(isToday ? Color.accentColor : .secondary)
        Spacer()
        Text(Fmt.day(d, tz: model.tz, style: "d"))
          .font(.system(size: 15, weight: .semibold).monospacedDigit())
          .foregroundStyle(isToday ? Color.white : (isPast ? Color.secondary : Color.primary))
          .frame(width: 26, height: 26)
          .background(isToday ? Color.accentColor : .clear, in: Circle())
      }
      if isPast || isToday { AwakeStrip(model: model, day: day, awake: awake).frame(height: 4) }
    }
  }

  /// Same-day and past-day drops are refused; a backlog video dropped on a planned day asks before replacing.
  private func drop(_ item: String) -> Bool {
    guard !isPast else { model.show("Past days can't be changed", error: true); return false }
    if item.hasPrefix("slot:") {
      let id = String(item.dropFirst(5))
      guard let src = otherSlots.first(where: { $0.id == id }), src.date != day else { return false }
      guard src.date >= model.todayKey else { model.show("That video already went out", error: true); return false }
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

/// Thin 24 h bar: green awake, hatched grey asleep / Mac off (W.S4).
struct AwakeStrip: View {
  @Bindable var model: AppModel
  let day: String
  let awake: [DateInterval]

  var body: some View {
    GeometryReader { g in
      let start = model.dm.date(day)
      let end = min(model.dm.date(model.dm.addDays(day, 1)), model.now)
      let total = 86400.0
      ZStack(alignment: .leading) {
        Hatch().fill(Color.secondary.opacity(0.35))
          .frame(width: g.size.width * max(0, end.timeIntervalSince(start)) / total)
        ForEach(Array(awake.enumerated()), id: \.offset) { _, iv in
          let a = max(iv.start, start), b = min(iv.end, end)
          if b > a {
            Rectangle().fill(Color.green.opacity(0.7))
              .frame(width: max(1, g.size.width * b.timeIntervalSince(a) / total))
              .offset(x: g.size.width * a.timeIntervalSince(start) / total)
          }
        }
      }
      .clipShape(Capsule())
    }
    .help("Mac awake (green) / off or asleep (hatched)")
  }
}

struct Hatch: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    var x = r.minX - r.height
    while x < r.maxX {
      p.move(to: CGPoint(x: x, y: r.maxY))
      p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
      p.addLine(to: CGPoint(x: x + r.height + 1.5, y: r.minY))
      p.addLine(to: CGPoint(x: x + 1.5, y: r.maxY))
      p.closeSubpath()
      x += 4
    }
    return p
  }
}

/// W.S2.a video card + W.S2.b slot chips.
struct WeekCard: View {
  @Bindable var model: AppModel
  let slot: PlanSlot
  let video: Video
  let approved: Bool
  let isPast: Bool
  let otherSlots: [PlanSlot]

  private var posts: [Platform: PlatformPost] {
    Dictionary((model.postsBySlot[slot.id] ?? []).map { ($0.platform, $0) }, uniquingKeysWith: { a, b in a.attemptNo > b.attemptNo ? a : b })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        CoverThumb(video: video, width: 54, height: 96)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.displayName(video)).font(.system(size: 12, weight: .semibold)).lineLimit(3)
          HStack(spacing: 4) {
            Text(video.score.map(String.init) ?? "–").font(DS.Font.score)
            Text("v\(posts.values.map(\.versionNo).max() ?? 1)").font(DS.Font.secondary).foregroundStyle(.secondary)
            if slot.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
          }
          if hasProblem { StatusPill(text: "Needs you", tint: .red, icon: "exclamationmark.triangle.fill") }
        }
      }
      VStack(spacing: 3) {
        ForEach(model.settings.activePlatforms) { p in
          SlotChip(model: model, platform: p, post: posts[p], date: slot.date, position: slot.position, approved: approved)
        }
      }
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.card))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.card)
        .strokeBorder(hasProblem ? Color.red.opacity(0.7) : Color.primary.opacity(approved ? 0.12 : 0.25),
                      style: StrokeStyle(lineWidth: hasProblem ? 1.5 : 1, dash: approved ? [] : [4, 3]))
    }
    .opacity(isPast ? 0.8 : 1)
    .draggable("slot:\(slot.id)") {
      CoverThumb(video: video, width: 54, height: 96)
    }
    .contextMenu { menu }
    .onTapGesture(count: 2) { model.openEditor(video.id) }
  }

  private var hasProblem: Bool { posts.values.contains { $0.state.isProblem && $0.resolution == nil } }

  @ViewBuilder private var menu: some View {
    // Locked: past days are fixed; only future slots can be swapped, removed or pinned.
    Menu("Swap with") {
      ForEach(otherSlots.filter { $0.id != slot.id && $0.date >= model.todayKey }) { o in
        Button("\(Fmt.day(model.dm.date(o.date), tz: model.tz, style: "EEE d")) · \(model.video(o.videoId).map(model.displayName) ?? "")") {
          model.swap(slot.id, o.id)
        }
      }
    }
    .disabled(isPast)
    Button("Remove from week", systemImage: "minus.circle") { model.removeSlot(slot.id) }.disabled(isPast)
    Button(slot.pinned ? "Pinned to this day" : "Pin to this day", systemImage: "pin") { model.pin(video.id, dayKey: slot.date) }
      .disabled(slot.pinned || isPast)
    Menu("Skip platform") {
      ForEach(posts.values.filter { !$0.state.isTerminal }.sorted { $0.platform < $1.platform }) { p in
        Button(p.platform.displayName) { model.skip(p) }
      }
    }
    .disabled(!approved)
    Divider()
    Button("Edit", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id) }
    Button("Show in Queue") { model.setSelection([video.id], screen: .queue); model.screen = .queue }
  }
}

/// "TT 7:00p ●" chip coloured by post state (planned/rendered/due/posted/failed/©/overdue/missed/skipped).
struct SlotChip: View {
  @Bindable var model: AppModel
  let platform: Platform
  let post: PlatformPost?
  let date: String
  let position: Int
  let approved: Bool

  var body: some View {
    let time = post.map { Fmt.compactTime($0.scheduledAt, tz: model.tz) }
      ?? Fmt.compactMinutes(model.settings.slot(for: platform) + position * model.settings.secondPostOffsetMinutes)
    let tint: Color = post?.state.tint ?? (approved ? DS.Status.planned : Color.secondary)
    let paused = model.settings.pausedPlatforms.contains(platform)
    HStack(spacing: 5) {
      Text(platform.shortName).font(.system(size: 9, weight: .heavy, design: .rounded)).frame(width: 16, alignment: .leading)
      Text(time).font(.system(size: 10.5).monospacedDigit())
      Spacer(minLength: 2)
      if let s = post?.state, s.isProblem || s == .posted || s == .skipped {
        Text(s == .overdue ? "Missed" : s.displayName).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
      }
      if let s = post?.state, s.isCopyright {
        Image(systemName: "c.circle.fill").font(.system(size: 9))
      } else {
        StateDot(tint: tint, filled: post != nil, size: 6)
      }
    }
    .foregroundStyle(post?.state.isProblem == true ? tint : Color.primary.opacity(post?.state == .skipped ? 0.4 : 0.85))
    .strikethrough(post?.state == .skipped || paused)
    .padding(.horizontal, 5)
    .frame(height: 18)
    .background(tint.opacity(post == nil ? 0.05 : 0.12), in: RoundedRectangle(cornerRadius: 4))
    .help("\(platform.displayName) · \(post?.state.displayName ?? (approved ? "Planned" : "Draft"))\(paused ? " · platform paused" : "")")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(platform.displayName): \(post?.state.displayName.lowercased() ?? (approved ? "planned" : "draft")), \(time)")
    .contextMenu { if let post { PostContextMenu(model: model, post: post) } }
  }
}

/// Retry / repost chips that aren't part of a plan slot.
struct ExtraChip: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: post.kind == .repost ? "arrow.uturn.forward" : "arrow.clockwise").font(.system(size: 9, weight: .bold))
      Text(post.platform.shortName).font(.system(size: 9, weight: .heavy, design: .rounded))
      Text(Fmt.compactTime(post.scheduledAt, tz: model.tz)).font(.system(size: 10).monospacedDigit())
      Text(post.kind == .repost ? "Repost v\(post.versionNo)" : "Retry").font(.system(size: 10)).lineLimit(1)
      Spacer(minLength: 0)
      StateDot(tint: post.state.tint, size: 6)
    }
    .padding(.horizontal, 6)
    .frame(height: 20)
    .background(post.state.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    .help(post.kind == .repost ? "Repost (v\(post.versionNo))" : "Re-queued attempt #\(post.attemptNo)")
    .contextMenu { PostContextMenu(model: model, post: post) }
  }
}

/// W.S3 backlog drawer (collapsed by default): next ready videos in sort order, drag into a day.
struct BacklogDrawer: View {
  @Bindable var model: AppModel
  @Binding var expanded: Bool
  let weekDays: [String]

  private var backlog: [Video] {
    let planned = Set(model.upcomingSlots.map(\.videoId))
    return model.ordered.filter { !planned.contains($0.id) }
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      Button { withAnimation(.snappy) { expanded.toggle() } } label: {
        HStack(spacing: 8) {
          Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .bold))
          Text("Backlog").font(DS.Font.bodyStrong)
          Text("\(backlog.count) ready").font(DS.Font.body).foregroundStyle(.secondary)
          Spacer()
          if expanded { Text("Drag a video onto a day").font(DS.Font.secondary).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 34)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(backlog.prefix(30)) { v in
              VStack(alignment: .leading, spacing: 4) {
                CoverThumb(video: v, width: 54, height: 96)
                Text(model.displayName(v)).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 80, alignment: .leading)
                Text(v.score.map(String.init) ?? "–").font(DS.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
              }
              .draggable("video:\(v.id)") { CoverThumb(video: v, width: 54, height: 96) }
              .contextMenu { VideoContextMenu(model: model, video: v) }
            }
          }
          .padding(.horizontal, DS.Space.l)
          .padding(.bottom, 12)
        }
        .frame(height: 150)
      }
    }
    .background(.bar)
  }
}
