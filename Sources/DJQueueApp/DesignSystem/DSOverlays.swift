import SwiftUI

// MARK: - Floating surface (popover / menu / dialog / toast base)

extension View {
  /// surface.raised + border.subtle + elevation (e2 popovers/menus/toasts/bulk bar, e3 modals).
  func dsFloatingSurface(radius: CGFloat = DS.radius.lg, elevation: DSShadow = DS.elevation.e2) -> some View {
    background(DS.color.surfaceRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.color.border))
      .dsElevation(elevation)
  }
}

// MARK: - Popover

extension View {
  /// Native popover with DS padding/width. Content: DS components (DSMenuList, fields, toggles).
  func dsPopover<C: View>(isPresented: Binding<Bool>, edge: Edge = .bottom, width: CGFloat? = 280,
                          @ViewBuilder content: @escaping () -> C) -> some View {
    popover(isPresented: isPresented, arrowEdge: edge) {
      content()
        .padding(6)
        .frame(width: width)
        .background(DS.color.surfaceRaised)
    }
  }
}

/// Popover/menu surface drawn by SwiftUI (in-window dropdowns, ⌘K panel, gallery). r.lg + e2.
struct DSPopoverSurface<Content: View>: View {
  var width: CGFloat = 260
  var padding: CGFloat = 6
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(padding).frame(width: width, alignment: .leading).dsFloatingSurface(radius: DS.radius.lg)
  }
}

// MARK: - Menu list (shadcn DropdownMenu content)

struct DSMenuItem: Identifiable {
  enum Kind { case action, label, separator }
  let id = UUID()
  var kind: Kind = .action
  var title: String = ""
  var icon: String? = nil
  var shortcut: String? = nil
  var isChecked = false
  var isDestructive = false
  var disabledReason: String? = nil
  var action: () -> Void = {}

  static func label(_ t: String) -> DSMenuItem { DSMenuItem(kind: .label, title: t) }
  static var separator: DSMenuItem { DSMenuItem(kind: .separator) }
}

/// DropdownMenu anatomy (ChatGPT account menu): Label · Item (icon, title, shortcut / check) · Separator ·
/// destructive Item. Rows r.sm, `callout`. Context menus stay native (`.contextMenu`).
struct DSMenuList: View {
  let items: [DSMenuItem]
  var forcedHoverIndex: Int? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
        switch item.kind {
        case .label:
          Text(item.title).font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
        case .separator:
          DSSeparator().padding(.vertical, 4).padding(.horizontal, -6)
        case .action:
          DSMenuRow(item: item, forcedHover: forcedHoverIndex == i)
        }
      }
    }
  }
}

private struct DSMenuRow: View {
  let item: DSMenuItem
  var forcedHover = false
  @State private var hovering = false

  var body: some View {
    let enabled = item.disabledReason == nil
    let hot = (hovering || forcedHover) && enabled
    Button {
      if enabled { item.action() }
    } label: {
      HStack(spacing: 10) {
        if let icon = item.icon {
          Image(systemName: icon).font(.system(size: 13, weight: .regular)).frame(width: 16)
            .foregroundStyle(item.isDestructive ? DS.color.danger : DS.color.textSecondary)
        }
        Text(item.title).font(DS.type.callout)
        Spacer(minLength: DS.space.sm)
        if item.isChecked {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
        } else if let s = item.shortcut {
          Text(s).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        }
      }
      .foregroundStyle(!enabled ? DS.color.textDisabled : item.isDestructive ? DS.color.danger : DS.color.text)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(hot ? (item.isDestructive ? DS.color.dangerTint : DS.color.hover) : .clear,
                  in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsTooltip(item.disabledReason, edge: .bottom)
  }
}

// MARK: - Dialog / Sheet

/// shadcn Dialog / AlertDialog: Header (icon, title, description, close) → Body → Footer (ghost Cancel + one
/// primary, right-aligned). r.lg, e3. Use inside `.dsSheet`, or standalone in-window over `DS.color.scrim`.
struct DSDialog<Body: View, Footer: View>: View {
  let title: String
  var description: String? = nil
  var icon: String? = nil
  var iconTone: DSTone = .neutral
  var width: CGFloat = 480
  var onClose: (() -> Void)? = nil
  @ViewBuilder var content: Body
  @ViewBuilder var footer: Footer

  init(_ title: String, description: String? = nil, icon: String? = nil, iconTone: DSTone = .neutral, width: CGFloat = 480,
       onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Body, @ViewBuilder footer: () -> Footer) {
    self.title = title
    self.description = description
    self.icon = icon
    self.iconTone = iconTone
    self.width = width
    self.onClose = onClose
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.md) {
      HStack(alignment: .top, spacing: DS.space.sm) {
        if let icon {
          Image(systemName: icon).font(.system(size: 15, weight: .medium))
            .foregroundStyle(iconTone == .neutral ? DS.color.text : iconTone.color)
            .frame(width: 36, height: 36)
            .background(DS.color.tint(iconTone), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
          if let description {
            Text(description).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
        if let onClose { DSIconButton("xmark", tooltip: "Close", size: .sm, shortcut: "esc", action: onClose) }
      }
      content
      HStack(spacing: DS.space.xs) {
        Spacer(minLength: 0)
        footer
      }
      .padding(.top, 4)
    }
    .padding(DS.space.xl)
    .frame(width: width, alignment: .leading)
  }
}

/// "What will change" list for bulk confirmation sheets (DESIGN-v2 §5): "crop → Default".
struct DSChangeList: View {
  struct Change: Identifiable {
    let field: String
    let value: String
    var id: String { field }
  }
  let changes: [Change]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(changes.enumerated()), id: \.element.id) { i, c in
        HStack {
          Text(c.field).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          Spacer(minLength: DS.space.sm)
          Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
          Text(c.value).font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        }
        .padding(.horizontal, DS.space.sm)
        .frame(height: 36)
        if i < changes.count - 1 { DSSeparator() }
      }
    }
    .dsSurface(DS.color.surfaceSunken, radius: DS.radius.sm, border: nil)
  }
}

extension View {
  /// Sheet hosting a DSDialog with DS background (macOS draws its own sheet chrome + scrim).
  func dsSheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
    sheet(isPresented: isPresented) {
      content().background(DS.color.surfaceRaised)
    }
  }
}

