import AppKit
import DJQCore
import SwiftUI

// Post dialogs (T.S2, T.S3, L.S4) rebuilt on DSDialog. MainWindowView presents them in-window over the scrim
// (`ModalHost`) while `model.markPostedTarget` / `reportTarget` / `longformTarget` is set; closing = setting the
// target back to nil.

/// T.S2 Mark posted: one URL field validated against the platform's domain + the posted time. The field starts
/// EMPTY — the only text ever put in it is a URL Eric already typed into a notification (`markPostedDraftURL`).
struct MarkPostedSheet: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var url = ""
  @State private var postedAt = Date()
  @State private var attempted = false

  private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var validationError: String? {
    guard !trimmed.isEmpty else { return nil }
    do { try PostActions.validate(url: trimmed, for: post.platform); return nil } catch { return error.localizedDescription }
  }

  var body: some View {
    let title = model.video(post.videoId).map(model.displayName) ?? "this clip"
    DSDialog("Mark posted on \(post.platform.displayName)", description: "Paste the post URL for “\(title)”.",
             icon: post.platform.dsSymbol, onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        DSTextField("Post URL", placeholder: "https://\(post.platform.urlHosts[0])/…", text: $url, icon: "link",
                    hint: validationError == nil ? "Must be a \(post.platform.urlHosts[0]) link" : nil,
                    error: (attempted || !trimmed.isEmpty) ? (trimmed.isEmpty ? (attempted ? "Paste the post URL" : nil) : validationError) : nil,
                    size: .lg, onSubmit: save)
        HStack {
          Text("Posted at").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          Spacer()
          DatePicker("Posted at", selection: $postedAt, in: ...Date().addingTimeInterval(3600))
            .labelsHidden()
            .datePickerStyle(.compact)
            .dsTooltip("When it went live")
        }
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("Mark posted", icon: "checkmark", variant: .primary,
               disabledReason: trimmed.isEmpty ? "Paste the post URL first" : validationError, action: save)
        .keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .onAppear {
      postedAt = model.frozen ? model.now : Date()
      if let typed = model.markPostedDraftURL {
        url = typed
        attempted = true
        model.markPostedDraftURL = nil
      }
    }
  }

  private func save() {
    attempted = true
    guard !trimmed.isEmpty, validationError == nil else { return }
    model.markPosted(post, url: trimmed, at: postedAt)
    close()
  }

  private func close() { model.markPostedTarget = nil }
}

/// T.S3 Report problem: error type + what happened (+ optional raw response).
struct ReportProblemSheet: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var type: ErrorType = .uploadFailed
  @State private var message = ""
  @State private var raw = ""
  @State private var showRaw = false

  var body: some View {
    let title = model.video(post.videoId).map(model.displayName) ?? "this clip"
    DSDialog("Report a problem on \(post.platform.displayName)", description: "What went wrong with “\(title)”?",
             icon: "exclamationmark.bubble", iconTone: .danger, width: 520, onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Problem").font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
          DSFlowLayout(spacing: 6) {
            ForEach(ErrorType.allCases, id: \.self) { t in
              DSChip(t.displayName, isSelected: type == t, tone: type == t && t.postState.isCopyright ? .danger : nil, size: .sm) { type = t }
            }
          }
        }
        DSTextArea("What happened?", placeholder: "Optional — the message the platform showed", text: $message, minHeight: 64, maxHeight: 120)
        if showRaw {
          DSTextArea("Raw response", placeholder: "Paste the raw error, if any", text: $raw, minHeight: 64, maxHeight: 140)
        } else {
          DSButton("Add raw response", icon: "plus", variant: .ghost, size: .sm) { dsWithAnimation { showRaw = true } }
        }
        if type.postState.isCopyright {
          Label("Copyright stops this platform only. No automatic retry.", systemImage: "c.circle.fill")
            .font(DS.type.caption).foregroundStyle(DS.color.danger)
        }
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("Save problem", variant: .primary) {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        model.reportProblem(post, type: type, message: m.isEmpty ? type.displayName : m, raw: raw.isEmpty ? nil : raw)
        close()
      }
      .keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func close() { model.reportTarget = nil }
}

