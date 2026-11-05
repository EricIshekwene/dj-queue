import AppKit
import DJQCore
import Observation
import SwiftUI

/// The eleven Settings sections (DESIGN-v2 §6.9), in nav order.
enum SettingsSection: String, CaseIterable, Identifiable {
  case general, platforms, publishing, schedule, queue, newClipDefaults, captions, rendering, playback, alerts, engine
  var id: String { rawValue }

  /// The pane's name, shared with search (`SettingsSearchRegistry`).
  var title: String { SettingsPane(rawValue: rawValue)?.title ?? rawValue }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .platforms: "square.stack.3d.up"
    case .publishing: "paperplane"
    case .schedule: "clock"
    case .queue: "list.number"
    case .newClipDefaults: "slider.horizontal.3"
    case .captions: "text.bubble"
    case .rendering: "film"
    case .playback: "play.rectangle"
    case .alerts: "bell"
    case .engine: "gearshape.2"
    }
  }
}

/// Settings UI state that outlives one modal presentation: the New clip defaults draft (kept until Save or
/// Cancel, so closing the modal never loses edits), the in-modal confirmation and a scroll target (snapshots).
@MainActor @Observable
final class SettingsUIState {
  static let shared = SettingsUIState()
  /// nil = no edits (the pane shows the saved defaults).
  var draft: NewClipDefaults?
  var confirm: SettingsConfirm?
  /// Anchor the open pane scrolls to (consumed once). A row or header anchor also flashes (⌘K).
  var scrollTarget: String?
  /// The row flashing after a search result opened it.
  var flashAnchor: String?
  @ObservationIgnored private var flashSerial = 0
  /// Publishing rows open when the pane appears (snapshots).
  var publishingExpanded: Set<Platform> = []
  /// Publishing opens with the key field in Replace mode (snapshots).
  var publishingReplacingKey = false

  /// Scrolls the pane to `scrollTarget` and flashes it. Panes that fill in after appearing (Captions & titles) get
  /// the repeat, and the row is scrolled to the centre so it never sits under the sticky footer.
  func landOnTarget(_ proxy: ScrollViewProxy) {
    guard let t = scrollTarget else { return }
    scrollTarget = nil
    let isRow = t.contains(":")
    for delay in isRow ? [0, 0.08, 0.3] : [0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(t, anchor: isRow ? .center : .top) }
    }
    guard isRow else { return }
    flashSerial += 1
    let serial = flashSerial
    flashAnchor = t
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.8))
      guard let self, self.flashSerial == serial else { return }
      self.flashAnchor = nil
    }
  }

  func reset() {
    draft = nil
    confirm = nil
    scrollTarget = nil
    flashAnchor = nil
    publishingExpanded = []
    publishingReplacingKey = false
  }

  func isDirty(_ saved: NewClipDefaults) -> Bool { draft.map { $0 != saved } ?? false }
}

/// A confirmation shown inside the Settings modal (DSDialog over a scrim).
struct SettingsConfirm: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let confirmTitle: String
  var destructive = false
  var icon = "exclamationmark.triangle"
  let action: () -> Void
}

/// Settings as an in-window modal (DESIGN-v2 §6.9, ref R2.SETTINGS): 760×560, r.lg, e3 over the scrim (drawn by
/// `ModalHost`). Left nav 200 pt on `DS.color.sidebar` with ✕ top-left; right pane = section title + hairline +
/// ChatGPT rows scrolling inside the pane.
struct SettingsModal: View {
  @Bindable var model: AppModel
  @State private var ui = SettingsUIState.shared

