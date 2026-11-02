import AppKit
import DJQCore
import SwiftUI

// DJ Queue design system, round 2 (design/DESIGN-SYSTEM.md). Values follow design/DESIGN-v2.md §2 exactly.
//
// One central source for colour, radius, spacing, type, elevation and motion. ChatGPT feel: flat white
// (dark #212121), one near-black capsule primary per screen, blue accent only for toggle-on / focus / link /
// checked, hairlines instead of boxes, shadows only in light mode.
//
// Access: `DS.color.text`, `DS.radius.lg`, `DS.space.md`, `DS.type.body`, `DS.elevation.e2`, `DS.motion.layout`.
// (`DS` itself is the round-1 enum in Design/Tokens.swift; these lowercase members extend it so both coexist
// until the screens are rebuilt.)

extension DS {
  static let color = DSColorTokens()
  static let radius = DSRadiusTokens()
  static let space = DSSpaceTokens()
  static let type = DSTypeTokens()
  static let elevation = DSElevationTokens()
  static let motion = DSMotionTokens()
  static let size = DSSizeTokens()
}

// MARK: - Colour

extension Color {
  /// Appearance-aware colour (resolved by the window/view appearance, so light + dark come from one token).
  init(light: NSColor, dark: NSColor) {
    self.init(nsColor: NSColor(name: nil) { ap in
      let dk = ap.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
      return dk == .darkAqua || dk == .vibrantDark ? dark : light
    })
  }

  init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
    self.init(light: NSColor(hex: light, alpha: lightAlpha), dark: NSColor(hex: dark, alpha: darkAlpha))
  }
}

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
              blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}

/// Semantic colours (DESIGN-v2 §2.1 name in brackets). Never use raw colours in screens; add a token instead.
struct DSColorTokens {
  // Backgrounds
  /// [bg.app] content background.
  let background = Color(light: 0xFFFFFF, dark: 0x212121)
  /// [bg.sidebar] sidebar, settings-modal nav.
  let sidebar = Color(light: 0xF9F9F9, dark: 0x181818)
  /// [bg.canvas] editor canvas behind the preview.
  let canvas = Color(light: 0xF4F4F4, dark: 0x171717)

