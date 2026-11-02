import SwiftUI

// MARK: - Field chrome (shared by text field, text area, select)

/// shadcn Field anatomy: Label → Control → Description (hint) | Error, + counter slot on the right of the footer.
struct DSFieldFrame<Control: View>: View {
  var label: String? = nil
  var hint: String? = nil
  var error: String? = nil
  var counter: (count: Int, limit: Int)? = nil
  var trailingLabel: AnyView? = nil
  @ViewBuilder var control: Control

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if label != nil || trailingLabel != nil {
        HStack(spacing: 6) {
          if let label { Text(label).font(DS.type.calloutMedium).foregroundStyle(DS.color.text) }
          Spacer(minLength: 0)
          trailingLabel
        }
      }
      control
      if error != nil || hint != nil || counter != nil {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let error {
            Label(error, systemImage: "exclamationmark.circle.fill")
              .labelStyle(DSButtonLabelStyle(iconSize: 11))
              .font(DS.type.caption).foregroundStyle(DS.color.danger)
          } else if let hint {
            Text(hint).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          if let counter { DSCounter(count: counter.count, limit: counter.limit) }
        }
      }
    }
  }
}

/// "158/1500" — grey, amber within 10% of the limit, red over.
struct DSCounter: View {
  let count: Int
  let limit: Int
  var body: some View {
    let tone: Color = count > limit ? DS.color.danger : Double(count) >= Double(limit) * 0.9 ? DS.color.warning : DS.color.textTertiary
    Text("\(count)/\(limit)").font(DS.type.caption.monospacedDigit()).foregroundStyle(tone)
      .accessibilityLabel("\(count) of \(limit) characters")
  }
}

/// Visual state for a field box.
/// DESIGN-v2: inputs = surface.sunken fill + border.strong, r.sm (search: capsule). Focus = accent ring;
/// composer look (caption) = surface.raised + border.strong, r.lg.
struct DSFieldBox: ViewModifier {
  var focused: Bool
  var hovering: Bool
  var error: Bool
  var disabled: Bool
  var radius: CGFloat = DS.radius.sm
  var fill: Color = DS.color.surfaceSunken

  func body(content: Content) -> some View {
    let border: Color = error ? DS.color.danger : focused ? DS.color.accent : hovering ? DS.color.text.opacity(0.28) : DS.color.borderStrong
    let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
    content
      .background(fill, in: shape)
      .overlay(shape.strokeBorder(border, lineWidth: 1))
      .overlay {
        RoundedRectangle(cornerRadius: min(radius, 999) + 3, style: .continuous)
          .strokeBorder(error ? DS.color.danger.opacity(0.25) : DS.color.focusRing.opacity(0.6), lineWidth: 3)
          .padding(-3).opacity(focused || (error && focused) ? 1 : 0).allowsHitTesting(false)
      }
      .opacity(disabled ? 0.6 : 1)
  }
}

// MARK: - Text field

struct DSTextField: View {
  var label: String? = nil
  let placeholder: String
  @Binding var text: String
  var icon: String? = nil
  var hint: String? = nil
  var error: String? = nil
  var limit: Int? = nil
  var disabledReason: String? = nil
  var size: DSButtonSize = .md
  /// Capsule search field (DESIGN-v2: search is a capsule).
  var isSearch = false
  var onSubmit: (() -> Void)? = nil
  @FocusState private var focused: Bool
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(_ label: String? = nil, placeholder: String, text: Binding<String>, icon: String? = nil, hint: String? = nil,
       error: String? = nil, limit: Int? = nil, disabledReason: String? = nil, size: DSButtonSize = .md, isSearch: Bool = false,
       onSubmit: (() -> Void)? = nil) {
    self.label = label
    self.placeholder = placeholder
    _text = text
    self.icon = icon
    self.hint = hint
    self.error = error
    self.limit = limit
    self.disabledReason = disabledReason
    self.size = size
    self.isSearch = isSearch
    self.onSubmit = onSubmit
  }

  var body: some View {
    let isFocused = forced == .focused || focused
    let isHover = forced == .hover || hovering
    let icon = isSearch ? (icon ?? "magnifyingglass") : icon
    DSFieldFrame(label: label, hint: disabledReason ?? hint, error: error, counter: limit.map { (text.count, $0) }) {
      HStack(spacing: 8) {
        if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.color.textTertiary) }
        TextField(placeholder, text: $text)
          .textFieldStyle(.plain)
          .font(size == .sm ? DS.type.callout : size == .lg ? Font.system(size: 15) : DS.type.body)
          .foregroundStyle(DS.color.text)
          .focused($focused)
          .onSubmit { onSubmit?() }
          .disabled(disabledReason != nil)
        if !text.isEmpty && isFocused && disabledReason == nil {
          Button { text = "" } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.color.textTertiary)
          }
          .buttonStyle(.plain).dsTooltip("Clear")
        }
      }
      .padding(.horizontal, isSearch ? 14 : 12)
      .frame(height: size.height)
      .modifier(DSFieldBox(focused: isFocused, hovering: isHover, error: error != nil, disabled: disabledReason != nil,
                           radius: isSearch ? size.height / 2 : DS.radius.sm))
      .onHover { hovering = $0 }
      .dsTooltip(disabledReason)
      .dsAnimation(DS.motion.hover, value: isFocused)
    }
  }
}

