import DJQCore
import SwiftUI

/// The 360 pt post inspector (DESIGN-v2 §6.7; r.lg card, e1): header, facts (version shown here), error, metrics
/// entry, attempt history, repost per platform (with the blocker reason) and the post actions.
struct PostInspector: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var views = ""
  @State private var likes = ""

  var body: some View {
    let v = model.video(post.videoId)
    let fixes = PostFixes(model: model, post: post)
    VStack(spacing: 0) {
      header(v)
      DSSeparator()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          section("Details") { facts }
          if let pz = model.postizState(post) { section("Postiz") { postizSection(pz) } }
          if post.errorType != nil || post.errorMessage != nil {
            section(model.postizState(post)?.isRetrying == true ? "Last failure" : "Problem") { problem }
          }
          if post.state == .posted { section("Metrics") { metrics } }
          section("Attempts") { attempts }
          section("Repost") { repost }
          section("Actions", last: true) { actions(fixes) }
        }
      }
    }
    .background(DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous).strokeBorder(DS.color.border) }
    .dsElevation(DS.elevation.e1)
    .onAppear {
      views = post.metrics?.views.map(String.init) ?? ""
      likes = post.metrics?.likes.map(String.init) ?? ""
    }
  }

  // MARK: Pieces

  private func header(_ v: Video?) -> some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      HStack(spacing: DS.space.xs) {
        DSPlatformIcon(platform: post.platform, state: model.platformState(post), size: 26)
        Text(post.platform.displayName).font(DS.type.headline).foregroundStyle(DS.color.text)
        Spacer(minLength: 0)
        // No esc here: the inspector never holds focus, and esc already clears the bulk selection / closes dialogs.
        DSIconButton("xmark", tooltip: "Close details", size: .sm) {
          dsWithAnimation { model.postsSelection = nil }
        }
      }
      HStack(spacing: DS.space.sm) {
        BrowsePoster(model: model, video: v, width: 36, height: 64, radius: DS.radius.sm, post: post)
        VStack(alignment: .leading, spacing: 4) {
          Text(v.map(model.displayName) ?? post.videoId).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(2)
          HStack(spacing: 6) {
            if let pz = model.postizRowState(post) {
              PostizBadge(model: model, post: post, state: pz)
            } else {
              PostStatePill(post: post)
            }
            if model.isTestRun(post) { TestRunBadge() }
            Text("v\(post.versionNo) · #\(post.attemptNo)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .padding(DS.space.md)
  }

  private func section<C: View>(_ title: String, last: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      DSSectionHeader(title)
      content()
    }
    .padding(DS.space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { if !last { DSSeparator() } }
  }

  private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.sm) {
      Text(label).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).frame(width: 84, alignment: .leading)
      value().font(DS.type.callout).foregroundStyle(DS.color.text).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 22)
  }

  private var facts: some View {
    VStack(alignment: .leading, spacing: 2) {
      row("Scheduled") { Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE d MMM, h:mm a")) }
      if let at = post.postedAt { row("Posted") { Text(Fmt.day(at, tz: model.tz, style: "EEE d MMM, h:mm a")) } }
      row("Version") { Text("v\(post.versionNo)") }
      row("Attempt") { Text(PostText.attempt(post)) }
      row("Publisher") { Text(publisherText) }
      row("Link") {
        if let u = post.url, let url = URL(string: u) {
          Link(destination: url) { Text(u).lineLimit(1).truncationMode(.middle) }.foregroundStyle(DS.color.accent).dsTooltip("Open the live post")
        } else {
          Text("Not posted yet").foregroundStyle(DS.color.textTertiary)
        }
      }
      row("Render") {
        // Every file of the render: one for a clip, one per photo for a photo post (`Render.allPaths`). The link shows
        // them all in Finder and can be dragged out as files.
        let files = model.renderFiles(post)
        if let first = files.first {
          Button(files.count == 1 ? first.lastPathComponent : "\(files.count) photos · \(first.lastPathComponent)") {
            NSWorkspace.shared.activateFileViewerSelecting(files)
          }
          .buttonStyle(.plain).foregroundStyle(DS.color.accent).lineLimit(1).truncationMode(.middle)
          .overlay { FileDragSource(urls: files) { NSWorkspace.shared.activateFileViewerSelecting(files) } }
          .dsTooltip(files.count == 1 ? "Click to show the file in Finder, or drag it out"
                       : "Click to show all \(files.count) photos in Finder, or drag them out")
          .accessibilityLabel(files.count == 1 ? "Rendered file \(first.lastPathComponent)" : "\(files.count) rendered photos")
        } else {
          Text("Not rendered yet").foregroundStyle(DS.color.textTertiary)
        }
      }
      if let r = post.resolution { row("Resolution") { Text(r.capitalized) } }
      row("Post ID") { Text(post.id).font(DS.type.mono).foregroundStyle(DS.color.textSecondary).lineLimit(1).textSelection(.enabled) }
    }
  }

  /// Who delivers it, when, and the one Postiz action that applies (release a test-run draft, open the live post).
  private func postizSection(_ pz: PostizPostState) -> some View {
    let job = model.postiz.jobs[post.id]
    let channel = model.postiz.channel(job?.integrationId ?? model.settings.publishing.channels[post.platform])
    return VStack(alignment: .leading, spacing: 2) {
      row("Status") { PostizBadge(model: model, post: post, state: pz) }
      if !pz.isLoud {  // a failure's message is in Problem below
        Text(model.postizLine(post, pz))
          .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 84 + DS.space.sm)
      }
      if let channel { row("Channel") { Text("\(channel.name) · \(channel.identifier)").lineLimit(1) } }
      if let job, job.isOpen { row("Goes out") { Text(Fmt.day(job.remoteDate, tz: model.tz, style: "EEE d MMM, h:mm a")) } }
      if model.isTestRun(post) { row("Test run") { Text(testRunText).fixedSize(horizontal: false, vertical: true) } }
      if pz == .unconfirmed {
        VStack(alignment: .leading, spacing: DS.space.xxs) {
          DSButton("It's in Postiz", icon: "checkmark.circle", variant: .outline, size: .sm,
                   tooltip: "Keep it as Postiz's; it's never sent again") { model.resolveUnconfirmed(post, inPostiz: true) }
          DSButton("Not in Postiz — post it myself", variant: .ghost, size: .sm,
                   tooltip: "Post it by hand from the Calendar (asks first)") { model.resolveUnconfirmed(post, inPostiz: false) }
        }
        .padding(.top, DS.space.xs)
      }
      if pz == .draft {
        DSButton("Release draft", icon: "paperplane", variant: .outline, size: .sm,
                 tooltip: "Let Postiz post this draft at its time") { model.releaseDraft(post) }
          .padding(.top, DS.space.xs)
      }
    }
  }

  /// "Postiz" while Postiz delivers it (or did), even before the post row records it.
  private var publisherText: String {
    switch model.postizState(post) {
    case nil, .fellBack?, .inbox?: post.publisher.capitalized
    default: "Postiz"
    }
  }

  private var testRunText: String {
    switch post.platform {
    case .tiktok: "Sent to your TikTok inbox"
    case .youtube: "Posted as Unlisted"
    default: "Saved as a Postiz draft"
    }
  }

  private var problem: some View {
    VStack(alignment: .leading, spacing: 6) {
      DSBadge(PostText.problemType(post), style: model.postizState(post)?.isRetrying == true ? .soft(.neutral) : .soft(.danger),
              help: "What went wrong with this post")
      if let m = post.errorMessage, !m.isEmpty {
        Text(m).font(DS.type.callout).foregroundStyle(DS.color.text).fixedSize(horizontal: false, vertical: true)
      }
      if let raw = post.rawResponse, !raw.isEmpty {
        Text(raw).font(DS.type.mono).foregroundStyle(DS.color.textSecondary).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(DS.space.xs)
          .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      }
    }
  }

  private var metrics: some View {
    let dirty = views != (post.metrics?.views.map(String.init) ?? "") || likes != (post.metrics?.likes.map(String.init) ?? "")
    let invalid = (!views.isEmpty && Int(views) == nil) || (!likes.isEmpty && Int(likes) == nil)
    return HStack(alignment: .bottom, spacing: DS.space.xs) {
      DSTextField("Views", placeholder: "0", text: $views, size: .sm)
      DSTextField("Likes", placeholder: "0", text: $likes, size: .sm)
      DSButton("Save", variant: .outline, size: .sm,
               disabledReason: invalid ? "Whole numbers only" : !dirty ? "Nothing changed" : nil) {
        model.setMetrics(post, views: Int(views), likes: Int(likes))
      }
    }
  }

  /// Every attempt on this platform for the clip, newest first, with this post's state history underneath.
  private var attempts: some View {
    let all = (model.postsByVideo[post.videoId] ?? []).filter { $0.platform == post.platform }.sorted { $0.attemptNo > $1.attemptNo }
    let history = ((try? model.store.history(postId: post.id)) ?? []).reversed()
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      ForEach(all) { a in
        HStack(spacing: DS.space.xs) {
          Text("#\(a.attemptNo)").font(DS.type.captionMedium.monospacedDigit()).foregroundStyle(DS.color.text).frame(width: 24, alignment: .leading)
          Text("v\(a.versionNo)\(a.kind == .regular ? "" : " · \(a.kind.rawValue)")").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          Spacer(minLength: 4)
          PostStatePill(post: a)
          Text(Fmt.day(a.scheduledAt, tz: model.tz, style: "d MMM")).font(DS.type.caption.monospacedDigit())
            .foregroundStyle(DS.color.textTertiary).frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(a.id == post.id ? DS.color.surfaceSunken : .clear, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if a.id != post.id { model.postsSelection = a.id } }
        .dsTooltip(a.id == post.id ? "This attempt" : "Show attempt #\(a.attemptNo)")
      }
      if !history.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(history.prefix(8))) { e in
            HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
              DSStatusDot(tone: tone(PostState(rawValue: e.toState)), size: 6)
              VStack(alignment: .leading, spacing: 1) {
                Text("\(e.fromState.flatMap { PostState(rawValue: $0)?.displayName } ?? "Created") → \(PostState(rawValue: e.toState)?.displayName ?? e.toState)")
                  .font(DS.type.caption).foregroundStyle(DS.color.text)
                if let n = e.note, !n.isEmpty { Text(n).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(2) }
              }
              Spacer(minLength: 4)
              Text(Fmt.day(e.at, tz: model.tz, style: "d MMM HH:mm")).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
            }
          }
        }
        .padding(.top, DS.space.xxs)
      }
    }
  }

  private func tone(_ s: PostState?) -> DSTone {
    guard let s else { return .neutral }
    if s == .posted { return .success }
    if s.isProblem { return s == .overdue ? .warning : .danger }
    if s == .skipped { return .neutral }
    return .info
  }

  private var repost: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(model.settings.activePlatforms) { p in
        let why = model.repostBlocker(post.videoId, p)
        HStack(spacing: DS.space.xs) {
          DSPlatformIcon(platform: p, size: 20, showsLabel: true)
          Spacer(minLength: 4)
          DSButton("Repost", icon: "arrow.uturn.forward", variant: .ghost, size: .sm, disabledReason: why,
                   tooltip: "Queue the next version on \(p.displayName)") { model.repost(post.videoId, p) }
        }
        .frame(height: 30)
      }
    }
  }

  private func actions(_ fixes: PostFixes) -> some View {
    DSFlowLayout(spacing: 6) {
      DSButton("Mark posted…", icon: "checkmark.circle", variant: .outline, size: .sm,
               disabledReason: post.state.isTerminal ? "Already \(post.state.displayName.lowercased())" : nil) {
        model.markPostedTarget = post
      }
      DSButton("Report problem…", variant: .ghost, size: .sm,
               disabledReason: post.state.isTerminal && post.state != .posted ? "Already \(post.state.displayName.lowercased())" : nil) {
        model.reportTarget = post
      }
      DSButton("Reset", variant: .ghost, size: .sm, disabledReason: fixes.resetReason,
               tooltip: "Back to Planned, error cleared") { model.reset(post) }
      DSButton("Skip \(post.platform.dsxCompactName)", variant: .ghost, size: .sm, disabledReason: fixes.skipReason,
               tooltip: "Don't post this clip on \(post.platform.displayName)") { model.skip(post) }
      DSButton("Open editor", variant: .ghost, size: .sm) { model.openEditor(post.videoId) }
    }
  }
}

