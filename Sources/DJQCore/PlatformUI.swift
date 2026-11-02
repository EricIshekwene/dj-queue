import CoreGraphics
import Foundation

/// Platform overlay geometry and preview facts as DATA (round 2 #4 safe zones, #8 realistic preview).
///
/// Values come from `design/DESIGN-v2.md` §8 (measured on iOS screenshots). Every number lives in
/// `PlatformUI.table`, so refining a platform is a one-line change. Rects are normalised (0…1, top-left origin):
/// - `screen`: on the full phone screen (aspect `PlatformUI.screenAspect`, 9:19.5) — draw the mock with these.
/// - `frame`: the same element on the 9:16 video frame after the feed's aspect-fill — the safe-zone overlay.
///   nil when the element isn't over the video (bottom nav, card layouts). Values may exceed 0…1 slightly
///   (behind the nav); `overlays` clips them.
/// Feeds (TikTok, Instagram Reels, Facebook Reels, YouTube Shorts) draw UI over the video; Threads and X show it
/// inside a post card where nothing covers it. Drawn generically by the UI: no logos, no brand colours.
public enum OverlayKind: String, Codable, Sendable, CaseIterable {
  case topBar, rightRail
  /// Handle / avatar row (+ Follow / Subscribe).
  case handleRow
  /// Caption (YouTube: the title line).
  case caption
  /// Sound / music line.
  case musicTicker
  case bottomNav
  /// Card: avatar + handle row.
  case postHeader
  /// Card: the post text.
  case postText
  /// Card: the video box.
  case media
  /// Card: reply / repost / like row.
  case postActions
  /// X's floating compose button.
  case fab

  public var displayName: String {
    switch self {
    case .topBar: "Top bar"
    case .rightRail: "Buttons"
    case .handleRow: "Handle"
    case .caption: "Caption"
    case .musicTicker: "Sound"
    case .bottomNav: "Tab bar"
    case .postHeader: "Header"
    case .postText: "Post text"
    case .media: "Video"
    case .postActions: "Actions"
    case .fab: "Compose button"
    }
  }
}

public enum PreviewLayout: String, Codable, Sendable { case feed, postCard }

public struct OverlayElement: Codable, Sendable, Hashable {
  public var kind: OverlayKind
  /// On the phone screen (9:19.5).
  public var screen: CGRect
  /// On the 9:16 video frame (feeds only).
  public var frame: CGRect?

  /// Percent values `x0, y0, x1, y1` as in DESIGN-v2 §8.
  public init(_ kind: OverlayKind, screen s: [Double], frame f: [Double]? = nil) {
    self.kind = kind
    screen = Self.rect(s)
    frame = f.map(Self.rect)
  }

  public init(kind: OverlayKind, screen: CGRect, frame: CGRect?) { self.kind = kind; self.screen = screen; self.frame = frame }

  static func rect(_ p: [Double]) -> CGRect { CGRect(x: p[0] / 100, y: p[1] / 100, width: (p[2] - p[0]) / 100, height: (p[3] - p[1]) / 100) }
}

public struct PlatformUISpec: Codable, Sendable, Hashable {
  public var platform: Platform
  public var layout: PreviewLayout
  /// Account handle shown in the preview.
  public var handle: String
  /// Caption lines the preview shows before truncating (YouTube: the title line).
  public var captionLines: Int
  /// Approximate characters per caption line at the mock's text size.
  public var charsPerLine: Int
  /// What the truncated caption ends with ("… more", "…", "Show more").
  public var moreLabel: String
  /// YouTube shows the title, not the caption, under the handle.
  public var showsTitle: Bool
  /// Feeds: where the content area ends (top of the bottom nav), as a fraction of the screen height.
  public var contentBottom: Double
  /// Card platforms that crop portrait video (X shows tall clips at ≈ 4:5).
  public var cardCrop: Aspect?
  public var elements: [OverlayElement]

  /// Characters shown before the "more" label (preview only).
  public var captionPreviewChars: Int { captionLines * charsPerLine }
}

public enum PlatformUI {
  /// iPhone screen aspect the mocks are drawn on (393×852 pt).
  public static let screenAspect = 9.0 / 19.5

