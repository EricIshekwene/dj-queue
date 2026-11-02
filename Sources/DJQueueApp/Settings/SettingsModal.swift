import AppKit
import DJQCore
import Observation
import SwiftUI

/// The ten Settings sections (DESIGN-v2 §6.9), in nav order.
enum SettingsSection: String, CaseIterable, Identifiable {
  case general, platforms, schedule, queue, newClipDefaults, captions, rendering, playback, alerts, engine
  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .platforms: "Platforms"
    case .schedule: "Schedule"
    case .queue: "Queue"
    case .newClipDefaults: "New clip defaults"
    case .captions: "Captions & titles"
    case .rendering: "Rendering"
    case .playback: "Playback & autoplay"
    case .alerts: "Alerts"
    case .engine: "Engine"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .platforms: "square.stack.3d.up"
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
  /// Anchor id the New clip defaults pane scrolls to when it appears (consumed once).
  var scrollTarget: String?

  func reset() {
    draft = nil
    confirm = nil
    scrollTarget = nil
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
      DSIconButton("xmark", tooltip: "Close settings", size: .sm, shortcut: "esc") { model.showSettings = false }
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
          DSButton("Cancel", variant: .ghost) { ui.confirm = nil }
            .keyboardShortcut(.cancelAction)
          DSButton(c.confirmTitle, variant: c.destructive ? .destructiveSolid : .primary) {
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

/// The scrolling body of an immediate-apply section.
struct SettingsScroll<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.bottom, DS.space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
  }
}
