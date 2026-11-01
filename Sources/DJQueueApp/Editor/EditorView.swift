import AppKit
import DJQCore
import SwiftUI

/// The full-window short-form editor (spec §6, DESIGN.md §Editor, slots E.L–E.S9).
/// Entry point used by the main app: `EditorView(store:videoId:videoIds:onDone:)`.
struct EditorView: View {
  @StateObject private var model: EditorModel
  private let videoIds: [String]
  private let onDone: () -> Void

  init(store: Store, videoId: String, videoIds: [String], onDone: @escaping () -> Void) {
    _model = StateObject(wrappedValue: EditorModel(store: store, videoId: videoId))
    self.videoIds = videoIds
    self.onDone = onDone
  }

  /// Harness/snapshot initialiser with a pre-built model.
  init(model: EditorModel, videoIds: [String], onDone: @escaping () -> Void) {
    _model = StateObject(wrappedValue: model)
    self.videoIds = videoIds
    self.onDone = onDone
  }

  var body: some View {
    VStack(spacing: 0) {
      EditorHeader(model: model, videoIds: videoIds, done: done)
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          EditorValidationStrip(model: model)
          Divider()
          EditorPreview(model: model, playback: model.playback)
            .allowsHitTesting(!model.readOnly)
          Divider()
          EditorTimeline(model: model, playback: model.playback)
            .disabled(model.fileMissing || model.video == nil || model.readOnly)
        }
        Divider()
        EditorInspector(model: model)
          .disabled(model.readOnly || model.video == nil)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .background(EditorKeyMonitor(handle: handleKey))
    .onChange(of: model.tab) { _, t in
      if t == .cover {
        model.playback.pause()
        model.playback.seek(model.edit.coverTime ?? model.trim.start, exact: true)
      }
    }
    .onDisappear { model.flushAndWait(); model.playback.unload() }
  }

  private func done() {
    model.flushAndWait()
    model.playback.pause()
    onDone()
  }

  /// Space play/pause · I / O trim at playhead · ←/→ step a frame. Ignored while typing.
  private func handleKey(_ e: NSEvent) -> Bool {
    if e.window?.firstResponder is NSTextView { return false }
    let mods = e.modifierFlags.intersection([.command, .option, .control])
    guard mods.isEmpty, !model.fileMissing, model.video != nil else { return false }
    let pb = model.playback
    switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased()) {
    case (49, _): pb.toggle(); return true
    case (123, _): pb.step(e.modifierFlags.contains(.shift) ? -10 : -1, fps: model.fps); return true
    case (124, _): pb.step(e.modifierFlags.contains(.shift) ? 10 : 1, fps: model.fps); return true
    case (_, "i"):
      let t = min(pb.time, model.trim.end - 0.5)
      model.updateEdit { $0.trimIn = t <= 0.01 ? nil : t }
      return true
    case (_, "o"):
      let t = max(pb.time, model.trim.start + 0.5)
      model.updateEdit { $0.trimOut = t >= model.duration - 0.01 ? nil : t }
      return true
    default: return false
    }
  }
}

// MARK: - Header (E.L)

struct EditorHeader: View {
  @ObservedObject var model: EditorModel
  var videoIds: [String]
  var done: () -> Void

  private var index: Int? { videoIds.firstIndex(of: model.videoId) }

  /// The clip's own name without the "<date> – <session> – " prefix.
  private var title: String {
    guard let v = model.video else { return "Video" }
    let prefix = model.sessionName + " – "
    return v.name.hasPrefix(prefix) ? String(v.name.dropFirst(prefix.count)) : v.name
  }