  /// THE table (DESIGN-v2 §8). Handles: @dj.lovd except X (@djlovdreal) and YouTube (@dj.lovdreal).
  public static let table: [Platform: PlatformUISpec] = [
    .tiktok: PlatformUISpec(
      platform: .tiktok, layout: .feed, handle: "@dj.lovd", captionLines: 2, charsPerLine: 40, moreLabel: "… more",
      showsTitle: false, contentBottom: 0.90, cardCrop: nil,
      elements: [
        OverlayElement(.topBar, screen: [3, 7.5, 97, 11.5], frame: [7.2, 8.3, 92.8, 12.8]),
        OverlayElement(.rightRail, screen: [86, 44.5, 98, 88.5], frame: [82.8, 49.4, 93.7, 98.3]),
        OverlayElement(.handleRow, screen: [3, 77.8, 40, 80.2], frame: [7.2, 86.4, 40.9, 89.1]),
        OverlayElement(.caption, screen: [3, 81.4, 74, 85.6], frame: [7.2, 90.4, 71.9, 95.1]),
        OverlayElement(.musicTicker, screen: [3, 86.4, 55, 89], frame: [7.2, 96.0, 54.6, 98.9]),
        OverlayElement(.bottomNav, screen: [0, 90, 100, 100]),
      ]),
    .instagram: PlatformUISpec(
      platform: .instagram, layout: .feed, handle: "@dj.lovd", captionLines: 1, charsPerLine: 44, moreLabel: "…",
      showsTitle: false, contentBottom: 0.90, cardCrop: nil,
      elements: [
        OverlayElement(.topBar, screen: [4, 7.5, 96, 12], frame: [8.1, 8.3, 91.9, 13.3]),
        OverlayElement(.rightRail, screen: [87, 45.5, 97, 88], frame: [83.7, 50.6, 92.8, 97.8]),
        OverlayElement(.handleRow, screen: [4, 74.5, 75, 79.5], frame: [8.1, 82.8, 72.8, 88.3]),
        OverlayElement(.musicTicker, screen: [17, 77.5, 60, 79.2], frame: [19.9, 86.1, 59.1, 88.0]),
        OverlayElement(.caption, screen: [4, 80, 82, 82.5], frame: [8.1, 88.9, 79.2, 91.7]),
        OverlayElement(.bottomNav, screen: [0, 90, 100, 100]),
      ]),
    .facebook: PlatformUISpec(
      platform: .facebook, layout: .feed, handle: "@dj.lovd", captionLines: 1, charsPerLine: 46, moreLabel: "… more",
      showsTitle: false, contentBottom: 0.905, cardCrop: nil,
      elements: [
        OverlayElement(.topBar, screen: [3, 8.5, 21, 11.5], frame: [7.4, 9.4, 23.7, 12.7]),
        OverlayElement(.rightRail, screen: [88, 52, 98, 87.5], frame: [84.4, 57.5, 93.5, 96.7]),
        OverlayElement(.handleRow, screen: [3, 80.5, 77, 84.5], frame: [7.4, 89.0, 74.5, 93.4]),
        OverlayElement(.musicTicker, screen: [14, 82.8, 58, 84.5], frame: [17.4, 91.5, 57.2, 93.4]),
        OverlayElement(.caption, screen: [3, 85.8, 85, 88], frame: [7.4, 94.8, 81.7, 97.2]),
        OverlayElement(.bottomNav, screen: [0, 90.5, 100, 100]),
      ]),
    .youtube: PlatformUISpec(
      platform: .youtube, layout: .feed, handle: "@dj.lovdreal", captionLines: 1, charsPerLine: 44, moreLabel: "…",
      showsTitle: true, contentBottom: 0.905, cardCrop: nil,
      elements: [
        OverlayElement(.topBar, screen: [78, 8.5, 95, 11], frame: [75.4, 9.4, 90.8, 12.2]),
        OverlayElement(.rightRail, screen: [86, 39.5, 98, 88.5], frame: [82.6, 43.6, 93.5, 97.8]),
        OverlayElement(.handleRow, screen: [4, 77, 62, 81], frame: [8.3, 85.1, 60.9, 89.5]),
        OverlayElement(.caption, screen: [4, 82, 82, 84.5], frame: [8.3, 90.6, 79.0, 93.4]),
        OverlayElement(.musicTicker, screen: [4, 86.3, 84, 88.5], frame: [8.3, 95.4, 80.8, 97.8]),
        OverlayElement(.bottomNav, screen: [0, 90.5, 100, 100]),
      ]),
    // Cards: header/body positions follow §8.5/8.6; vertical placement of the post is illustrative (the refs crop
    // the top), video sizes are measured (Threads 61 % wide at 9:16; X full body width cropped to 4:5).
    .threads: PlatformUISpec(
      platform: .threads, layout: .postCard, handle: "@dj.lovd", captionLines: 5, charsPerLine: 45, moreLabel: "Show more",
      showsTitle: false, contentBottom: 0.90, cardCrop: nil,
      elements: [
        OverlayElement(.topBar, screen: [0, 7.5, 100, 11]),
        OverlayElement(.postHeader, screen: [3.5, 13, 96, 16]),
        OverlayElement(.postText, screen: [16, 16, 96.5, 21]),
        OverlayElement(.media, screen: [16, 21.5, 77, 69.3]),
        OverlayElement(.postActions, screen: [16, 70.7, 56, 73.2]),
        OverlayElement(.bottomNav, screen: [0, 90, 100, 100]),
      ]),
    .x: PlatformUISpec(
      platform: .x, layout: .postCard, handle: "@djlovdreal", captionLines: 5, charsPerLine: 46, moreLabel: "Show more",
      showsTitle: false, contentBottom: 0.90, cardCrop: .r4x5,
      elements: [
        OverlayElement(.topBar, screen: [0, 7.5, 100, 16]),
        OverlayElement(.postHeader, screen: [2.5, 18, 97, 21]),
        OverlayElement(.postText, screen: [15.5, 21, 97.5, 26]),
        OverlayElement(.media, screen: [15.5, 26.5, 97.5, 73.5]),
        OverlayElement(.postActions, screen: [15.5, 74.7, 97, 77.2]),
        OverlayElement(.fab, screen: [83, 82.5, 98, 89]),
        OverlayElement(.bottomNav, screen: [0, 90, 100, 100]),
      ]),
  ]

