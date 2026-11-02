import SwiftUI

// MARK: - Chip

/// Toggle chip (shadcn Toggle, capsule, `caption` text). Unselected = border.strong outline; selected =
/// fill.selected + check. `tone` gives a semantic tint (warning chips). Platform chips: glyph + name, no colour.
struct DSChip: View {
  let title: String
  var icon: String? = nil
  var isSelected: Bool
  var tone: DSTone? = nil
  var count: Int? = nil
  var showsCheck = true
  var disabledReason: String? = nil
  var size: DSButtonSize = .md
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  /// What the chip does when the title alone doesn't say (shown on hover; the reason replaces it when disabled).
  var tooltip: String? = nil

  init(_ title: String, icon: String? = nil, isSelected: Bool, tone: DSTone? = nil, count: Int? = nil, showsCheck: Bool = true,
       disabledReason: String? = nil, size: DSButtonSize = .md, tooltip: String? = nil, action: @escaping () -> Void) {
    self.tooltip = tooltip
    self.title = title
    self.icon = icon
    self.isSelected = isSelected
    self.tone = tone
    self.count = count
    self.showsCheck = showsCheck
    self.disabledReason = disabledReason
    self.size = size
    self.action = action
  }

  var body: some View {
    let s = forced ?? (hovering ? .hover : .idle)
    let hot = s == .hover || s == .pressed
    let enabled = disabledReason == nil
    let h: CGFloat = size == .sm ? 26 : 30
    let tint = tone?.color
    Button {
      if enabled { dsWithAnimation { action() } }
    } label: {
      HStack(spacing: 5) {
        if isSelected && showsCheck && tone == nil {
          Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
        }
        if let icon {
          Image(systemName: icon).font(.system(size: size == .sm ? 10.5 : 11.5, weight: .medium))
            .foregroundStyle(tint ?? (isSelected ? DS.color.text : DS.color.textSecondary))
        }
        Text(title).lineLimit(1)
        if let count {
          Text("\(count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
        }
      }
      .font(size == .sm ? DS.type.caption : DS.type.captionMedium)
      .foregroundStyle(enabled ? (tint ?? DS.color.text) : DS.color.textDisabled)
      .padding(.horizontal, size == .sm ? 10 : 12)
      .frame(height: h)
      .background(fill(hot: hot), in: Capsule())
      .overlay(Capsule().strokeBorder(border(hot: hot), lineWidth: isSelected ? 1.2 : 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsFocusRing(s == .focused, radius: h / 2)
    .dsTooltip(tooltip ?? (disabledReason == nil ? nil : title), disabledReason: disabledReason)
    .dsAnimation(DS.motion.hover, value: s)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private func fill(hot: Bool) -> Color {
    if let tone { return DS.color.tint(tone) }
    if isSelected { return DS.color.selected }
    return hot ? DS.color.hover : .clear
  }

  private func border(hot: Bool) -> Color {
    if let tone { return tone.color.opacity(isSelected ? 0.5 : 0.25) }
    if isSelected { return DS.color.text.opacity(0.35) }
    return DS.color.borderStrong
  }
}

/// Multi-select (or single-select) chip group with an optional "None" chip.
struct DSChipGroup<Value: Hashable>: View {
  let options: [DSChipOption<Value>]
  @Binding var selection: Set<Value>
  var allowsMultiple = true
  /// Title for a "None" chip that clears the selection (e.g. safe zones: None).
  var noneTitle: String? = nil
  var size: DSButtonSize = .md

  var body: some View {
    DSFlowLayout(spacing: 6) {
      if let noneTitle {
        DSChip(noneTitle, isSelected: selection.isEmpty, size: size) { selection = [] }
      }
      ForEach(options) { o in
        DSChip(o.title, icon: o.icon, isSelected: selection.contains(o.value), disabledReason: o.disabledReason, size: size,
               tooltip: o.tooltip) {
          if allowsMultiple {
            if selection.contains(o.value) { selection.remove(o.value) } else { selection.insert(o.value) }
          } else {
            selection = [o.value]
          }
        }
      }
    }
  }
}

struct DSChipOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var icon: String? = nil
  var disabledReason: String? = nil
  /// What choosing it does, when the title alone doesn't say.
  var tooltip: String? = nil
  var id: Value { value }
}

/// Wrapping row layout for chips.
struct DSFlowLayout: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxW = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
    for s in subviews {
      let sz = s.sizeThatFits(.unspecified)
      if x > 0 && x + sz.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
      x += sz.width + spacing
      lineH = max(lineH, sz.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: y + lineH)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
    for s in subviews {
      let sz = s.sizeThatFits(.unspecified)
      if x > bounds.minX && x + sz.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
      x += sz.width + spacing
      lineH = max(lineH, sz.height)
    }
  }
}

// MARK: - Segmented

struct DSSegment<Value: Hashable>: Identifiable {
  let value: Value
  var title: String? = nil
  var icon: String? = nil
  /// Required when `title` is nil (icon-only segments explain themselves).
  var tooltip: String? = nil
  var id: Value { value }
}

/// Segmented control: capsule surface.sunken track, fill.selected thumb that slides. For 2–5 mutually exclusive
/// options that change a view (sort, aspect, view mode). For page-level sections use DSTabs.
struct DSSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  let segments: [DSSegment<Value>]
  var size: DSButtonSize = .md
  var fullWidth = false
  @Namespace private var ns

  var body: some View {
    let h: CGFloat = size == .sm ? 28 : size == .md ? 34 : 40
    HStack(spacing: 2) {
      ForEach(segments) { seg in
        DSSegmentButton(seg: seg, selected: seg.value == selection, height: h - 6, size: size, fullWidth: fullWidth, ns: ns) {
          if selection != seg.value { dsWithAnimation { selection = seg.value } }
        }
      }
    }
    .padding(3)
    .background(DS.color.surfaceSunken, in: Capsule())
    .fixedSize(horizontal: !fullWidth, vertical: true)
  }
}

private struct DSSegmentButton<Value: Hashable>: View {
  let seg: DSSegment<Value>
  let selected: Bool
  let height: CGFloat
  let size: DSButtonSize
  let fullWidth: Bool
  let ns: Namespace.ID
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let s = forced ?? (hovering ? .hover : .idle)
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon = seg.icon { Image(systemName: icon).font(.system(size: size.iconSize, weight: .medium)) }
        if let t = seg.title { Text(t).lineLimit(1) }
      }
      .font(size == .sm ? DS.type.caption.weight(.medium) : DS.type.calloutMedium)
      .foregroundStyle(selected ? DS.color.text : (s == .hover ? DS.color.text : DS.color.textSecondary))
      .padding(.horizontal, seg.title == nil ? 0 : (size == .sm ? 10 : 14))
      .frame(width: seg.title == nil ? height + 6 : nil, height: height)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background {
        if selected {
          Capsule().fill(DS.color.selected)
            .overlay(Capsule().strokeBorder(DS.color.border))
            .matchedGeometryEffect(id: "thumb", in: ns)
        } else if s == .hover {
          Capsule().fill(DS.color.hover.opacity(0.6))
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip(seg.tooltip)
    .accessibilityLabel(seg.title ?? seg.tooltip ?? "")
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Tabs

struct DSTab<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var count: Int? = nil
  var icon: String? = nil
  var id: Value { value }
}

/// Page-level tabs (ChatGPT "Chats | Sources"): text buttons, selected = soft grey pill. No track.
struct DSTabs<Value: Hashable>: View {
  @Binding var selection: Value
  let tabs: [DSTab<Value>]
  var size: DSButtonSize = .md
  @Namespace private var ns

  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs) { tab in
        DSTabButton(tab: tab, selected: tab.value == selection, size: size, ns: ns) { dsWithAnimation { selection = tab.value } }
      }
    }
  }
}

