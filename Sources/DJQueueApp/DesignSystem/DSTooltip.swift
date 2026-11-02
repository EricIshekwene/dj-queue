import AppKit
import DJQCore
import SwiftUI

// DSTooltip — Base UI / shadcn Tooltip anatomy, built natively (design/TOOLTIPS-DECISIONS.md):
//   Provider  → `DSTooltipController.shared` (one delay group for the whole app: 500 ms, instant re-open for 400 ms)
//   Trigger   → any view with `.dsTooltip(…)`: SwiftUI hover (respects z-order, in-window modals and scroll
//               clipping; fires on soft-disabled DS controls) + an invisible AppKit anchor view for the geometry
//   Positioner→ `TooltipPlacement.place` (DJQCore): side + centre align + 6 pt offset, flip, shift; bounded by the
//               window (∩ screen), so nothing is clipped by scroll views, cards or sidebars
//   Popup     → `DSTooltipBubble` hosted in a borderless, non-activating, click-through NSPanel
// Closes on press, scroll, any key (Escape included), app switch, and when the trigger leaves the window.
// VoiceOver gets the same text as the accessibility hint. No native `.help` — it would show a second bubble.

typealias DSTooltipSide = TooltipSide
/// Round-2 name, kept so existing `edge:` call sites compile.
typealias DSTooltipEdge = TooltipSide

/// What a tooltip says: a short verb phrase, an optional shortcut, and — for a disabled trigger — why.
struct DSTooltipContent: Equatable {
  var label: String?
  var shortcut: String?
  var disabledReason: String?
  /// A label view instead of `label` — used where only a view is at hand (a `Label`'s title drawn icon-only).
  var richLabel: AnyView? = nil

  var isEmpty: Bool { (label ?? "").isEmpty && (disabledReason ?? "").isEmpty && richLabel == nil }

