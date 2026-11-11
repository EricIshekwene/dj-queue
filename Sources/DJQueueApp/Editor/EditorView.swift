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
  /// The editor's own window (from its key monitor), for letting go of a field when another clip opens.
  @State private var hostWindow = EditorHostWindow()
  private let videoIds: [String]
  private let onDone: () -> Void
  /// Drawn in the header after the status chip for the clip being edited (the app's stage control).
  var headerAccessory: ((String) -> AnyView)?
  /// Opened from "Trim for X" in the Edit list: add X's trim lane (at X's limit) once, and show Platforms.
  private var trimPlatform: Platform?

  init(store: Store, videoId: String, videoIds: [String], onDone: @escaping () -> Void, trimPlatform: Platform? = nil,
       appHooks: EditorAppHooks = EditorAppHooks(), headerAccessory: ((String) -> AnyView)? = nil) {
    _model = StateObject(wrappedValue: {
      let m = EditorModel(store: store, videoId: videoId)
      m.appHooks = appHooks
      return m
    }())
    self.videoIds = videoIds
    self.onDone = onDone
    self.trimPlatform = trimPlatform
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
            .background(EditorClickAway(isCovered: { model.isCovered?() == true }))
            .allowsHitTesting(!model.readOnly)
            // Read-only canvas ignores the pointer; this layer only says why on hover.
            .overlay { if model.readOnly { Color.clear.contentShape(Rectangle()).dsTooltip(nil, disabledReason: Self.readOnlyReason) } }
          EditorTimeline(model: model, playback: model.playback)
            .background(EditorClickAway(isCovered: { model.isCovered?() == true }))
            // A photo post's strip stays usable while a photo file is missing: taking that photo out is the fix.
            .disabled((model.fileMissing && !model.isPhoto) || model.video == nil || model.readOnly)
            .dsTooltip(nil, disabledReason: timelineOff)
            .background(DS.color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
            .dsBorder(radius: DS.radius.lg)
            .dsElevation(DS.elevation.e1)
            .padding(.leading, DS.space.sm).padding(.bottom, DS.space.sm)
        }
        EditorInspector(model: model)
          .padding(DS.space.sm)
      }
      .background(DS.color.canvas)
      // Round 23: while this item's video is being made nothing here may write to it; it says how far along it is.
      .overlay { if PhotoAudioUI.shared.busy == model.videoId { EditorMakingVideo() } }
    }
    .background(DS.color.background)
    .overlay(alignment: .bottom) {
      if let t = model.toast {
        // A photo post's timeline card is taller than a clip's and grows with its text lanes, and the bar above it
        // holds the zoom and Reset crop: the toast floats over the bottom of the picture, clear of both.
        DSToast(toast: DSToastModel(message: t))
          .padding(.bottom, model.isPhoto ? EditorPhotoTimeline.cardHeight(lanes: model.photoTextBars.laneCount) + DS.space.sm + 34 + DS.space.xs + DS.space.sm + 6 : 180)
          .transition(.dsPop)
      }
    }
    .dsAnimation(DS.motion.popover, value: model.toast)
    .background(EditorKeyMonitor(handle: handleKey, onWindow: { hostWindow.window = $0 }))
    // A new clip starts with the keyboard on the player, as the first one does (a field kept from the last clip
    // would take Space).
    .onChange(of: model.videoId) { _, _ in if model.isCovered?() != true { EditorFocus.leaveText(in: hostWindow.window) } }
    // Don't start with the cursor in the Title field (Space should play, not type).
    .onAppear {
      DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
      if let p = trimPlatform, !model.isPhoto, model.posting(p), model.edit.platformTrims[p] == nil, !model.readOnly {
        model.addPlatformTrim(p)
        model.scrollTarget = .platforms
      }
    }
    .onDisappear { model.flushAndWait(); if !model.snapshotMode { model.playback.unload() } }
  }

  static let readOnlyReason = "Editing is off: the saved edit can't be read (run Doctor)"

  /// Why the timeline is disabled (shown on hover), nil when it works.
  private var timelineOff: String? {
    if model.readOnly { return Self.readOnlyReason }
    if model.video == nil { return model.loading ? nil : "This clip wasn't found" }
    return model.fileMissing && !model.isPhoto ? "The clip file is missing; relink it in Health" : nil
  }

  private func done() {
    model.flushAndWait()
    model.playback.pause()
    onDone()
  }

  /// ⌘Z / ⇧⌘Z (`EditorUndoKeys`), then `EditorKeys` (round 19): Space play/pause · ← / → jump by Eric's arrow step
  /// (⇧ one frame) · ↑ / ↓ previous / next clip · I / O trim at the playhead · Esc leaves a text field. Typing in a
  /// field keeps its keys; lists keep ↑ / ↓; an overlay over the editor keeps all of them.
  private func handleKey(_ e: NSEvent) -> Bool {
    if EditorUndoKeys.handle(e, model: model) { return true }
    let mods = e.modifierFlags
    guard let action = EditorKeys.action(
      keyCode: e.keyCode, characters: e.charactersIgnoringModifiers, shift: mods.contains(.shift),
      commandLike: !mods.intersection([.command, .option, .control]).isEmpty, focus: EditorFocus.of(e.window),
      covered: model.isCovered?() == true, hasClip: (!model.fileMissing || model.isPhoto) && model.video != nil)
    else { return false }
    let pb = model.playback
    if model.isPhoto {
      // Round 21: ← / → step photos, ↑ / ↓ still change posts, and there is nothing to play or trim.
      switch action {
      case .seek(let d, _): model.stepPhoto(d)
      case .clip(let d): Self.open(d, model: model, in: videoIds)
      case .leaveTextField:
        if e.window?.performKeyEquivalent(with: e) == true { return true }
        EditorFocus.leaveText(in: e.window)
      case .togglePlay, .trimIn, .trimOut: break
      }
      return true
    }
    switch action {
    case .togglePlay: pb.toggle()
    case .seek(let d, let fine): pb.jump(d, step: model.arrowStep, fine: fine, fps: model.fps, duration: model.duration)
    case .clip(let d): Self.open(d, model: model, in: videoIds)
    case .trimIn: model.setTrimIn(min(pb.time, model.trim.end - 0.5))
    case .trimOut: model.setTrimOut(max(pb.time, model.trim.start + 0.5))
    case .leaveTextField:
      // A form's Cancel (the group and template forms, `.cancelAction`) takes Esc first: one press closes it.
      if e.window?.performKeyEquivalent(with: e) == true { return true }
      EditorFocus.leaveText(in: e.window)
    }
    return true
  }

  /// Save and open the clip `d` places away in `videoIds` (header arrows, ⌘[ ⌘], ↑ ↓). Nothing past either end.
  static func open(_ d: Int, model: EditorModel, in videoIds: [String]) {
    guard let i = videoIds.firstIndex(of: model.videoId), videoIds.indices.contains(i + d) else { return }
    model.playback.pause()
    model.load(videoIds[i + d])
  }
}

