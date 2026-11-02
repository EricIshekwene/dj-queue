import AppKit
import DJQCore
import SwiftUI

/// Window root (DESIGN-v2 §3): custom 260 pt sidebar + the current screen (each screen draws its own toolbar via
/// ScreenScaffold). The editor takes over the whole window. In-window overlays (scrim + e3 card): ⌘K palette,
/// Settings modal, bulk confirmation, quick look, keyboard shortcuts. One toast at the bottom (`model.toast`).
struct MainWindowView: View {
  @Bindable var model: AppModel

  var body: some View {
    ZStack {
      if let ed = model.editor {
        EditorView(store: model.store, videoId: ed.videoId, videoIds: ed.videoIds, onDone: { model.closeEditor() })
          .transition(.opacity)
      } else {
        shell
      }
      overlays
    }
    .dsToast($model.toast)
    .background { ShortcutButtons(model: model) }
    .sheet(item: $model.markPostedTarget) { p in MarkPostedSheet(model: model, post: p) }
    .sheet(item: $model.reportTarget) { p in ReportProblemSheet(model: model, post: p) }
    .sheet(item: $model.longformTarget) { v in LongformPostedSheet(model: model, video: v) }
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
        screenView
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DS.color.background)
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

/// Settings as an in-window modal (DESIGN-v2 §6.9): 760×560, r.lg, e3. The Settings leaf replaces the body with
/// the ChatGPT-style rows; this host keeps the frame, the close button and `model.settingsSection`.
struct SettingsModal: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsView(model: model, initial: model.settingsSection)
      .id(model.settingsSection)
      .frame(width: 760, height: 560)
      .background(DS.color.background)
      .clipShape(RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
      .overlay(alignment: .topTrailing) {
        DSIconButton("xmark", tooltip: "Close settings", size: .sm, shortcut: "esc") { model.showSettings = false }
          .padding(DS.space.sm)
      }
      .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }
}

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
      DSButton("Not now", variant: .ghost) {
        UserDefaults.standard.set(true, forKey: "djq.askedLaunchAgent")
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      DSButton("Run at login", variant: .primary) {
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
      Button("") { if let v = model.focusedVideo { model.openEditor(v.id, in: model.selectedVideoIds) } }
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
      Button("") {
        if Self.textFieldIsEditing || model.editor != nil { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undoLast() }
      }
      .keyboardShortcut("z", modifiers: .command)
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
    model.editor = nil
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
                    ("⌘,", "Settings"), ("⌘R", "Refresh")]),
    ("Selecting clips", [("Click circle", "Select a clip"), ("⇧ Click", "Select a range"), ("⌘ Click", "Add or remove one"),
                         ("⌘A", "Select every clip on the screen"), ("Esc", "Clear the selection"), ("⌘Z", "Undo the last bulk change")]),
    ("Clips", [("⌘E", "Open the selected clip in the editor"), ("← / →", "Previous / next clip (Single view)")]),
    ("Week", [("⌘↩", "Approve week"), ("Drag", "Move or swap days")]),
  ]

  var body: some View {
    DSDialog("Keyboard shortcuts", width: 720, onClose: { model.showShortcuts = false }) {
      HStack(alignment: .top, spacing: DS.space.xxl) {
        VStack(alignment: .leading, spacing: DS.space.lg) { group(groups[0]); group(groups[3]) }
        VStack(alignment: .leading, spacing: DS.space.lg) { group(groups[1]); group(groups[2]) }
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
