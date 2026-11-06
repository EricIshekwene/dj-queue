import AppKit
import SwiftUI

/// A collapsible row (Kit and Better Stack's "Advanced options"): title, a quiet summary of what's inside, and a chevron at
/// the right, the whole row clickable. A problem inside shows on the closed row, so closing never hides one.
struct DSDisclosure<Content: View>: View {
  /// `.section` reads as a section title, `.field` as a row inside a section.
  enum Level { case section, field }

  let title: String
  /// What's inside, shown while closed.
  var summary: String? = nil
  /// A problem inside, shown instead of the summary while closed.
  var attention: String? = nil
  var level: Level = .field
  @Binding var isOpen: Bool
  @ViewBuilder var content: Content
  @State private var hovering = false

  init(_ title: String, summary: String? = nil, attention: String? = nil, level: Level = .field, isOpen: Binding<Bool>,
       @ViewBuilder content: () -> Content) {
    self.title = title
    self.summary = summary
    self.attention = attention
    self.level = level
    _isOpen = isOpen
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { dsWithAnimation { isOpen.toggle() } } label: { row }
        .buttonStyle(.plain)
        .dsTooltip(isOpen ? "Hide \(title)" : attention.map { "Show \(title): \($0)" } ?? "Show \(title)")
        .background(ScriptAnchor(title))
        .probeFrame("disclosure-\(title)")
      if isOpen {
        content
          .padding(.top, level == .section ? DS.space.md : DS.space.xs)
          .padding(.bottom, level == .section ? 0 : DS.space.sm)
          .transition(.opacity)
      }
    }
  }

  private var row: some View {
    HStack(spacing: DS.space.xs) {
      Text(title).font(level == .section ? DS.type.headline : DS.type.calloutMedium)
        .foregroundStyle(level == .section ? DS.color.text : DS.color.textSecondary)
      Spacer(minLength: DS.space.xs)
      if !isOpen {
        if let attention {
          HStack(spacing: 5) {
            Circle().fill(DS.color.warning).frame(width: 6, height: 6)
            Text(attention).lineLimit(1)
          }
          .font(DS.type.caption).foregroundStyle(DS.color.warning)
        } else if let summary {
          Text(summary).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary).lineLimit(1)
        }
      }
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(hovering ? DS.color.textSecondary : DS.color.textTertiary)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
        .frame(width: 14, height: 14)
    }
    .frame(height: level == .section ? 28 : 32)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .dsAnimation(DS.motion.hover, value: hovering)
  }
}

/// Preset colours plus a custom well (Hootsuite and Instagram's swatch rows): the swatches are one tap, the well opens the
/// system's colour panel. Colours are "#RRGGBB" strings, the way the data stores them.
struct DSColorSwatches: View {
  /// One preset. Its colour is data, so it's drawn as is rather than from a token.
  struct Swatch: Identifiable, Hashable {
    let hex: String
    let name: String
    var id: String { hex }
  }

  let name: String
  let swatches: [Swatch]
  /// The colour in use now (a default counts): the swatch it matches is ringed, and the well shows it.
  let selection: String
  var disabledReason: String? = nil
  /// A swatch was tapped: one change.
  var onPick: (String) -> Void
  /// The well moved. It fires many times while the panel is dragged, so the receiver coalesces.
  var onCustom: (String) -> Void

  static let size: CGFloat = 22

  var body: some View {
    HStack(spacing: DS.space.xxs) {
      ForEach(swatches) { s in tile(s) }
      Spacer(minLength: DS.space.xxs)
      ColorPicker("", selection: Binding(get: { Color(dsHex: selection) }, set: { c in
        if let h = c.dsHex { onCustom(h) }
      }), supportsOpacity: false)
        .labelsHidden()
        .disabled(disabledReason != nil)
        .opacity(disabledReason == nil ? 1 : 0.55)
        .dsTooltip("Pick any \(name)", disabledReason: disabledReason)
        .accessibilityLabel("Custom \(name)")
    }
  }

  private func tile(_ s: Swatch) -> some View {
    let on = s.hex == selection
    return Button { if disabledReason == nil && !on { onPick(s.hex) } } label: {
      Circle().fill(Color(dsHex: s.hex))
        .overlay(Circle().strokeBorder(DS.color.borderStrong, lineWidth: 1))
        .frame(width: Self.size - 4, height: Self.size - 4)
        .overlay(Circle().strokeBorder(on ? DS.color.text : Color.clear, lineWidth: 2).padding(-2))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(disabledReason == nil ? 1 : 0.55)
    .dsTooltip(on ? "\(s.name) is the \(name)" : "Use \(s.name.lowercased()) for the \(name)", disabledReason: disabledReason)
    .background(ScriptAnchor("swatch \(name) \(s.name)"))
    .accessibilityLabel("\(s.name) \(name)")
  }
}

extension Color {
  /// A stored "#RRGGBB" (never a theme colour: text on a video looks the same in light and dark).
  init(dsHex hex: String) {
    let n = Int(hex.drop { $0 == "#" }, radix: 16) ?? 0
    self.init(.sRGB, red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
  }

  /// "#RRGGBB" in sRGB, how a colour is stored.
  var dsHex: String? {
    guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
    func v(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", v(c.redComponent), v(c.greenComponent), v(c.blueComponent))
  }
}