  public static func spec(_ p: Platform) -> PlatformUISpec { table[p]! }
  public static func handle(_ p: Platform) -> String { spec(p).handle }

  /// Safe-zone overlays on a video of `aspect`: the feed elements' frame rects, clipped to the picture. 4:5 and 1:1
  /// clips are shown full-width and vertically centred in the 9:16 feed frame, so only the parts over the picture
  /// remain; 16:9 isn't a feed format and card platforms cover nothing → [].
  public static func overlays(_ p: Platform, aspect: Aspect) -> [OverlayElement] {
    let s = spec(p)
    guard s.layout == .feed else { return [] }
    return s.elements.compactMap { e in
      guard let f = e.frame else { return nil }
      let clipped = f.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !clipped.isNull, clipped.height > 0 else { return nil }
      return EditorLogic.safeZones([clipped], aspect: aspect).first.map { OverlayElement(kind: e.kind, screen: e.screen, frame: $0) }
    }
  }

  /// Overlay rects for several platforms at once (the editor's multi-select safe-zone chips).
  public static func unsafeRects(_ platforms: Set<Platform>, aspect: Aspect) -> [Platform: [CGRect]] {
    Dictionary(uniqueKeysWithValues: platforms.map { p in (p, overlays(p, aspect: aspect).compactMap(\.frame)) })
  }

  /// Card platforms: where a video of `aspect` sits on the screen (aspect-fit into the media box's width, after the
  /// platform's portrait crop). nil for feeds.
  public static func cardMediaFrame(_ p: Platform, aspect: Aspect) -> CGRect? {
    let s = spec(p)
    guard s.layout == .postCard, let box = s.elements.first(where: { $0.kind == .media })?.screen else { return nil }
    var a = aspect.ratio
    if let c = s.cardCrop, a < c.ratio { a = c.ratio }  // portrait cropped to the card's limit
    // Screen-normalised → physical: width × 9, height × 19.5.
    let w = Double(box.width), hPhys = w * 9 / a
    let h = min(Double(box.height), hPhys / 19.5)
    return CGRect(x: box.minX, y: box.minY, width: w, height: h)
  }

  /// The caption as the preview shows it: `captionLines` lines of ≈ `charsPerLine`, then the platform's
  /// "more" label. For YouTube pass the title.
  public static func previewCaption(_ caption: String, for p: Platform) -> (text: String, truncated: Bool) {
    let s = spec(p)
    var lines = caption.components(separatedBy: "\n")
    var truncated = false
    if s.captionLines == 1 || p == .tiktok || p == .facebook { lines = [lines.joined(separator: " ")] }  // feeds flow lines
    if lines.count > s.captionLines {
      lines = Array(lines.prefix(s.captionLines))
      truncated = true
    }
    var t = lines.joined(separator: "\n")
    if t.count > s.captionPreviewChars {
      t = String(t.prefix(max(1, s.captionPreviewChars - s.moreLabel.count))).trimmingCharacters(in: .whitespaces)
      truncated = true
    }
    return (truncated ? t + (s.moreLabel.hasPrefix("…") ? "" : " ") + s.moreLabel : t, truncated)
  }
}
