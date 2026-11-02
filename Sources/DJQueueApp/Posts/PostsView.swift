import DJQCore
import SwiftUI

/// Posts (DESIGN-v2 §6.7, refs R2.POSTS Substack segmented list + R2.POSTS-alt n8n status table). Job: see what was
/// posted, and fix problems.
///
/// Toolbar "Posts" · search · Platform ▾. Tabs `Problems 2 · Scheduled · Posted · All` head the centred column.
/// Every tab shows one card per (clip, scheduled day) (`PostGroupCard`, round 3 F4): cover, title, day + time span,
/// status summary and platform chips; "Show platforms" opens the per-platform rows (click one → the 360 pt
/// inspector with attempt history, metrics, repost). Problems: cards open, the affected platforms as problem cards
/// with their fixes, the rest folded into "+N fine".
/// Bulk (checkbox / ⇧ / ⌘ / ⌘A): Reset · Skip · Retry, confirmed in a dialog, then a toast.
struct PostsView: View {
  @Bindable var model: AppModel
  @Bindable private var ui = BrowseUI.shared

  var body: some View {
    let tab = ui.postsTab
    let list = rows(tab)
    let sel = model.selectedIds(.posts)
    let inspected = model.postsSelection.flatMap { id in model.posts.first { $0.id == id } }
    ZStack {
      ScreenScaffold(model: model, screen: .posts, subtitle: subtitle, readingColumn: true) {
        if !model.posts.isEmpty {
          DSTextField(placeholder: "Search posts", text: $ui.postsSearch, isSearch: true).frame(width: 220)
          BrowseFilterMenu(placeholder: "Platform", selection: $ui.postsPlatform, anyValue: nil,
                           options: [(nil, "All platforms")] + model.settings.activePlatforms.map { (Optional($0), $0.displayName) },
                           tooltip: "Show one platform")
        }
      } content: {
        HStack(alignment: .top, spacing: DS.space.md) {
          column(tab: tab, list: list, compact: inspected != nil)
            .frame(maxWidth: DS.size.readingColumn)
          if let p = inspected {
            PostInspector(model: model, post: p)
              .id(p.id)
              .frame(width: 360)
              .padding(.bottom, DS.space.md)
              .transition(.dsMove(.trailing))
          }
        }
        .frame(maxWidth: .infinity)
        .modifier(BrowseGutter())
        .dsAnimation(DS.motion.layout, value: inspected?.id)
      }
      .dsBulkBar(isPresented: !sel.isEmpty) { bulkBar(sel) }
      if let b = ui.pendingPostBulk {
        BrowseModal(onDismiss: { ui.pendingPostBulk = nil }) { PostBulkDialog(model: model, bulk: b) }
      }
    }
    .onAppear {
      consumeFilter()
      register(list.map(\.id))
    }
    .onChange(of: model.postsFilter) { consumeFilter() }
    .onChange(of: list.map(\.id)) { _, ids in register(ids) }
  }

  // MARK: Data

  /// Attention card "Review" → `reviewProblems()` sets `postsFilter = .problems`; open that tab once.
  private func consumeFilter() {
    guard model.postsFilter == .problems else { return }
    ui.postsTab = .problems
    model.postsFilter = .all
  }

  private func register(_ ids: [String]) {
    model.visibleIds[.posts] = ids
    let keep = Set(ids)
    if let s = model.selection[.posts], !s.isSubset(of: keep) { model.selection[.posts] = s.intersection(keep) }
  }

  private func scoped(_ posts: [PlatformPost]) -> [PlatformPost] {
    let q = ui.postsSearch.trimmingCharacters(in: .whitespaces)
    return posts.filter { p in
      (ui.postsPlatform == nil || p.platform == ui.postsPlatform)
        && (q.isEmpty || p.platform.displayName.localizedCaseInsensitiveContains(q)
            || (model.video(p.videoId).map { model.displayName($0).localizedCaseInsensitiveContains(q) || $0.tag.localizedCaseInsensitiveContains(q) } ?? false))
    }
  }

  private func rows(_ tab: PostsTab) -> [PlatformPost] {
    switch tab {
    case .problems: return scoped(model.problems)
    case .scheduled: return scoped(model.posts.filter { !$0.state.isTerminal && $0.state != .overdue }).sorted { $0.scheduledAt < $1.scheduledAt }
    case .posted: return scoped(model.posts.filter { $0.state == .posted }).sorted { ($0.postedAt ?? $0.scheduledAt) > ($1.postedAt ?? $1.scheduledAt) }
    case .all: return scoped(model.posts).sorted { $0.scheduledAt > $1.scheduledAt }
    }
  }

  private var subtitle: String? {
    guard model.loaded, !model.posts.isEmpty else { return nil }
    let posted = model.posts.filter { $0.state == .posted }.count
    let scheduled = model.posts.filter { !$0.state.isTerminal && $0.state != .overdue }.count
    return "\(posted) posted · \(scheduled) scheduled"
  }

