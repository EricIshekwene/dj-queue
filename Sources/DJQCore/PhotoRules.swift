import CoreGraphics
import Foundation

/// The rules of a photo post (round 21, DECISIONS-R21.md), pure and shared by the importer, the renderer, validation,
/// the publishers and the UI. A photo post is a `Video` with `photos`; see `PhotoImport` for how one is made.
public enum PhotoRules {
  /// The most photos one post holds: the largest platform cap (TikTok), since no platform would send a 36th.
  public static let maxPerPost = Platform.allCases.map(\.maxPhotos).max() ?? 35

  /// The shapes a photo post can take, the default first (D5).
  public static let aspects: [Aspect] = [.r4x5, .r1x1, .r9x16, .r16x9]

  /// File extensions the importer takes (lowercased).
  public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]

  /// Why YouTube Shorts is off for a photo post (D8). The platform row shows it.
  public static let youtubeReason = "YouTube Shorts takes video only, so a photo post skips it"

  /// Why Back from Edit doesn't apply to a photo post (D4).
  public static let noScoreStage = "Photos have no Score stage"

  /// Why bulk crop leaves a photo post alone (D17).
  public static let bulkCropReason = "photos are cropped in the editor"

  /// The post's one aspect: its own, else `defaults.photoAspect`.
  public static func aspect(_ e: Edit, defaults d: NewClipDefaults) -> Aspect { e.aspectOverride ?? d.photoAspect }

  /// The photo's own crop when it has one that still fits: the right shape for `aspect` and inside the photo. A crop
  /// made for another aspect is ignored, so changing the aspect never renders a stretched photo.
  public static func ownCrop(_ photo: PhotoItem, edit e: Edit, aspect: Aspect) -> CropRect? {
    guard let c = e.photoCrops[photo.id],
          Media.cropProblem(c, aspect: aspect, sourceWidth: photo.width, sourceHeight: photo.height) == nil else { return nil }
    return c
  }

  public static func hasOwnCrop(_ photo: PhotoItem, edit e: Edit, aspect: Aspect) -> Bool { ownCrop(photo, edit: e, aspect: aspect) != nil }

  /// The centred crop of `aspect` on this photo, in whole pixels as the renderer cuts it.
  public static func centredCrop(_ photo: PhotoItem, aspect: Aspect) -> CropRect {
    let c = Media.centredCrop(aspect: aspect, sourceWidth: photo.width, sourceHeight: photo.height)
    let px = Media.pixelCrop(c, sourceWidth: photo.width, sourceHeight: photo.height)
    return CropRect(x: px.minX, y: px.minY, w: px.width, h: px.height)
  }

  /// The crop this photo renders with, in its upright pixels: its own (`Edit.photoCrops`), else the centred one.
  public static func crop(for photo: PhotoItem, edit e: Edit, aspect: Aspect) -> CropRect {
    ownCrop(photo, edit: e, aspect: aspect) ?? centredCrop(photo, aspect: aspect)
  }

  // MARK: Shapes a platform takes (D20)

  /// The widest and tallest photo (width ÷ height) a platform's publishing API takes. nil = any of `aspects`.
  /// Instagram: 4:5 up to 1.91:1, so 4:5, 1:1 and 16:9 go and 9:16 doesn't.
  public static func shapeRange(_ platform: Platform) -> ClosedRange<Double>? {
    platform == .instagram ? 0.8...1.91 : nil
  }

  public static func takes(_ aspect: Aspect, platform: Platform) -> Bool {
    shapeRange(platform).map { $0.contains((aspect.ratio * 1000).rounded() / 1000) } ?? true
  }

  /// Why `platform` can't post a photo in this shape (nil = it can): the readiness issue's message, and what the
  /// platform's row says.
  public static func shapeProblem(_ aspect: Aspect, platform: Platform) -> String? {
    guard !takes(aspect, platform: platform) else { return nil }
    return "\(platform.displayName) takes photos from 4:5 to 16:9 — pick another shape or turn \(platform.displayName) off for this post"
  }

  /// The platforms of `posting` that refuse this shape.
  public static func refusing(_ aspect: Aspect, posting: [Platform]) -> [Platform] {
    posting.filter { !takes(aspect, platform: $0) }
  }

  /// What the aspect picker says next to a shape: "Instagram doesn't take 9:16 photos". nil = every platform does.
  public static func aspectNote(_ aspect: Aspect, posting: [Platform] = Platform.allCases.filter(\.supportsPhotos)) -> String? {
    let no = refusing(aspect, posting: posting).sorted().map(\.displayName)
    guard !no.isEmpty else { return nil }
    return "\(no.joined(separator: " and ")) \(no.count == 1 ? "doesn't" : "don't") take \(aspect.rawValue) photos"
  }

  // MARK: Text on a range of photos (D7)

  /// A text's window as it reads on a photo post: photo `index` (0-based) occupies [index, index + 1), and the text
  /// shows on it when its window overlaps that.
  public static func shows(_ window: ClosedRange<Double>, onPhoto index: Int) -> Bool {
    window.lowerBound < Double(index + 1) && window.upperBound > Double(index)
  }

  /// The texts drawn on photo `index` of `count`, in stacking order (`PreviewKeys.layerWindows` with one unit per photo).
  public static func layers(_ v: ResolvedVersion?, onPhoto index: Int, of count: Int) -> [TextLayer] {
    PreviewKeys.layerWindows(v, trimDuration: Double(count)).filter { shows($0.window, onPhoto: index) }.map(\.layer)
  }

  /// The stored window for "Photos `first`–`last`" (1-based, inclusive).
  public static func window(fromPhoto first: Int, toPhoto last: Int) -> (start: Double, end: Double) {
    (Double(max(1, first) - 1), Double(max(first, last)))
  }

  /// The photos a window shows on (1-based, inclusive) in a post of `count`. nil = none.
  public static func photoRange(_ window: ClosedRange<Double>, count: Int) -> ClosedRange<Int>? {
    let shown = (0..<max(0, count)).filter { shows(window, onPhoto: $0) }
    guard let a = shown.first, let b = shown.last else { return nil }
    return (a + 1)...(b + 1)
  }

  /// The photos text `layerId` of `v` shows on, by the one window rule the renderer uses. nil = it isn't drawn.
  public static func photoRange(of layerId: String, in v: ResolvedVersion?, count: Int) -> ClosedRange<Int>? {
    PreviewKeys.layerWindows(v, trimDuration: Double(count)).first { $0.layer.id == layerId }
      .flatMap { photoRange($0.window, count: count) }
  }

  /// "Every photo" · "Photo 2" · "Photos 1–3" · "No photo".
  public static func rangeLabel(_ range: ClosedRange<Int>?, count: Int) -> String {
    guard let r = range else { return "No photo" }
    if r.lowerBound <= 1 && r.upperBound >= count { return count == 1 ? "The photo" : "Every photo" }
    return r.lowerBound == r.upperBound ? "Photo \(r.lowerBound)" : "Photos \(r.lowerBound)–\(r.upperBound)"
  }

  // MARK: Per-platform counts (D9)

  /// How many of a post's `count` photos go out on `platform`, and how many are left off (its first ones go).
  public static func sent(count: Int, platform: Platform) -> (sent: Int, dropped: Int) {
    let n = min(max(0, count), platform.maxPhotos)
    return (n, max(0, count) - n)
  }

  /// "X gets the first 4 of 7 photos" when some are left off; nil when every photo goes (or the platform takes none:
  /// `youtubeReason` says that).
  public static func notice(count: Int, platform: Platform) -> String? {
    let r = sent(count: count, platform: platform)
    guard platform.supportsPhotos, r.dropped > 0 else { return nil }
    return "\(platform.displayName) gets the first \(r.sent) of \(count) photos"
  }

  /// What the platform's row says for a photo post: why it's off, or how many photos it gets. nil = nothing to say.
  public static func platformNote(count: Int, platform: Platform) -> String? {
    platform.supportsPhotos ? notice(count: count, platform: platform) : youtubeReason
  }

  /// The same with the post's shape: a shape the platform refuses comes first (it blocks; a dropped photo doesn't).
  public static func platformNote(count: Int, aspect: Aspect, platform: Platform) -> String? {
    guard platform.supportsPhotos else { return youtubeReason }
    return shapeProblem(aspect, platform: platform) ?? notice(count: count, platform: platform)
  }

  /// The render's files that go out on `platform`, in order.
  public static func files(_ render: Render, platform: Platform) -> [String] {
    Array(render.allPaths.prefix(platform.maxPhotos))
  }
}

extension Video {
  /// How many photos a photo post has (0 for a video).
  public var photoCount: Int { photos?.count ?? 0 }

  /// A photo post with more than one photo.
  public var isCarousel: Bool { photoCount > 1 }

  /// "Photo" · "Carousel · 5" where a clip says "DJ vid" or "Talking" (D18), and "Photo + audio" for a video made from a
  /// photo (round 23, D8). nil for any other video. It is only the mark: `isPhoto` says whether the item is a photo post.
  public var photoLabel: String? {
    if isStill { return StillVideo.label }
    guard let photos else { return nil }
    return photos.count > 1 ? "Carousel · \(photos.count)" : "Photo"
  }

  /// What a card's kind mark says: the photo label, else the clip's kind.
  public var kindLabel: String { photoLabel ?? kind.displayName }
}
