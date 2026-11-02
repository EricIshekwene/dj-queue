import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

/// DSTooltip rules (design/TOOLTIPS-DECISIONS.md): placement with flip + shift, the delay group, keycaps.
@Suite struct TooltipLogicTests {
  let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)  // y-up, like AppKit screen space
  let size = CGSize(width: 120, height: 26)

  @Test func topIsCentredAboveWithGap() {
    let a = CGRect(x: 400, y: 300, width: 28, height: 28)
    let p = TooltipPlacement.place(anchor: a, size: size, preferred: .top, bounds: bounds, gap: 6)
    #expect(p.side == .top)
    #expect(p.frame.minY == a.maxY + 6)
    #expect(abs(p.frame.midX - a.midX) <= 0.5)
  }

  @Test func flipsToBottomAtTheTopEdge() {
    // Toolbar button 10 pt under the window's top edge: no room above.
    let a = CGRect(x: 400, y: 662, width: 28, height: 28)
    let p = TooltipPlacement.place(anchor: a, size: size, preferred: .top, bounds: bounds, gap: 6)
    #expect(p.side == .bottom)
    #expect(p.frame.maxY == a.minY - 6)
  }

  @Test func flipsToTopAtTheBottomEdge() {
    let a = CGRect(x: 400, y: 4, width: 28, height: 28)
    let p = TooltipPlacement.place(anchor: a, size: size, preferred: .bottom, bounds: bounds, gap: 6)
    #expect(p.side == .top)
    #expect(bounds.contains(p.frame))
  }

  @Test func shiftsAlongTheCrossAxisNearSideEdges() {
    let left = TooltipPlacement.place(anchor: CGRect(x: 2, y: 300, width: 28, height: 28), size: size, preferred: .top, bounds: bounds)
    #expect(left.side == .top && left.frame.minX == 0)
    let right = TooltipPlacement.place(anchor: CGRect(x: 980, y: 300, width: 20, height: 28), size: size, preferred: .top, bounds: bounds)
    #expect(right.side == .top && right.frame.maxX == 1000)
  }

  @Test func sideTooltipsFlipHorizontally() {
    let a = CGRect(x: 960, y: 300, width: 28, height: 28)
    let p = TooltipPlacement.place(anchor: a, size: size, preferred: .trailing, bounds: bounds, gap: 6)
    #expect(p.side == .leading)
    #expect(p.frame.maxX == a.minX - 6)
  }

  @Test func neverLeavesBoundsEvenWhenNothingFits() {
    let tiny = CGRect(x: 0, y: 0, width: 100, height: 40)
    let p = TooltipPlacement.place(anchor: CGRect(x: 40, y: 10, width: 20, height: 20), size: size, preferred: .top, bounds: tiny)
    #expect(p.frame.minX == 0 && p.frame.minY >= 0)
  }

  @Test func delayGroupOpensInstantlyWhileOpenOrJustClosed() {
    var g = TooltipDelayGroup(delay: 0.5, timeout: 0.4)
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    #expect(g.openDelay(now: t0) == 0.5)
    g.opened()
    #expect(g.openDelay(now: t0) == 0)
    g.closed(at: t0)
    #expect(g.openDelay(now: t0.addingTimeInterval(0.2)) == 0)
    #expect(g.openDelay(now: t0.addingTimeInterval(0.5)) == 0.5)
  }

  @Test func pressScrollOrKeyResetsTheGroup() {
    var g = TooltipDelayGroup(delay: 0.5, timeout: 0.4)
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    g.opened()
    g.closed(at: t0, resetGroup: true)
    #expect(g.openDelay(now: t0.addingTimeInterval(0.1)) == 0.5)
  }

  @Test func shortcutsSplitIntoKeycaps() {
    #expect(TooltipKeys.split("⇧⌘K") == ["⇧", "⌘", "K"])
    #expect(TooltipKeys.split("⌘↩") == ["⌘", "↩"])
    #expect(TooltipKeys.split("esc") == ["esc"])
    #expect(TooltipKeys.split("⌘ ,") == ["⌘", ","])
    #expect(TooltipKeys.split("⌘") == ["⌘"])
    #expect(TooltipKeys.split("G then E") == ["G", "then", "E"])
  }
}
