import AppKit
import SwiftUI

/// `.onHover` for anything that starts a preview or gives it sound: `action(true)` while the pointer is really on the
/// view, `action(false)` as soon as it isn't. Controls that appear on hover keep plain `.onHover`, because taking one
/// away while its menu is open would close the menu.
extension View {
  func dsPlaybackHover(_ action: @escaping (Bool) -> Void) -> some View { modifier(DSPlaybackHoverModifier(action: action)) }
}

private struct DSPlaybackHoverModifier: ViewModifier {
  let action: (Bool) -> Void
  @State private var box = DSPlaybackHoverBox()

  func body(content: Content) -> some View {
    content
      .background(DSPlaybackHoverAnchor(box: box, action: action).allowsHitTesting(false))
      .onHover { inside in
        if let v = box.view { DSPlaybackHoverGuard.shared.swiftUIHover(v, inside: inside) }
      }
  }
}

/// Lets the hover handler reach the view that `makeNSView` created.
@MainActor
private final class DSPlaybackHoverBox {
  weak var view: DSPlaybackHoverView?
}

private struct DSPlaybackHoverAnchor: NSViewRepresentable {
  let box: DSPlaybackHoverBox
  let action: (Bool) -> Void

  func makeNSView(context: Context) -> DSPlaybackHoverView {
    let v = DSPlaybackHoverView()
    box.view = v
    return v
  }

  func updateNSView(_ v: DSPlaybackHoverView, context: Context) {
    box.view = v
    v.action = action
  }
}

/// Where a hover region is on screen. Never takes the pointer.
final class DSPlaybackHoverView: NSView {
  var action: ((Bool) -> Void)?
  /// SwiftUI says the pointer is here.
  fileprivate var reported = false
  /// What `action` last heard.
  fileprivate var delivered = false

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { DSPlaybackHoverGuard.shared.gone(self) }
  }

  /// The visible part of the region (a scroll view clips it), in screen coordinates.
  var visibleScreenRect: CGRect? {
    guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
    let r = bounds.intersection(visibleRect)
    guard r.width > 0.5, r.height > 0.5 else { return nil }
    return window.convertToScreen(convert(r, to: nil))
  }
}

/// SwiftUI only reports a hover exit when a mouse-moved event reaches the window, so it says nothing when the view
/// scrolls out from under a still pointer, while a menu or a drag has the mouse, or when the window goes to the
/// background. While SwiftUI says a region is hovered, this checks ten times a second that it's true: the pointer is
/// inside the region, its window has focus and no menu is open. If not, the region reads as left; if it becomes true
/// again while SwiftUI still says hovered (a menu closed with the pointer on the card), it reads as entered.
@MainActor
final class DSPlaybackHoverGuard {
  static let shared = DSPlaybackHoverGuard()

  private var hovered: [DSPlaybackHoverView] = []
  private var timer: Timer?
  private var menuOpen = false

  private init() {
    let center = NotificationCenter.default
    // Delivered on the posting thread (AppKit posts these on main), so the guard is up before the menu draws.
    _ = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.menuOpen = true; self?.recheck() }
    }
    _ = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.menuOpen = false; self?.recheck() }
    }
  }

  func swiftUIHover(_ v: DSPlaybackHoverView, inside: Bool) {
    if let sim = simulatedPointer, (v.visibleScreenRect?.contains(sim) ?? false) != inside {
      debugRealCursorHovers += 1  // the user's real cursor, not the probe's pointer
      return
    }
    report(v, inside: inside)
  }

  func gone(_ v: DSPlaybackHoverView) {
    report(v, inside: false)
  }

  private func report(_ v: DSPlaybackHoverView, inside: Bool) {
    v.reported = inside
    hovered.removeAll { $0 === v }
    if inside { hovered.append(v) }
    deliver(v, inside && pointerIsOn(v))
    if hovered.isEmpty {
      timer?.invalidate()
      timer = nil
    } else if timer == nil {
      // Common modes: the check keeps running while a menu or a drag has the run loop.
      let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.recheck() } }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
  }

  private func recheck() {
    for v in hovered { deliver(v, pointerIsOn(v)) }
  }

  private func deliver(_ v: DSPlaybackHoverView, _ on: Bool) {
    guard on != v.delivered else { return }
    v.delivered = on
    v.action?(on)
  }

  private func pointerIsOn(_ v: DSPlaybackHoverView) -> Bool {
    guard !menuOpen, let w = v.window, w.isVisible, simulatedFocus ?? (NSApp.isActive && w.isKeyWindow),
          let r = v.visibleScreenRect else { return false }
    // 1 pt of slack: SwiftUI can call a point on the edge inside.
    return r.insetBy(dx: -1, dy: -1).contains(simulatedPointer ?? NSEvent.mouseLocation)
  }

  // MARK: Evidence hooks (DSHoverProbe only; never set in the app)

  /// Probe pointer in screen coordinates (replaces the real cursor).
  var simulatedPointer: CGPoint?
  /// Probe's "window has focus" (the probe never activates the app).
  var simulatedFocus: Bool?
  /// SwiftUI hover events dropped because they followed the real cursor, not the probe's pointer.
  var debugRealCursorHovers = 0

  /// The enter/exit pairs a pointer moving to `p` would produce.
  func debugPointerMoved(to p: CGPoint, in w: NSWindow) {
    simulatedPointer = p
    func walk(_ v: NSView) {
      if let h = v as? DSPlaybackHoverView {
        let inside = h.visibleScreenRect?.contains(p) ?? false
        if inside != h.reported { report(h, inside: inside) }
      }
      v.subviews.forEach(walk)
    }
    if let root = w.contentView { walk(root) }
  }
}
