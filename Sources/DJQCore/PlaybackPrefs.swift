import Foundation

/// Autoplay preferences (decision #12), persisted by the app in UserDefaults `djq.playback`. Settings → Playback &
/// autoplay edits them through `AppModel.setPlayback`. Lives in the core so the stored-JSON migration is testable.
public struct PlaybackPrefs: Codable, Equatable, Sendable {
  /// Previews play from their 540×960 proxies (small ones while hovered, large ones by themselves).
  public var autoplay = true
  /// Sound for the clip under the pointer (on by default since round 3; never auto-unmutes otherwise).
  public var unmuteOnHover = true
  /// True once Eric set "Unmute on hover" himself. Saved prefs from before round 3 never had it: they had the old
  /// default (off) without anyone choosing it, so they load as on (one-time migration); a later choice sticks.
  public var unmuteOnHoverChosen = false
  /// With hover-only off: only the hovered / keyboard-focused clip plays (instead of every visible clip, ≤ 4 players).
  public var focusOnly = false
  /// What the proxies loop: the resolved trim (what will post) or the whole clip file.
  public var loop: ProxyRange = .trim
  /// "Small previews: play on hover only": Calendar, Cards, Grid and List show covers and a clip plays only while
  /// it's hovered (grids since round 3, every small preview since round 14; on by default).
  public var gridHoverOnly = true
  /// True once Eric set that switch himself (same one-time migration as `unmuteOnHoverChosen`).
  public var gridHoverOnlyChosen = false
  /// How far ← / → move the editor's playhead (round 19; ⇧ moves one frame). Also the jump buttons beside Play.
  public var arrowStep: ArrowStep = .standard

  public init() {}

  /// Hover plays with sound only while Autoplay is on (Settings disables "Unmute on hover" when Autoplay is off,
  /// so with Autoplay off hovering does nothing). Every preview reads this, never `unmuteOnHover` directly.
  public var hoverSound: Bool { autoplay && unmuteOnHover }

  enum CodingKeys: String, CodingKey {
    case autoplay, unmuteOnHover, unmuteOnHoverChosen, focusOnly, loop, gridHoverOnly, gridHoverOnlyChosen, arrowStep
  }

  /// Lenient: missing keys keep their defaults; an unchosen "Unmute on hover" becomes the new default (on).
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    autoplay = (try? c.decodeIfPresent(Bool.self, forKey: .autoplay)) ?? true
    focusOnly = (try? c.decodeIfPresent(Bool.self, forKey: .focusOnly)) ?? false
    loop = (try? c.decodeIfPresent(ProxyRange.self, forKey: .loop)) ?? .trim
    unmuteOnHoverChosen = (try? c.decodeIfPresent(Bool.self, forKey: .unmuteOnHoverChosen)) ?? false
    let stored = (try? c.decodeIfPresent(Bool.self, forKey: .unmuteOnHover)) ?? nil
    unmuteOnHover = unmuteOnHoverChosen ? (stored ?? true) : true
    gridHoverOnlyChosen = (try? c.decodeIfPresent(Bool.self, forKey: .gridHoverOnlyChosen)) ?? false
    let grid = (try? c.decodeIfPresent(Bool.self, forKey: .gridHoverOnly)) ?? nil
    gridHoverOnly = gridHoverOnlyChosen ? (grid ?? true) : true
    arrowStep = (try? c.decodeIfPresent(ArrowStep.self, forKey: .arrowStep)) ?? .standard
  }

  /// Eric's own choice from Settings (marks it chosen).
  public mutating func chooseGridHoverOnly(_ on: Bool) {
    gridHoverOnly = on
    gridHoverOnlyChosen = true
  }

  /// Eric's own choice from Settings (marks it chosen so it's respected from then on).
  public mutating func chooseUnmuteOnHover(_ on: Bool) {
    unmuteOnHover = on
    unmuteOnHoverChosen = true
  }
}

/// How far ← / → move the editor's playhead (round 19). Before it they moved one frame, which Eric found far too
/// small for 15–60 s clips; the default is now 2 seconds and ⇧ keeps the one-frame nudge.
public enum ArrowStep: String, Codable, CaseIterable, Sendable {
  case frame, halfSecond, oneSecond, twoSeconds, fiveSeconds, tenSeconds

  public static let standard: ArrowStep = .twoSeconds

