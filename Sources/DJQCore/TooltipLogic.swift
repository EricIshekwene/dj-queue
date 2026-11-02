import CoreGraphics
import Foundation

// Pure tooltip rules used by the app's DSTooltip (design/TOOLTIPS-DECISIONS.md). Kept in core so they are unit
// tested: where the bubble goes (Base UI Positioner: side + align center + offset, flip on collision, then shift
// along the cross axis), how long to wait (Base UI Provider delay group) and how a shortcut splits into keycaps.

/// Which side of the trigger the bubble sits on.
public enum TooltipSide: String, CaseIterable, Sendable {
  case top, bottom, leading, trailing

  public var opposite: TooltipSide {
    switch self {
    case .top: .bottom
    case .bottom: .top
    case .leading: .trailing
    case .trailing: .leading
    }
  }

  var isVertical: Bool { self == .top || self == .bottom }
}

public enum TooltipPlacement {
  /// Places a bubble of `size` next to `anchor`, inside `bounds`. Coordinates are y-up (AppKit screen space).
  /// Order of tries: preferred side, its opposite, then the two remaining sides. The first side whose main axis
  /// fits wins; if none fits, the preferred side is kept. The cross axis is then centred on the anchor and shifted
  /// to stay inside `bounds` (Base UI `collisionAvoidance: flip + shift`).
  public static func place(anchor: CGRect, size: CGSize, preferred: TooltipSide, bounds: CGRect,
                           gap: CGFloat = 6) -> (frame: CGRect, side: TooltipSide) {
    let others = TooltipSide.allCases.filter { $0 != preferred && $0 != preferred.opposite }
    let order = [preferred, preferred.opposite] + others
    let side = order.first { fitsMainAxis($0, anchor: anchor, size: size, bounds: bounds, gap: gap) } ?? preferred
    var f = raw(side, anchor: anchor, size: size, gap: gap)
    // Shift on the cross axis (and, as a last resort, clamp the main axis) so the bubble never leaves bounds.
    if side.isVertical {
      f.origin.x = clamp(f.origin.x, bounds.minX, bounds.maxX - size.width)
    } else {
      f.origin.y = clamp(f.origin.y, bounds.minY, bounds.maxY - size.height)
    }
    f.origin.x = clamp(f.origin.x, bounds.minX, bounds.maxX - size.width)
    f.origin.y = clamp(f.origin.y, bounds.minY, bounds.maxY - size.height)
    return (f.integral, side)
  }

  static func raw(_ side: TooltipSide, anchor a: CGRect, size s: CGSize, gap: CGFloat) -> CGRect {
    switch side {
    case .top: CGRect(x: a.midX - s.width / 2, y: a.maxY + gap, width: s.width, height: s.height)
    case .bottom: CGRect(x: a.midX - s.width / 2, y: a.minY - gap - s.height, width: s.width, height: s.height)
    case .leading: CGRect(x: a.minX - gap - s.width, y: a.midY - s.height / 2, width: s.width, height: s.height)
    case .trailing: CGRect(x: a.maxX + gap, y: a.midY - s.height / 2, width: s.width, height: s.height)
    }
  }

  static func fitsMainAxis(_ side: TooltipSide, anchor: CGRect, size: CGSize, bounds: CGRect, gap: CGFloat) -> Bool {
    let f = raw(side, anchor: anchor, size: size, gap: gap)
    switch side {
    case .top: return f.maxY <= bounds.maxY
    case .bottom: return f.minY >= bounds.minY
    case .leading: return f.minX >= bounds.minX
    case .trailing: return f.maxX <= bounds.maxX
    }
  }

  /// Clamp that tolerates an inverted range (bubble wider than bounds → pin to the minimum edge).
  static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
}

/// Base UI `Tooltip.Provider` delay group: the first tooltip waits `delay`; while one is open, or within
/// `timeout` after it closed, moving to another trigger opens it instantly (no animation).
public struct TooltipDelayGroup: Sendable {
  public var delay: TimeInterval
  public var timeout: TimeInterval
  public private(set) var isOpen = false
  public private(set) var lastClosed: Date = .distantPast

  public init(delay: TimeInterval = 0.5, timeout: TimeInterval = 0.4) {
    self.delay = delay
    self.timeout = timeout
  }

  /// Seconds to wait before opening a tooltip now (0 = instant, part of the group).
  public func openDelay(now: Date) -> TimeInterval {
    isOpen || now.timeIntervalSince(lastClosed) < timeout ? 0 : delay
  }

  public mutating func opened() { isOpen = true }

  /// `resetGroup` (press, scroll, Escape) ends the group so the next tooltip waits the full delay again.
  public mutating func closed(at now: Date, resetGroup: Bool = false) {
    if resetGroup { lastClosed = .distantPast } else if isOpen { lastClosed = now }
    isOpen = false
  }
}

public enum TooltipKeys {
  /// Splits a shortcut into keycaps: "⇧⌘K" → ["⇧", "⌘", "K"], "⌘↩" → ["⌘", "↩"], "esc" → ["esc"],
  /// "⌘ ," → ["⌘", ","], "G then E" → ["G", "then", "E"]. Leading modifier glyphs become their own caps; the
  /// rest of a word stays one cap.
  public static func split(_ shortcut: String) -> [String] {
    var caps: [String] = []
    for word in shortcut.split(separator: " ", omittingEmptySubsequences: true) {
      var rest = Substring(word)
      while let c = rest.first, ["⌘", "⇧", "⌥", "⌃"].contains(c), rest.count > 1 {
        caps.append(String(c))
        rest = rest.dropFirst()
      }
      if !rest.isEmpty { caps.append(String(rest)) }
    }
    return caps
  }
}