  // Surfaces
  /// [surface.raised] cards, inspector, fields with composer look.
  let surface = Color(light: 0xFFFFFF, dark: 0x2F2F2F)
  /// [surface.raised] popovers, menus, toasts, bulk bar, dialogs (same value as `surface`).
  let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x2F2F2F)
  /// [surface.sunken] input fill, segmented track, empty-state icon tile.
  let surfaceSunken = Color(light: 0xF3F3F3, dark: 0x2A2A2A)
  /// [fill.hover] row hover, ghost button hover.
  let hover = Color(light: 0xECECEC, dark: 0x2F2F2F)
  /// [fill.selected] selected sidebar row, selected segment, selected card fill.
  let selected = Color(light: 0xE8E8E8, dark: 0x383838)
  /// Secondary control fill (= surface.sunken), its hover (= fill.hover) and pressed (= fill.selected).
  let fill = Color(light: 0xF3F3F3, dark: 0x2A2A2A)
  let fillHover = Color(light: 0xECECEC, dark: 0x383838)
  let fillPressed = Color(light: 0xE3E3E3, dark: 0x424242)
  /// Tooltip bubble (inverse).
  let inverseSurface = Color(light: 0x0D0D0D, dark: 0xECECEC)
  let inverseText = Color(light: 0xFFFFFF, dark: 0x0D0D0D)
  /// [overlay.scrim] behind modals and sheets.
  let scrim = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.40, darkAlpha: 0.60)

  // Lines
  /// [border.subtle] hairlines, card border.
  let border = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
  /// [border.strong] inputs, outlined buttons, chips.
  let borderStrong = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.15)
  /// List separators (= border.subtle).
  let separator = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

  // Text
  /// [text.primary]
  let text = Color(light: 0x0D0D0D, dark: 0xECECEC)
  /// [text.secondary]
  let textSecondary = Color(light: 0x5D5D5D, dark: 0xB4B4B4)
  /// [text.tertiary] placeholders, counts.
  let textTertiary = Color(light: 0x8F8F8F, dark: 0x8F8F8F)
  /// Disabled labels (= text.tertiary, DESIGN-v2 uses tertiary for disabled).
  let textDisabled = Color(light: 0x8F8F8F, dark: 0x8F8F8F, lightAlpha: 0.8, darkAlpha: 0.8)

  // Primary — the one filled capsule per screen.
  /// [primary.bg]
  let primary = Color(light: 0x0D0D0D, dark: 0xECECEC)
  let primaryHover = Color(light: 0x2F2F2F, dark: 0xD4D4D4)
  /// [primary.fg]
  let primaryText = Color(light: 0xFFFFFF, dark: 0x0D0D0D)

  /// [accent] Only: toggle-on, focus ring, link, checked checkbox.
  let accent = Color(light: 0x0285FF, dark: 0x3B9EFF)
  let accentSoft = Color(light: 0x0285FF, dark: 0x3B9EFF, lightAlpha: 0.10, darkAlpha: 0.16)
  let focusRing = Color(light: 0x0285FF, dark: 0x3B9EFF, lightAlpha: 0.45, darkAlpha: 0.55)

  // Status
  /// [status.success] posted, healthy.
  let success = Color(light: 0x10A37F, dark: 0x19C37D)
  /// [status.warning] missing, late, low runway.
  let warning = Color(light: 0xD97706, dark: 0xF5A524)
  /// [status.danger] failed, copyright, missing file.
  let danger = Color(light: 0xE02E2A, dark: 0xFF5B57)
  /// [status.info] planned, rendering.
  let info = Color(light: 0x0285FF, dark: 0x3B9EFF)

  // [tint.*] 10 % (light) / 16 % (dark) of the status colour — chip and attention-card backgrounds.
  let successTint = Color(light: 0x10A37F, dark: 0x19C37D, lightAlpha: 0.10, darkAlpha: 0.16)
  let warningTint = Color(light: 0xD97706, dark: 0xF5A524, lightAlpha: 0.10, darkAlpha: 0.16)
  let dangerTint = Color(light: 0xE02E2A, dark: 0xFF5B57, lightAlpha: 0.10, darkAlpha: 0.16)
  let infoTint = Color(light: 0x0285FF, dark: 0x3B9EFF, lightAlpha: 0.10, darkAlpha: 0.16)

  /// Tint background for a tone.
  func tint(_ t: DSTone) -> Color {
    switch t {
    case .neutral: surfaceSunken
    case .success: successTint
    case .warning: warningTint
    case .danger: dangerTint
    case .info: infoTint
    case .accent: accentSoft
    }
  }

  // Platform colours are deliberately absent (DESIGN-v2 §2.1): platforms are a drawn generic glyph + name.
}

/// Tone shared by badges, chips, toasts, dots, attention cards.
enum DSTone: String, CaseIterable, Sendable {
  case neutral, success, warning, danger, info, accent

  var color: Color {
    switch self {
    case .neutral: DS.color.textSecondary
    case .success: DS.color.success
    case .warning: DS.color.warning
    case .danger: DS.color.danger
    case .info: DS.color.info
    case .accent: DS.color.accent
    }
  }

  var symbol: String {
    switch self {
    case .neutral: "info.circle"
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .danger: "exclamationmark.octagon.fill"
    case .info: "info.circle.fill"
    case .accent: "sparkle"
    }
  }
}

// MARK: - Radius, spacing, sizes

/// DESIGN-v2 §2.2.
struct DSRadiusTokens {
  /// [r.xs] list thumbnails, duration badge, keycaps.
  let xs: CGFloat = 6
  /// [r.sm] rows, menu items, inputs, tile thumbnails, segmented segment, sidebar rows.
  let sm: CGFloat = 10
  /// [r.md] grid tiles, Week day cards, toasts.
  let md: CGFloat = 12
  /// [r.lg] horizontal clip cards, inspector, popovers, modals, attention cards, cards.
  let lg: CGFloat = 16
  /// [r.xl] Score large player, phone mock screen.
  let xl: CGFloat = 20
  /// [r.full] buttons, chips, segmented track, search, bulk bar, pills. Use `Capsule()`.
  let pill: CGFloat = 999
}

