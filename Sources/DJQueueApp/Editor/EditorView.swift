import AppKit
import DJQCore
import SwiftUI

/// The full-window short-form editor (DESIGN-v2 §7). Entry point used by the app:
/// `EditorView(store:videoId:videoIds:onDone:)`.
///
/// ```
/// ┌ header 52: ‹ Back · Title · ‹ › clip · [2 to fix] · v1 ▾ ·························· Done ┐
/// │ canvas (bg.canvas): [Frame | Zones | Preview]                     ┌ inspector 340 ┐ │
/// │                     picture / safe zones / phone mocks            │ Title Frame … │ │
/// │                     mode chips                                    │               │ │
/// ├ timeline card: transport · text bar · filmstrip, markers, grace   │               │ │
/// └──────────────────────────────────────────────────────────────────┴───────────────┘
/// ```
struct EditorView: View {
  @StateObject private var model: EditorModel
  private let videoIds: [String]
  private let onDone: () -> Void
  /// Drawn in the header after the status chip for the clip being edited (the app's stage control).
  var headerAccessory: ((String) -> AnyView)?

  init(store: Store, videoId: String, videoIds: [String], onDone: @escaping () -> Void,
       headerAccessory: ((String) -> AnyView)? = nil) {
    _model = StateObject(wrappedValue: EditorModel(store: store, videoId: videoId))
    self.videoIds = videoIds
    self.onDone = onDone
    self.headerAccessory = headerAccessory
  }

  /// Harness/snapshot initialiser with a pre-built model.
  init(model: EditorModel, videoIds: [String], onDone: @escaping () -> Void) {
    _model = StateObject(wrappedValue: model)
    self.videoIds = videoIds
    self.onDone = onDone
  }

  var body: some View {
    VStack(spacing: 0) {
      EditorHeader(model: model, videoIds: videoIds, done: done, accessory: headerAccessory)
      DSSeparator()
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: DS.space.sm) {
          if let e = model.loadError {
            DSAttentionCard(title: e, tone: .danger).padding(.horizontal, DS.space.md).padding(.top, DS.space.sm)
          }
          EditorCanvas(model: model, playback: model.playback)
            .allowsHitTesting(!model.readOnly)
          EditorTimeline(model: model, playback: model.playback)
            .disabled(model.fileMissing || model.video == nil || model.readOnly)
            .background(DS.color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
            .dsBorder(radius: DS.radius.lg)
            .dsElevation(DS.elevation.e1)
            .padding(.leading, DS.space.sm).padding(.bottom, DS.space.sm)
        }
        EditorInspector(model: model)
          .padding(DS.space.sm)
      }
      .background(DS.color.canvas)
    }
    .background(DS.color.background)
    .overlay(alignment: .bottom) {
      if let t = model.toast {
        DSToast(toast: DSToastModel(message: t)).padding(.bottom, 180).transition(.dsPop)
      }
    }
    .dsAnimation(DS.motion.popover, value: model.toast)
    .background(EditorKeyMonitor(handle: handleKey))
    // Don't start with the cursor in the Title field (Space should play, not type).
    .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    .onDisappear { model.flushAndWait(); if !model.snapshotMode { model.playback.unload() } }
  }

  private func done() {
    model.flushAndWait()
    model.playback.pause()
    onDone()
  }

  /// Space play/pause · I / O trim at playhead · ←/→ step a frame (⇧ ten). Ignored while typing.
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
      model.setTrimIn(min(pb.time, model.trim.end - 0.5)); return true
    case (_, "o"):
      model.setTrimOut(max(pb.time, model.trim.start + 0.5)); return true
    default: return false
    }
  }
}

// MARK: - Header (52)

struct EditorHeader: View {
  @ObservedObject var model: EditorModel
  var videoIds: [String]
  var done: () -> Void
  var accessory: ((String) -> AnyView)? = nil
  @State private var showVersions = false