  /// Unknown stored values (a newer build's) load as the default instead of failing the whole prefs blob.
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ArrowStep(rawValue: raw) ?? .standard
  }

  /// Seconds for one press at `fps` (a frame is 1/fps).
  public func seconds(fps: Double) -> Double {
    switch self {
    case .frame: return 1 / max(fps, 1)
    case .halfSecond: return 0.5
    case .oneSecond: return 1
    case .twoSeconds: return 2
    case .fiveSeconds: return 5
    case .tenSeconds: return 10
    }
  }

  /// "2 seconds" — menus and Settings.
  public var title: String {
    switch self {
    case .frame: return "1 frame"
    case .halfSecond: return "½ second"
    case .oneSecond: return "1 second"
    case .twoSeconds: return "2 seconds"
    case .fiveSeconds: return "5 seconds"
    case .tenSeconds: return "10 seconds"
    }
  }

  /// "2 s" — the compact chip in the editor's transport.
  public var short: String {
    switch self {
    case .frame: return "1 frame"
    case .halfSecond: return "0.5 s"
    case .oneSecond: return "1 s"
    case .twoSeconds: return "2 s"
    case .fiveSeconds: return "5 s"
    case .tenSeconds: return "10 s"
    }
  }

  /// SF Symbols for the jump buttons beside Play (numbered ones exist only for 5 and 10).
  public var backSymbol: String {
    switch self {
    case .frame: return "backward.frame"
    case .fiveSeconds: return "gobackward.5"
    case .tenSeconds: return "gobackward.10"
    default: return "gobackward"
    }
  }

  public var forwardSymbol: String {
    switch self {
    case .frame: return "forward.frame"
    case .fiveSeconds: return "goforward.5"
    case .tenSeconds: return "goforward.10"
    default: return "goforward"
    }
  }
}

/// Where an arrow press puts the playhead: `direction` −1 / +1, `fine` (⇧) moves one frame whatever the step.
/// Clamped to the clip (0 … duration; an unknown duration of 0 only clamps at 0).
public enum EditorSeek {
  public static func target(from time: Double, step: ArrowStep, fps: Double, direction: Int, fine: Bool,
                            duration: Double) -> Double {
    let amount = fine ? ArrowStep.frame.seconds(fps: fps) : step.seconds(fps: fps)
    let t = max(0, time + Double(direction.signum()) * amount)
    return duration > 0 ? min(t, duration) : t
  }
}

/// Which preview tiles play and which proxies to fetch (round 3 F7). Pure, so the rules are unit-tested.
public enum PreviewPlayback {
  public enum Layout: Sendable { case cards, grid, single, list }

  /// Size decides (round 14). A tile plays when autoplay is on and:
  /// - Any small preview (Cards, Grid, List, Calendar covers) with "play on hover only": only while hovered (or
  ///   keyboard-focused, the keyboard's pointer).
  /// - Single: the shown clip (focus playback) — or every one when not focus-only.
  /// - Small previews with hover-only off: every visible tile, or only the hovered/focused one in focus-only.
  public static func plays(_ p: PlaybackPrefs, layout: Layout, hovered: Bool, focused: Bool) -> Bool {
    guard p.autoplay else { return false }
    if layout != .single && p.gridHoverOnly { return hovered || focused }
    return !p.focusOnly || hovered || focused
  }

  /// Proxies to request for a layout: `now` at visible priority, `prefetch` at background priority. Grid with
  /// hover-only: the hovered tile now, its 2 neighbours in display order as prefetch (nothing hovered: the 2
  /// tiles at the middle of what's visible). Every other layout: all visible tiles now.
  public static func proxyTargets(_ p: PlaybackPrefs, layout: Layout, visible: [String], hovered: String?)
    -> (now: [String], prefetch: [String]) {
    guard p.autoplay else { return ([], []) }
    guard layout == .grid && p.gridHoverOnly else { return (visible, []) }
    guard !visible.isEmpty else { return ([], []) }
    if let h = hovered, let i = visible.firstIndex(of: h) {
      return ([h], [i + 1, i - 1].filter { visible.indices.contains($0) }.map { visible[$0] })
    }
    let mid = visible.count / 2
    return ([], [mid, mid - 1].filter { visible.indices.contains($0) }.map { visible[$0] })
  }
}
