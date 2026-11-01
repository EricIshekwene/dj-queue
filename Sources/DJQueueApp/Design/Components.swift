import AppKit
import DJQCore
import SwiftUI

/// Capsule status label: 11 pt semibold on a tinted background (DESIGN: "status is a shape, not a sentence").
struct StatusPill: View {
  let text: String
  var tint: Color = .secondary
  var icon: String? = nil
  var loud = false

  var body: some View {
    HStack(spacing: 3) {
      if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
      Text(text).lineLimit(1)
    }
    .font(DS.Font.secondaryStrong)
    .foregroundStyle(loud ? Color.white : tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(loud ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.15)), in: Capsule())
    .fixedSize()
  }
}

extension StatusPill {
  init(post: PlatformPost, now: Date) {
    var text = post.state.displayName
    var tint = post.state.tint
    if post.state == .due || post.state == .overdue, post.scheduledAt < now {
      let h = Int(now.timeIntervalSince(post.scheduledAt) / 3600)
      if h >= 1 { text = "Late \(h)h"; tint = DS.Status.warn } else if post.state == .due { text = "Due now" }
    }
    if post.state == .rendered && post.scheduledAt > now { text = "Ready" }
    self.init(text: text, tint: tint, icon: post.state.symbol)
  }

  init(video: Video) {
    self.init(text: video.state.displayName, tint: video.state.tint)
  }
}

/// 8 pt dot. Filled = has state, outline = not planned.
struct StateDot: View {
  var tint: Color
  var filled = true
  var size: CGFloat = 8

  var body: some View {
    Group {
      if filled { Circle().fill(tint) } else { Circle().strokeBorder(tint, lineWidth: 1.2) }
    }
    .frame(width: size, height: size)
  }
}

/// Monochrome letter mark (no brand logos), tinted by state.
struct PlatformGlyph: View {
  let platform: Platform
  var tint: Color = .primary
  var size: CGFloat = 18

  var body: some View {
    Text(platform.shortName)
      .font(.system(size: size * 0.46, weight: .heavy, design: .rounded))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
      .help(platform.displayName)
      .accessibilityLabel(platform.displayName)
  }
}

/// Big runway number with a short label (APP.TB.a).
struct RunwayNumber: View {
  let days: Int
  let label: String
  var emphasized = true
  var tint: Color = .primary
  var big = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\(days)d")
        .font(big ? DS.Font.runway : DS.Font.runwaySmall)
        .foregroundStyle(emphasized ? tint : .secondary)
      Text(label).font(DS.Font.secondary).foregroundStyle(.secondary)
    }
  }
}

/// SF Symbol 32 pt, one line, one button (EMPTY ref).
struct EmptyState: View {
  let symbol: String
  let title: String
  var subtitle: String? = nil
  var buttonTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
      Text(title).font(DS.Font.title)
      if let subtitle { Text(subtitle).font(DS.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }
      if let buttonTitle, let action {
        Button(buttonTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Full-width 40 pt bar under the toolbar (APP.ERR red, APP.WARN amber, paused amber).
struct Banner: View {
  enum Kind { case error, warning, paused }
  let kind: Kind
  let text: String
  var detail: String? = nil
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  var onDismiss: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 14, weight: .semibold))
      Text(text).font(DS.Font.bodyStrong).lineLimit(1)
      if let detail { Text(detail).font(DS.Font.body).lineLimit(1).opacity(0.85) }
      Spacer(minLength: 8)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(BannerButtonStyle(kind: kind))
      }
      if let onDismiss {
        Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
          .buttonStyle(.plain).help("Hide for 24 hours")
      }
    }
    .foregroundStyle(kind == .error ? Color.white : Color.primary)
    .padding(.horizontal, DS.Space.l)
    .frame(height: 40)
    .background(background)
    .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: kind == .error ? 0 : 1) }
  }

  private var icon: String {
    switch kind {
    case .error: "exclamationmark.octagon.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    }
  }

  @ViewBuilder private var background: some View {
    switch kind {
    case .error: Color.red
    case .warning, .paused: Color.orange.opacity(0.18)
    }
  }
}

struct BannerButtonStyle: ButtonStyle {
  let kind: Banner.Kind
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.bodyStrong)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .foregroundStyle(kind == .error ? Color.red : Color.primary)
      .background(kind == .error ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.orange.opacity(0.25)),
                  in: RoundedRectangle(cornerRadius: DS.Radius.control))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// Small uppercase section label.
struct Eyebrow: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text.uppercased()).font(DS.Font.eyebrow).foregroundStyle(.secondary).tracking(0.4)
  }
}

/// Key-value property row (Linear inspector, Stripe details).
struct PropertyRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content
  init(_ label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
      Text(label).font(DS.Font.body).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
      content.font(DS.Font.body).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 24)
  }
}

/// Rounded card used for grouped content (Health, Posts error cards).
struct Card<Content: View>: View {
  var padding: CGFloat = DS.Space.l
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.card))
      .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.08)))
  }
}

/// Selectable chip used for filters and error-type pickers.
struct Chip: View {
  let title: String
  var icon: String? = nil
  var selected = false
  var tint: Color = .accentColor
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
        Text(title).lineLimit(1)
      }
      .font(DS.Font.body)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .foregroundStyle(selected ? tint : Color.primary)
      .background(selected ? tint.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
      .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : Color.primary.opacity(0.1)))
    }
    .buttonStyle(.plain)
  }
}

/// Keycap hint ("⌘K").
struct KeyHint: View {
  let keys: String
  init(_ keys: String) { self.keys = keys }
  var body: some View {
    Text(keys)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
  }
}
