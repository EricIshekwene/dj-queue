import SwiftUI

/// shadcn Button variants. One `.primary` per screen. Every button is a capsule (DESIGN-v2 §1.3).
enum DSButtonVariant: String, CaseIterable, Sendable {
  /// shadcn `default`: near-black (light) / near-white (dark) fill. The single main action.
  case primary
  /// shadcn `secondary`: surface.sunken fill (rare — prefer ghost/outline).
  case secondary
  /// shadcn `outline`: transparent + border.strong.
  case outline
  /// shadcn `ghost`: no chrome until hover.
  case ghost
  /// shadcn `destructive`: soft red fill, red text (loud red only in confirm dialogs via `.destructiveSolid`).
  case destructive
  /// Confirm-dialog destructive action.
  case destructiveSolid
}

enum DSButtonSize: String, CaseIterable, Sendable {
  case sm, md, lg

  var height: CGFloat {
    switch self {
    case .sm: DS.size.controlSm
    case .md: DS.size.controlMd
    case .lg: DS.size.controlLg
    }
  }

  var hPad: CGFloat {
    switch self {
    case .sm: 12
    case .md: 16
    case .lg: 20
    }
  }

  var font: Font {
    switch self {
    case .sm: DS.type.calloutMedium
    case .md: DS.type.bodyMedium
    case .lg: Font.system(size: 15, weight: .medium)
    }
  }

  var iconSize: CGFloat {
    switch self {
    case .sm: 11.5
    case .md: 13
    case .lg: 14.5
    }
  }
}

/// Resolved colours for a variant in a state.
struct DSButtonColors {
  var fill: Color
  var text: Color
  var border: Color?

  static func resolve(_ v: DSButtonVariant, state: DSInteraction, enabled: Bool) -> DSButtonColors {
    let hot = state == .hover || state == .focused
    let pressed = state == .pressed
    var c: DSButtonColors
    switch v {
    case .primary:
      c = .init(fill: hot || pressed ? DS.color.primaryHover : DS.color.primary, text: DS.color.primaryText)
    case .secondary:
      c = .init(fill: pressed ? DS.color.fillPressed : hot ? DS.color.fillHover : DS.color.fill, text: DS.color.text)
    case .outline:
      c = .init(fill: pressed ? DS.color.selected : hot ? DS.color.hover : .clear, text: DS.color.text,
                border: DS.color.borderStrong)
    case .ghost:
      c = .init(fill: pressed ? DS.color.selected : hot ? DS.color.hover : .clear, text: DS.color.text)
    case .destructive:
      c = .init(fill: DS.color.danger.opacity(pressed ? 0.2 : hot ? 0.15 : 0.1), text: DS.color.danger)
    case .destructiveSolid:
      c = .init(fill: DS.color.danger.opacity(hot || pressed ? 0.88 : 1), text: .white)
    }
    if !enabled {
      c.text = v == .primary || v == .destructiveSolid ? c.text.opacity(0.75) : DS.color.textDisabled
      if v == .primary || v == .destructiveSolid { c.fill = c.fill.opacity(0.35) }
      if v == .secondary || v == .destructive { c.fill = DS.color.hover }
      if v == .outline { c.border = DS.color.border; c.fill = .clear }
    }
    return c
  }
}

/// ButtonStyle that renders the DS button anatomy. Usable on any `Button` (and on `Menu` labels via DSSelect).
struct DSButtonStyle: ButtonStyle {
  var variant: DSButtonVariant = .secondary
  var size: DSButtonSize = .md
  var fullWidth = false
  /// Looks disabled but stays hoverable so its tooltip can explain why (see DSButton.disabledReason).
  var softDisabled = false
  var iconOnly = false

  func makeBody(configuration: Configuration) -> some View {
    DSButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth,
                 softDisabled: softDisabled, iconOnly: iconOnly)
  }
}

private struct DSButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let variant: DSButtonVariant
  let size: DSButtonSize
  let fullWidth: Bool
  let softDisabled: Bool
  let iconOnly: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.dsForcedState) private var forced
  @State private var hovering = false

  var body: some View {
    let enabled = isEnabled && !softDisabled
    let state: DSInteraction = forced ?? (!enabled ? .idle : configuration.isPressed ? .pressed : isFocused ? .focused : hovering ? .hover : .idle)
    let c = DSButtonColors.resolve(variant, state: state, enabled: enabled)
    let r = size.height / 2
    configuration.label
      .font(size.font)
      .labelStyle(DSButtonLabelStyle(iconSize: size.iconSize))
      .lineLimit(1)
      .foregroundStyle(c.text)
      .padding(.horizontal, iconOnly ? 0 : size.hPad)
      .frame(width: iconOnly ? size.height : nil, height: size.height)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(c.fill, in: RoundedRectangle(cornerRadius: r, style: .continuous))
      .overlay {
        if let b = c.border { RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(b, lineWidth: 1) }
      }
      .contentShape(RoundedRectangle(cornerRadius: r, style: .continuous))
      .scaleEffect(state == .pressed && enabled ? 0.98 : 1)
      .dsFocusRing(state == .focused, radius: r)
      .onHover { hovering = $0 }
      .dsAnimation(DS.motion.hover, value: state)
  }
}

