import DJQCore
import SwiftUI

/// The Calendar's shared hover and tooltip words.
enum CalendarWords {
  static let pinned = "Pinned: stays on this day"
  static let moreHelp = "Move, set a time, unschedule or skip"
}

/// A clip's actions on every card and row (⋯ and right-click, `C.CTX` Motion's Do later · Unschedule menu). Native menu
/// items show no tooltip, so a disabled item carries its reason in the title.
struct CalendarClipMenu: View {
  @Bindable var model: AppModel
  let video: Video
  /// nil: a retry or repost with no day of its own.
  let slot: PlanSlot?
  let posts: [Platform: PlatformPost]
  /// The day showing, when it can differ from the slot's (a shifted post in Day view).
  var day: String? = nil

  var body: some View {
    let moveWhy = model.calendarMoveBlocker(slot, posts: posts)
    // Round 21: a set-time item keeps its minute. Post today would drop it, so it says why not (Core's words).
    let timed = slot?.isExact == true || model.setTime(video.id) != nil
    Button("Move to…" + AppModel.menuReason(moveWhy), systemImage: "calendar") { model.calendarPinTarget = [video.id] }
      .disabled(moveWhy != nil)
    if let slot, !timed, slot.date == day ?? slot.date {
      Button(slot.pinned ? "Pinned to this day" : "Pin to this day" + AppModel.menuReason(moveWhy), systemImage: "pin") {
        model.pin(video.id, dayKey: slot.date)
      }
      .disabled(slot.pinned || moveWhy != nil)
    }
    let todayWhy = timed ? StageWording.hasSetTime : moveWhy
    Button("Post today" + AppModel.menuReason(todayWhy), systemImage: "bolt") { model.postTodayAsking([video.id]) }
      .disabled(todayWhy != nil)
    Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id) }
    Divider()
    let timeWhy = model.postAtBlocker(video)
    Button((timed ? "Change set time…" : "Post at a set time…") + AppModel.menuReason(timeWhy), systemImage: "clock") { model.askPostAt([video.id]) }
      .disabled(timeWhy != nil)
    if timed {
      Button(StageWording.useRegularSchedule, systemImage: "arrow.uturn.backward") { model.clearSetTimeAsking([video.id]) }
    }
    Divider()
    let unscheduleWhy = model.calendarUnscheduleBlocker(video, slot: slot)
    Button("Unschedule" + AppModel.menuReason(unscheduleWhy), systemImage: "calendar.badge.minus") { model.calendarUnschedule(video.id) }
      .disabled(unscheduleWhy != nil)
    let skippable = posts.values.filter { model.canSkip($0) }.sorted { $0.platform < $1.platform }
    Menu(skippable.isEmpty ? "Skip platform — nothing left to skip" : "Skip platform") {
      ForEach(skippable) { p in Button("Skip \(p.platform.displayName)") { model.skip(p) } }
    }
    .disabled(skippable.isEmpty)
    Divider()
    Button("Preview", systemImage: "play.rectangle") { model.previewVideo = video }
    Button("Show in Queue", systemImage: "list.bullet") { model.setSelection([video.id], screen: .queue); model.screen = .queue }
  }
}

/// Drag source for a clip (only future clips with nothing posted).
struct SlotDrag: ViewModifier {
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

/// Repost / retry that isn't part of a plan slot: "↻ X 8:00 PM · Retry ●".
struct ExtraPostChip: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let status = model.postStatus(post)
    HStack(spacing: 5) {
      if post.kind != .regular {
        Image(systemName: post.kind == .repost ? "arrow.uturn.forward" : "arrow.clockwise")
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.color.textSecondary)
      }
      Image(systemName: post.platform.dsSymbol).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DS.color.textSecondary)
      Text("\(post.platform.dsxCompactName) \(AppModel.shortClock(post.scheduledAt, tz: model.tz))")
        .font(DS.type.microCompact).foregroundStyle(DS.color.text).lineLimit(1).minimumScaleFactor(0.9)
      Spacer(minLength: 2)
      if let dot = status.dot { Circle().fill(dot).frame(width: 6, height: 6) }
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(DS.color.surfaceSunken, in: Capsule())
    .dsTooltip(help)
    .contextMenu { PostContextMenu(model: model, post: post) }
  }

  private var help: String {
    let name = model.video(post.videoId).map(model.displayName) ?? "a clip"
    switch post.kind {
    case .repost: return "Repost of \(name) (new version)"
    case .retry: return "Re-queued attempt #\(post.attemptNo) of \(name)"
    default:
      // A set-time post is on another day only when YouTube's quiet hours put it there.
      if model.hasSetTime(post) { return "\(post.platform.displayName) post of \(name), set time moved out of YouTube's quiet hours" }
      return "\(post.platform.displayName) post of \(name)" + (model.calendarWasMoved(post) ? ", moved to this day" : ", just after midnight")
    }
  }
}
