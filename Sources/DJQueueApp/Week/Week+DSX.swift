import DJQCore
import SwiftUI

// Planning leaf DS extensions (Week, Today, menu bar). Built only from DS tokens/components; the design system
// itself stays untouched.

extension Platform {
  /// Platform name for tight places (Week slot chips, menu bar rows): "YouTube" instead of "YouTube Shorts".
  /// Still a name, never a code.
  var dsxCompactName: String { self == .youtube ? "YouTube" : displayName }
}

extension DSTypeTokens {
  /// 10.5 medium tabular — dense chips in 7-column grids (same size as DSBadge `.sm`).
  var microCompact: Font { .system(size: 10.5, weight: .medium).monospacedDigit() }
}

/// Where a post stands, as one status chip/dot (Week slot chips, Today rows, menu bar).
enum DSXPostStatus: Equatable {
  case draft, planned, rendering(Double?), ready, dueNow, late(String), posted, failed, copyright, skipped, resolved(String)

  var text: String {
    switch self {
    case .draft: "Draft"
    case .planned: "Planned"
    case .rendering(let f): f.map { "Rendering \(Int($0 * 100))%" } ?? "Rendering"
    case .ready: "Rendered"
    case .dueNow: "Due now"
    case .late(let t): "Late \(t)"
    case .posted: "Posted"
    case .failed: "Failed"
    case .copyright: "©"
    case .skipped: "Skipped"
    case .resolved(let t): t
    }
  }

  /// Badge style (Today rows): due now is the near-black solid pill; problems danger; late warning.
  var badgeStyle: DSBadgeStyle {
    switch self {
    case .draft, .planned, .ready: .outline
    case .rendering: .soft(.info)
    case .dueNow: .solid
    case .late: .soft(.warning)
    case .posted: .soft(.success)
    case .failed, .copyright: .soft(.danger)
    case .skipped, .resolved: .soft(.neutral)
    }
  }

  var badgeIcon: String? {
    switch self {
    case .posted: "checkmark"
    case .copyright: "c.circle"
    case .failed: "exclamationmark"
    default: nil
    }
  }

  /// Dot colour (Week slot chips, menu bar). nil = hollow (draft / skipped).
  var dot: Color? {
    switch self {
    case .draft, .skipped, .resolved: nil
    case .planned, .rendering, .ready: DS.color.info
    case .dueNow: DS.color.primary
    case .late: DS.color.warning
    case .posted: DS.color.success
    case .failed, .copyright: DS.color.danger
    }
  }

  var isProblem: Bool { problemTone != nil }

  /// Tint for rows/chips that need Eric: late = warning, failed/© = danger.
  var problemTone: DSTone? {
    switch self {
    case .late: .warning
    case .failed, .copyright: .danger
    default: nil
    }
  }
}

/// Week slot chip (DESIGN-v2 §6.4): generic glyph · "TikTok 7:00 PM" · state dot. Skipped / paused = struck through.
struct DSXSlotChip: View {
  let platform: Platform
  let time: String
  let status: DSXPostStatus
  var paused = false
  /// A post exists, so right-click opens the post actions (said in the tooltip).
  var hasActions = false

  var body: some View {
    let struck = status == .skipped || paused
    HStack(spacing: 3) {
      Image(systemName: platform.dsSymbol)
        .font(.system(size: 9, weight: .medium))
        .frame(width: 11)
        .foregroundStyle(DS.color.textSecondary)
      Text("\(platform.dsxCompactName) \(time)")
        .font(DS.type.microCompact)
        .foregroundStyle(status.isProblem ? (status.dot ?? DS.color.text) : DS.color.text)
        .strikethrough(struck)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
      Spacer(minLength: 2)
      if status == .copyright {
        Image(systemName: "c.circle.fill").font(.system(size: 9)).foregroundStyle(DS.color.danger)
      } else if let dot = status.dot {
        Circle().fill(dot).frame(width: 6, height: 6)
      } else {
        Circle().strokeBorder(DS.color.textTertiary, lineWidth: 1).frame(width: 6, height: 6)
      }
    }
    .opacity(struck ? 0.55 : 1)
    .padding(.horizontal, 4)
    .frame(height: 20)
    .background(status.problemTone.map { DS.color.tint($0) } ?? .clear,
                in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
    .contentShape(Rectangle())
    .dsTooltip("\(platform.displayName) · \(time) · \(status.text)\(paused ? " · platform paused" : "")\(hasActions ? " · right-click for actions" : "")")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(platform.displayName), \(time), \(status.text)\(paused ? ", paused" : "")")
  }
}

/// Native `Menu` behind a DS ghost icon button (⋯). Context menus and menus stay native (DESIGN-v2 §1.8).
struct DSXMenuButton<Items: View>: View {
  var icon = "ellipsis"
  let tooltip: String
  var size: DSButtonSize = .md
  var variant: DSButtonVariant = .ghost
  @ViewBuilder var items: Items