  // MARK: Column

  @ViewBuilder private func column(tab: PostsTab, list: [PlatformPost], compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      if !model.posts.isEmpty {
        DSTabs(selection: $ui.postsTab, tabs: [
          DSTab(value: .problems, title: "Problems", count: model.problems.isEmpty ? nil : model.problems.count),
          DSTab(value: .scheduled, title: "Scheduled"),
          DSTab(value: .posted, title: "Posted"),
          DSTab(value: .all, title: "All"),
        ])
        // DSTabs has no per-tab tooltip: one quiet line says what the open tab holds (e.g. Scheduled leaves out missed).
        Text(tab.blurb).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).padding(.leading, DS.space.xs)
      }
      if !model.loaded {
        Color.clear
      } else if model.posts.isEmpty {
        DSEmptyState(icon: "paperplane", title: "No posts yet", message: "Posts appear once a week is approved.",
                     actionTitle: "Open Week") { model.screen = .week }
      } else if list.isEmpty {
        if tab == .problems && ui.postsSearch.isEmpty && ui.postsPlatform == nil {
          DSEmptyState(icon: "checkmark.circle", title: "No problems", message: "Every post went out or is on schedule.",
                       actionTitle: "Show all posts") { ui.postsTab = .all }
        } else {
          DSEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No posts match",
                       message: "Nothing in \(tab.title) fits this search or platform.", actionTitle: "Clear filters") {
            ui.postsSearch = ""
            ui.postsPlatform = nil
          }
        }
      } else {
        let groups = PostGrouping.group(list, day: { model.dm.key($0) })
        let ordered = list.map(\.id)
        let primaryId = tab == .problems ? list.first { PostFixes(model: model, post: $0).fixReason == nil }?.id : nil
        ScrollView {
          LazyVStack(spacing: DS.space.xs) {
            ForEach(groups) { g in
              PostGroupCard(model: model, group: g, ordered: ordered, compact: compact, problems: tab == .problems,
                            primaryProblemId: primaryId)
            }
          }
          .padding(.vertical, DS.space.xxs)
          .padding(.bottom, ScreenMetrics.bulkBarInset)
        }
        .scrollIndicators(.automatic)
      }
    }
  }

  // MARK: Bulk (reset / skip / retry)

  private func bulkBar(_ sel: [String]) -> some View {
    let posts = sel.compactMap { id in model.posts.first { $0.id == id } }
    let resettable = posts.filter(model.canReset).count
    let skippable = posts.filter(model.canSkip).count
    let retryable = posts.filter(PostFixes.canRetry).count
    return ScreenBulkBar(model: model, screen: .posts) {
      bulkButton("Reset", icon: "arrow.counterclockwise", n: resettable, tooltip: "Back to Planned, errors cleared",
                 why: "None of these can be reset (planned, or their time passed)") {
        ui.pendingPostBulk = PostBulk(op: .reset, postIds: sel)
      }
      bulkButton("Skip", icon: "forward", n: skippable, tooltip: "Don't post these on their platforms", why: "These are already finished") {
        ui.pendingPostBulk = PostBulk(op: .skip, postIds: sel)
      }
      bulkButton("Retry", icon: "arrow.clockwise", n: retryable, tooltip: "Try failed posts again on the next slot",
                 why: "Only failed posts can be retried") {
        ui.pendingPostBulk = PostBulk(op: .retry, postIds: sel)
      }
    }
  }

  private func bulkButton(_ title: String, icon: String, n: Int, tooltip: String, why: String, action: @escaping () -> Void) -> some View {
    Button(n > 0 && n < model.selected(.posts).count ? "\(title) \(n)" : title, systemImage: icon, action: action)
      .disabled(n == 0)
      .contentShape(Rectangle())
      .dsTooltip(tooltip, disabledReason: n == 0 ? why : nil)
  }
}

// MARK: - Rows

/// Column labels above the post rows (aligned with PostRowView).
struct PostListHeader: View {
  var compact = false
  var body: some View {
    HStack(spacing: DS.space.sm) {
      Color.clear.frame(width: 20, height: 1)
      Color.clear.frame(width: 24, height: 1)
      Text("Clip").frame(maxWidth: .infinity, alignment: .leading)
      Text(compact ? "" : "Platform").frame(width: compact ? 24 : 130, alignment: .leading)
      Text("Ver.").frame(width: 30, alignment: .leading)
      if !compact { Text("Try").frame(width: 36, alignment: .leading) }
      Text("State").frame(width: 96, alignment: .leading)
      Text("Date").frame(width: 104, alignment: .leading)
      Color.clear.frame(width: 28, height: 1)
    }
    .font(DS.type.micro)
    .foregroundStyle(DS.color.textTertiary)
    .padding(.horizontal, DS.space.xs)
    .frame(height: 32)
    .overlay(alignment: .bottom) { DSSeparator() }
  }
}