// MARK: - Toast

struct DSToastModel: Identifiable, Equatable {
  let id = UUID()
  var message: String
  var detail: String? = nil
  var tone: DSTone = .neutral
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  /// Seconds before auto-dismiss; nil = sticky.
  var duration: Double? = 5

  static func == (a: DSToastModel, b: DSToastModel) -> Bool { a.id == b.id }
}

/// Sonner-style toast: r.md, e2, tone icon, message, optional action ("Undo") and close.
struct DSToast: View {
  let toast: DSToastModel
  var onDismiss: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 10) {
      if toast.tone != .neutral {
        Image(systemName: toast.tone.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(toast.tone.color)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(toast.message).font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        if let d = toast.detail { Text(d).font(DS.type.caption).foregroundStyle(DS.color.textSecondary) }
      }
      Spacer(minLength: DS.space.sm)
      if let t = toast.actionTitle, let a = toast.action {
        DSButton(t, variant: .outline, size: .sm) { a(); onDismiss?() }
      }
      if let onDismiss {
        DSIconButton("xmark", tooltip: "Dismiss", size: .sm, action: onDismiss)
      }
    }
    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
    .frame(minWidth: 300, maxWidth: 560)
    .dsFloatingSurface(radius: DS.radius.md)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
  }
}

/// Where the toast may go: the content area (right of the sidebar; nil = the whole window, e.g. the editor) and
/// the floating controls it must never cover (bulk bar, Score's control pill), as anchors.
struct DSToastLayout {
  var area: Anchor<CGRect>?
  var avoid: [Anchor<CGRect>] = []
}

struct DSToastLayoutKey: PreferenceKey {
  static let defaultValue = DSToastLayout()
  static func reduce(value: inout DSToastLayout, nextValue: () -> DSToastLayout) {
    let n = nextValue()
    value.area = n.area ?? value.area
    value.avoid += n.avoid
  }
}

private struct DSToastHost: ViewModifier {
  @Binding var toast: DSToastModel?
  func body(content: Content) -> some View {
    content.overlayPreferenceValue(DSToastLayoutKey.self) { layout in
      GeometryReader { geo in
        let area = layout.area.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
        // Sit above the highest floating control in the content area, else 24 pt above its bottom edge.
        let top = layout.avoid.map { geo[$0] }.filter { $0.intersects(area) }.map(\.minY).min()
        let bottom = min(area.maxY - DS.space.xl, (top ?? .infinity) - DS.space.sm)
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          if let t = toast {
            DSToast(toast: t) { dsWithAnimation { toast = nil } }
              .transition(.dsMove(.bottom))
              .task(id: t.id) {
                guard let d = t.duration else { return }
                try? await Task.sleep(for: .seconds(d))
                if toast?.id == t.id { dsWithAnimation { toast = nil } }
              }
          }
        }
        .frame(width: area.width, height: max(0, bottom - area.minY))
        .padding(.leading, area.minX)
        .padding(.top, area.minY)
      }
    }
    .dsAnimation(DS.motion.layout, value: toast)
  }
}

