import DJQCore
import SwiftUI

/// P.L: pinned red error cards, then the full table (Gumloop ref) with a detail inspector (Stripe ref).
struct PostsView: View {
  @Bindable var model: AppModel
  @State private var platform: Platform?
  @State private var range: Int? = nil
  @State private var search = ""
  @State private var sortOrder = [KeyPathComparator(\PostRow.scheduledAt, order: .reverse)]

  private var rows: [PostRow] {
    let since = range.map { model.now.addingTimeInterval(-Double($0) * 86400) }
    return model.posts
      .filter { p in
        switch model.postsFilter {
        case .all: true
        case .problems: p.state.isProblem && p.resolution == nil
        case .posted: p.state == .posted
        case .failed: p.state == .failed
        case .copyright: p.state.isCopyright
        }
      }
      .filter { platform == nil || $0.platform == platform }
      .filter { since == nil || $0.scheduledAt >= since! }
      .filter { search.isEmpty || (model.video($0.videoId).map { model.displayName($0).localizedCaseInsensitiveContains(search) } ?? false) }
      .map { PostRow(model: model, post: $0) }
      .sorted(using: sortOrder)
  }

  var body: some View {
    // FOUNDATION: round-1 body inside the shared scaffold until the Browse leaf rewrites this screen.
    ScreenScaffold(model: model, screen: .posts, content: { legacyBody })
  }

  @ViewBuilder private var legacyBody: some View {
    VStack(spacing: 0) {
      if !model.problems.isEmpty {
        VStack(spacing: 8) {
          ForEach(model.problems.prefix(3)) { p in ErrorCard(model: model, post: p, primary: p.id == model.problems.first?.id) }
          if model.problems.count > 3 {
            Button("Show all \(model.problems.count) problems") { model.postsFilter = .problems }.buttonStyle(.link)
          }
        }
        .padding(DS.Space.l)
        Divider()
      }
      filterBar
      Divider()
      if model.posts.isEmpty {
        EmptyState(symbol: "paperplane", title: "No posts yet", subtitle: "Posts appear once a week is approved.",
                   buttonTitle: "Open Week") { model.screen = .week }
      } else if rows.isEmpty {
        EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No posts match", buttonTitle: "Show all") {
          model.postsFilter = .all; platform = nil; range = nil; search = ""
        }
      } else {
        table
      }
    }
    .inspector(isPresented: $model.showInspector) {
      Group {
        if let id = model.postsSelection, let p = model.posts.first(where: { $0.id == id }) {
          PostDetail(model: model, post: p).id(p.id)  // fresh metric fields per post
        } else {
          EmptyState(symbol: "sidebar.right", title: "No post selected")
        }
      }
      .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 8) {
      Picker("Filter", selection: $model.postsFilter) {
        ForEach(PostsFilter.allCases) { f in Text(f.title).tag(f) }
      }
      .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
      Menu {
        Button("All platforms") { platform = nil }
        ForEach(Platform.allCases.sorted()) { p in Button(p.displayName) { platform = p } }
      } label: { Text(platform?.displayName ?? "Platform") }
        .menuStyle(.borderlessButton).fixedSize()
      Menu {
        Button("Any date") { range = nil }
        Button("Last 7 days") { range = 7 }
        Button("Last 30 days") { range = 30 }
      } label: { Text(range.map { "Last \($0) days" } ?? "Date") }
        .menuStyle(.borderlessButton).fixedSize()
      Spacer()
      TextField("Search video", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 180)
    }
    .padding(.horizontal, DS.Space.l)
    .padding(.vertical, 8)
  }

  private var table: some View {
    Table(rows, selection: $model.postsSelection, sortOrder: $sortOrder) {
      TableColumn("Date", value: \.scheduledAt) { r in
        Text("\(Fmt.day(r.post.scheduledAt, tz: model.tz, style: "dd MMM")) · \(Fmt.shortTime(r.post.scheduledAt, tz: model.tz))")
          .font(DS.Font.mono)
      }
      .width(min: 104, ideal: 108)
      TableColumn("Platform", value: \.platformName) { r in
        HStack(spacing: 6) {
          PlatformGlyph(platform: r.post.platform, size: 18)
          Text(r.post.platform.displayName).lineLimit(1)
        }
      }
      .width(min: 96, ideal: 116)
      TableColumn("Video", value: \.videoName) { r in
        HStack(spacing: 8) {
          CoverThumb(video: model.video(r.post.videoId), width: 18, height: 32, radius: 3)
          Text(r.videoName).font(DS.Font.bodyStrong).lineLimit(1)
        }
      }
      .width(min: 150, ideal: 200)
      TableColumn("Ver.", value: \.post.versionNo) { r in Text("v\(r.post.versionNo)").foregroundStyle(.secondary) }.width(40)
      TableColumn("Try", value: \.post.attemptNo) { r in
        Text("#\(r.post.attemptNo)\(r.post.kind == .repost ? " ↻" : "")").foregroundStyle(.secondary)
      }
      .width(44)
      TableColumn("State", value: \.stateName) { r in StatusPill(post: r.post, now: model.now) }.width(min: 80, ideal: 96)
      TableColumn("Publisher", value: \.post.publisher) { r in Text(r.post.publisher.capitalized).foregroundStyle(.secondary) }.width(64)
      TableColumn("URL", value: \.urlText) { r in
        if let u = r.post.url, let url = URL(string: u) {
          Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }.help(u)
        } else { Text("—").foregroundStyle(.tertiary) }
      }
      .width(min: 80, ideal: 110)
    }
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let p = model.posts.first(where: { $0.id == id }) { PostContextMenu(model: model, post: p) }
    }
  }
}