struct PostRowView: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  let ordered: [String]
  var compact = false
  @State private var hovering = false

  var body: some View {
    let v = model.video(post.videoId)
    let selected = model.isSelected(post.id, in: .posts)
    let inspected = model.postsSelection == post.id
    let showCheck = hovering || selected || !model.selected(.posts).isEmpty
    HStack(spacing: DS.space.sm) {
      DSCheckbox(isOn: selected, size: 20, shape: .circle) { model.toggleSelection(post.id, screen: .posts) }
        .opacity(showCheck ? 1 : 0.0001)
        .dsTooltip(selected ? "Deselect" : "Select")
      BrowsePoster(model: model, video: v, width: 24, height: 42)
      VStack(alignment: .leading, spacing: 1) {
        Text(v.map(model.displayName) ?? post.videoId).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
        if let v { Text(model.sessionName(v)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      DSPlatformIcon(platform: post.platform, size: 22, showsLabel: !compact)
        .frame(width: compact ? 24 : 130, alignment: .leading)
      Text("v\(post.versionNo)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        .frame(width: 30, alignment: .leading)
        .dsTooltip("Version \(post.versionNo)")
      if !compact {
        Text("#\(post.attemptNo)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          .frame(width: 36, alignment: .leading)
          .dsTooltip(PostText.attempt(post))
      }
      PostStatePill(post: post).frame(width: 96, alignment: .leading)
      Text(PostText.date(post, model: model)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        .lineLimit(1).frame(width: 104, alignment: .leading)
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
    .frame(height: DS.size.listRow)
    .background(selected || inspected ? DS.color.selected : hovering ? DS.color.hover : .clear,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .overlay(alignment: .bottom) { if !(selected || inspected || hovering) { DSSeparator().padding(.horizontal, DS.space.xs) } }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { tap() }
    .contextMenu { PostContextMenu(model: model, post: post) }
    .onAppear { if let v { model.requestPoster(v) } }
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

/// The post's state as a pill (status = chip, never a sentence).
struct PostStatePill: View {
  let post: PlatformPost
  var body: some View {
    let s = PostText.pill(post)
    DSBadge(s.text, style: s.style, icon: s.icon)
  }
}

extension PostsTab {
  /// What the tab holds, in one line (shown under the tabs).
  var blurb: String {
    switch self {
    case .problems: "Failed, missed or copyright posts that need you"
    case .scheduled: "Posts still to go out (missed ones are in Problems)"
    case .posted: "Posts that went live"
    case .all: "Every attempt on every platform"
    }
  }
}

/// Shared wording for posts.
enum PostText {
  static func pill(_ p: PlatformPost) -> (text: String, style: DSBadgeStyle, icon: String?) {
    switch p.state {
    case .posted: return ("Posted", .soft(.success), nil)
    case .failed:
      return p.resolution == nil ? (p.errorType?.displayName ?? "Failed", .soft(.danger), nil) : ("Retried", .outline, nil)
    case .copyrightBlocked, .copyrightMuted, .removed:
      switch p.resolution {
      case "accepted": return ("Accepted", .outline, "c.circle")
      case "reuploaded": return ("Re-uploaded", .outline, "c.circle")
      default: return (p.state == .removed ? "Removed" : p.state == .copyrightMuted ? "Muted" : "Blocked", .soft(.danger), "c.circle")
      }
    case .overdue: return ("Missed", .soft(.warning), nil)
    case .due: return ("Due now", .solid, nil)
    case .planned: return ("Planned", .soft(.info), nil)
    case .rendering: return ("Rendering", .soft(.info), nil)
    case .rendered: return ("Ready", .soft(.info), nil)
    case .skipped: return ("Skipped", .outline, nil)
    }
  }

  /// "5 Nov · 7:00 PM": posted time for posted posts, else the scheduled time.
  @MainActor static func date(_ p: PlatformPost, model: AppModel) -> String {
    let d = p.state == .posted ? (p.postedAt ?? p.scheduledAt) : p.scheduledAt
    return "\(Fmt.day(d, tz: model.tz, style: "d MMM")) · \(AppModel.clockText(d, tz: model.tz))"
  }

  static func attempt(_ p: PlatformPost) -> String {
    let kind = p.kind == .regular ? "" : p.kind == .retry ? " · retry" : " · repost"
    return "Attempt \(p.attemptNo)\(kind)"
  }

  /// One line for a problem ("Copyright blocked", "Too long", "Missed slot").
  static func problemType(_ p: PlatformPost) -> String {
    if p.state == .overdue { return "Missed slot" }
    return p.errorType?.displayName ?? p.state.displayName
  }
}
