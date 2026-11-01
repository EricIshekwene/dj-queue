import AppKit
import DJQCore
import SwiftUI

/// T.L (Todoist ref): day header + "3 / 6 posted", then one row per platform post today.
struct TodayView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header.padding(.bottom, 18)
        if model.dueToday.isEmpty {
          empty
        } else {
          let firstDue = model.dueToday.first { $0.state == .due || $0.state == .overdue || (!$0.state.isTerminal && $0.scheduledAt <= model.now) }?.id
            ?? model.dueToday.first { !$0.state.isTerminal }?.id
          ForEach(model.dueToday) { p in
            TodayRow(model: model, post: p, primary: p.id == firstDue)
            Divider()
          }
          if let n = model.posts.first(where: { !$0.state.isTerminal && model.dm.key($0.scheduledAt) > model.todayKey }) {
            nextLine(n).padding(.top, 14)
          }
        }
      }
      .frame(maxWidth: 1040)
      .padding(.horizontal, 32)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity)
    }
  }

  private var header: some View {
    HStack(alignment: .lastTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Today").font(DS.Font.largeTitle)
        Text(Fmt.day(model.now, tz: model.tz, style: "EEEE d MMMM")).font(DS.Font.body).foregroundStyle(.secondary)
      }
      Spacer()
      if model.todayTotal > 0 {
        VStack(alignment: .trailing, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(model.postedTodayCount)").font(DS.Font.runway)
            Text("/ \(model.todayTotal) posted").font(DS.Font.body).foregroundStyle(.secondary)
          }
          Capsule().fill(Color.primary.opacity(0.1)).frame(width: 140, height: 5)
            .overlay(alignment: .leading) {
              Capsule().fill(Color.green).frame(width: 140 * Double(model.postedTodayCount) / Double(max(model.todayTotal, 1)), height: 5)
            }
        }
      }
    }
  }

  private var empty: some View {
    let next = model.nextPost
    return EmptyState(symbol: "checkmark.circle", title: "Nothing due today",
                      subtitle: next.map { "Next: \(Fmt.day($0.scheduledAt, tz: model.tz, style: "EEE")) \(Fmt.shortTime($0.scheduledAt, tz: model.tz)) · \($0.platform.displayName)" }
                        ?? "No posts planned — approve a week.",
                      buttonTitle: next == nil ? "Open Week" : nil) { model.screen = .week }
      .frame(minHeight: 420)
  }

  private func nextLine(_ p: PlatformPost) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
      Text("Next: \(Fmt.day(p.scheduledAt, tz: model.tz, style: "EEE")) \(Fmt.shortTime(p.scheduledAt, tz: model.tz)) · \(p.platform.displayName) · \(model.video(p.videoId).map(model.title) ?? "")")
        .font(DS.Font.secondary).foregroundStyle(.secondary)
    }
  }
}