extension View {
  /// Shows `toast` at the bottom centre of the content area (`dsToastArea`), above any `dsToastAvoid` control;
  /// auto-dismisses after its duration.
  func dsToast(_ toast: Binding<DSToastModel?>) -> some View { modifier(DSToastHost(toast: toast)) }
  /// Marks a floating control the toast must stay above (bulk bar, Score pill).
  func dsToastAvoid(_ active: Bool = true) -> some View {
    anchorPreference(key: DSToastLayoutKey.self, value: .bounds) { DSToastLayout(avoid: active ? [$0] : []) }
  }
  /// Marks the area the toast centres in (the screen beside the sidebar).
  func dsToastArea() -> some View {
    transformAnchorPreference(key: DSToastLayoutKey.self, value: .bounds) { $0.area = $1 }
  }
}

// MARK: - Bulk bar (DESIGN-v2 §5)

/// Floating capsule shown while ≥1 item is selected: ✕ clear · "4 selected" · divider · ≤4 labelled ghost
/// actions · More ▾ · the screen's primary capsule. surface.raised, e2, height 48, padding 6, max 720.
/// Place with `.dsBulkBar(isPresented:)` (16 pt above the bottom edge, slides up 12 pt + fades).
struct DSBulkBar<Actions: View, Trailing: View>: View {
  let count: Int
  var noun: String = "selected"
  var onSelectAll: (() -> Void)? = nil
  let onClear: () -> Void
  @ViewBuilder var actions: Actions
  /// More ▾ menu and the primary DSButton.
  @ViewBuilder var trailing: Trailing

  init(count: Int, noun: String = "selected", onSelectAll: (() -> Void)? = nil, onClear: @escaping () -> Void,
       @ViewBuilder actions: () -> Actions, @ViewBuilder trailing: () -> Trailing) {
    self.count = count
    self.noun = noun
    self.onSelectAll = onSelectAll
    self.onClear = onClear
    self.actions = actions()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onClear) {
        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 36, height: 36).contentShape(Circle())
      }
      .buttonStyle(DSBulkActionStyle(circle: true))
      .dsTooltip("Clear selection", shortcut: "esc")
      Text("\(count) \(noun)").font(DS.type.calloutSemibold.monospacedDigit()).foregroundStyle(DS.color.text).padding(.trailing, 4)
      if let onSelectAll {
        Button("Select all", action: onSelectAll).buttonStyle(DSBulkActionStyle())
          .dsTooltip("Select every clip on this screen", shortcut: "⌘A")
      }
      DSSeparator(vertical: true).frame(height: 22).padding(.horizontal, 4)
      actions.buttonStyle(DSBulkActionStyle())
      trailing
    }
    .padding(6)
    .frame(height: DS.size.bulkBar)
    .background(DS.color.surfaceRaised, in: Capsule())
    .overlay(Capsule().strokeBorder(DS.color.border))
    .dsElevation(DS.elevation.e2)
    .frame(maxWidth: 720)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(count) \(noun)")
  }
}

extension DSBulkBar where Trailing == EmptyView {
  init(count: Int, noun: String = "selected", onSelectAll: (() -> Void)? = nil, onClear: @escaping () -> Void,
       @ViewBuilder actions: () -> Actions) {
    self.init(count: count, noun: noun, onSelectAll: onSelectAll, onClear: onClear, actions: actions) { EmptyView() }
  }
}

/// Labelled ghost capsule inside the bulk bar (icon + short label, `callout`).
struct DSBulkActionStyle: ButtonStyle {
  var circle = false
  func makeBody(configuration: Configuration) -> some View {
    DSBulkActionBody(configuration: configuration, circle: circle)
  }
}

private struct DSBulkActionBody: View {
  let configuration: ButtonStyleConfiguration
  let circle: Bool
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    configuration.label
      .labelStyle(DSButtonLabelStyle(iconSize: 13))
      .font(DS.type.calloutMedium)
      .foregroundStyle(isEnabled ? DS.color.text : DS.color.textDisabled)
      .padding(.horizontal, circle ? 0 : 12)
      .frame(height: 36)
      .background(configuration.isPressed ? DS.color.selected : (hovering || forced == .hover) ? DS.color.hover : .clear, in: Capsule())
      .contentShape(Capsule())
      .onHover { hovering = $0 }
  }
}

