import AppKit
import DJQCore
import SwiftUI

/// Window root (DESIGN-v2 §3): custom 260 pt sidebar + the current screen (each screen draws its own toolbar via
/// ScreenScaffold). The editor takes over the whole window. In-window overlays (scrim + e3 card): ⌘K palette,
/// Settings modal, bulk confirmation, quick look, keyboard shortcuts. One toast at the bottom of the content area, above the bulk bar / Score pill (`model.toast`).
struct MainWindowView: View {
  @Bindable var model: AppModel

  var body: some View {
    ZStack {
      if let ed = model.editor {
        EditorView(store: model.store, videoId: ed.videoId, videoIds: ed.videoIds, onDone: { model.closeEditor() },
                   trimPlatform: ed.trimPlatform,
                   onDeleteGroup: { model.confirmDeleteGroup($0, undoHint: "Undo on the message that follows brings it back.") },
                   headerAccessory: { id in AnyView(EditorStageControl(model: model, videoId: id)) })
          .transition(.opacity)
      } else {
        shell
      }
      overlays
    }
    .dsToast($model.toast)
    .background { ShortcutButtons(model: model) }
    .sheet(isPresented: $model.offerLaunchAgent) { LaunchAgentOffer(model: model) }
    .sheet(item: $model.scorePrompt) { v in ScorePromptSheet(model: model, video: v) }
    .sheet(item: $model.pinPrompt) { v in PinPromptSheet(model: model, video: v) }
    .confirmationDialog("Pause all posting?", isPresented: $model.confirmPause) {
      Button("Pause all posting", role: .destructive) { model.setPaused(true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Nothing is handed to you or posted until you resume. The plan stays as it is.")
    }
    .frame(minWidth: 1100, minHeight: 700)
    .background(DS.color.background)
    .ignoresSafeArea()
  }

  private var shell: some View {
    GeometryReader { geo in
      let compact = model.sidebarIsCompact(width: geo.size.width)
      HStack(spacing: 0) {
        AppSidebar(model: model, compact: compact)
          .frame(width: compact ? AppSidebar.compactWidth : DS.size.sidebarWidth)
        VStack(spacing: 0) { UpdateBanner(); screenView }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DS.color.background)
          .dsToastArea()
      }
      .dsAnimation(DS.motion.layout, value: compact)
    }
  }

  @ViewBuilder private var screenView: some View {
    switch model.screen {
    case .score: ScoreView(model: model)
    case .edit: EditView(model: model)
    case .queue: QueueView(model: model)
    case .week: WeekView(model: model)
    case .today: TodayView(model: model)
    case .library: LibraryView(model: model)
    case .posts: PostsView(model: model)
    case .health: HealthView(model: model)
    }
  }

  @ViewBuilder private var overlays: some View {
    if model.showPalette {
      CommandPalette(model: model).transition(.opacity)
    }
    if model.showSettings {
      ModalHost(onDismiss: { model.showSettings = false }) { SettingsModal(model: model) }
    }
    if let v = model.previewVideo {
      ModalHost(onDismiss: { model.previewVideo = nil }) { ClipPreviewSheet(model: model, video: v) }
    }
    if model.showShortcuts {
      ModalHost(onDismiss: { model.showShortcuts = false }) { ShortcutSheet(model: model) }
    }
    if let p = model.pendingBulk {
      ModalHost(onDismiss: { model.cancelPendingBulk() }) { BulkConfirmSheet(model: model, pending: p) }
    }
    // PLANNING: post dialogs in-window (DSDialog over the scrim; they also render in snapshots).
    if let p = model.markPostedTarget {
      ModalHost(onDismiss: { model.markPostedTarget = nil }) { MarkPostedSheet(model: model, post: p).id(p.id) }
    }
    if let p = model.reportTarget {
      ModalHost(onDismiss: { model.reportTarget = nil }) { ReportProblemSheet(model: model, post: p).id(p.id) }
    }
    if let v = model.longformTarget {
      ModalHost(onDismiss: { model.longformTarget = nil }) { LongformPostedSheet(model: model, video: v).id(v.id) }
    }
    // F8: "Are you sure?" for destructive / plan-wide actions — above everything, the editor included.
    ConfirmDialogHost(model: model)
  }
}

/// Scrim (`DS.color.scrim`) + centred card; click outside or Esc dismisses.
struct ModalHost<Content: View>: View {
  let onDismiss: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    ZStack {
      DS.color.scrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onDismiss)
      content.onExitCommand(perform: onDismiss)
    }
    .transition(.opacity)
  }
}

// SettingsModal lives in Settings/SettingsModal.swift (Settings leaf).

/// First run of the installed app (decision Q28): run in the background at login? Default Yes.
struct LaunchAgentOffer: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    DSDialog("Run DJ Queue in the background at login?",
             description: "The menu-bar item and the engine keep running when the window is closed, so posts are prepared and reminders arrive on time.",
             icon: "menubar.rectangle") {
      EmptyView()
    } footer: {
      DSButton("Not now", variant: .ghost, tooltip: "Run only while this window is open; ask again from Settings › Engine") {
        UserDefaults.standard.set(true, forKey: "djq.askedLaunchAgent")
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      DSButton("Run at login", variant: .primary, tooltip: "Install the background engine; DJ Queue restarts once") {
        dismiss()
        AppHost.shared.installLaunchAgent()
      }
      .keyboardShortcut(.defaultAction)
    }
    .background(DS.color.surfaceRaised)
  }
}