/// T.S1 row (64 pt): time · glyph · cover · name + version · status · [file] [Copy caption] … [Mark posted].
struct TodayRow: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  let primary: Bool
  @State private var showMetrics = false

  private var video: Video? { model.video(post.videoId) }
  private var isCopyright: Bool { post.state.isCopyright && post.resolution == nil }
  private var isFailed: Bool { post.state == .failed && post.resolution == nil }
  private var isResolved: Bool { post.resolution != nil }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 0) {
        if model.dm.key(post.scheduledAt) != model.todayKey {
          Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE")).font(DS.Font.secondaryStrong).foregroundStyle(.orange)
        }
        Text(Fmt.shortTime(post.scheduledAt, tz: model.tz)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
      }
      .frame(width: 52, alignment: .leading)
      PlatformGlyph(platform: post.platform, tint: post.state == .posted ? .green : .primary, size: 22)
      CoverThumb(video: video, width: 30, height: 53)
      VStack(alignment: .leading, spacing: 2) {
        Text(video.map(model.title) ?? "Missing video").font(DS.Font.bodyStrong).lineLimit(1)
        Text("v\(post.versionNo) · \(post.platform.displayName)\(post.attemptNo > 1 ? " · attempt \(post.attemptNo)" : "")")
          .font(DS.Font.secondary).foregroundStyle(.secondary)
      }
      .frame(minWidth: 160, alignment: .leading)
      Spacer(minLength: 8)
      StatusPill(post: post, now: model.now)
      actions
    }
    .padding(.horizontal, 10)
    .frame(height: DS.Row.today)
    .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
    .contextMenu { PostContextMenu(model: model, post: post) }
    // Only rows whose render already exists get a file; nothing renders on display.
    .task(id: AppModel.prepStamp(post)) { await model.prepareIfRendered(post) }
  }

  private var rowBackground: Color {
    if isCopyright || isFailed { return Color.red.opacity(0.10) }
    if post.id == model.highlightPostId { return Color.accentColor.opacity(0.10) }
    return .clear
  }

  @ViewBuilder private var actions: some View {
    if isResolved {
      // Handled problem (accepted / skipped / re-uploaded / retried): no live posting actions on this attempt.
      HStack(spacing: 6) {
        StatusPill(text: resolutionLabel, tint: .secondary, icon: "checkmark.circle")
        moreMenu
      }
    } else if isCopyright {
      HStack(spacing: 6) {
        Button("Re-upload anyway") { model.resolve(post, .reuploadAnyway(versionNo: nil)) }
        Button("Skip platform") { model.resolve(post, .skipPlatform) }
        Button("Accept") { model.resolve(post, .accept) }
        moreMenu
      }
      .controlSize(.small)
    } else if isFailed {
      HStack(spacing: 6) {
        Button("Fix…") { model.openEditor(post.videoId, fixPostId: post.id) }
        Button("Re-queue") { model.fixed(post.id) }.help("The cause is fixed: try again on the next day's slot")
        moreMenu
      }
      .controlSize(.small)
    } else if post.state == .posted {
      HStack(spacing: 6) {
        if let u = post.url, let url = URL(string: u) {
          Link(destination: url) { Label("Open post", systemImage: "arrow.up.right.square") }
            .font(DS.Font.body)
        }
        Button { showMetrics = true } label: {
          Label(post.metrics?.views.map { "\($0) views" } ?? "Metrics", systemImage: "chart.bar")
        }
        .popover(isPresented: $showMetrics) { MetricsPopover(model: model, post: post) }
        moreMenu
      }
      .controlSize(.small)
      .buttonStyle(.borderless)
    } else if post.state == .skipped {
      moreMenu
    } else {
      HStack(spacing: 6) {
        FileDragChip(model: model, post: post)
        Button { model.copyCaption(post) } label: { Label("Copy caption", systemImage: "text.quote") }
          .buttonStyle(.bordered)
        if post.platform == .youtube {
          Button { model.copyTitle(post) } label: { Image(systemName: "textformat") }
            .buttonStyle(.bordered).help("Copy title").accessibilityLabel("Copy title")
        }
        Button { model.openUploadPage(post) } label: { Image(systemName: "safari") }
          .buttonStyle(.bordered).help("Open upload page").accessibilityLabel("Open upload page")
        if primary {
          Button("Mark posted") { model.markPostedTarget = post }.buttonStyle(.borderedProminent)
        } else {
          Button("Mark posted") { model.markPostedTarget = post }.buttonStyle(.bordered)
        }
        moreMenu
      }
      .controlSize(.regular)
    }
  }

  private var resolutionLabel: String {
    switch post.resolution ?? "" {
    case "accepted": "Accepted"
    case "skipped": "Skipped"
    case "reuploaded": "Re-uploading"
    case "retried": "Re-queued"
    default: (post.resolution ?? "").capitalized
    }
  }

  private var moreMenu: some View {
    Menu {
      if !post.state.isTerminal {
        Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
        Button("Reveal in Finder", systemImage: "folder") { model.revealFile(post) }
        Button("Copy file", systemImage: "doc.on.doc") { model.copyFile(post) }
      }
      if post.state == .posted { Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post } }
      if model.canReset(post) || model.canSkip(post) { Divider() }
      if model.canReset(post) { Button("Reset", systemImage: "arrow.counterclockwise") { model.reset(post) } }
      if model.canSkip(post) { Button("Skip this platform", systemImage: "forward") { model.skip(post) } }
      if let v = model.video(post.videoId) {
        Divider()
        Button("Edit video", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(v.id) }
      }
    } label: { Image(systemName: "ellipsis") }
      .accessibilityLabel("More actions")
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
  }
}

/// T.S1.a drag-out of the render file (decision Q4: drag file + caption are primary).
struct FileDragChip: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let ready = model.preparedPost(post.id)
    HStack(spacing: 5) {
      Image(systemName: ready == nil ? "hourglass" : "film").font(.system(size: 11, weight: .semibold))
      Text(ready != nil ? "Drag file" : (model.isRenderable(post) ? "Preparing" : "Rendering")).font(DS.Font.body)
      Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 9)
    .frame(height: 24)
    .background(Color.accentColor.opacity(ready == nil ? 0.05 : 0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    .foregroundStyle(ready == nil ? Color.secondary : Color.accentColor)
    .onDrag {
      guard let url = model.preparedPost(post.id)?.fileURL else { return NSItemProvider() }
      return NSItemProvider(object: url as NSURL)
    }
    .help(ready.map { "Drag \($0.fileURL.lastPathComponent) into the browser upload page" } ?? "Waiting for the render")
  }
}

