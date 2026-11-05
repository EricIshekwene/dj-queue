import AppKit
import DJQCore
import Observation
import SwiftUI

/// Which Posts cards Eric opened, remembered for the app session (not saved).
@MainActor
@Observable
final class PostsCardState {
  static let shared = PostsCardState()
  /// Scheduled / Posted / All: cards showing their per-platform rows.
  var expanded: Set<String> = []
  /// Problems: cards whose unaffected platforms ("+4 fine") are shown too.
  var fineShown: Set<String> = []
}

/// One Posts card per (clip, scheduled day) (round 3 F4, DSCard): cover · title + session · day and time span ·
/// one-line status summary · platform chips coloured by state · "Show platforms" chevron that reveals the
/// per-platform rows (time, state pill, link, the usual actions; click a row → inspector). Problems: always open,
/// the affected platforms as problem cards with their fixes, the rest folded into "+N fine".
struct PostGroupCard: View {
  @Bindable var model: AppModel
  let group: PostGroup
  /// Post ids in list order (⇧-click ranges).
  let ordered: [String]
  var compact = false
  /// Problems tab: `group.posts` are the problem posts; the clip's other posts that day are "fine".
  var problems = false
  var primaryProblemId: String? = nil
  @State private var hovering = false
  private var state: PostsCardState { .shared }

  private var fine: [PlatformPost] {
    guard problems else { return [] }
    let ids = Set(group.posts.map(\.id))
    return model.posts.filter { $0.videoId == group.videoId && !ids.contains($0.id) && model.dm.key($0.scheduledAt) == group.day }
      .sorted { ($0.scheduledAt, $0.platform, $0.attemptNo) < ($1.scheduledAt, $1.platform, $1.attemptNo) }
  }

  private var allPosts: [PlatformPost] { group.posts + fine }