  var body: some View {
    Menu {
      items
    } label: {
      Image(systemName: icon).font(.system(size: size.iconSize + 1, weight: .medium))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(DSButtonStyle(variant: variant, size: size, iconOnly: true))
    .fixedSize()
    .dsTooltip(tooltip)
    .accessibilityLabel(tooltip)
  }
}

/// Native `Menu` behind a labelled DS button ("Re-upload anyway ▾").
struct DSXMenuLabelButton<Items: View>: View {
  let title: String
  var icon: String? = nil
  var variant: DSButtonVariant = .ghost
  var size: DSButtonSize = .sm
  var tooltip: String? = nil
  /// Why the menu can't open (shown under the label in the tooltip); nil = enabled.
  var disabledReason: String? = nil
  @ViewBuilder var items: Items

  var body: some View {
    Menu {
      items
    } label: {
      HStack(spacing: 5) {
        if let icon { Image(systemName: icon) }
        Text(title)
        Image(systemName: "chevron.down").font(.system(size: size.iconSize - 2, weight: .semibold)).opacity(0.7)
      }
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(DSButtonStyle(variant: variant, size: size))
    .fixedSize()
    .disabled(disabledReason != nil)
    .dsTooltip(tooltip, disabledReason: disabledReason)
  }
}

/// Diagonal hatch (Mac off / asleep periods).
struct DSXHatch: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    let step: CGFloat = 4
    var x = r.minX - r.height
    while x < r.maxX {
      p.move(to: CGPoint(x: x, y: r.maxY))
      p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
      p.addLine(to: CGPoint(x: x + r.height + 1.5, y: r.minY))
      p.addLine(to: CGPoint(x: x + 1.5, y: r.maxY))
      p.closeSubpath()
      x += step
    }
    return p
  }
}

/// Thin 24 h bar under a past/today day header: success = Mac awake, hatched = off or asleep.
struct AwakeStrip: View {
  @Bindable var model: AppModel
  let day: String
  let awake: [DateInterval]

  var body: some View {
    GeometryReader { g in
      let start = model.dm.date(day)
      let end = min(model.dm.date(model.dm.addDays(day, 1)), model.now)
      let total = 86400.0
      ZStack(alignment: .leading) {
        Capsule().fill(DS.color.surfaceSunken)
        DSXHatch().fill(DS.color.textTertiary.opacity(0.55))
          .frame(width: g.size.width * max(0, end.timeIntervalSince(start)) / total)
        ForEach(Array(awake.enumerated()), id: \.offset) { _, iv in
          let a = max(iv.start, start), b = min(iv.end, end)
          if b > a {
            Rectangle().fill(DS.color.success.opacity(0.75))
              .frame(width: max(1, g.size.width * b.timeIntervalSince(a) / total))
              .offset(x: g.size.width * a.timeIntervalSince(start) / total)
          }
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: 4)
    .dsTooltip("Mac awake (green) · off or asleep (hatched)")
    .accessibilityLabel("Mac awake periods")
  }
}

/// Small 9:16 poster with a rounded corner (Today rows, backlog, menu bar).
struct DSXThumb: View {
  @Bindable var model: AppModel
  let video: Video?
  var width: CGFloat = 30

  var body: some View {
    let h = width * 16 / 9
    Group {
      if let v = video, let img = model.poster(v) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        DSPosterPlaceholder()
      }
    }
    .frame(width: width, height: h)
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous).strokeBorder(DS.color.border))
    .onAppear { if let video { model.requestPoster(video) } }
  }
}