/// Multi-line text (composer look: surface.raised, r.lg, border.strong) with placeholder, counter, min/max height.
struct DSTextArea: View {
  var label: String? = nil
  let placeholder: String
  @Binding var text: String
  var hint: String? = nil
  var error: String? = nil
  var limit: Int? = nil
  var minHeight: CGFloat = 88
  var maxHeight: CGFloat = 220
  @FocusState private var focused: Bool
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(_ label: String? = nil, placeholder: String, text: Binding<String>, hint: String? = nil, error: String? = nil,
       limit: Int? = nil, minHeight: CGFloat = 88, maxHeight: CGFloat = 220) {
    self.label = label
    self.placeholder = placeholder
    _text = text
    self.hint = hint
    self.error = error
    self.limit = limit
    self.minHeight = minHeight
    self.maxHeight = maxHeight
  }

  var body: some View {
    let isFocused = forced == .focused || focused
    DSFieldFrame(label: label, hint: hint, error: error, counter: limit.map { (text.count, $0) }) {
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(placeholder).font(DS.type.body).foregroundStyle(DS.color.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
        }
        TextEditor(text: $text)
          .font(DS.type.body)
          .foregroundStyle(DS.color.text)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.never)
          .focused($focused)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 10)
      .frame(minHeight: minHeight, idealHeight: minHeight, maxHeight: maxHeight)
      .fixedSize(horizontal: false, vertical: true)
      .modifier(DSFieldBox(focused: isFocused, hovering: forced == .hover || hovering, error: error != nil, disabled: false,
                           radius: DS.radius.lg, fill: DS.color.surfaceRaised))
      .onHover { hovering = $0 }
    }
  }
}

// MARK: - Select

struct DSSelectOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var icon: String? = nil
  var detail: String? = nil
  var id: Value { value }
}

/// shadcn Select / Base UI Select: Trigger (value + chevron) → native menu popup with a check on the current value.
/// The trigger is DS-styled; the popup is the system menu (keyboard, type-ahead and accessibility for free).
struct DSSelect<Value: Hashable>: View {
  var label: String? = nil
  @Binding var selection: Value
  let options: [DSSelectOption<Value>]
  var placeholder: String = "Choose…"
  var hint: String? = nil
  var size: DSButtonSize = .md
  var variant: DSButtonVariant = .outline
  var fullWidth = true
  var disabledReason: String? = nil

  var body: some View {
    DSFieldFrame(label: label, hint: disabledReason ?? hint) {
      Menu {
        ForEach(options) { o in
          Button {
            selection = o.value
          } label: {
            if o.value == selection { Label(o.title, systemImage: "checkmark") } else if let i = o.icon { Label(o.title, systemImage: i) } else { Text(o.title) }
          }
        }
      } label: {
        DSSelectTrigger(title: current?.title ?? placeholder, icon: current?.icon, isPlaceholder: current == nil, size: size,
                        variant: variant, fullWidth: fullWidth, disabled: disabledReason != nil)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize(horizontal: !fullWidth, vertical: true)
      .disabled(disabledReason != nil)
      .dsTooltip(disabledReason)
    }
  }

  private var current: DSSelectOption<Value>? { options.first { $0.value == selection } }
}

/// The select trigger on its own (also used for "menu" buttons like "Newest ▾").
struct DSSelectTrigger: View {
  let title: String
  var icon: String? = nil
  var isPlaceholder = false
  var size: DSButtonSize = .md
  var variant: DSButtonVariant = .outline
  var fullWidth = true
  var disabled = false
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let state = forced ?? (hovering ? .hover : .idle)
    let ghost = variant == .ghost
    let c = DSButtonColors.resolve(variant, state: state, enabled: !disabled)
    let r: CGFloat = ghost ? size.height / 2 : DS.radius.sm
    HStack(spacing: 7) {
      if let icon { Image(systemName: icon).font(.system(size: size.iconSize, weight: .medium)).foregroundStyle(DS.color.textSecondary) }
      Text(title).font(size == .sm ? DS.type.callout : DS.type.body).foregroundStyle(isPlaceholder ? DS.color.textTertiary : c.text).lineLimit(1)
      if fullWidth { Spacer(minLength: 4) }
      Image(systemName: "chevron.down").font(.system(size: size.iconSize - 2.5, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
    }
    .padding(.horizontal, ghost ? 12 : 12)
    .frame(height: size.height)
    .frame(maxWidth: fullWidth ? .infinity : nil)
    .background(ghost ? c.fill : (state == .hover ? DS.color.hover : DS.color.surfaceSunken),
                in: RoundedRectangle(cornerRadius: r, style: .continuous))
    .overlay { if !ghost { RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(DS.color.borderStrong) } }
    .dsFocusRing(state == .focused, radius: r)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }
}

// MARK: - Toggle (switch)

/// shadcn Switch: label on the left, switch on the right, optional description. On = accent.
struct DSToggle: View {
  var label: String? = nil
  var description: String? = nil
  @Binding var isOn: Bool
  var disabledReason: String? = nil
  var size: DSButtonSize = .md