struct PostRow: Identifiable {
  let post: PlatformPost
  let videoName: String
  var id: String { post.id }
  var scheduledAt: Date { post.scheduledAt }
  var platformName: String { post.platform.displayName }
  var stateName: String { post.state.displayName }
  var urlText: String { post.url ?? "" }

  @MainActor init(model: AppModel, post: PlatformPost) {
    self.post = post
    videoName = model.video(post.videoId).map(model.displayName) ?? post.videoId
  }
}

/// P.S1 error card: red stripe, platform, video, type, message, raw response disclosure, actions.
struct ErrorCard: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  /// Only the top card's Fix in editor is prominent (one primary per screen).
  var primary = false
  @State private var showRaw = false

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        PlatformGlyph(platform: post.platform, tint: .red, size: 28)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("\(post.platform.displayName) · \(model.video(post.videoId).map(model.displayName) ?? "")").font(DS.Font.bodyStrong)
            StatusPill(text: post.errorType?.displayName ?? post.state.displayName, tint: .red, icon: post.state.symbol, loud: true)
            Text(Fmt.relative(post.updatedAt, now: model.now)).font(DS.Font.secondary).foregroundStyle(.secondary)
          }
          Text(post.errorMessage ?? (post.state == .overdue ? "Slot passed without a post." : "No message")).font(DS.Font.body)
            .foregroundStyle(.secondary).lineLimit(2)
          if let raw = post.rawResponse, !raw.isEmpty {
            DisclosureGroup("Raw response", isExpanded: $showRaw) {
              ScrollView { Text(raw).font(DS.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 90)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(DS.Font.secondary)
          }
        }
        Spacer(minLength: 8)
        actions.controlSize(.small)
      }
      .padding(12)
    }
    .padding(.leading, 4)
    .background(alignment: .leading) { Rectangle().fill(Color.red).frame(width: 4) }
    .background(Color.red.opacity(0.07))
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.red.opacity(0.35)))
    .contentShape(Rectangle())
    .onTapGesture { model.postsSelection = post.id }
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 6) {
      if post.state.isCopyright {
        ReuploadMenu(model: model, post: post)
        Button("Skip") { model.resolve(post, .skipPlatform) }
        Button("Accept") { model.resolve(post, .accept) }
      } else if post.state == .overdue {
        Button("Post now") { model.postNow(post) }
        Button("Shift plan") { model.shiftPlan(post) }
        Button("Skip") { model.skip(post) }
      } else {
        if primary {
          Button("Fix in editor") { model.openEditor(post.videoId, fixPostId: post.id) }.buttonStyle(.borderedProminent)
        } else {
          Button("Fix in editor") { model.openEditor(post.videoId, fixPostId: post.id) }
        }
        Button("Re-queue") { model.fixed(post.id) }.help("The cause is fixed: try again on the next day's slot")
      }
      Menu {
        if model.canReset(post) { Button("Reset post") { model.reset(post) } }
        if post.state == .overdue { Button("Mark posted…") { model.markPostedTarget = post } }
        Button("Copy details") {
          model.copy("\(post.platform.displayName) · \(post.errorType?.displayName ?? post.state.displayName)\n\(post.errorMessage ?? "")\n\(post.rawResponse ?? "")")
        }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
  }
}

