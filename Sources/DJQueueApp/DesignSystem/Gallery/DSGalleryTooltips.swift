import AppKit
import DJQCore
import SwiftUI

// MARK: - 8 Tooltips (design/TOOLTIPS-DECISIONS.md)

/// Every tooltip state, drawn in place (`forceVisible`) so snapshots show them. In the running app the same bubble
/// is a floating panel positioned by `TooltipPlacement` — the "Collision" section draws that algorithm's real output.
struct GalleryTooltips: View {
  var body: some View {
    HStack(alignment: .top, spacing: DS.space.xl) {
      VStack(alignment: .leading, spacing: DS.space.xl) {
        GSection("Anatomy", note: "trigger · positioner (side, 6 pt offset, flip + shift) · popup · keycaps") {
          HStack(spacing: DS.space.xl) {
            ForEach(TooltipSide.allCases, id: \.self) { side in
              GCell(side.rawValue.capitalized) {
                DSIconButton("square.and.arrow.up", tooltip: "Share", variant: .outline) {}
                  .dsTooltip("Share", side: side, forceVisible: true)
                  .padding(.vertical, side.isHorizontalDemo ? 0 : 30)
              }
              .frame(width: side.isHorizontalDemo ? 150 : 80, height: 110)
            }
          }
        }
        GSection("Content", note: "short verb phrase · optional shortcut · disabled reason") {
          VStack(alignment: .leading, spacing: DS.space.lg) {
          HStack(alignment: .bottom, spacing: DS.space.xl) {
            demo("Label") {
              DSIconButton("pin", tooltip: "Pin to its date", variant: .ghost) {}
            } bubble: { DSTooltipBubble(text: "Pin to its date") }
            demo("Label + shortcut") {
              DSIconButton("slider.horizontal.3", tooltip: "Open editor", variant: .ghost, shortcut: "⌘E") {}
            } bubble: { DSTooltipBubble(text: "Open editor", shortcut: "⌘E") }
            demo("Modifier keys split") {
              DSIconButton("command", tooltip: "Search commands", variant: .ghost, shortcut: "⇧⌘K") {}
            } bubble: { DSTooltipBubble(text: "Search commands", shortcut: "⇧⌘K") }
          }
          HStack(alignment: .bottom, spacing: DS.space.xl) {
            demo("Disabled — says why", width: 260) {
              DSButton("Post today", icon: "bolt", variant: .outline, disabledReason: "Instagram isn't rendered yet") {}
            } bubble: { DSTooltipBubble(text: "Post today", shortcut: "⌘T", disabledReason: "Instagram isn't rendered yet — usually ready within a minute") }
            demo("Reason only", width: 200) {
              DSButton("Approve week", variant: .primary, size: .sm, disabledReason: "Nothing planned this week") {}
            } bubble: { DSTooltipBubble(DSTooltipContent(disabledReason: "Nothing planned this week")) }
          }
          }
        }
        GSection("In context", note: "toolbar · icon segmented · ⋯ · bulk bar") {
          VStack(alignment: .leading, spacing: 64) {
            DSToolbar("Queue", subtitle: "41 ready · next Thu 5 Nov") {
              EmptyView()
            } trailing: {
              GState(DSViewMode.grid) { DSViewModeSwitcher(mode: $0, size: .sm) }
              DSIconButton("ellipsis", tooltip: "More actions", size: .sm) {}
                .dsTooltip("More actions", side: .bottom, forceVisible: true)
              DSButton("Approve week", variant: .primary, size: .sm, shortcut: "⌘↩") {}
            }
            .dsSurface(DS.color.background, radius: DS.radius.lg)
            .frame(width: 680)
            DSBulkBar(count: 4, onClear: {}) {
              Button {} label: { Label("Post today", systemImage: "bolt") }
                .dsTooltip("Post the 4 clips today, before the planned ones", forceVisible: true)
              Button {} label: { Label("Exclude", systemImage: "eye.slash") }
            }
            .frame(width: 680)
          }
          .padding(.top, 36)
        }
      }
      VStack(alignment: .leading, spacing: DS.space.xl) {
        GSection("Collision", note: "TooltipPlacement output · preferred side top") {
          GalleryCollisionDemo().frame(width: 360, height: 250)
        }
        GSection("Wraps at 280 pt", note: "max 3 lines label · 4 lines reason") {
          DSTooltipBubble(text: "Remove from queue — goes back to Edit; future unposted slots are cleared, posted ones stay",
                          shortcut: "⌫")
            .frame(width: DSTooltipBubble.maxWidth, alignment: .leading)
        }
        GSection("Behaviour") {
          VStack(alignment: .leading, spacing: 6) {
            rule("Opens after 500 ms of hover; moving to another trigger within 400 ms opens it at once, without animation.")
            rule("Closes on press, scroll, any key (Esc), app switch or window move. A pressed trigger stays closed until the pointer leaves.")
            rule("Disabled controls keep their tooltip: hover is tracked by an AppKit tracking area, not hit-testing.")
            rule("Floats in its own click-through panel above the window — never clipped by cards, lists or sidebars.")
            rule("Fade + 4 pt slide in 120 ms. Reduce Motion: fade only. No shadow in dark mode.")
            rule("VoiceOver reads the same text as the trigger's hint; the panel itself is hidden from accessibility.")
          }
          .frame(width: 360, alignment: .leading)
        }
        GSection("Writing") {
          VStack(alignment: .leading, spacing: 6) {
            rule("Start with a verb and say the consequence: “Post today, before the planned ones”, not “Bolt”.")
            rule("Sentence case, no full stop, ≤ 45 characters. Shortcut as keycaps, never in the text.")
            rule("Disabled: label first, then why and how to fix it.")
            rule("A visible label that already says it all needs no tooltip.")
          }
          .frame(width: 360, alignment: .leading)
        }
      }
    }
  }