/// DESIGN-v2 §2.3 (4-pt grid: 2 · 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48).
struct DSSpaceTokens {
  let hair: CGFloat = 2
  let xxs: CGFloat = 4
  let xs: CGFloat = 8
  /// Card padding.
  let sm: CGFloat = 12
  /// Grid gap, inspector section padding.
  let md: CGFloat = 16
  let lg: CGFloat = 20
  /// Screen gutter (< 1100 pt content).
  let xl: CGFloat = 24
  /// Section gap, gutter (≥ 1100 pt content).
  let xxl: CGFloat = 32
  let xxxl: CGFloat = 48
}

struct DSSizeTokens {
  /// Capsule control heights (shadcn sm h-8 / default h-9 / lg h-10, macOS-scaled).
  let controlSm: CGFloat = 28
  let controlMd: CGFloat = 34
  let controlLg: CGFloat = 40
  let sidebarWidth: CGFloat = 260
  let sidebarItem: CGFloat = 36
  let toolbar: CGFloat = 52
  /// List-mode row.
  let listRow: CGFloat = 52
  /// Cards-mode clip card.
  let clipCard: CGFloat = 132
  let inspectorWidth: CGFloat = 340
  /// Centred reading column for text-heavy screens.
  let readingColumn: CGFloat = 880
  let bulkBar: CGFloat = 48
}

// MARK: - Type (DESIGN-v2 §2.4; SF Pro, tabular figures for numbers)

struct DSTypeTokens {
  /// 28/34 regular — empty-state hero, Score number field.
  let display = Font.system(size: 28, weight: .regular)
  /// 20/26 semibold — screen title.
  let title = Font.system(size: 20, weight: .semibold)
  /// 15/20 semibold — card title, section header.
  let headline = Font.system(size: 15, weight: .semibold)
  /// 14/20 — default text, fields.
  let body = Font.system(size: 14)
  let bodyMedium = Font.system(size: 14, weight: .medium)
  /// 13/18 — meta lines, menu items, sidebar rows, button labels.
  let callout = Font.system(size: 13)
  let calloutMedium = Font.system(size: 13, weight: .medium)
  let calloutSemibold = Font.system(size: 13, weight: .semibold)
  /// 12/16 — counts, chip text, helper text.
  let caption = Font.system(size: 12)
  let captionMedium = Font.system(size: 12, weight: .medium)
  /// 11/14 medium — badges, duration, eyebrow (sentence case, no all-caps).
  let micro = Font.system(size: 11, weight: .medium)
  /// 22/26 semibold rounded tabular — score on cards.
  let score = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
  /// 12/16 SF Mono — ids, durations in tables.
  let mono = Font.system(size: 12, design: .monospaced)
  /// Big stat numbers (DSStat): rounded tabular, between display and score.
  let stat = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
}

// MARK: - Elevation (DESIGN-v2 §2.5) — shadows only in light mode; dark uses border + lighter surface.

struct DSShadow {
  let color: Color
  let radius: CGFloat
  let y: CGFloat
  /// e3 also dims what's behind with `overlay.scrim` (the presenter draws the scrim).
  var scrim = false
}

struct DSElevationTokens {
  /// e0: none (rows, page).
  let e0 = DSShadow(color: .clear, radius: 0, y: 0)
  /// e1: border.subtle + 0 1 2 #0000000A (cards, tiles, inspector).
  let e1 = DSShadow(color: Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0), radius: 2, y: 1)
  /// e2: border.subtle + 0 8 24 #0000001F (popovers, menus, bulk bar, toasts).
  let e2 = DSShadow(color: Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0), radius: 24, y: 8)
  /// e3: 0 24 64 #0000002E + scrim (settings modal, confirmation sheets).
  let e3 = DSShadow(color: Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0), radius: 64, y: 24, scrim: true)

  /// Aliases used by components.
  var none: DSShadow { e0 }
  var soft: DSShadow { e1 }
  var floating: DSShadow { e2 }
  var modal: DSShadow { e3 }
}

extension View {
  /// Applies an elevation shadow (SwiftUI radius ≈ CSS blur / 2).
  func dsElevation(_ s: DSShadow) -> some View {
    shadow(color: s.color, radius: s.radius / 2, y: s.y)
  }
}

// MARK: - Motion (DESIGN-v2 §2.6)

