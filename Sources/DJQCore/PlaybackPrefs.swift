import Foundation

/// Autoplay preferences (decision #12), persisted by the app in UserDefaults `djq.playback`. Settings → Playback &
/// autoplay edits them through `AppModel.setPlayback`. Lives in the core so the stored-JSON migration is testable.
public struct PlaybackPrefs: Codable, Equatable, Sendable {
  /// Muted autoplay of visible clips from their 540×960 proxies.
  public var autoplay = true
  /// Sound for the clip under the pointer (on by default since round 3; never auto-unmutes otherwise).
  public var unmuteOnHover = true
  /// True once Eric set "Unmute on hover" himself. Saved prefs from before round 3 never had it: they had the old
  /// default (off) without anyone choosing it, so they load as on (one-time migration); a later choice sticks.
  public var unmuteOnHoverChosen = false
  /// Only the hovered / keyboard-focused clip plays (instead of every visible clip, ≤ 4 players).
  public var focusOnly = false
  /// What the proxies loop: the resolved trim (what will post) or the whole clip file.
  public var loop: ProxyRange = .trim
  /// Grid views show posters and play a tile only while it's hovered (round 3; on by default).
  public var gridHoverOnly = true
  /// True once Eric set "Grids: play on hover only" himself (same one-time migration as `unmuteOnHoverChosen`).
  public var gridHoverOnlyChosen = false

  public init() {}

  enum CodingKeys: String, CodingKey {
    case autoplay, unmuteOnHover, unmuteOnHoverChosen, focusOnly, loop, gridHoverOnly, gridHoverOnlyChosen
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

/// Which preview tiles play and which proxies to fetch (round 3 F7). Pure, so the rules are unit-tested.
public enum PreviewPlayback {
  public enum Layout: Sendable { case cards, grid, single, list }

  /// A tile plays when autoplay is on and:
  /// - Grid with "play on hover only": only while hovered (or keyboard-focused, the keyboard's pointer).
  /// - Single: the shown clip (focus playback) — or every one when not focus-only.
  /// - Cards / List (and grids with hover-only off): every visible tile, or only the hovered/focused one in focus-only.
  public static func plays(_ p: PlaybackPrefs, layout: Layout, hovered: Bool, focused: Bool) -> Bool {
    guard p.autoplay else { return false }
    if layout == .grid && p.gridHoverOnly { return hovered || focused }
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