  private func demo<T: View, B: View>(_ label: String, width: CGFloat = 170, @ViewBuilder trigger: () -> T,
                                      @ViewBuilder bubble: () -> B) -> some View {
    VStack(alignment: .center, spacing: 6) {
      bubble().fixedSize(horizontal: false, vertical: true)
      trigger()
      Text(label).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).padding(.top, 4)
    }
    .frame(width: width)
  }

  private func rule(_ s: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("·").foregroundStyle(DS.color.textTertiary)
      Text(s).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A mock window with triggers at its edges; each bubble is placed by the production algorithm.
private struct GalleryCollisionDemo: View {
  struct Case: Identifiable {
    let id: String
    let trigger: CGRect  // y-down, in the mock window
    let label: String
  }

  let window = CGSize(width: 360, height: 250)
  let bubble = CGSize(width: 128, height: 26)
  var cases: [Case] {
    [
      Case(id: "tl", trigger: CGRect(x: 8, y: 8, width: 28, height: 28), label: "Flipped below"),
      Case(id: "tr", trigger: CGRect(x: 324, y: 8, width: 28, height: 28), label: "Flipped + shifted"),
      Case(id: "mid", trigger: CGRect(x: 166, y: 110, width: 28, height: 28), label: "Top: room above"),
      Case(id: "br", trigger: CGRect(x: 324, y: 186, width: 28, height: 28), label: "Shifted left"),
    ]
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous).strokeBorder(DS.color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      Text("window bounds").font(DS.type.micro).foregroundStyle(DS.color.textTertiary).offset(x: 130, y: 232)
      ForEach(cases) { c in
        let placed = place(c.trigger)
        Circle().fill(DS.color.surfaceSunken).overlay(Circle().strokeBorder(DS.color.borderStrong))
          .overlay(Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.color.text))
          .frame(width: c.trigger.width, height: c.trigger.height)
          .offset(x: c.trigger.minX, y: c.trigger.minY)
        DSTooltipBubble(text: c.label)
          .frame(width: placed.width, height: placed.height, alignment: .center)
          .offset(x: placed.minX, y: placed.minY)
      }
    }
    .frame(width: window.width, height: window.height, alignment: .topLeading)
  }

  /// Converts the y-down mock into y-up space, runs TooltipPlacement, converts back.
  private func place(_ t: CGRect) -> CGRect {
    let flip = { (r: CGRect) in CGRect(x: r.minX, y: window.height - r.maxY, width: r.width, height: r.height) }
    let bounds = CGRect(origin: .zero, size: window).insetBy(dx: 6, dy: 6)
    let p = TooltipPlacement.place(anchor: flip(t), size: bubble, preferred: .top, bounds: bounds, gap: 6)
    return flip(p.frame)
  }
}

private extension TooltipSide {
  var isHorizontalDemo: Bool { self == .leading || self == .trailing }
}
