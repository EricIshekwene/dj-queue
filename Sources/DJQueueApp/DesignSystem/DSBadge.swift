import AppKit
import DJQCore
import SwiftUI

// MARK: - Badge / Pill

/// shadcn Badge variants: soft tone (default/destructive/…), outline, solid. Capsule, `micro` text.
enum DSBadgeStyle: Hashable, Sendable {
  /// Tone tint background + tone text (status: Ready, Needs edit, Failed…).
  case soft(DSTone)
  /// border.strong outline, secondary text (metadata: kind, "Long-form").
  case outline
  /// Solid near-black (counts, "New", "Due now").
  case solid
}

enum DSBadgeSize: Sendable { case sm, md }

/// Capsule label. Status is a chip or a dot, never a sentence (DESIGN-v2 §1.7).
struct DSBadge: View {
  let text: String
  var style: DSBadgeStyle = .soft(.neutral)
  var icon: String? = nil
  var size: DSBadgeSize = .md
  /// Optional hover explanation (what the status means or what to do about it).
  var help: String? = nil

  init(_ text: String, style: DSBadgeStyle = .soft(.neutral), icon: String? = nil, size: DSBadgeSize = .md, help: String? = nil) {
    self.text = text
    self.style = style
    self.icon = icon
    self.size = size
    self.help = help
  }

  var body: some View {
    HStack(spacing: 4) {
      if let icon { Image(systemName: icon).font(.system(size: size == .sm ? 8.5 : 9.5, weight: .bold)) }
      Text(text).lineLimit(1)
    }
    .font(size == .sm ? Font.system(size: 10.5, weight: .medium) : DS.type.micro)
    .foregroundStyle(fg)
    .padding(.horizontal, size == .sm ? 6 : 8)
    .frame(height: size == .sm ? 18 : 22)
    .background(bg, in: Capsule())
    .overlay { if case .outline = style { Capsule().strokeBorder(DS.color.borderStrong) } }
    .fixedSize()
    .accessibilityElement(children: .combine)
    .dsTooltip(help)
  }

  private var fg: Color {
    switch style {
    case .soft(.neutral): DS.color.textSecondary
    case .soft(let t): t.color
    case .outline: DS.color.textSecondary
    case .solid: DS.color.primaryText
    }
  }

  private var bg: Color {
    switch style {
    case .soft(let t): DS.color.tint(t)
    case .outline: .clear
    case .solid: DS.color.primary
    }
  }
}

/// Same component; "pill" is the name screens used in round 1.
typealias DSPill = DSBadge

/// Count shown at the right of sidebar rows and tabs. Plain = tertiary number; attention = near-black capsule
/// (Today: something due now); danger = red capsule (Posts: problems). Zero shows nothing.
struct DSCount: View {
  enum Style: Sendable { case plain, attention, danger }
  let count: Int
  var style: Style = .plain

  var body: some View {
    if count > 0 {
      let t = Text("\(count)").font(DS.type.caption.monospacedDigit())
      switch style {
      case .plain:
        t.foregroundStyle(DS.color.textTertiary)
      case .attention, .danger:
        t.fontWeight(.semibold)
          .foregroundStyle(style == .danger ? Color.white : DS.color.primaryText)
          .padding(.horizontal, 6)
          .frame(minWidth: 20, minHeight: 18)
          .background(style == .danger ? DS.color.danger : DS.color.primary, in: Capsule())
          .fixedSize()
      }
    }
  }
}

// MARK: - Status dot

struct DSStatusDot: View {
  var tone: DSTone = .neutral
  var size: CGFloat = 8
  /// Hollow = "not planned / off".
  var hollow = false
  /// Gentle pulse for live states (engine running, posting). Off under Reduce Motion.
  var pulse = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var on = false

  var body: some View {
    ZStack {
      if pulse && !reduceMotion {
        Circle().fill(tone.color.opacity(0.35)).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 1)
      }
      if hollow { Circle().strokeBorder(tone.color, lineWidth: 1.3) } else { Circle().fill(tone.color) }
    }
    .frame(width: size, height: size)
    .onAppear {
      guard pulse, !reduceMotion else { return }
      withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Platform icon

/// Where a platform stands for one clip. Show icons only when the clip is planned or posted (DESIGN-v2 §4).
enum DSPlatformState: String, CaseIterable, Sendable {
  case planned, due, posted, failed, skipped, off

  var label: String {
    switch self {
    case .off: "Not planned"
    case .planned: "Planned"
    case .due: "Due now"
    case .posted: "Posted"
    case .failed: "Needs attention"
    case .skipped: "Skipped"
    }
  }

  /// The dot at the glyph's corner (nil = none).
  var dot: Color? {
    switch self {
    case .posted: DS.color.success
    case .failed: DS.color.danger
    case .due: DS.color.primary
    default: nil
    }
  }

  var tone: DSTone {
    switch self {
    case .posted: .success
    case .failed: .danger
    case .due: .neutral
    default: .neutral
    }
  }
}

extension Platform {
  /// Generic SF Symbol stand-in (no brand logos or colours in a public repo).
  var dsSymbol: String {
    switch self {
    case .tiktok: "music.note"
    case .instagram: "camera"
    case .facebook: "person.2"
    case .youtube: "play.rectangle"
    case .threads: "at"
    case .x: "xmark"
    }
  }
}

/// Generic platform glyph in a soft circle + state dot. Planned = outlined glyph, posted = glyph + green dot,
/// failed = red dot, due = near-black dot, skipped = dashed + dim. `state == nil` = identity only (glyph + name).
struct DSPlatformIcon: View {
  let platform: Platform
  var state: DSPlatformState? = nil
  var size: CGFloat = 22
  var showsLabel = false

  var body: some View {
    HStack(spacing: 6) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: platform.dsSymbol)
          .font(.system(size: size * 0.46, weight: .medium))
          .foregroundStyle(glyphColor)
          .frame(width: size, height: size)
          .background(bg, in: Circle())
          .overlay {
            switch state {
            case .planned?, nil:
              Circle().strokeBorder(DS.color.borderStrong, lineWidth: 1)
            case .skipped?:
              Circle().strokeBorder(DS.color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            default:
              EmptyView()
            }
          }
        if let dot = state?.dot {
          Circle().fill(dot)
            .frame(width: size * 0.36, height: size * 0.36)
            .overlay(Circle().strokeBorder(DS.color.background, lineWidth: 1.5))
            .offset(x: size * 0.06, y: size * 0.06)
        }
      }
      if showsLabel {
        Text(platform.displayName).font(DS.type.callout).foregroundStyle(DS.color.text)
      }
    }
    .opacity(state == .skipped || state == .off ? 0.55 : 1)
    .dsTooltip(showsLabel ? nil : "\(platform.displayName)\(state.map { " · \($0.label)" } ?? "")")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(platform.displayName)\(state.map { ", \($0.label)" } ?? "")")
  }