  var body: some View {
    let ids = group.posts.map(\.id)
    let sel = model.selected(.posts)
    let allSelected = !ids.isEmpty && ids.allSatisfy(sel.contains)
    let open = problems || state.expanded.contains(group.id)
    let inspected = model.postsSelection.map { id in allPosts.contains { $0.id == id } } ?? false
    DSCard(variant: .outline, padding: DS.space.sm, isSelected: allSelected || inspected) {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        header(ids: ids, allSelected: allSelected, someSelected: !sel.isEmpty, open: open)
        if problems {
          problemBody
        } else if open {
          rows(group.posts)
        } else {
          chips.padding(.leading, chipInset)
        }
      }
    }
    .onHover { hovering = $0 }
    .contextMenu {
      if group.posts.count == 1, let p = group.posts.first { PostContextMenu(model: model, post: p) }
      Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(group.videoId) }
    }
    .onAppear { if let p = group.posts.first { model.requestPreview(post: p) } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title), \(dayText), \(group.summary)")
  }

  private var video: Video? { model.video(group.videoId) }
  private var title: String { video.map(model.displayName) ?? group.videoId }
  private var chipInset: CGFloat { 20 + DS.space.sm + 36 + DS.space.sm }

  // MARK: Header

  private func header(ids: [String], allSelected: Bool, someSelected: Bool, open: Bool) -> some View {
    HStack(alignment: .center, spacing: DS.space.sm) {
      DSCheckbox(isOn: allSelected, size: 20, shape: .circle) { toggleGroup(ids, allSelected) }
        .opacity(hovering || allSelected || someSelected ? 1 : 0.0001)
        .dsTooltip(allSelected ? "Deselect these \(ids.count) posts" : "Select these \(ids.count) posts")
      BrowsePoster(model: model, video: video, width: 36, height: 64, post: group.posts.first)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.type.calloutMedium).foregroundStyle(DS.color.text).lineLimit(1)
        if let v = video, !model.sessionName(v).isEmpty {
          Text(model.sessionName(v)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(dayText).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.text).lineLimit(1)
        Text(problems ? problemSummary : group.summary).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
      }
      if !problems {
        Button {
          dsWithAnimation { if open { state.expanded.remove(group.id) } else { state.expanded.insert(group.id) } }
        } label: {
          Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(open ? 180 : 0))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSButtonStyle(variant: .ghost, size: .sm, iconOnly: true))
        .dsTooltip(open ? "Hide the per-platform rows" : "Show each platform's time and actions")
        .accessibilityLabel(open ? "Hide platforms" : "Show platforms")
      }
    }
    .contentShape(Rectangle())
    .dsTooltip(problems ? nil : open ? "Click to hide the platforms" : "Click to show each platform")
    .onTapGesture {
      guard !problems else { return }
      dsWithAnimation { if open { state.expanded.remove(group.id) } else { state.expanded.insert(group.id) } }
    }
  }

  /// "Sun 2 Nov · 12:30–7:00 PM" (one time when every platform posts at the same time).
  var dayText: String { PostGroupText.span(group, model: model) }

  private var problemSummary: String {
    let n = group.posts.count
    return "\(n) problem\(n == 1 ? "" : "s")" + (fine.isEmpty ? "" : " · \(fine.count) fine")
  }

  private func toggleGroup(_ ids: [String], _ allSelected: Bool) {
    var s = model.selected(.posts)
    if allSelected { s.subtract(ids) } else { s.formUnion(ids) }
    model.setSelection(s, screen: .posts)
  }

  // MARK: Collapsed: chips

  private var chips: some View {
    let multiPerPlatform = Dictionary(grouping: group.posts, by: \.platform).values.contains { $0.count > 1 }
    return HStack(spacing: 5) {
      ForEach(group.posts) { p in PostPlatformChip(post: p, model: model, showsKind: multiPerPlatform || p.kind != .regular) }
    }
  }

  // MARK: Expanded: rows

  private func rows(_ posts: [PlatformPost]) -> some View {
    VStack(spacing: 0) {
      ForEach(posts) { p in PostGroupRow(model: model, post: p, ordered: ordered, compact: compact) }
    }
    .padding(.leading, chipInset - DS.space.xs - 20 - DS.space.sm)
  }

  @ViewBuilder private var problemBody: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      ForEach(group.posts) { p in PostProblemCard(model: model, post: p, isPrimary: p.id == primaryProblemId, embedded: true) }
      let others = fine
      if !others.isEmpty {
        let shown = state.fineShown.contains(group.id)
        Button {
          dsWithAnimation { if shown { state.fineShown.remove(group.id) } else { state.fineShown.insert(group.id) } }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(shown ? 90 : 0))
            Text(shown ? "Hide \(others.count) fine" : "+\(others.count) fine").font(DS.type.captionMedium)
            if !shown { DSPlatformRow(items: others.map { ($0.platform, model.platformState($0)) }, size: 18) }
          }
          .foregroundStyle(DS.color.textSecondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsTooltip(shown ? "Hide the platforms without a problem" : "Show the platforms that posted fine")
        .padding(.leading, DS.space.xs)
        if shown { rows(others) }
      }
    }
  }
}

/// A coloured platform chip on a collapsed card: glyph + short name, tinted by the post's state; tooltip says it all.
struct PostPlatformChip: View {
  let post: PlatformPost
  let model: AppModel
  var showsKind = false

  var body: some View {
    let s = PostText.pill(post)
    let pz = model.postizRowState(post)
    let label = post.platform.shortName + (showsKind && post.kind != .regular ? " · \(post.kind == .retry ? "retry" : "repost")" : "")
    DSBadge(label, style: pz?.badgeStyle ?? s.style, icon: post.platform.dsSymbol)
      .contentShape(Capsule())
      .dsTooltip("\(post.platform.displayName) · \(pz?.text ?? s.text) · \(PostText.date(post, model: model))"
            + (post.kind == .regular ? "" : " · \(PostText.attempt(post))"))
  }
}

