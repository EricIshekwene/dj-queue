import DJQCore
import SwiftUI

// ChatGPT settings-row anatomy (DESIGN-v2 §6.9) built from DS components and tokens. Settings-only helpers; the
// `DSX…` types are local stand-ins for controls the design system doesn't ship (stepper).

/// Binding into a Settings key path that saves on set (immediate-apply sections).
extension AppModel {
  func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { self.settings[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
  }
}

/// One settings row: label (`body`) + description (`caption` secondary, ≤ 2 lines) on the left, the control
/// right-aligned; or `stacked` with the control full width under the text (chip groups, fields). 56–72 pt with a
/// hairline under it. `disabledReason` dims the row, replaces the description with the reason and tooltips it.
struct SettingsRow<Control: View>: View {
  let label: String
  var description: String? = nil
  var disabledReason: String? = nil
  var stacked = false
  var platform: Platform? = nil
  /// Description is a file path: one line, truncated in the middle.
  var isPath = false
  @ViewBuilder var control: Control

  init(_ label: String, description: String? = nil, disabledReason: String? = nil, stacked: Bool = false,
       platform: Platform? = nil, isPath: Bool = false, @ViewBuilder control: () -> Control) {
    self.isPath = isPath
    self.label = label
    self.description = description
    self.disabledReason = disabledReason
    self.stacked = stacked
    self.platform = platform
    self.control = control()
  }

  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: DS.space.sm) {
          text
          control.disabled(disabledReason != nil).opacity(disabledReason == nil ? 1 : 0.55)
        }
        .padding(.vertical, DS.space.md)
      } else {
        HStack(alignment: .top, spacing: DS.space.md) {
          if let platform { DSPlatformIcon(platform: platform, size: 26).padding(.top, 1) }
          text.padding(.top, 4)
          Spacer(minLength: DS.space.sm)
          control
            .disabled(disabledReason != nil)
            .opacity(disabledReason == nil ? 1 : 0.55)
            .frame(minHeight: DS.size.controlSm)
        }
        .padding(.vertical, 14)
      }
    }
    .frame(minHeight: 56)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { DSSeparator() }
    .dsTooltip(disabledReason)
    .accessibilityElement(children: .contain)
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(DS.type.body).foregroundStyle(disabledReason == nil ? DS.color.text : DS.color.textDisabled)
      if let d = disabledReason ?? description {
        Text(d).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          .lineLimit(isPath && disabledReason == nil ? 1 : 2)
          .truncationMode(isPath ? .middle : .tail)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Sub-heading inside a section (DSSectionHeader with section spacing).
struct SettingsGroupHeader: View {
  let title: String
  var description: String? = nil
  var first = false
  init(_ title: String, description: String? = nil, first: Bool = false) {
    self.title = title
    self.description = description
    self.first = first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      DSSectionHeader(title)
      if let description {
        Text(description).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, first ? DS.space.lg : DS.space.xxl)
    .padding(.bottom, DS.space.xxs)
  }
}

/// A quiet explanatory line (caption, secondary) — no box.
struct SettingsNote: View {
  let text: String
  var icon: String = "info.circle"
  init(_ text: String, icon: String = "info.circle") {
    self.text = text
    self.icon = icon
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
      Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.textTertiary)
      Text(text).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, DS.space.md)
  }
}

/// Compact DS select for a row's trailing slot (ChatGPT "Push ⌄": value + chevron, no box until hover).
struct SettingsSelect<Value: Hashable>: View {
  let label: String
  @Binding var selection: Value
  let options: [DSSelectOption<Value>]
  var body: some View {
    DSSelect(selection: $selection, options: options, size: .sm, variant: .ghost, fullWidth: false)
      .accessibilityLabel(label)
  }
}

/// −/+ stepper (the DS has none): capsule surface.sunken track, ghost icon buttons, tabular value. Disabled ends
/// say why.
struct DSXStepper: View {
  let label: String
  @Binding var value: Double
  var range: ClosedRange<Double>
  var step: Double = 1
  var format: (Double) -> String

  var body: some View {
    HStack(spacing: 0) {
      DSIconButton("minus", tooltip: "Decrease \(label.lowercased())", size: .sm,
                   disabledReason: value <= range.lowerBound ? "Already at the minimum (\(format(range.lowerBound)))" : nil) {
        value = max(range.lowerBound, value - step)
      }
      Text(format(value))
        .font(DS.type.callout.monospacedDigit())
        .foregroundStyle(DS.color.text)
        .lineLimit(1)
        .frame(minWidth: 72)
        .contentTransition(.numericText())
      DSIconButton("plus", tooltip: "Increase \(label.lowercased())", size: .sm,
                   disabledReason: value >= range.upperBound ? "Already at the maximum (\(format(range.upperBound)))" : nil) {
        value = min(range.upperBound, value + step)
      }
    }
    .padding(2)
    .background(DS.color.surfaceSunken, in: Capsule())
    .overlay(Capsule().strokeBorder(DS.color.border))
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(format(value))
    .accessibilityAdjustableAction { d in
      value = d == .increment ? min(range.upperBound, value + step) : max(range.lowerBound, value - step)
    }
  }
}

extension DSXStepper {
  /// Int convenience.
  init(label: String, int: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, format: @escaping (Int) -> String) {
    self.label = label
    _value = Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0.rounded()) })
    self.range = Double(range.lowerBound)...Double(range.upperBound)
    self.step = Double(step)
    self.format = { format(Int($0.rounded())) }
  }
}

/// Formatting shared by the settings sections.
enum SettingsFmt {
  /// "7:00 PM".
  static func time(_ minutes: Int) -> String {
    let h = (minutes / 60) % 24, m = minutes % 60
    let h12 = h % 12 == 0 ? 12 : h % 12
    return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
  }

  /// Times every 30 minutes, plus `current` when it isn't on the grid.
  static func timeOptions(current: Int) -> [DSSelectOption<Int>] {
    var mins = Array(stride(from: 0, to: 24 * 60, by: 30))
    if !mins.contains(current) { mins.append(current); mins.sort() }
    return mins.map { DSSelectOption(value: $0, title: time($0)) }
  }

  static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
  static func hours(_ n: Double) -> String { n == 1 ? "1 hour" : "\(Int(n)) hours" }

  static func seconds(_ s: Double) -> String {
    let v = s.rounded() == s ? String(Int(s)) : String(format: "%.1f", s)
    return s == 1 ? "1 second" : "\(v) seconds"
  }

  /// Calendar weekday (1 = Sunday) as a full English name, independent of the process locale.
  static func weekday(_ d: Int) -> String {
    ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][((d - 1) % 7 + 7) % 7]
  }
}

/// Small numeric field for tables (limits): commits a positive integer, ignores anything else.
struct SettingsNumberField: View {
  let label: String
  let value: Int
  let commit: (Int) -> Void
  @State private var text = ""

  var body: some View {
    DSTextField(placeholder: "—", text: Binding(get: { text }, set: { t in
      text = t.filter(\.isNumber)
      if let v = Int(text), v > 0 { commit(v) }
    }), size: .sm)
    .multilineTextAlignment(.trailing)
    .accessibilityLabel(label)
    .onAppear { text = String(value) }
    .onChange(of: value) { _, v in if Int(text) != v { text = String(v) } }
  }
}