  private var glyphColor: Color {
    switch state {
    case .failed?: DS.color.danger
    case .posted?, .due?: DS.color.text
    case .planned?, nil: DS.color.textSecondary
    case .skipped?, .off?: DS.color.textTertiary
    }
  }

  private var bg: Color {
    switch state {
    case .posted?, .due?: DS.color.surfaceSunken
    case .failed?: DS.color.dangerTint
    default: .clear
    }
  }
}

/// A row of platform icons (only the platforms passed in — screens decide relevance).
struct DSPlatformRow: View {
  let items: [(Platform, DSPlatformState)]
  var size: CGFloat = 22
  var body: some View {
    HStack(spacing: 5) {
      ForEach(items, id: \.0) { p, s in DSPlatformIcon(platform: p, state: s, size: size) }
    }
  }
}

// MARK: - Avatar

struct DSAvatar: View {
  let name: String
  var image: NSImage? = nil
  var size: CGFloat = 28

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Text(initials)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(DS.color.primaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DS.color.primary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(DS.color.border))
    .accessibilityLabel(name)
  }

  private var initials: String {
    name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
  }
}

// MARK: - Progress

/// Linear progress (capsule, 4 pt by default — Score strip). `value == nil` = indeterminate.
struct DSProgress: View {
  var value: Double?
  var tone: DSTone? = nil
  var height: CGFloat = 4
  var label: String? = nil
  var valueLabel: String? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if label != nil || valueLabel != nil {
        HStack {
          if let label { Text(label).font(DS.type.caption).foregroundStyle(DS.color.textSecondary) }
          Spacer()
          if let valueLabel { Text(valueLabel).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.text) }
        }
      }
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(DS.color.surfaceSunken)
          if let value {
            Capsule().fill(tone?.color ?? DS.color.primary).frame(width: max(height, g.size.width * min(1, max(0, value))))
          } else {
            TimelineView(.animation(paused: reduceMotion)) { ctx in
              let t = reduceMotion ? 0.3 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
              Capsule().fill(tone?.color ?? DS.color.primary)
                .frame(width: g.size.width * 0.3)
                .offset(x: (g.size.width * 1.3) * t - g.size.width * 0.3)
            }
            .clipShape(Capsule())
          }
        }
      }
      .frame(height: height)
    }
    .accessibilityElement()
    .accessibilityLabel(label ?? "Progress")
    .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
  }
}

/// Circular progress ring with a centred value (Today "3 of 6 posted").
struct DSProgressRing: View {
  var value: Double
  var size: CGFloat = 36
  var lineWidth: CGFloat = 4
  var tone: DSTone? = nil
  var centerText: String? = nil

  var body: some View {
    ZStack {
      Circle().stroke(DS.color.surfaceSunken, lineWidth: lineWidth)
      Circle().trim(from: 0, to: min(1, max(0, value)))
        .stroke(tone?.color ?? DS.color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if let centerText { Text(centerText).font(.system(size: size * 0.28, weight: .semibold).monospacedDigit()).foregroundStyle(DS.color.text) }
    }
    .frame(width: size, height: size)
  }
}

// MARK: - Skeleton

/// Loading placeholder with a soft pulse (static under Reduce Motion).
struct DSSkeleton: View {
  var width: CGFloat? = nil
  var height: CGFloat = 12
  var radius: CGFloat = DS.radius.xs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
      let t = reduceMotion ? 0 : (sin(ctx.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(DS.color.surfaceSunken)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.color.hover).opacity(t))
    }
    .frame(width: width, height: height)
    .accessibilityLabel("Loading")
  }
}

// MARK: - Separator

struct DSSeparator: View {
  var vertical = false
  var inset: CGFloat = 0
  var body: some View {
    Rectangle().fill(DS.color.separator)
      .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
      .padding(vertical ? .vertical : .horizontal, inset)
  }
}