struct MetricsPopover: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var views = ""
  @State private var likes = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Metrics after 72 h").font(DS.Font.bodyStrong)
      HStack {
        TextField("Views", text: $views).textFieldStyle(.roundedBorder).frame(width: 90)
        TextField("Likes", text: $likes).textFieldStyle(.roundedBorder).frame(width: 90)
      }
      HStack {
        Spacer()
        Button("Save") {
          model.setMetrics(post, views: Int(views), likes: Int(likes))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
    .onAppear {
      views = post.metrics?.views.map(String.init) ?? ""
      likes = post.metrics?.likes.map(String.init) ?? ""
    }
  }
}

// MARK: - Sheets (T.S2, T.S3, L.S4)

/// T.S2 (Arcade ref): one URL field validated against the platform's domain, posted time.
struct MarkPostedSheet: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var url = ""
  @State private var postedAt = Date()
  @Environment(\.dismiss) private var dismiss

  private var valid: Bool { (try? PostActions.validate(url: url.trimmingCharacters(in: .whitespaces), for: post.platform)) != nil }
  private var validationError: String? {
    do { try PostActions.validate(url: url.trimmingCharacters(in: .whitespaces), for: post.platform); return nil } catch {
      return error.localizedDescription
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        PlatformGlyph(platform: post.platform, size: 22)
        Text("Mark posted").font(DS.Font.title)
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
      }
      Text("Paste the \(post.platform.displayName) post URL for “\(model.video(post.videoId).map(model.title) ?? "")”.")
        .font(DS.Font.body).foregroundStyle(.secondary)
      TextField("https://\(post.platform.urlHosts[0])/…", text: $url)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 14))
        .controlSize(.large)
      if !url.isEmpty, let e = validationError {
        Label(e, systemImage: "exclamationmark.circle.fill").font(DS.Font.secondary).foregroundStyle(.red)
      }
      DatePicker("Posted", selection: $postedAt, in: ...Date().addingTimeInterval(3600)).font(DS.Font.body)
      HStack {
        Text(post.platform.urlHosts[0]).font(DS.Font.secondary).foregroundStyle(.tertiary)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Mark posted") {
          model.markPosted(post, url: url.trimmingCharacters(in: .whitespaces), at: postedAt)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!valid)
      }
    }
    .padding(22)
    .frame(width: 480)
    .onAppear {
      postedAt = model.frozen ? model.now : Date()
      if let pre = model.markPostedPrefill {
        url = pre
        model.markPostedPrefill = nil
      } else if let s = NSPasteboard.general.string(forType: .string), (try? PostActions.validate(url: s, for: post.platform)) != nil {
        url = s
      }
    }
  }
}

/// T.S3: error type + message (+ optional raw response).
struct ReportProblemSheet: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var type: ErrorType = .uploadFailed
  @State private var message = ""
  @State private var raw = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        PlatformGlyph(platform: post.platform, size: 22)
        Text("Report problem").font(DS.Font.title)
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
        ForEach(ErrorType.allCases, id: \.self) { t in
          Button { type = t } label: {
            Text(t.displayName).font(DS.Font.body).lineLimit(1).frame(maxWidth: .infinity).frame(height: 26)
              .background(type == t ? (t.postState.isCopyright ? Color.red : Color.accentColor).opacity(0.18) : Color.primary.opacity(0.05),
                          in: RoundedRectangle(cornerRadius: DS.Radius.control))
              .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(type == t ? (t.postState.isCopyright ? Color.red : Color.accentColor) : Color.primary.opacity(0.1)))
          }
          .buttonStyle(.plain)
        }
      }
      TextField("What happened?", text: $message, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
      DisclosureGroup("Raw response (optional)") {
        TextEditor(text: $raw).font(DS.Font.mono).frame(height: 70)
      }
      .font(DS.Font.body)
      if type.postState.isCopyright {
        Label("Copyright stops this platform only. No automatic retry.", systemImage: "c.circle.fill")
          .font(DS.Font.secondary).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          model.reportProblem(post, type: type, message: message.isEmpty ? type.displayName : message, raw: raw.isEmpty ? nil : raw)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

/// L.S4: paste the YouTube URL → long-form moves to Posted/Longform.
struct LongformPostedSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var url = ""
  @Environment(\.dismiss) private var dismiss

  private var valid: Bool { URL(string: url)?.host.map { $0.contains("youtube.com") || $0.contains("youtu.be") } ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Mark long-form posted").font(DS.Font.title)
      Text("Paste the YouTube URL for “\(model.title(video))”. The file moves from Ready to Post to Posted.")
        .font(DS.Font.body).foregroundStyle(.secondary)
      TextField("https://youtube.com/watch?v=…", text: $url).textFieldStyle(.roundedBorder).controlSize(.large)
      HStack {
        Text("Then run a Test & Compare on the thumbnail.").font(DS.Font.secondary).foregroundStyle(.tertiary)
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Mark posted") { model.markLongformPosted(video, url: url); dismiss() }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
      }
    }
    .padding(22)
    .frame(width: 480)
  }
}
