import CoreGraphics

/// The test behind `ScreenGuard`: which of a run's windows show on a display. Rects share one coordinate space.
public enum ScreenGuardLogic {
  public struct Seen: Equatable, Sendable {
    public var bounds: CGRect
    public var alpha: Double
    public init(bounds: CGRect, alpha: Double) { self.bounds = bounds; self.alpha = alpha }
  }

  /// A window breaks the rule when any visible part of it lands on a display.
  public static func onScreen(_ windows: [Seen], displays: [CGRect]) -> [Seen] {
    windows.filter { w in
      w.alpha > 0 && !w.bounds.isEmpty && displays.contains { $0.intersects(w.bounds) }
    }
  }
}