private struct DSTabButton<Value: Hashable>: View {
  let tab: DSTab<Value>
  let selected: Bool
  let size: DSButtonSize
  let ns: Namespace.ID
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let s = forced ?? (hovering ? .hover : .idle)
    Button(action: action) {
      HStack(spacing: 6) {
        if let icon = tab.icon { Image(systemName: icon).font(.system(size: size.iconSize, weight: .medium)) }
        Text(tab.title)
        if let c = tab.count {
          Text("\(c)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
        }
      }
      .font(DS.type.calloutMedium)
      .foregroundStyle(selected || s == .hover ? DS.color.text : DS.color.textSecondary)
      .padding(.horizontal, 12)
      .frame(height: size == .sm ? 28 : 32)
      .background {
        if selected {
          Capsule().fill(DS.color.selected).matchedGeometryEffect(id: "tab", in: ns)
        } else if s == .hover {
          Capsule().fill(DS.color.hover)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - View mode switcher

/// The four list view modes (decision #12), remembered per list by the screens.
enum DSViewMode: String, CaseIterable, Codable, Sendable, Identifiable {
  /// Order = toolbar order (DESIGN-v2 §4: Cards · Grid · Single · List).
  case wide, grid, single, list
  var id: String { rawValue }

  var icon: String {
    switch self {
    case .grid: "square.grid.2x2"
    case .single: "rectangle.portrait"
    case .list: "list.bullet"
    case .wide: "rectangle.grid.1x2"
    }
  }

  var title: String {
    switch self {
    case .grid: "Grid"
    case .single: "Single"
    case .list: "List"
    case .wide: "Cards"
    }
  }

  var help: String {
    switch self {
    case .grid: "Show clips as a grid of tiles"
    case .single: "Show one clip at a time, large"
    case .list: "Show clips as a compact list"
    case .wide: "Show clips as cards"
    }
  }
}

/// Icon-only segmented control for DSViewMode, each segment tooltipped.
struct DSViewModeSwitcher: View {
  @Binding var mode: DSViewMode
  var modes: [DSViewMode] = DSViewMode.allCases
  var size: DSButtonSize = .md

  var body: some View {
    DSSegmented(selection: $mode, segments: modes.map { DSSegment(value: $0, icon: $0.icon, tooltip: $0.help) }, size: size)
      .accessibilityLabel("View mode")
  }
}