struct DSMotionTokens {
  let fast: Double = 0.12
  let base: Double = 0.15
  let slow: Double = 0.20
  /// Hover/press: 120 ms ease-out (background + opacity only).
  var hover: Animation { .easeOut(duration: fast) }
  /// Layout: reorder, card expand, bulk bar in/out, selection, toggles.
  var layout: Animation { .spring(response: 0.30, dampingFraction: 0.85) }
  /// Popovers: 150 ms (scale from 0.97 + fade).
  var popover: Animation { .easeOut(duration: base) }
  /// Fades: autoplay proxy over poster, Score save & next.
  var fade: Animation { .easeOut(duration: slow) }
  /// Aliases.
  var snappy: Animation { layout }
  var gentle: Animation { layout }

  /// Reduce Motion: every movement becomes an opacity fade.
  func respecting(_ a: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: slow) : a }
}

private struct DSAnimationModifier<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation
  let value: V
  func body(content: Content) -> some View {
    content.animation(DS.motion.respecting(animation, reduceMotion: reduceMotion), value: value)
  }
}

extension View {
  /// `.animation` that becomes a plain fade under Reduce Motion. Pair movement with `dsMoveTransition`.
  func dsAnimation<V: Equatable>(_ a: Animation, value: V) -> some View {
    modifier(DSAnimationModifier(animation: a, value: value))
  }
}

extension AnyTransition {
  /// Slide `edge` by `distance` + fade; opacity only when Reduce Motion is on.
  @MainActor static func dsMove(_ edge: Edge, distance: CGFloat = 12) -> AnyTransition {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
    let o: CGSize = switch edge {
    case .bottom: CGSize(width: 0, height: distance)
    case .top: CGSize(width: 0, height: -distance)
    case .leading: CGSize(width: -distance, height: 0)
    case .trailing: CGSize(width: distance, height: 0)
    }
    return .offset(o).combined(with: .opacity)
  }

  /// Popover-style: scale from 0.97 + fade.
  @MainActor static var dsPop: AnyTransition {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity)
  }
}

/// `withAnimation` that respects Reduce Motion.
@MainActor
func dsWithAnimation<R>(_ a: Animation = DS.motion.layout, _ body: () throws -> R) rethrows -> R {
  try withAnimation(DS.motion.respecting(a, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), body)
}

// MARK: - Interaction state (live or forced for the gallery)

/// Visual interaction state. Components compute it from hover/press/focus; the gallery forces one via
/// `.dsForcedState(_:)` so every state can be rendered statically.
enum DSInteraction: String, CaseIterable, Sendable {
  case idle, hover, pressed, focused
}

private struct DSForcedStateKey: EnvironmentKey {
  static let defaultValue: DSInteraction? = nil
}

extension EnvironmentValues {
  var dsForcedState: DSInteraction? {
    get { self[DSForcedStateKey.self] }
    set { self[DSForcedStateKey.self] = newValue }
  }
}

extension View {
  /// Gallery/snapshot only: render DS components as if hovered/pressed/focused.
  func dsForcedState(_ s: DSInteraction?) -> some View { environment(\.dsForcedState, s) }
}

// MARK: - Shared modifiers

extension View {
  /// shadcn `ring-2 ring-ring ring-offset-2`: accent halo outside the shape (`radius` ≥ 900 = capsule).
  func dsFocusRing(_ on: Bool, radius: CGFloat) -> some View {
    overlay {
      Group {
        if radius >= 900 { Capsule().strokeBorder(DS.color.focusRing, lineWidth: 3) }
        else { RoundedRectangle(cornerRadius: radius + 3, style: .continuous).strokeBorder(DS.color.focusRing, lineWidth: 3) }
      }
      .padding(-3)
      .opacity(on ? 1 : 0)
      .allowsHitTesting(false)
    }
  }

  /// Hairline border in the continuous rounded shape.
  func dsBorder(_ color: Color = DS.color.border, radius: CGFloat, width: CGFloat = 1) -> some View {
    overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width).allowsHitTesting(false))
  }

  /// Rounded background + optional hairline in one call.
  func dsSurface(_ fill: Color = DS.color.surface, radius: CGFloat = DS.radius.lg, border: Color? = DS.color.border) -> some View {
    background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        if let border { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
      }
  }
}