/// L.S4: paste the YouTube URL → the long-form file moves to Posted/Longform.
struct LongformPostedSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var url = ""

  private var valid: Bool { URL(string: url.trimmingCharacters(in: .whitespaces))?.host.map { $0.contains("youtube.com") || $0.contains("youtu.be") } ?? false }

  var body: some View {
    DSDialog("Mark long-form posted", description: "Paste the YouTube URL for “\(model.displayName(video))”. The file moves from Ready to Post to Posted.",
             icon: "play.rectangle", onClose: close) {
      DSTextField("YouTube URL", placeholder: "https://youtube.com/watch?v=…", text: $url, icon: "link",
                  hint: "Then run a Test & Compare on the thumbnail.",
                  error: !url.isEmpty && !valid ? "Must be a youtube.com or youtu.be link" : nil, size: .lg)
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("Mark posted", icon: "checkmark", variant: .primary, disabledReason: valid ? nil : "Paste the YouTube URL first") {
        model.markLongformPosted(video, url: url.trimmingCharacters(in: .whitespaces))
        close()
      }
      .keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func close() { model.longformTarget = nil }
}

/// T.S4 "Re-upload anyway" with a version choice: same, an existing later one, or a new version (opens the editor).
struct ReuploadMenu: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    let versions = max(1, model.versionCounts[post.videoId] ?? 1)
    DSXMenuLabelButton(title: "Re-upload anyway", variant: .ghost, size: .sm, tooltip: "Upload again despite the copyright claim") {
      Button("Same version (v\(post.versionNo))") { model.reupload(post, version: post.versionNo) }
      ForEach(Array(stride(from: post.versionNo + 1, through: versions, by: 1)), id: \.self) { n in
        Button("v\(n)") { model.reupload(post, version: n) }
      }
      Divider()
      Button("New version (v\(versions + 1))…") { model.reupload(post, version: nil, newVersion: true) }
    }
  }
}

/// Views and likes after 72 h.
struct MetricsPopover: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  @State private var views = ""
  @State private var likes = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      Text("Metrics after 72 h").font(DS.type.headline).foregroundStyle(DS.color.text)
      HStack(spacing: DS.space.xs) {
        DSTextField("Views", placeholder: "0", text: $views, size: .sm)
        DSTextField("Likes", placeholder: "0", text: $likes, size: .sm)
      }
      HStack {
        Spacer()
        DSButton("Save", variant: .primary, size: .sm,
                 disabledReason: (views.isEmpty || Int(views) != nil) && (likes.isEmpty || Int(likes) != nil) ? nil : "Numbers only") {
          model.setMetrics(post, views: Int(views), likes: Int(likes))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DS.space.md)
    .frame(width: 260)
    .background(DS.color.surfaceRaised)
    .onAppear {
      views = post.metrics?.views.map(String.init) ?? ""
      likes = post.metrics?.likes.map(String.init) ?? ""
    }
  }
}

/// Placeholder rows while the first load runs (Today, Library).
struct SkeletonRows: View {
  var count = 8
  var height: CGFloat = DS.size.listRow

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { i in
        HStack(spacing: DS.space.sm) {
          DSSkeleton(width: 52, height: 10)
          DSSkeleton(width: 27, height: 48, radius: DS.radius.xs)
          VStack(alignment: .leading, spacing: 6) {
            DSSkeleton(width: CGFloat(140 + (i * 37) % 120), height: 11)
            DSSkeleton(width: 96, height: 8)
          }
          Spacer()
          DSSkeleton(width: 56, height: 18, radius: 9)
        }
        .padding(.horizontal, DS.space.xs)
        .frame(height: height)
        if i < count - 1 { DSSeparator() }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
  }
}
