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

private struct DSTooltipModifier: ViewModifier {
  let text: String?
  let shortcut: String?
  let edge: DSTooltipEdge
  let forceVisible: Bool
  @State private var hovering = false
  @State private var visible = false
  @State private var task: Task<Void, Never>?

  func body(content: Content) -> some View {
    if let text, !text.isEmpty {
      content
        .onHover { h in
          hovering = h
          task?.cancel()
          if h {
            task = Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(450))
              if !Task.isCancelled, hovering { visible = true }
            }
          } else {
            visible = false
          }
        }
        .overlay(alignment: edge == .top ? .top : .bottom) {
          if visible || forceVisible {
            DSTooltipBubble(text: text, shortcut: shortcut)
              .alignmentGuide(edge == .top ? VerticalAlignment.top : VerticalAlignment.bottom) { d in
                edge == .top ? d[.bottom] + 6 : d[.top] - 6
              }
              .transition(.opacity)
              .allowsHitTesting(false)
          }
        }
        .zIndex(visible || forceVisible ? 10 : 0)
        .accessibilityHint(Text(text))
    } else {
      content
    }
  }
}

extension View {
  /// Custom hover tooltip (inverse bubble). Pass nil to show nothing. `forceVisible` is for the gallery.
  /// In containers that clip (ScrollView edges) prefer `edge: .bottom` near the top edge.
  func dsTooltip(_ text: String?, shortcut: String? = nil, edge: DSTooltipEdge = .top, forceVisible: Bool = false) -> some View {
    modifier(DSTooltipModifier(text: text, shortcut: shortcut, edge: edge, forceVisible: forceVisible))
  }
}