  var body: some View {
    HStack(spacing: 10) {
      Button(action: done) { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
        .buttonStyle(.borderless).help("Back").accessibilityLabel("Back")
      VStack(alignment: .leading, spacing: 0) {
        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(Captions.setName(model.sessionName)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      HStack(spacing: 2) {
        Button { go(-1) } label: { Image(systemName: "chevron.left") }
          .keyboardShortcut("[", modifiers: .command).disabled((index ?? 0) <= 0).help("Previous video (⌘[)")
          .accessibilityLabel("Previous video")
        Button { go(1) } label: { Image(systemName: "chevron.right") }
          .keyboardShortcut("]", modifiers: .command).disabled((index ?? videoIds.count) >= videoIds.count - 1).help("Next video (⌘])")
          .accessibilityLabel("Next video")
        if let i = index {
          Text("\(i + 1) of \(videoIds.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 4)
        }
      }
      .buttonStyle(.borderless).controlSize(.small)
      Spacer()
      saveIndicator
      statusPill
      Button("Done", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
  }

  private func go(_ d: Int) {
    guard let i = index, videoIds.indices.contains(i + d) else { return }
    model.playback.pause()
    model.load(videoIds[i + d])
  }

  @ViewBuilder private var saveIndicator: some View {
    if model.readOnly {
      EditorPill(text: "Read only", color: .red, systemImage: "lock.fill")
    } else if model.saving {
      HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Saving").font(.system(size: 11)) }.foregroundStyle(.secondary)
    } else if model.lastSaved != nil {
      Label("Saved", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
    } else {
      Label("Auto-saves", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder private var statusPill: some View {
    let issues = EditorValidationStrip.liveIssues(model)
    if model.readOnly || model.loadError != nil {
      EmptyView()  // the Read only pill and the strip say why
    } else if model.video?.missing == true || model.fileMissing {
      EditorPill(text: "File missing", color: .red, systemImage: "exclamationmark.triangle.fill")
    } else if issues.isEmpty {
      EditorPill(text: "Ready", color: .green, systemImage: "checkmark")
    } else {
      EditorPill(text: "\(issues.count) to fix", color: .orange)
    }
  }
}

// MARK: - Validation strip (E.S9)

struct EditorValidationStrip: View {
  @ObservedObject var model: EditorModel

  /// Store issues, with platform length checks recomputed live from the in-memory edit.
  static func liveIssues(_ m: EditorModel) -> [ValidationIssue] {
    guard let v = m.video else { return m.issues }
    return m.issues.filter { $0.kind != .tooLong } + Validation.platformIssues(video: v, edit: m.edit, settings: m.settings)
  }

  var body: some View {
    let issues = Self.liveIssues(model)
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let e = model.loadError {
          EditorPill(text: e, color: .red, systemImage: "exclamationmark.octagon.fill")
        } else if model.fileMissing && !issues.contains(where: { $0.kind == .missingFile }) {
          EditorPill(text: "File missing", color: .red, systemImage: "exclamationmark.triangle.fill")
        } else if issues.isEmpty {
          Text("Posts to " + model.postingPlatforms.map(\.shortName).joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(issues) { i in item(i) }
        ForEach(Array(model.edit.skippedPlatforms).sorted()) { p in
          HStack(spacing: 4) {
            EditorPill(text: "\(p.displayName) skipped", color: .secondary, systemImage: "slash.circle")
            Button("Undo") { model.updateEdit { $0.skippedPlatforms.remove(p) } }.buttonStyle(.borderless).font(.system(size: 11))
          }
        }
      }
      .padding(.horizontal, 14)
    }
    .frame(height: 34)
  }

  @ViewBuilder private func item(_ i: ValidationIssue) -> some View {
    switch i.kind {
    case .tooLong:
      if let p = i.platform {
        HStack(spacing: 4) {
          EditorPill(text: i.message, color: .orange, systemImage: "clock.badge.exclamationmark")
          Button("Trim for \(p.displayName)") { model.addPlatformTrim(p) }.controlSize(.small)
          Button("Skip") { model.updateEdit { $0.skippedPlatforms.insert(p) } }.controlSize(.small).help("Skip this platform")
        }
      }
    case .missingFile, .corrupt:
      EditorPill(text: i.message, color: .red, systemImage: "exclamationmark.triangle.fill")
    default:
      Button { model.tab = tab(for: i.kind) } label: {
        EditorPill(text: i.message, color: .orange, systemImage: icon(for: i.kind))
      }
      .buttonStyle(.plain)
      .help("Open the \(tab(for: i.kind).rawValue) tab")
    }
  }

  private func tab(for k: ValidationIssue.Kind) -> EditorTab {
    switch k {
    case .noCrop: .frame
    case .noText: .text
    default: .caption
    }
  }

  private func icon(for k: ValidationIssue.Kind) -> String {
    switch k {
    case .noCrop: "crop"
    case .noText: "textformat"
    case .captionTooLong, .titleTooLong: "character.cursor.ibeam"
    default: "text.bubble"
    }
  }
}

// MARK: - Keyboard

/// Local key monitor active while the editor is in a window.
struct EditorKeyMonitor: NSViewRepresentable {
  var handle: (NSEvent) -> Bool
  func makeNSView(context: Context) -> MonitorView { let v = MonitorView(); v.handle = handle; return v }
  func updateNSView(_ v: MonitorView, context: Context) { v.handle = handle }
  final class MonitorView: NSView {
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        guard let self, e.window === self.window, let h = self.handle else { return e }
        return h(e) ? nil : e
      }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
  }
}
