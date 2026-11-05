import SwiftUI

// MARK: - Card

enum DSCardVariant: Sendable {
  /// surface.raised + border.subtle + e1 (default card).
  case outline
  /// surface.sunken fill, no border (wells, grouped content).
  case filled
  /// surface.raised + e2 (rare: a floating hero card).
  case elevated
}

/// shadcn Card: Card → CardHeader (title, description, action) → CardContent → CardFooter.
/// Interactive cards (`onTap`/`interactive`) get hover and pressed states. Selected = 2 pt text.primary ring +
/// fill.selected (DESIGN-v2 §4).
struct DSCard<Content: View>: View {
  var variant: DSCardVariant = .outline
  var padding: CGFloat = DS.space.md
  var radius: CGFloat = DS.radius.lg
  var isSelected = false
  var interactive = false
  var onTap: (() -> Void)? = nil
  @ViewBuilder var content: Content
  @Environment(\.dsForcedState) private var forced
  @State private var hovering = false
  @State private var pressed = false

  init(variant: DSCardVariant = .outline, padding: CGFloat = DS.space.md, radius: CGFloat = DS.radius.lg,
       isSelected: Bool = false, interactive: Bool = false, onTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
    self.variant = variant
    self.padding = padding
    self.radius = radius
    self.isSelected = isSelected
    self.interactive = interactive || onTap != nil
    self.onTap = onTap
    self.content = content()
  }

  var body: some View {
    let state: DSInteraction = forced ?? (pressed ? .pressed : hovering ? .hover : .idle)
    let hot = interactive && (state == .hover || state == .pressed)
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill(hot: hot), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(isSelected ? DS.color.text : border(hot: hot), lineWidth: isSelected ? 2 : 1)
      }
      .dsElevation(variant == .elevated ? DS.elevation.e2 : variant == .outline ? DS.elevation.e1 : DS.elevation.e0)
      .scaleEffect(interactive && state == .pressed ? 0.995 : 1)
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onHover { if interactive { hovering = $0 } }
      .simultaneousGesture(onTap == nil ? nil : TapGesture().onEnded { onTap?() })
      .dsAnimation(DS.motion.hover, value: state)
      .dsAnimation(DS.motion.snappy, value: isSelected)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func fill(hot: Bool) -> Color {
    if isSelected { return DS.color.selected }
    switch variant {
    case .outline, .elevated: return hot ? DS.color.hover.opacity(0.5) : DS.color.surface
    case .filled: return hot ? DS.color.hover : DS.color.surfaceSunken
    }
  }

  private func border(hot: Bool) -> Color {
    switch variant {
    case .outline: hot ? DS.color.borderStrong : DS.color.border
    case .filled: .clear
    case .elevated: DS.color.border
    }
  }
}

/// CardHeader: title, optional description, trailing action slot.
struct DSCardHeader<Trailing: View>: View {
  let title: String
  var description: String? = nil
  @ViewBuilder var trailing: Trailing

  init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.title = title
    self.description = description
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .top, spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
        if let description {
          Text(description).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      trailing
    }
  }
}

/// CardFooter: right-aligned actions, optional leading note.
struct DSCardFooter<Actions: View>: View {
  var note: String? = nil
  @ViewBuilder var actions: Actions
  var body: some View {
    HStack(spacing: DS.space.xs) {
      if let note { Text(note).font(DS.type.callout).foregroundStyle(DS.color.textTertiary) }
      Spacer(minLength: 0)
      actions
    }
  }
}

// MARK: - Section header

/// Section header: `headline` title + tertiary count + optional description and trailing action.
struct DSSectionHeader<Trailing: View>: View {
  let title: String
  var count: Int? = nil
  var description: String? = nil
  @ViewBuilder var trailing: Trailing

  init(_ title: String, count: Int? = nil, description: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.title = title
    self.count = count
    self.description = description
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
      Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
      if let count { Text("\(count)").font(DS.type.headline.monospacedDigit()).foregroundStyle(DS.color.textTertiary) }
      if let description {
        Text(description).font(DS.type.callout).foregroundStyle(DS.color.textTertiary).lineLimit(1)
      }
      Spacer(minLength: 0)
      trailing
    }
    .accessibilityAddTraits(.isHeader)
  }
}

/// `micro` tertiary eyebrow, sentence case ("Browse").
struct DSEyebrow: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Stat

/// Big number + label (+ optional delta/hint). Runway, scores, counts.
struct DSStat: View {
  let value: String
  let label: String
  var hint: String? = nil
  var tone: DSTone? = nil
  var size: Size = .md
  var alignment: HorizontalAlignment = .leading

  enum Size { case sm, md, lg }

  var body: some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(value)
        .font(size == .lg ? Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
              : size == .md ? DS.type.stat : DS.type.score)
        .foregroundStyle(tone?.color ?? DS.color.text)
        .contentTransition(.numericText())
      Text(label).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
      if let hint { Text(hint).font(DS.type.micro).foregroundStyle(DS.color.textTertiary) }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Empty state

/// DESIGN-v2 §6.11: 20 pt symbol in a 40 pt surface.sunken tile (r.sm), headline title, one callout line,
/// one near-black capsule. No illustrations.
struct DSEmptyState: View {
  let icon: String
  let title: String
  var message: String? = nil
  var actionTitle: String? = nil
  var actionIcon: String? = nil
  /// A quieter second way out, beside the primary action.
  var secondary: Secondary? = nil
  var action: (() -> Void)? = nil

  struct Secondary {
    var title: String
    var icon: String? = nil
    var tooltip: String? = nil
    var shortcut: String? = nil
    var action: () -> Void
  }

  var body: some View {
    VStack(spacing: DS.space.sm) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(DS.color.textSecondary)
        .frame(width: 40, height: 40)
        .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      VStack(spacing: 4) {
        Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
        if let message {
          Text(message).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).multilineTextAlignment(.center)
            .frame(maxWidth: 320)
        }
      }
      HStack(spacing: DS.space.xs) {
        if let actionTitle, let action {
          DSButton(actionTitle, icon: actionIcon, variant: .primary, action: action)
        }
        if let secondary {
          DSButton(secondary.title, icon: secondary.icon, variant: .outline, tooltip: secondary.tooltip, shortcut: secondary.shortcut,
                   action: secondary.action)
        }
      }
      .padding(.top, 4)
    }
    .padding(DS.space.xxxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