  static func == (a: Self, b: Self) -> Bool {
    a.label == b.label && a.shortcut == b.shortcut && a.disabledReason == b.disabledReason && (a.richLabel == nil) == (b.richLabel == nil)
  }
  /// Spoken by VoiceOver (as the hint).
  var spoken: String { [label, disabledReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ") }
}

/// The popup: inverse surface (near-black on light, near-white on dark), r.sm, caption type, keycaps.
/// Disabled triggers show the label, then the reason on its own line.
struct DSTooltipBubble: View {
  let content: DSTooltipContent
  static let maxWidth: CGFloat = 280

  init(_ content: DSTooltipContent) { self.content = content }
  init(text: String, shortcut: String? = nil, disabledReason: String? = nil) {
    content = DSTooltipContent(label: text, shortcut: shortcut, disabledReason: disabledReason)
  }

  var body: some View {
    let label = (content.label ?? "").isEmpty ? nil : content.label
    let reason = (content.disabledReason ?? "").isEmpty ? nil : content.disabledReason
    VStack(alignment: .leading, spacing: 2) {
      if let rich = content.richLabel {
        rich.font(DS.type.captionMedium).lineLimit(2).labelStyle(.titleOnly)
      } else if let title = label ?? reason {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title).font(DS.type.captionMedium).lineLimit(3).fixedSize(horizontal: false, vertical: true)
          if reason == nil, let shortcut = content.shortcut, !shortcut.isEmpty {
            DSTooltipKeys(shortcut)
          }
        }
      }
      if label != nil, let reason {
        Text(reason).font(DS.type.caption).opacity(0.72).lineLimit(4).fixedSize(horizontal: false, vertical: true)
      }
    }
    .multilineTextAlignment(.leading)
    .foregroundStyle(DS.color.inverseText)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(DS.color.inverseSurface, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// shadcn `KbdGroup` inside a tooltip: one keycap per key ("⇧⌘K" → ⇧ ⌘ K).
struct DSTooltipKeys: View {
  let keys: [String]
  init(_ shortcut: String) { keys = TooltipKeys.split(shortcut) }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
        Text(k)
          .font(DS.type.micro)
          .foregroundStyle(DS.color.inverseText.opacity(0.8))
          .padding(.horizontal, 4)
          .frame(minWidth: 16, minHeight: 16)
          .background(DS.color.inverseText.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      }
    }
    .fixedSize()
  }
}

/// Sizes the popup like Base UI's: its natural width up to `maxWidth`, then wraps (height follows).
struct DSTooltipFit: Layout {
  var maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let v = subviews.first else { return .zero }
    let w = min(v.sizeThatFits(.unspecified).width, maxWidth)
    return v.sizeThatFits(ProposedViewSize(width: w, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

// MARK: - Modifier

private struct DSTooltipModifier: ViewModifier {
  let content: DSTooltipContent
  let side: TooltipSide
  let forceVisible: Bool
  @Environment(\.colorScheme) private var scheme
  @State private var box = DSTooltipAnchorBox()

  func body(content view: Content) -> some View {
    if content.isEmpty {
      view
    } else {
      view
        .background(DSTooltipAnchor(content: content, side: side, scheme: scheme, box: box).allowsHitTesting(false))
        .onHover { inside in
          guard let a = box.view else { return }
          if inside { DSTooltipController.shared.debugHoverEvents += 1; DSTooltipController.shared.hoverBegan(a) } else { DSTooltipController.shared.hoverEnded(a) }
        }
        .overlay(alignment: side.overlayAlignment) {
          if forceVisible || DSTooltipController.forcedLabels.contains(content.label ?? content.disabledReason ?? "") { staticBubble }
        }
        .accessibilityHint(Text(content.spoken))
    }
  }

  /// Gallery/snapshot rendering: the bubble drawn in place, 6 pt from the trigger (the real one is a panel).
  /// A zero-thickness strip on the trigger's edge carries the bubble, which hangs off it on the outside.
  @ViewBuilder private var staticBubble: some View {
    let b = DSTooltipBubble(content).fixedSize().allowsHitTesting(false)
    switch side {
    case .top: Color.clear.frame(height: 0).overlay(alignment: .bottom) { b.padding(.bottom, 6) }
    case .bottom: Color.clear.frame(height: 0).overlay(alignment: .top) { b.padding(.top, 6) }
    case .leading: Color.clear.frame(width: 0).overlay(alignment: .trailing) { b.padding(.trailing, 6) }
    case .trailing: Color.clear.frame(width: 0).overlay(alignment: .leading) { b.padding(.leading, 6) }
    }
  }
}

private extension TooltipSide {
  var overlayAlignment: Alignment {
    switch self {
    case .top: .top
    case .bottom: .bottom
    case .leading: .leading
    case .trailing: .trailing
    }
  }
}

extension View {
  /// Tooltip whose label is a view (e.g. a `Label`'s title shown icon-only on media). Prefer `dsTooltip(_:)`.
  func dsTooltip<V: View>(view: V, side: DSTooltipSide = .top) -> some View {
    modifier(DSTooltipModifier(content: DSTooltipContent(richLabel: AnyView(view)), side: side, forceVisible: false))
  }

  /// Hover tooltip (Base UI anatomy). `text` is a short verb phrase ("Post today"), `shortcut` shows as keycaps,
  /// `disabledReason` (non-nil = the control is disabled) adds why on a second line and hides the shortcut.
  /// nil/empty text and reason = no tooltip. `forceVisible` draws the bubble in place (gallery/snapshots).
  func dsTooltip(_ text: String?, shortcut: String? = nil, disabledReason: String? = nil, side: DSTooltipSide = .top,
                 forceVisible: Bool = false) -> some View {
    modifier(DSTooltipModifier(content: DSTooltipContent(label: text, shortcut: shortcut, disabledReason: disabledReason),
                               side: side, forceVisible: forceVisible))
  }

  /// Round-2 spelling (`edge:`); same as `side:`.
  func dsTooltip(_ text: String?, shortcut: String? = nil, edge: DSTooltipEdge, forceVisible: Bool = false) -> some View {
    dsTooltip(text, shortcut: shortcut, side: edge, forceVisible: forceVisible)
  }
}

// MARK: - Trigger anchor (AppKit)

/// Lets the hover handler reach the anchor view that `makeNSView` created.
@MainActor
final class DSTooltipAnchorBox {
  weak var view: DSTooltipAnchorView?
}

private struct DSTooltipAnchor: NSViewRepresentable {
  let content: DSTooltipContent
  let side: TooltipSide
  let scheme: ColorScheme
  let box: DSTooltipAnchorBox

  func makeNSView(context: Context) -> DSTooltipAnchorView {
    let v = DSTooltipAnchorView()
    v.update(content: content, side: side, scheme: scheme)
    box.view = v
    return v
  }

  func updateNSView(_ v: DSTooltipAnchorView, context: Context) {
    v.update(content: content, side: side, scheme: scheme)
  }

  static func dismantleNSView(_ v: DSTooltipAnchorView, coordinator: ()) {
    DSTooltipController.shared.anchorGone(v)
  }
}

/// Invisible, click-through view filling the trigger: gives the trigger's real frame in screen space. (Not an
/// NSTrackingArea: under SwiftUI an embedded view's `visibleRect` is the enclosing clip region, and tracking ignores
/// z-order — a card under an in-window modal would still fire. SwiftUI hover handles both.)
final class DSTooltipAnchorView: NSView {
  private(set) var content = DSTooltipContent()
  private(set) var side: TooltipSide = .top
  private(set) var scheme: ColorScheme = .light

  func update(content: DSTooltipContent, side: TooltipSide, scheme: ColorScheme) {
    let changed = content != self.content || scheme != self.scheme
    self.content = content
    self.side = side
    self.scheme = scheme
    if changed { DSTooltipController.shared.contentChanged(self) }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
  override func isAccessibilityElement() -> Bool { false }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { DSTooltipController.shared.anchorGone(self) }
    super.viewWillMove(toWindow: newWindow)
  }

  /// The visible part of the trigger in screen coordinates (nil when scrolled out or off-window). SwiftUI's
  /// `visibleRect` is the ancestor clip region, so intersect it with our bounds.
  var visibleScreenRect: CGRect? {
    guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
    let r = bounds.intersection(visibleRect)
    guard r.width > 0.5, r.height > 0.5 else { return nil }
    return window.convertToScreen(convert(r, to: nil))
  }

  /// Is the cursor over this trigger right now (guards against stale enter/exit pairs)?
  var containsMouse: Bool {
    guard let window else { return false }
    if let sim = DSTooltipController.shared.simulatedPointer { return visibleScreenRect?.contains(sim) ?? false }
    let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return bounds.intersection(visibleRect).contains(p)
  }
}

// MARK: - Provider + popup panel

private final class DSTooltipPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// One per app: the delay group, the hovered-trigger stack (innermost wins; leaving it falls back to its parent),
/// the single popup panel and the dismiss monitors.
@MainActor
final class DSTooltipController {
  static let shared = DSTooltipController()
  /// Snapshots only: tooltips whose label is listed draw in place (set before the window is built).
  nonisolated(unsafe) static var forcedLabels: Set<String> = []

  var group = TooltipDelayGroup(delay: 0.5, timeout: 0.4)
  /// Offset between trigger and bubble (shadcn sideOffset 4–8; Base UI collisionPadding 5).
  let gap: CGFloat = 6
  let edgePadding: CGFloat = 6

  private var hovered: [WeakAnchor] = []
  private weak var shown: DSTooltipAnchorView?
  /// Pressed while hovered: stays closed until the pointer leaves it (Base UI behaviour).
  private weak var suppressed: DSTooltipAnchorView?
  private var pending: Task<Void, Never>?
  private var panel: DSTooltipPanel?
  private var host: NSHostingView<AnyView>?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var lastSide: TooltipSide?

  private struct WeakAnchor { weak var view: DSTooltipAnchorView? }

  private var target: DSTooltipAnchorView? {
    hovered.removeAll { $0.view == nil || $0.view?.window == nil }
    return hovered.last?.view
  }

  // MARK: Hover

  func hoverBegan(_ a: DSTooltipAnchorView) {
    installMonitorsIfNeeded()
    hovered.removeAll { $0.view === a || $0.view == nil }
    hovered.append(WeakAnchor(view: a))
    retarget()
  }

  func hoverEnded(_ a: DSTooltipAnchorView) {
    hovered.removeAll { $0.view === a || $0.view == nil }
    if suppressed === a { suppressed = nil }
    retarget()
  }

  func anchorGone(_ a: DSTooltipAnchorView) {
    hovered.removeAll { $0.view === a || $0.view == nil }
    if shown === a { hide(resetGroup: false) }
    if suppressed === a { suppressed = nil }
  }

  func contentChanged(_ a: DSTooltipAnchorView) {
    guard shown === a else { return }
    if a.content.isEmpty { hide(resetGroup: false) } else { present(a, animated: false) }
  }

  /// Points the popup at the innermost hovered trigger: instantly inside the delay group, else after the delay.
  private func retarget() {
    pending?.cancel()
    pending = nil
    guard let t = target, t !== suppressed, !t.content.isEmpty else {
      if shown != nil { hide(resetGroup: false) }
      return
    }
    if t === shown { return }
    let wait = group.openDelay(now: Date())
    if wait == 0 {
      present(t, animated: false)
      return
    }
    if shown != nil { hide(resetGroup: false) }
    schedule(t, after: wait)
  }

  // MARK: Show / hide

  private func canShow(_ a: DSTooltipAnchorView) -> Bool {
    guard NSApp.isActive || !requireActiveApp, let w = a.window, w.isVisible, w.attachedSheet == nil else { return false }
    if let modal = NSApp.modalWindow, modal !== w { return false }
    return true
  }

  private func present(_ a: DSTooltipAnchorView, animated: Bool) {
    guard canShow(a), let anchorRect = a.visibleScreenRect, let window = a.window else { return }
    let panel = ensurePanel()
    let bubble = DSTooltipFit(maxWidth: DSTooltipBubble.maxWidth) { DSTooltipBubble(a.content) }
      .environment(\.colorScheme, a.scheme).ignoresSafeArea()
    host?.rootView = AnyView(bubble)
    let fit = host?.fittingSize ?? .zero
    let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
    let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
    var bounds = window.frame.intersection(screen).insetBy(dx: edgePadding, dy: edgePadding)
    // A bubble too big for the window (menu bar popover, tiny sheet) may use the whole screen instead.
    if bounds.width < size.width || bounds.height < size.height * 3 { bounds = screen.insetBy(dx: edgePadding, dy: edgePadding) }
    let placed = TooltipPlacement.place(anchor: anchorRect, size: size, preferred: a.side, bounds: bounds, gap: gap)
    lastSide = placed.side

    panel.appearance = NSAppearance(named: a.scheme == .dark ? .darkAqua : .aqua)
    panel.hasShadow = a.scheme == .light  // DS: no shadows in dark mode
    // Above every window of ours (menus, sheets, the menu bar popover). The background evidence probe instead keeps
    // it just above its own window so nothing floats over the user's other apps.
    panel.level = requireActiveApp ? .popUpMenu : window.level
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let wasShown = shown != nil
    shown = a
    group.opened()
    if animated && !wasShown {
      // Fade in 120 ms with a 4 pt slide away from the trigger; Reduce Motion = fade only.
      var start = placed.frame
      if !reduceMotion {
        switch placed.side {
        case .top: start.origin.y -= 4
        case .bottom: start.origin.y += 4
        case .leading: start.origin.x += 4
        case .trailing: start.origin.x -= 4
        }
      }
      panel.setFrame(start, display: false)
      panel.alphaValue = 0
      orderFront(panel, over: window)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = DS.motion.fast
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        panel.animator().setFrame(placed.frame, display: true)
      }
    } else {
      // Delay-group hand-off: no animation (Base UI `data-instant`).
      panel.setFrame(placed.frame, display: true)
      panel.alphaValue = 1
      orderFront(panel, over: window)
    }
    panel.invalidateShadow()
  }

  private func orderFront(_ panel: NSPanel, over window: NSWindow) {
    if requireActiveApp { panel.orderFrontRegardless() } else { panel.order(.above, relativeTo: window.windowNumber) }
  }

  /// Hides now. `resetGroup` (press, scroll, key) means the next tooltip waits the full delay again.
  func hide(resetGroup: Bool) {
    pending?.cancel()
    pending = nil
    if shown != nil || resetGroup { group.closed(at: Date(), resetGroup: resetGroup) }
    shown = nil
    panel?.orderOut(nil)
  }

  private func ensurePanel() -> DSTooltipPanel {
    if let panel { return panel }
    let p = DSTooltipPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.ignoresMouseEvents = true
    p.hidesOnDeactivate = true
    p.isReleasedWhenClosed = false
    p.becomesKeyOnlyIfNeeded = true
    p.animationBehavior = .none
    p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
    p.isExcludedFromWindowsMenu = true
    p.setAccessibilityElement(false)  // VoiceOver reads the trigger's hint instead
    let h = NSHostingView(rootView: AnyView(EmptyView()))
    h.autoresizingMask = [.width, .height]
    p.contentView = h
    panel = p
    host = h
    return p
  }

  // MARK: Dismiss monitors

  private func installMonitorsIfNeeded() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
      MainActor.assumeIsolated { self?.handle(e) }
      return e
    }
    let nc = NotificationCenter.default
    for name in [NSApplication.didResignActiveNotification, NSWindow.willBeginSheetNotification, NSWindow.didResignKeyNotification,
                 NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
        MainActor.assumeIsolated {
          guard let self else { return }
          // App switch: always. Window events: only for the window the tooltip lives in.
          if let w = n.object as? NSWindow, w !== self.shown?.window, w !== self.target?.window { return }
          if self.shown != nil || self.pending != nil { self.hide(resetGroup: true) }
        }
      })
    }
  }

  private func handle(_ e: NSEvent) {
    switch e.type {
    case .scrollWheel:
      // Close while scrolling; whatever ends up under the pointer opens after the full delay once scrolling stops.
      hide(resetGroup: true)
      if let t = target, t !== suppressed, !t.content.isEmpty { schedule(t, after: group.delay) }
    default:
      // Press or key (Escape included): close and keep this trigger closed until the pointer leaves it.
      suppressed = target
      hide(resetGroup: true)
    }
  }

  private func schedule(_ t: DSTooltipAnchorView, after seconds: TimeInterval) {
    pending?.cancel()
    pending = Task { @MainActor [weak self, weak t] in
      try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
      guard !Task.isCancelled, let self, let t, self.target === t, t.containsMouse else { return }
      self.present(t, animated: true)
    }
  }

  // MARK: Evidence hooks (DSTooltipProbe only; never set in the app)

  /// Tooltips show only while the app is active; the probe runs in the background so it never steals focus.
  var requireActiveApp = true
  /// Probe pointer in screen coordinates (replaces the real cursor for `containsMouse`).
  var simulatedPointer: CGPoint?
  /// Hover-ins seen (tells the probe whether SwiftUI delivered hover from its posted mouse events).
  var debugHoverEvents = 0
  var debugShown: DSTooltipAnchorView? { shown }
  var debugSide: TooltipSide? { shown == nil ? nil : lastSide }
  var debugPanelWindow: NSWindow? { panel }
  var debugPanelFrame: CGRect? { panel?.isVisible == true && shown != nil ? panel?.frame : nil }

  /// What SwiftUI hover would do for a pointer at `p`: exit triggers it left, enter the ones it is
  /// now over (outermost first, so the innermost wins).
  func debugPointerMoved(to p: CGPoint, in w: NSWindow) {
    func depth(_ v: NSView) -> Int { var d = 0; var s = v.superview; while let x = s { d += 1; s = x.superview }; return d }
    let inside = DSTooltipProbe.anchors(in: w).filter { $0.visibleScreenRect?.contains(p) ?? false }.sorted { depth($0) < depth($1) }
    for h in hovered.compactMap(\.view) where !inside.contains(where: { $0 === h }) { hoverEnded(h) }
    for a in inside where !hovered.contains(where: { $0.view === a }) { hoverBegan(a) }
  }

  func debugHandle(_ e: NSEvent) { handle(e) }

  /// Shows `a`'s tooltip now, ignoring hover (evidence captures).
  func debugShow(_ a: DSTooltipAnchorView) { present(a, animated: false) }
}