/// A per-platform row inside an open card: platform · time · v/# only when not v1/#1 · retry/repost label ·
/// state pill · link. Click → inspector; ⇧/⌘-click selects; right-click → post actions.
struct PostGroupRow: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  let ordered: [String]
  var compact = false
  @State private var hovering = false

  var body: some View {
    let selected = model.isSelected(post.id, in: .posts)
    let inspected = model.postsSelection == post.id
    HStack(spacing: DS.space.sm) {
      DSCheckbox(isOn: selected, size: 18, shape: .circle) { model.toggleSelection(post.id, screen: .posts) }
        .opacity(hovering || selected || !model.selected(.posts).isEmpty ? 1 : 0.0001)
        .dsTooltip(selected ? "Deselect" : "Select")
      DSPlatformIcon(platform: post.platform, size: 22, showsLabel: !compact)
        .frame(width: compact ? 24 : 130, alignment: .leading)
      // The card already says the day: rows show the time (posted rows: when it went out).
      Text(post.state == .posted ? "Posted \(PostText.date(post, model: model))" : AppModel.clockText(post.scheduledAt, tz: model.tz))
        .font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        .lineLimit(1)
      if post.versionNo != 1 {
        Text("v\(post.versionNo)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          .dsTooltip("Version \(post.versionNo)")
      }
      if post.attemptNo != 1 {
        Text("#\(post.attemptNo)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          .dsTooltip(PostText.attempt(post))
      }
      if post.kind != .regular {
        DSBadge(post.kind == .retry ? "Retry" : "Repost", style: .outline)
          .dsTooltip(post.kind == .retry ? "Tried again after a failure, same day" : "Posted again (a new version), same day")
      }
      Spacer(minLength: DS.space.xs)
      if model.isTestRun(post) { TestRunBadge() }
      if let pz = model.postizRowState(post) {
        if pz == .draft {
          DSButton("Release", icon: "paperplane", variant: .ghost, size: .sm, tooltip: "Let Postiz post this draft at its time") {
            model.releaseDraft(post)
          }
        }
        PostizBadge(model: model, post: post, state: pz)
      } else {
        PostStatePill(post: post)
      }
      Group {
        if let u = post.url, let url = URL(string: u) {
          DSIconButton("arrow.up.right.square", tooltip: "Open the live post · \(u)", size: .sm) { NSWorkspace.shared.open(url) }
        } else {
          DSIconButton("arrow.up.right.square", tooltip: "Open the live post", size: .sm, disabledReason: "No link yet — not posted") {}
            .opacity(0.5)
        }
      }
      .frame(width: 28)
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: 40)
    .background(selected || inspected ? DS.color.selected : hovering ? DS.color.hover : .clear,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { tap() }
    .contextMenu { PostContextMenu(model: model, post: post) }
    .dsTooltip("Click for details · ⌘-click to select")
  }

  private func tap() {
    let flags = NSEvent.modifierFlags
    var m: EventModifiers = []
    if flags.contains(.shift) { m.insert(.shift) }
    if flags.contains(.command) { m.insert(.command) }
    guard model.select(post.id, modifiers: m, ordered: ordered, screen: .posts) == .plainClick else { return }
    if !model.selected(.posts).isEmpty {
      model.toggleSelection(post.id, screen: .posts)
    } else {
      dsWithAnimation { model.postsSelection = model.postsSelection == post.id ? nil : post.id }
    }
  }
}

enum PostGroupText {
  /// "Sun 2 Nov · 12:30–7:00 PM" / "Sun 2 Nov · 7:00 PM".
  @MainActor static func span(_ g: PostGroup, model: AppModel) -> String {
    let day = Fmt.day(g.first, tz: model.tz, style: "EEE d MMM")
    let a = AppModel.clockText(g.first, tz: model.tz), b = AppModel.clockText(g.last, tz: model.tz)
    return "\(day) · \(timeSpan(a, b))"
  }

  /// "12:30 PM" + "7:00 PM" → "12:30–7:00 PM"; "9:00 AM" + "7:00 PM" → "9:00 AM–7:00 PM"; equal → one time.
  static func timeSpan(_ a: String, _ b: String) -> String {
    guard a != b else { return a }
    let sa = a.split(separator: " "), sb = b.split(separator: " ")
    if sa.count == 2, sb.count == 2, sa[1] == sb[1] { return "\(sa[0])–\(b)" }
    return "\(a)–\(b)"
  }
}