/// P.S3 detail: key/value details, error, metrics, render, history log.
struct PostDetail: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var views = ""
  @State private var likes = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Eyebrow("Post details")
          HStack(spacing: 8) {
            PlatformGlyph(platform: post.platform, tint: post.state.tint, size: 24)
            Text("\(post.platform.displayName) · \(model.video(post.videoId).map(model.displayName) ?? "")").font(DS.Font.title).lineLimit(2)
          }
          StatusPill(post: post, now: model.now)
        }
        VStack(alignment: .leading, spacing: 2) {
          PropertyRow("Post ID") { Text(post.id).font(DS.Font.mono).textSelection(.enabled).lineLimit(1) }
          PropertyRow("Scheduled") { Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE d MMM, h:mm a")) }
          if let at = post.postedAt { PropertyRow("Posted") { Text(Fmt.day(at, tz: model.tz, style: "EEE d MMM, h:mm a")) } }
          PropertyRow("Version") { Text("v\(post.versionNo)") }
          PropertyRow("Attempt") { Text("#\(post.attemptNo) · \(post.kind.rawValue)") }
          PropertyRow("Publisher") { Text(post.publisher.capitalized) }
          if let u = post.url, let url = URL(string: u) { PropertyRow("URL") { Link(u, destination: url).lineLimit(1) } }
          if let r = post.resolution { PropertyRow("Resolution") { Text(r.capitalized) } }
          PropertyRow("Render") {
            if let rid = post.renderId, let r = try? model.store.render(id: rid), let path = r.outputPath {
              Button((path as NSString).lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                .buttonStyle(.link).lineLimit(1)
            } else { Text("Not rendered yet").foregroundStyle(.secondary) }
          }
        }
        if post.errorType != nil || post.errorMessage != nil {
          VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Error")
            Text(post.errorType?.displayName ?? "").font(DS.Font.bodyStrong).foregroundStyle(.red)
            Text(post.errorMessage ?? "").font(DS.Font.body)
            if let raw = post.rawResponse, !raw.isEmpty {
              Text(raw).font(DS.Font.mono).textSelection(.enabled).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
          }
        }
        if post.state == .posted {
          VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Metrics")
            HStack {
              TextField("Views", text: $views).textFieldStyle(.roundedBorder).frame(width: 90)
              TextField("Likes", text: $likes).textFieldStyle(.roundedBorder).frame(width: 90)
              Button("Save") { model.setMetrics(post, views: Int(views), likes: Int(likes)) }
            }
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Eyebrow("History")
          let h = (try? model.store.history(postId: post.id)) ?? []
          if h.isEmpty { Text("No changes yet").font(DS.Font.secondary).foregroundStyle(.secondary) }
          ForEach(h) { e in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Circle().fill(PostState(rawValue: e.toState)?.tint ?? .secondary).frame(width: 6, height: 6)
              VStack(alignment: .leading, spacing: 1) {
                Text("\(e.fromState.flatMap { PostState(rawValue: $0)?.displayName } ?? "Created") → \(PostState(rawValue: e.toState)?.displayName ?? e.toState)")
                  .font(DS.Font.body)
                if let n = e.note { Text(n).font(DS.Font.secondary).foregroundStyle(.secondary) }
              }
              Spacer()
              Text(Fmt.day(e.at, tz: model.tz, style: "d MMM HH:mm")).font(DS.Font.mono).foregroundStyle(.secondary)
            }
          }
        }
        HStack {
          if !post.state.isTerminal { Button("Mark posted…") { model.markPostedTarget = post } }
          if !post.state.isTerminal || post.state == .posted { Button("Report…") { model.reportTarget = post } }
          if model.canReset(post) { Button("Reset") { model.reset(post) } }
          if model.canSkip(post) { Button("Skip") { model.skip(post) } }
        }
        .controlSize(.small)
      }
      .padding(DS.Space.l)
    }
    .onAppear {
      views = post.metrics?.views.map(String.init) ?? ""
      likes = post.metrics?.likes.map(String.init) ?? ""
    }
  }
}