/// Icon + title with DS spacing.
struct DSButtonLabelStyle: LabelStyle {
  var iconSize: CGFloat = 13
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: iconSize, weight: .medium))
      configuration.title
    }
  }
}

/// The DS button. `disabledReason` non-nil = disabled, and the reason shows as a tooltip (decision #6/#7:
/// disabled controls say why). `isLoading` swaps the icon for a spinner and blocks the action.
struct DSButton: View {
  let title: String
  var icon: String? = nil
  var trailingIcon: String? = nil
  var variant: DSButtonVariant = .secondary
  var size: DSButtonSize = .md
  var fullWidth = false
  var isLoading = false
  var disabledReason: String? = nil
  var tooltip: String? = nil
  var shortcut: String? = nil
  let action: () -> Void

  init(_ title: String, icon: String? = nil, trailingIcon: String? = nil, variant: DSButtonVariant = .secondary,
       size: DSButtonSize = .md, fullWidth: Bool = false, isLoading: Bool = false, disabledReason: String? = nil,
       tooltip: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.trailingIcon = trailingIcon
    self.variant = variant
    self.size = size
    self.fullWidth = fullWidth
    self.isLoading = isLoading
    self.disabledReason = disabledReason
    self.tooltip = tooltip
    self.shortcut = shortcut
    self.action = action
  }

  var body: some View {
    let blocked = disabledReason != nil || isLoading
    Button {
      if !blocked { action() }
    } label: {
      HStack(spacing: 6) {
        if isLoading {
          DSSpinner(size: size.iconSize + 1, color: DSButtonColors.resolve(variant, state: .idle, enabled: true).text)
        } else if let icon {
          Image(systemName: icon).font(.system(size: size.iconSize, weight: .medium))
        }
        Text(title)
        if let trailingIcon {
          Image(systemName: trailingIcon).font(.system(size: size.iconSize - 1.5, weight: .semibold)).opacity(0.7)
        }
      }
    }
    .buttonStyle(DSButtonStyle(variant: variant, size: size, fullWidth: fullWidth, softDisabled: disabledReason != nil))
    .dsTooltip(disabledReason ?? tooltip, shortcut: disabledReason == nil ? shortcut : nil)
    .accessibilityLabel(title)
    .accessibilityAddTraits(blocked ? [] : .isButton)
  }
}

/// Square/round icon-only button. Tooltip is required (icon-only controls must explain themselves).
struct DSIconButton: View {
  let icon: String
  let tooltip: String
  var variant: DSButtonVariant = .ghost
  var size: DSButtonSize = .md
  var shortcut: String? = nil
  var disabledReason: String? = nil
  var isOn = false
  let action: () -> Void

  init(_ icon: String, tooltip: String, variant: DSButtonVariant = .ghost, size: DSButtonSize = .md, shortcut: String? = nil,
       disabledReason: String? = nil, isOn: Bool = false, action: @escaping () -> Void) {
    self.icon = icon
    self.tooltip = tooltip
    self.variant = variant
    self.size = size
    self.shortcut = shortcut
    self.disabledReason = disabledReason
    self.isOn = isOn
    self.action = action
  }

  var body: some View {
    Button {
      if disabledReason == nil { action() }
    } label: {
      Image(systemName: icon).font(.system(size: size.iconSize + 1, weight: .medium))
    }
    .buttonStyle(DSButtonStyle(variant: isOn ? .secondary : variant, size: size, softDisabled: disabledReason != nil, iconOnly: true))
    .dsTooltip(disabledReason ?? tooltip, shortcut: disabledReason == nil ? shortcut : nil)
    .accessibilityLabel(tooltip)
  }
}

/// Small activity indicator drawn with SwiftUI (renders in snapshots, tints with the label colour).
struct DSSpinner: View {
  var size: CGFloat = 14
  var color: Color = DS.color.textSecondary
  var lineWidth: CGFloat? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { ctx in
      let angle = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
      ZStack {
        Circle().stroke(color.opacity(0.2), lineWidth: lineWidth ?? max(1.5, size / 8))
        Circle().trim(from: 0, to: 0.28)
          .stroke(color, style: StrokeStyle(lineWidth: lineWidth ?? max(1.5, size / 8), lineCap: .round))
          .rotationEffect(.degrees(angle))
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Loading")
  }
}

/// Keycap hint ("⌘K", "↩").
struct DSKeyHint: View {
  let keys: String
  var inverted = false
  init(_ keys: String, inverted: Bool = false) {
    self.keys = keys
    self.inverted = inverted
  }

  var body: some View {
    Text(keys)
      .font(DS.type.micro)
      .foregroundStyle(inverted ? DS.color.inverseText.opacity(0.75) : DS.color.textSecondary)
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 18)
      .background(inverted ? DS.color.inverseText.opacity(0.12) : DS.color.surfaceSunken,
                  in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous).strokeBorder(inverted ? .clear : DS.color.border))
      .accessibilityLabel("Shortcut \(keys)")
  }
}