/// Confirmation for bulk post actions (#11): lists what changes, applies through PostActions as one journaled step
/// (AppModel.undoable), then a "… · Undo" toast (⌘Z).
struct PostBulkDialog: View {
  @Bindable var model: AppModel
  let bulk: PostBulk

  private var posts: [PlatformPost] { bulk.postIds.compactMap { id in model.posts.first { $0.id == id } } }

  private func eligible(_ p: PlatformPost) -> Bool {
    switch bulk.op {
    case .reset: model.canReset(p)
    case .skip: model.canSkip(p)
    case .retry: PostFixes.canRetry(p) && model.heldReason(p.videoId) == nil
    }
  }

  private var verb: String {
    switch bulk.op {
    case .reset: "Reset"
    case .skip: "Skip"
    case .retry: "Retry"
    }
  }

  private var result: String {
    switch bulk.op {
    case .reset: "Planned"
    case .skip: "Skipped"
    case .retry: "New attempt, next slot"
    }
  }

  var body: some View {
    let ok = posts.filter(eligible)
    let left = posts.count - ok.count
    DSDialog("\(verb) \(ok.count) post\(ok.count == 1 ? "" : "s")?",
             description: (left > 0 ? "\(left) of the selected can't be \(verb.lowercased())\(bulk.op == .retry ? "ied" : bulk.op == .skip ? "ped" : "") and stay as they are. " : "")
               + "You can undo this.",
             icon: "paperplane", onClose: close) {
      ScrollView {
        DSChangeList(changes: ok.prefix(12).map { p in
          DSChangeList.Change(field: "\(p.platform.displayName) · \(model.video(p.videoId).map(model.displayName) ?? p.videoId)", value: result)
        } + (ok.count > 12 ? [DSChangeList.Change(field: "… and \(ok.count - 12) more", value: result)] : []))
      }
      .frame(maxHeight: 300)
      .fixedSize(horizontal: false, vertical: true)
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("\(verb) \(ok.count)", variant: .primary, disabledReason: ok.isEmpty ? "Nothing to \(verb.lowercased())" : nil) {
        apply(ok)
      }
      .keyboardShortcut(.defaultAction)
    }
  }

  private func apply(_ ok: [PlatformPost]) {
    let pa = model.postActions
    let op = bulk.op
    let n = ok.count
    let done = op == .reset ? "Reset" : op == .skip ? "Skipped" : "Retrying"
    let vids = Array(Set(ok.map(\.videoId))).sorted()
    model.undoable("\(done) \(n) post\(n == 1 ? "" : "s")", "posts-\(verb.lowercased())", ids: vids, plan: true) {
      for p in ok {
        switch op {
        case .reset: try pa.reset(postId: p.id)
        case .skip: if p.state.isCopyright { try pa.resolveCopyright(postId: p.id, .skipPlatform) } else { try pa.skip(postId: p.id) }
        case .retry: _ = try pa.fixed(postId: p.id)
        }
      }
    }
    model.clearSelection(.posts)
    close()
  }

  private func close() { BrowseUI.shared.pendingPostBulk = nil }
}