extension View {
  /// Floats `bar` 16 pt above the bottom edge while `isPresented`, sliding up 12 pt + fading.
  func dsBulkBar<B: View>(isPresented: Bool, @ViewBuilder bar: () -> B) -> some View {
    overlay(alignment: .bottom) {
      if isPresented { bar().dsToastAvoid().padding(.bottom, DS.space.md).transition(.dsMove(.bottom)) }
    }
    .dsAnimation(DS.motion.layout, value: isPresented)
  }
}

// MARK: - Toolbar

/// Screen toolbar (DESIGN-v2 §3): 52 pt, transparent. Title (`title`) + context line (`callout` secondary) on the
/// left; optional centre; right = view toggle, ⋯ menu, the single primary capsule.
struct DSToolbar<Center: View, Trailing: View>: View {
  let title: String
  var subtitle: String? = nil
  var showsDivider = false
  @ViewBuilder var center: Center
  @ViewBuilder var trailing: Trailing

  init(_ title: String, subtitle: String? = nil, showsDivider: Bool = false, @ViewBuilder center: () -> Center = { EmptyView() },
       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.title = title
    self.subtitle = subtitle
    self.showsDivider = showsDivider
    self.center = center()
    self.trailing = trailing()
  }

  var body: some View {
    ZStack {
      HStack(spacing: DS.space.sm) {
        HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
          Text(title).font(DS.type.title).foregroundStyle(DS.color.text)
          if let subtitle { Text(subtitle).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
        }
        Spacer(minLength: DS.space.md)
        HStack(spacing: DS.space.xs) { trailing }
      }
      center
    }
    .padding(.horizontal, DS.space.xl)
    .frame(height: DS.size.toolbar)
    .overlay(alignment: .bottom) { if showsDivider { DSSeparator() } }
  }
}

// MARK: - Sidebar item

/// ChatGPT sidebar row (DESIGN-v2 §3): 36 pt, r.sm, 16 pt symbol, `callout` label, right-aligned count or dot.
struct DSSidebarItem: View {
  let title: String
  let icon: String
  var count: Int? = nil
  var countStyle: DSCount.Style = .plain
  var dot: DSTone? = nil
  var isSelected = false
  var shortcut: String? = nil
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(_ title: String, icon: String, count: Int? = nil, countStyle: DSCount.Style = .plain, dot: DSTone? = nil, isSelected: Bool = false,
       shortcut: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.count = count
    self.countStyle = countStyle
    self.dot = dot
    self.isSelected = isSelected
    self.shortcut = shortcut
    self.action = action
  }

  var body: some View {
    let s = forced ?? (hovering ? .hover : .idle)
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon).font(.system(size: 14, weight: .regular)).frame(width: 18)
          .foregroundStyle(DS.color.text)
        Text(title).font(DS.type.callout).foregroundStyle(DS.color.text)
        Spacer(minLength: 4)
        if let count { DSCount(count: count, style: countStyle) }
        if let dot { DSStatusDot(tone: dot, size: 7) }
      }
      .padding(.horizontal, 10)
      .frame(height: DS.size.sidebarItem)
      .background(isSelected ? DS.color.selected : s == .hover ? DS.color.hover : .clear,
                  in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsFocusRing(s == .focused, radius: DS.radius.sm)
    .dsTooltip(shortcut.map { _ in title }, shortcut: shortcut, edge: .bottom)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Attention card (replaces round-1 full-width bars)

/// DESIGN-v2 §3: r.lg card at the top of the content, tone tint background, icon, one line, action. Danger can't be
/// dismissed while unresolved; warning can be hidden for 24 h (pass `onDismiss`).
struct DSAttentionCard: View {
  let title: String
  var message: String? = nil
  var tone: DSTone = .danger
  var actionTitle: String? = nil
  var onDismiss: (() -> Void)? = nil
  var action: (() -> Void)? = nil

  init(title: String, message: String? = nil, tone: DSTone = .danger, actionTitle: String? = nil, onDismiss: (() -> Void)? = nil,
       action: (() -> Void)? = nil) {
    self.title = title
    self.message = message
    self.tone = tone
    self.actionTitle = actionTitle
    self.onDismiss = onDismiss
    self.action = action
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: tone.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tone.color)
      Text(title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
      if let message { Text(message).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
      Spacer(minLength: DS.space.sm)
      if let actionTitle, let action { DSButton(actionTitle, variant: .outline, size: .sm, action: action) }
      if let onDismiss { DSIconButton("xmark", tooltip: "Hide for 24 hours", size: .sm, action: onDismiss) }
    }
    .padding(.leading, DS.space.md).padding(.trailing, 10)
    .frame(minHeight: 52)
    .background(DS.color.tint(tone), in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
  }
}

/// Round-1 name.
typealias DSBanner = DSAttentionCard