  init(_ label: String? = nil, description: String? = nil, isOn: Binding<Bool>, disabledReason: String? = nil, size: DSButtonSize = .md) {
    self.label = label
    self.description = description
    _isOn = isOn
    self.disabledReason = disabledReason
    self.size = size
  }

  var body: some View {
    HStack(alignment: description == nil ? .center : .top, spacing: DS.space.sm) {
      if label != nil || description != nil {
        VStack(alignment: .leading, spacing: 2) {
          if let label { Text(label).font(DS.type.body).foregroundStyle(disabledReason == nil ? DS.color.text : DS.color.textDisabled) }
          if let d = disabledReason ?? description {
            Text(d).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: DS.space.sm)
      }
      DSSwitch(isOn: $isOn, disabled: disabledReason != nil, small: size == .sm)
    }
    .contentShape(Rectangle())
    .onTapGesture { if disabledReason == nil { dsWithAnimation { isOn.toggle() } } }
    .dsTooltip(disabledReason)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Toggle")
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { if disabledReason == nil { isOn.toggle() } }
  }
}

/// The bare switch control.
struct DSSwitch: View {
  @Binding var isOn: Bool
  var disabled = false
  var small = false
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let w: CGFloat = small ? 28 : 36, h: CGFloat = small ? 16 : 20
    let state = forced ?? (hovering ? .hover : .idle)
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule().fill(isOn ? DS.color.accent : (state == .hover ? DS.color.fillPressed : DS.color.fillHover))
      Circle().fill(Color.white).padding(2)
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
    .frame(width: w, height: h)
    .opacity(disabled ? 0.45 : 1)
    .dsFocusRing(state == .focused, radius: h / 2)
    .onHover { hovering = $0 }
    .onTapGesture { if !disabled { dsWithAnimation { isOn.toggle() } } }
    .dsAnimation(DS.motion.snappy, value: isOn)
  }
}

// MARK: - Checkbox

enum DSCheckState: Sendable { case off, on, mixed }

/// Rounded square for forms; circle for selecting clips (DESIGN-v2 §4: 20 pt circle on cards).
enum DSCheckShape: Sendable { case square, circle }

/// shadcn Checkbox: 16 pt rounded square, accent when checked, dash when mixed.
struct DSCheckbox: View {
  var state: DSCheckState
  var label: String? = nil
  var description: String? = nil
  var disabledReason: String? = nil
  var size: CGFloat = 16
  var shape: DSCheckShape = .square
  /// On a photo/video: white ring + shadow so it reads on any image.
  var onMedia = false
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(isOn: Bool, label: String? = nil, description: String? = nil, disabledReason: String? = nil, size: CGFloat = 16,
       shape: DSCheckShape = .square, onMedia: Bool = false, action: @escaping () -> Void) {
    self.init(state: isOn ? .on : .off, label: label, description: description, disabledReason: disabledReason, size: size,
              shape: shape, onMedia: onMedia, action: action)
  }

  init(state: DSCheckState, label: String? = nil, description: String? = nil, disabledReason: String? = nil, size: CGFloat = 16,
       shape: DSCheckShape = .square, onMedia: Bool = false, action: @escaping () -> Void) {
    self.state = state
    self.label = label
    self.description = description
    self.disabledReason = disabledReason
    self.size = size
    self.shape = shape
    self.onMedia = onMedia
    self.action = action
  }