// MARK: - Keyboard shortcuts

/// Window-wide shortcuts as hidden buttons. ⌘A and ⌘Z act on the current screen's clips only when no text field
/// is being edited and the editor is closed; otherwise they go down the responder chain (Select All / Undo typing).
/// Esc clears the selection while no overlay is open.
struct ShortcutButtons: View {
  @Bindable var model: AppModel

  var body: some View {
    ZStack {
      ForEach(Screen.allCases) { s in
        Button("") { go(s) }.keyboardShortcut(s.key, modifiers: .command)
      }
      Button("") { model.showPalette.toggle() }.keyboardShortcut("k", modifiers: .command)
      Button("") { model.showShortcuts.toggle() }.keyboardShortcut("/", modifiers: .command)
      Button("") {
        if let v = model.focusedVideo { model.openEditor(v.id, in: model.selectedVideoIds) } else { model.show("Select one clip to open it in the editor") }
      }
        .keyboardShortcut("e", modifiers: .command)
      Button("") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
      Button("") {
        if Self.textFieldIsEditing || model.editor != nil {
          NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } else {
          model.selectAll(model.screen)
        }
      }
      .keyboardShortcut("a", modifiers: .command)
      // ⌘Z: typing → the text field's own undo; the editor handles its own ⌘Z/⇧⌘Z (EditorUndoKeys, field-level
      // edit history); otherwise the most recent undoable app action (UndoHistory).
      if model.editor == nil {
        Button("") {
          if Self.textFieldIsEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undoLast() }
        }
        .keyboardShortcut("z", modifiers: .command)
      }
      if !model.selected(model.screen).isEmpty && !anyOverlay {
        Button("") { model.clearSelection(model.screen) }.keyboardShortcut(.escape, modifiers: [])
      }
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var anyOverlay: Bool {
    model.showPalette || model.showSettings || model.pendingBulk != nil || model.previewVideo != nil || model.showShortcuts
      || model.editor != nil
  }

  private func go(_ s: Screen) {
    // Leaving the editor by sidebar / ⌘-number / ⌘K: `editor = nil` runs the same close path as Done
    // (`AppModel.editorDidClose`: saves land, changed covers + proxies refresh, the session is journaled), without
    // Done's "mark the post fixed".
    if model.editor != nil { model.editor = nil }
    model.showSettings = false
    model.screen = s
  }

  /// True while an NSTextView (a SwiftUI TextField's field editor or a text area) has keyboard focus.
  static var textFieldIsEditing: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
}

/// ⌘/ cheat sheet (in-window modal).
struct ShortcutSheet: View {
  @Bindable var model: AppModel

  private let groups: [(String, [(String, String)])] = [
    ("Everywhere", [("⌘K", "Search clips and commands"), ("⌘/", "This cheat sheet"), ("⌘1 – ⌘8", "Score · Edit · Queue · Week · Today · Library · Posts · Health"),
                    ("⌘,", "Settings"), ("⌘R", "Refresh"), ("⌘0", "Open the DJ Queue window (menu bar)"),
                    ("⌘Z", "Undo the most recent change (again for the one before)")]),
    ("Selecting clips", [("Click circle", "Select a clip"), ("⇧ Click", "Select a range"), ("⌘ Click", "Add or remove one"),
                         ("⌘A", "Select every clip on the screen"), ("Esc", "Clear the selection")]),
    ("Clips", [("⌘E", "Open the selected clip in the editor"), ("← / →", "Previous / next clip (Single view)"),
               ("0–9", "Type a score for the selected clips (Queue, Library)"), ("⌘⌫", "Exclude the clip (Score)")]),
    ("Week", [("⌘↩", "Approve week"), ("Drag", "Move or swap days")]),
    ("Editor", [("⌘Z / ⇧⌘Z", "Undo / redo the last change to this clip"), ("⌘[ / ⌘]", "Previous / next clip"), ("⌘↩", "Done"),
                ("Space", "Play / pause"), ("I / O", "Set the trim start / end at the playhead")]),
  ]

  var body: some View {
    DSDialog("Keyboard shortcuts", width: 720, onClose: { model.showShortcuts = false }) {
      HStack(alignment: .top, spacing: DS.space.xxl) {
        VStack(alignment: .leading, spacing: DS.space.lg) { group(groups[0]); group(groups[3]) }
        VStack(alignment: .leading, spacing: DS.space.lg) { group(groups[1]); group(groups[2]); group(groups[4]) }
      }
    } footer: {
      DSButton("Done", variant: .primary) { model.showShortcuts = false }.keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func group(_ g: (String, [(String, String)])) -> some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      DSEyebrow(g.0)
      ForEach(g.1, id: \.0) { k in
        HStack {
          Text(k.1).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(2)
          Spacer(minLength: DS.space.md)
          DSKeyHint(k.0)
        }
        .frame(width: 310)
      }
    }
  }
}