  private var index: Int? { videoIds.firstIndex(of: model.videoId) }

  var body: some View {
    HStack(spacing: DS.space.xs) {
      DSButton("Back", icon: "chevron.left", variant: .ghost, size: .sm, tooltip: "Save and go back") { done() }
      DSSeparator(vertical: true).frame(height: 20)
      Button { model.scrollTarget = .title; model.focusTitle += 1 } label: {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 5) {
            Text(model.video?.displayName ?? "Clip").font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(1)
              .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if model.title == nil && model.video != nil {
              DSBadge("Raw tag", style: .outline, size: .sm)
            }
          }
          Text(Captions.setName(model.sessionName)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(EditorPressStyle())
      .help("Rename — edit the Title")
      HStack(spacing: 2) {
        DSIconButton("chevron.left", tooltip: "Previous clip", size: .sm, shortcut: "⌘[",
                     disabledReason: (index ?? 0) <= 0 ? "This is the first clip in the list" : nil) { go(-1) }
          .keyboardShortcut("[", modifiers: .command)
        DSIconButton("chevron.right", tooltip: "Next clip", size: .sm, shortcut: "⌘]",
                     disabledReason: (index ?? videoIds.count) >= videoIds.count - 1 ? "This is the last clip in the list" : nil) { go(1) }
          .keyboardShortcut("]", modifiers: .command)
        if let i = index, videoIds.count > 1 {
          Text("\(i + 1) of \(videoIds.count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
            .padding(.leading, 2)
        }
      }
      statusChip
      if let accessory { accessory(model.videoId) }
      Spacer()
      saveIndicator
      versionPicker
      DSButton("Done", variant: .primary, size: .md, tooltip: "Save and close", shortcut: "⌘↩") { done() }
        .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, DS.space.sm)
    .frame(height: DS.size.toolbar)
    .background(DS.color.background)
  }

  private func go(_ d: Int) {
    guard let i = index, videoIds.indices.contains(i + d) else { return }
    model.playback.pause()
    model.load(videoIds[i + d])
  }

  private var versionPicker: some View {
    Button { showVersions.toggle() } label: {
      HStack(spacing: 4) {
        Text("v\(model.versionNo)").font(DS.type.calloutSemibold)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
      }
    }
    .buttonStyle(DSButtonStyle(variant: .outline, size: .sm))
    .help("Text version — versions change the text and caption for reposts")
    .popover(isPresented: $showVersions, arrowEdge: .bottom) { EditorVersionList(model: model) }
  }

  @ViewBuilder private var saveIndicator: some View {
    Group {
      if model.readOnly {
        DSBadge("Read only", style: .soft(.danger), icon: "lock.fill").help("The saved edit can't be read — run Doctor")
      } else if model.saving {
        HStack(spacing: 5) { DSSpinner(size: 10); Text("Saving") }
      } else if model.lastSaved != nil {
        Label("Saved", systemImage: "checkmark")
      } else {
        Label("Saves as you go", systemImage: "checkmark.circle")
      }
    }
    .font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    .padding(.trailing, 4)
  }

  @ViewBuilder private var statusChip: some View {
    let issues = model.liveIssues
    if model.readOnly || model.loadError != nil {
      EmptyView()
    } else if model.video?.missing == true || model.fileMissing {
      DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark.triangle.fill")
    } else if issues.isEmpty {
      DSBadge("Ready", style: .soft(.success), icon: "checkmark").help("Nothing to fix — this clip can be queued")
    } else {
      Button {
        if let first = issues.first { model.scrollTarget = EditorModel.section(for: first.kind) }
      } label: {
        DSBadge("\(issues.count) to fix", style: .soft(.warning), icon: "exclamationmark.circle.fill")
      }
      .buttonStyle(EditorPressStyle())
      .help(issues.map(\.message).joined(separator: "\n") + "\n\nClick to jump to the first one")
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
