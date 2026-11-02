import SwiftUI

/// Base UI Tooltip anatomy: Trigger → Positioner → Popup (+ optional shortcut). A small inverse bubble that
/// appears after a short hover delay. Every icon-only control and every disabled control must have one.
struct DSTooltipBubble: View {
  let text: String
  var shortcut: String? = nil

  var body: some View {
    HStack(spacing: 6) {
      Text(text).font(DS.type.captionMedium).lineLimit(2).multilineTextAlignment(.leading)
      if let shortcut {
        Text(shortcut).font(DS.type.caption).opacity(0.6)
      }
    }
    .foregroundStyle(DS.color.inverseText)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(DS.color.inverseSurface, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .dsElevation(DS.elevation.e2)
    .fixedSize()
    .accessibilityHidden(true)
  }
}

enum DSTooltipEdge { case top, bottom }

/// Tooltips are native (`.help`): reliable over clipping containers, disabled-looking controls and every window
/// level, with system delay and accessibility. The styled bubble above is drawn only when `forceVisible`
/// (gallery/snapshots) at a fixed offset — see DS-DECISIONS.md (custom hover positioning was fragile).
private struct DSTooltipModifier: ViewModifier {
  let text: String?
  let shortcut: String?
  let edge: DSTooltipEdge
  let forceVisible: Bool

  func body(content: Content) -> some View {
    if let text, !text.isEmpty {
      content
        .help(shortcut.map { "\(text)  \($0)" } ?? text)
        .overlay(alignment: edge == .top ? .top : .bottom) {
          if forceVisible {
            DSTooltipBubble(text: text, shortcut: shortcut)
              .offset(y: edge == .top ? -32 : 32)
              .allowsHitTesting(false)
          }
        }
        .accessibilityHint(Text(text))
    } else {
      content
    }
  }
}

extension View {
  /// Tooltip for icon-only and disabled controls (native `.help`). Pass nil for none. `forceVisible` draws the
  /// styled bubble for the gallery.
  func dsTooltip(_ text: String?, shortcut: String? = nil, edge: DSTooltipEdge = .top, forceVisible: Bool = false) -> some View {
    modifier(DSTooltipModifier(text: text, shortcut: shortcut, edge: edge, forceVisible: forceVisible))
  }
}