  var body: some View {
    HStack(spacing: 0) {
      nav
      pane
    }
    .frame(width: 760, height: 560)
    .background(DS.color.surfaceRaised)
    .background { SettingsFocusParker(token: model.settingsSection.rawValue) }
    .overlay { confirmOverlay }
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private var nav: some View {
    VStack(alignment: .leading, spacing: 2) {
      DSIconButton("xmark", tooltip: ui.isDirty(model.settings.defaults) ? "Close settings (unsaved defaults are kept)" : "Close settings",
                   size: .sm, shortcut: "esc") { model.showSettings = false }
        .padding(.leading, 2)
        .padding(.bottom, DS.space.sm)
      ForEach(SettingsSection.allCases) { s in
        SettingsNavRow(section: s, isSelected: model.settingsSection == s,
                       unsaved: s == .newClipDefaults && ui.isDirty(model.settings.defaults)) {
          model.settingsSection = s
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DS.space.xs)
    .padding(.top, DS.space.sm)
    .frame(width: 200)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(DS.color.sidebar)
  }

  private var pane: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(model.settingsSection.title)
        .font(DS.type.headline)
        .foregroundStyle(DS.color.text)
        .frame(height: DS.size.controlSm)
        .padding(.top, DS.space.sm)
        .padding(.bottom, DS.space.sm)
      DSSeparator()
      content
    }
    .padding(.horizontal, DS.space.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var content: some View {
    switch model.settingsSection {
    case .general: SettingsScroll { GeneralSettings(model: model) }
    case .platforms: SettingsScroll { PlatformsSettings(model: model) }
    case .publishing: SettingsScroll { PublishingSection(model: model) }
    case .schedule: SettingsScroll { ScheduleSettings(model: model) }
    case .queue: SettingsScroll { QueueSettings(model: model) }
    case .newClipDefaults: NewClipDefaultsSettings(model: model, ui: ui)
    case .captions: CaptionsSettings(model: model)
    case .rendering: SettingsScroll { RenderingSettings(model: model) }
    case .playback: SettingsScroll { PlaybackSettings(model: model) }
    case .alerts: SettingsScroll { AlertsSettings(model: model) }
    case .engine: SettingsScroll { EngineSettings(model: model, ui: ui) }
    }
  }

  @ViewBuilder private var confirmOverlay: some View {
    if let c = ui.confirm {
      ZStack {
        DS.color.scrim.contentShape(Rectangle()).onTapGesture { ui.confirm = nil }
        DSDialog(c.title, description: c.message, icon: c.icon, iconTone: c.destructive ? .danger : .neutral, width: 420) {
          EmptyView()
        } footer: {
          DSButton("Cancel", variant: .ghost, tooltip: "Close without changing anything", shortcut: "esc") { ui.confirm = nil }
            .keyboardShortcut(.cancelAction)
          DSButton(c.confirmTitle, variant: c.destructive ? .destructiveSolid : .primary, shortcut: "↩") {
            ui.confirm = nil
            c.action()
          }
          .keyboardShortcut(.defaultAction)
        }
        .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
      }
      .transition(.opacity)
    }
  }
}

/// Nav row (ChatGPT settings nav): 16 pt symbol, `callout` label on one line, r.sm selected fill. A dot marks
/// unsaved New clip defaults.
private struct SettingsNavRow: View {
  let section: SettingsSection
  let isSelected: Bool
  var unsaved = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DS.space.xs) {
        Image(systemName: section.symbol).font(.system(size: 14, weight: .regular)).frame(width: 18)
        Text(section.title).font(DS.type.callout).lineLimit(1)
        Spacer(minLength: 0)
        if unsaved { DSStatusDot(tone: .neutral, size: 6) }
      }
      .foregroundStyle(DS.color.text)
      .padding(.horizontal, 10)
      .frame(height: DS.size.sidebarItem)
      .background(isSelected ? DS.color.selected : hovering ? DS.color.hover : .clear,
                  in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsAnimation(DS.motion.hover, value: hovering)
    .dsTooltip(unsaved ? "New clip defaults have unsaved changes" : nil)
    .accessibilityLabel(section.title + (unsaved ? ", unsaved changes" : ""))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// Parks keyboard focus on the window whenever the modal opens or the section changes, so AppKit never drops the
/// caret into the section's first text field on its own.
private struct SettingsFocusParker: NSViewRepresentable {
  let token: String

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ v: NSView, context: Context) {
    guard context.coordinator.token != token else { return }
    context.coordinator.token = token
    for delay in [0.0, 0.1] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak v] in
        guard let w = v?.window, w.firstResponder is NSTextView else { return }
        w.makeFirstResponder(nil)
      }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator { var token: String? }
}

/// The scrolling body of an immediate-apply section. Goes to `SettingsUIState.scrollTarget` when it's set. The
/// horizontal padding pair leaves room for the row flash inside the scroll view's clip.
struct SettingsScroll<Content: View>: View {
  @ViewBuilder var content: Content
  private var ui: SettingsUIState { .shared }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) { content }
          .padding(.bottom, DS.space.xl)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, DS.space.xs)
      }
      .scrollIndicators(.automatic)
      .padding(.horizontal, -DS.space.xs)
      .onAppear { ui.landOnTarget(proxy) }
      .onChange(of: ui.scrollTarget) { ui.landOnTarget(proxy) }
    }
  }
}

/// Marks a row as a place search can land on: `scrollTo` finds it and it flashes `DS.color.selected` when it does.
struct SettingsAnchorModifier: ViewModifier {
  let anchor: String
  private var ui: SettingsUIState { .shared }

  func body(content: Content) -> some View {
    let on = ui.flashAnchor == anchor
    content
      .background {
        if on {
          RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous).fill(DS.color.selected)
            .padding(.horizontal, -DS.space.xs)
            .transition(.opacity)
            .probeFrame("setting:\(anchor)")
        }
      }
      .dsAnimation(DS.motion.hover, value: on)
      .id(anchor)
  }
}

extension View {
  func settingsAnchor(_ anchor: String) -> some View { modifier(SettingsAnchorModifier(anchor: anchor)) }
}