  var body: some View {
    let s = forced ?? (hovering ? .hover : .idle)
    HStack(alignment: .top, spacing: 8) {
      box(s)
      if label != nil || description != nil {
        VStack(alignment: .leading, spacing: 2) {
          if let label { Text(label).font(DS.type.body).foregroundStyle(disabledReason == nil ? DS.color.text : DS.color.textDisabled) }
          if let d = disabledReason ?? description { Text(d).font(DS.type.caption).foregroundStyle(DS.color.textSecondary) }
        }
        .padding(.top, max(0, (size - 15) / 2))
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if disabledReason == nil { action() } }
    .onHover { hovering = $0 }
    .dsTooltip(disabledReason)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Select")
    .accessibilityValue(state == .on ? "Checked" : state == .mixed ? "Mixed" : "Unchecked")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { if disabledReason == nil { action() } }
  }

  private func box(_ s: DSInteraction) -> some View {
    let r = shape == .circle ? size / 2 : size * 0.3
    let checked = state != .off
    return ZStack {
      RoundedRectangle(cornerRadius: r, style: .continuous)
        .fill(checked ? DS.color.accent : onMedia ? Color.black.opacity(0.25) : DS.color.background)
      RoundedRectangle(cornerRadius: r, style: .continuous)
        .strokeBorder(checked ? Color.clear : onMedia ? Color.white : (s == .hover ? DS.color.text.opacity(0.5) : DS.color.borderStrong),
                      lineWidth: onMedia ? 1.5 : 1)
      if state == .on {
        Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white)
      } else if state == .mixed {
        Capsule().fill(.white).frame(width: size * 0.5, height: 2)
      }
    }
    .frame(width: size, height: size)
    .shadow(color: onMedia ? .black.opacity(0.3) : .clear, radius: 2, y: 1)
    .opacity(disabledReason != nil ? 0.45 : 1)
    .dsFocusRing(s == .focused, radius: r)
    .dsAnimation(DS.motion.snappy, value: state)
  }
}

// MARK: - Slider

/// shadcn Slider with label + live value label. Arrow keys step when focused.
struct DSSlider: View {
  var label: String? = nil
  @Binding var value: Double
  var range: ClosedRange<Double> = 0...100
  var step: Double = 1
  var format: (Double) -> String = { String(Int($0.rounded())) }
  var showsValue = true
  var disabledReason: String? = nil
  /// VoiceOver name when there's no visible `label` (e.g. the label sits in a surrounding field header).
  var accessibilityName: String? = nil
  @State private var dragging = false
  @State private var hovering = false
  @FocusState private var focused: Bool
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let s = forced ?? (dragging ? .pressed : focused ? .focused : hovering ? .hover : .idle)
    VStack(alignment: .leading, spacing: 8) {
      if label != nil || showsValue {
        HStack {
          if let label { Text(label).font(DS.type.calloutMedium).foregroundStyle(DS.color.text) }
          Spacer()
          if showsValue {
            Text(format(value)).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.text)
              .padding(.horizontal, 8).frame(height: 24)
              .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous).strokeBorder(DS.color.border))
          }
        }
      }
      GeometryReader { g in
        let w = g.size.width
        let frac = (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
        let knob: CGFloat = s == .pressed ? 18 : 16
        ZStack(alignment: .leading) {
          Capsule().fill(DS.color.surfaceSunken).overlay(Capsule().strokeBorder(DS.color.border)).frame(height: 4)
          Capsule().fill(disabledReason == nil ? DS.color.primary : DS.color.textDisabled).frame(width: max(4, w * frac), height: 4)
          Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(DS.color.borderStrong, lineWidth: 0.5))
            .frame(width: knob, height: knob)
            .shadow(color: .black.opacity(0.2), radius: s == .hover || s == .pressed ? 3 : 1.5, y: 1)
            .dsFocusRing(s == .focused, radius: knob / 2)
            .offset(x: max(0, min(w - knob, w * frac - knob / 2)))
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
          .onChanged { g in
            guard disabledReason == nil else { return }
            dragging = true
            set(Double(g.location.x / max(1, w)))
          }
          .onEnded { _ in dragging = false })
      }
      .frame(height: 20)
      .opacity(disabledReason == nil ? 1 : 0.5)
    }
    .focusable(disabledReason == nil)
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.leftArrow) { nudge(-step); return .handled }
    .onKeyPress(.rightArrow) { nudge(step); return .handled }
    .onHover { hovering = $0 }
    .dsTooltip(disabledReason)
    .accessibilityElement()
    .accessibilityLabel(label ?? accessibilityName ?? "Slider")
    .accessibilityValue(format(value))
    .accessibilityAdjustableAction { d in nudge(d == .increment ? step : -step) }
  }

  private func set(_ frac: Double) {
    let raw = range.lowerBound + min(1, max(0, frac)) * (range.upperBound - range.lowerBound)
    value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
  }

  private func nudge(_ d: Double) {
    guard disabledReason == nil else { return }
    value = min(range.upperBound, max(range.lowerBound, value + d))
  }
}