/// A weak hold on the editor's window, set by `EditorKeyMonitor`.
final class EditorHostWindow {
  weak var window: NSWindow?
}

/// Where the keyboard is in the editor's window, and letting go of a text field (round 19). Space only reaches the
/// player once no field has the cursor, and SwiftUI never takes the cursor out of a field by itself, so clicking the
/// picture or the timeline (`EditorClickAway`) and Esc both end typing.
enum EditorFocus {
  static func of(_ window: NSWindow?) -> EditorKeys.Focus {
    switch window?.firstResponder {
    case is NSTextView: return .text
    case is NSTableView, is NSOutlineView, is NSCollectionView, is NSBrowser: return .list
    default: return .none
    }
  }

  /// Ends typing in `window` (the field commits as it does on any blur). Leaves non-text focus alone.
  static func leaveText(in window: NSWindow?) {
    guard let w = window, w.firstResponder is NSTextView else { return }
    w.makeFirstResponder(nil)
  }
}

// MARK: - Header (52)

struct EditorHeader: View {
  @ObservedObject var model: EditorModel
  var videoIds: [String]
  var done: () -> Void
  var accessory: ((String) -> AnyView)? = nil
  @State private var showVersions = false
  /// Version waiting for the delete confirmation (asked here, after the popover closes).
  @State private var pendingDelete: Int?

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
              if model.namedByFile {
                DSBadge("No title", style: .outline, size: .sm, help: "No Title yet; screens show the photo's file name")
              } else {
                DSBadge("Raw tag", style: .outline, size: .sm, help: "No Title yet; screens show the marker tag")
              }
            }
          }
          // Round 21 (D18): a photo post says what it is where a clip names its set.
          Text(model.video?.markLabel ?? Captions.setName(model.sessionName)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(EditorPressStyle())
      .dsTooltip("Jump to the Title field to rename", side: .bottom)
      HStack(spacing: 2) {
        // Round 21: from a photo post the neighbour may be a clip or a photo post, so it isn't named.
        DSIconButton("chevron.left", tooltip: model.isPhoto ? "Save and open the one before" : "Save and open the previous clip", size: .sm, shortcut: "↑ or ⌘[",
                     disabledReason: (index ?? 0) <= 0 ? (model.isPhoto ? "This is the first in the list" : "This is the first clip in the list") : nil) { go(-1) }
          .keyboardShortcut("[", modifiers: .command)
        DSIconButton("chevron.right", tooltip: model.isPhoto ? "Save and open the next one" : "Save and open the next clip", size: .sm, shortcut: "↓ or ⌘]",
                     disabledReason: (index ?? videoIds.count) >= videoIds.count - 1 ? (model.isPhoto ? "This is the last in the list" : "This is the last clip in the list") : nil) { go(1) }
          .keyboardShortcut("]", modifiers: .command)
          .background(ScriptAnchor("Next clip"))
        if let i = index, videoIds.count > 1 {
          Text("\(i + 1) of \(videoIds.count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
            .padding(.leading, 2)
        }
      }
      statusChip
      if let accessory { accessory(model.videoId) }
      Spacer()
      saveIndicator
      undoButtons
      if !model.isPhoto { versionPicker }  // round 21 (D16): one version per photo post
      DSButton("Done", variant: .primary, size: .md, tooltip: "Save and close", shortcut: "⌘↩") { done() }
        .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, DS.space.sm)
    .frame(height: DS.size.toolbar)
    .background(DS.color.background)
    .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                        titleVisibility: .visible) {
      Button("Delete v\(pendingDelete ?? 0)", role: .destructive) {
        if let n = pendingDelete { model.deleteVersion(n) }
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text(deleteMessage)
    }
  }

  /// The editor's own change history (EditorModel.undo/redo, also ⌘Z / ⇧⌘Z).
  private var undoButtons: some View {
    let off = model.readOnly ? "Editing is off for this \(model.noun)" : nil
    return HStack(spacing: 0) {
      DSIconButton("arrow.uturn.backward", tooltip: "Undo the last change", size: .sm, shortcut: "⌘Z",
                   disabledReason: off ?? (model.canUndo ? nil : "Nothing to undo yet")) { model.undo() }
        .background(ScriptAnchor("Undo"))
      DSIconButton("arrow.uturn.forward", tooltip: "Redo the change you undid", size: .sm, shortcut: "⇧⌘Z",
                   disabledReason: off ?? (model.canRedo ? nil : "Nothing to redo")) { model.redo() }
        .background(ScriptAnchor("Redo"))
    }
  }

  private var deleteTitle: String { "Delete v\(pendingDelete ?? 0) of this clip?" }

  /// Says where the version is used, so a posted/planned version isn't deleted by accident.
  private var deleteMessage: String {
    guard let n = pendingDelete else { return "" }
    let u = model.usage(of: n)
    var parts: [String] = []
    if !u.posted.isEmpty { parts.append("It's posted on " + u.posted.map(\.displayName).joined(separator: ", ") + ".") }
    if !u.planned.isEmpty { parts.append("It's planned on " + u.planned.map(\.displayName).joined(separator: ", ") + ".") }
    if parts.isEmpty { parts.append("It isn't posted or planned anywhere.") }
    parts.append("Its text and caption are removed. ⌘Z in the editor brings it back.")
    return parts.joined(separator: " ")
  }

  private func go(_ d: Int) { EditorView.open(d, model: model, in: videoIds) }

  private var versionPicker: some View {
    Button { showVersions.toggle() } label: {
      HStack(spacing: 4) {
        Text("v\(model.versionNo)").font(DS.type.calloutSemibold)
        if model.isRepostReady(model.versionNo) {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.color.success)
        }
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
      }
    }
    .buttonStyle(DSButtonStyle(variant: .outline, size: .sm))
    .dsTooltip(model.isRepostReady(model.versionNo) ? "Switch or add text versions for reposts · v\(model.versionNo) is ready to repost"
                                                     : "Switch or add text versions for reposts")
    .background(ScriptAnchor("Versions"))
    .popover(isPresented: $showVersions, arrowEdge: .bottom) {
      EditorVersionList(model: model) { n in
        showVersions = false
        DispatchQueue.main.async { pendingDelete = n }
      }
    }
  }

  @ViewBuilder private var saveIndicator: some View {
    Group {
      if model.readOnly {
        DSBadge("Read only", style: .soft(.danger), icon: "lock.fill").dsTooltip("The saved edit can't be read; run Doctor")
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
    .dsTooltip(model.readOnly ? nil : "Every change saves at once; Undo takes it back", shortcut: model.readOnly ? nil : "⌘Z")
  }

  @ViewBuilder private var statusChip: some View {
    let issues = model.liveIssues
    if model.readOnly || model.loadError != nil {
      EmptyView()
    } else if model.video?.missing == true || model.fileMissing {
      DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark.triangle.fill")
        .dsTooltip(model.isPhoto ? "A photo file is gone. Put it back, or remove that photo from the strip."
                                 : "The clip file is gone; relink it in Health")
    } else if issues.isEmpty {
      // No "Ready" label: only Send to Queue, in the stage control beside it, moves the clip on (round 13).
      DSBadge("Nothing to fix", style: .soft(.success), icon: "checkmark")
        .dsTooltip("Nothing missing. Press Send to Queue when it's ready to post.")
    } else {
      // Round 7 (C1): jump to the first issue that has a section; a held clip is fixed with the stage control beside the
      // chip ("Send to Queue"), so the chip says that instead of pointing at an inspector section.
      let target = issues.first { EditorModel.section(for: $0.kind) != nil }
      let held = issues.first { $0.kind == .heldInEdit }
      Button {
        if let t = target, let s = EditorModel.section(for: t.kind) { model.scrollTarget = s }
        else if let h = held { model.show(h.message) }
        else if let first = issues.first { model.show(first.message) }
      } label: {
        DSBadge("\(issues.count) to fix", style: .soft(.warning), icon: "exclamationmark.circle.fill")  // tooltip-on-parent
      }
      .buttonStyle(EditorPressStyle())
      .dsTooltip(chipHelp(issues, target: target, held: held))
      .background(ScriptAnchor("To fix"))
    }
  }
}

extension EditorHeader {
  /// "Jump to: …" for the first issue with a section; held / missing / unreadable say what to do instead.
  func chipHelp(_ issues: [ValidationIssue], target: ValidationIssue?, held: ValidationIssue?) -> String {
    var parts: [String] = []
    if let t = target {
      parts.append(issues.count == 1 ? "Jump to: \(t.message)" : "Jump to the first of \(issues.count): \(t.message)")
    }
    if held != nil { parts.append("Sent back from the Queue: use Send to Queue (next to this) when it's done") }
    for i in issues where EditorModel.section(for: i.kind) == nil && i.kind != .heldInEdit { parts.append(i.message) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Keyboard

/// Put behind the picture and the timeline: a click there takes the cursor out of any text field first (round 19),
/// so Space plays right after typing a title or caption. Clicks on a text field itself (an inline editor) keep it.
struct EditorClickAway: NSViewRepresentable {
  /// True while an overlay (Settings, ⌘K) is over the editor: its clicks are its own.
  var isCovered: () -> Bool = { false }
  func makeNSView(context: Context) -> ZoneView { let v = ZoneView(); v.isCovered = isCovered; return v }
  func updateNSView(_ v: ZoneView, context: Context) { v.isCovered = isCovered }
  final class ZoneView: NSView {
    var isCovered: () -> Bool = { false }
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
        MainActor.assumeIsolated { self?.mouseDownAnywhere(e) }
        return e
      }
    }
    private func mouseDownAnywhere(_ e: NSEvent) {
      guard let w = window, e.window === w, w.firstResponder is NSTextView, !isHiddenOrHasHiddenAncestor, !isCovered(),
            bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
      // hitTest takes the point in the superview's coordinates: the frame view's are the window's.
      if let hit = w.contentView?.hitTest(e.locationInWindow), Self.isText(hit) { return }
      EditorFocus.leaveText(in: w)
    }
    static func isText(_ v: NSView) -> Bool {
      var cur: NSView? = v
      while let c = cur {
        if c is NSText || c is NSTextField { return true }
        cur = c.superview
      }
      return false
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
  }
}

/// Local key monitor active while the editor is in a window.
struct EditorKeyMonitor: NSViewRepresentable {
  var handle: (NSEvent) -> Bool
  /// Told the window the monitor lives in (nil when it leaves one).
  var onWindow: ((NSWindow?) -> Void)? = nil
  func makeNSView(context: Context) -> MonitorView { let v = MonitorView(); v.handle = handle; v.onWindow = onWindow; return v }
  func updateNSView(_ v: MonitorView, context: Context) { v.handle = handle; v.onWindow = onWindow }
  final class MonitorView: NSView {
    var handle: ((NSEvent) -> Bool)?
    var onWindow: ((NSWindow?) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
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
