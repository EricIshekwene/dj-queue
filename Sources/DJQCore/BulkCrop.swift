import CoreGraphics
import Foundation

/// One crop offset for many clips (round 15). Eric's footage is filmed horizontally, so a vertical crop mostly needs moving
/// left or right, by about the same distance. The app's Crop dialog and `djq bulk crop-offset` both land here, and `previewCrop`
/// shows what `setCropOffset` would write.
public struct CropChange: Sendable, Hashable {
  /// How far the crop's centre sits from the frame's centre, as a share of the frame's width. Negative = left.
  public var offset: Double
  /// A clip adjusted on its own. It wins over `offset`, and moves a clip that has its own crop.
  public var overrides: [String: Double]
  /// Also move clips that already have a crop.
  public var movesOwnCrops: Bool

  public init(offset: Double = 0, overrides: [String: Double] = [:], movesOwnCrops: Bool = false) {
    self.offset = offset; self.overrides = overrides; self.movesOwnCrops = movesOwnCrops
  }

  public func offset(for id: String) -> Double { overrides[id] ?? offset }

  /// `base` moved so its centre is `offset` from the frame's centre. Size and height stay; it never leaves the frame.
  public static func moved(_ base: CropRect, offset: Double, source: CGSize) -> CropRect {
    var c = base
    c.x = source.width / 2 + offset * source.width - c.w / 2
    c.x = min(max(0, c.x), max(0, source.width - c.w))
    let px = Media.pixelCrop(c, sourceWidth: Int(source.width), sourceHeight: Int(source.height))
    return CropRect(x: px.minX, y: px.minY, w: px.width, h: px.height)
  }

  /// `crop`'s offset from the frame's centre.
  public static func offset(of crop: CropRect, source: CGSize) -> Double {
    source.width > 0 ? (crop.x + crop.w / 2 - source.width / 2) / source.width : 0
  }
}

/// What the offset would do to one clip.
public struct CropPreview: Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  public var source: CGSize?
  /// The crop this clip would have.
  public var crop: CropRect?
  public var changes: Bool
  /// It already has a crop, and keeps it.
  public var keepsOwn: Bool
  /// It had a crop before this pass.
  public var hasOwn: Bool
  /// It has a post that hasn't gone out, which renders again.
  public var scheduled: Bool
  /// Why it's left out (nil = it isn't).
  public var skipped: String?
  /// The frame to show, in seconds of the clip's file.
  public var frameTime: Double
}

public extension BulkActions {
  /// Moves the crop of every clip in `ids`, as one batch. Clips with a post that went out stay as they are.
  @discardableResult
  func setCropOffset(_ ids: [String], _ change: CropChange, dryRun: Bool = false) throws -> BulkResult {
    let params = ["offset": String(format: "%.4f", change.offset), "own": change.movesOwnCrops ? "yes" : "no",
                  "adjusted": String(change.overrides.count)]
    return try run("crop-offset", ids: ids, params: params, dryRun: dryRun) { _, v, s in
      let out = try plan(v, change, s)
      if let why = out.skipped { return .skipped(why) }
      guard out.changes, let crop = out.crop else { return .unchanged }
      var e = try store.edit(videoId: v.id)
      e.crop = crop
      try store.save(e, videoId: v.id)
      return .changed
    }
  }

  /// Each clip's outcome, in the order of `ids`, without changing the clip.
  func previewCrop(_ ids: [String], _ change: CropChange) throws -> [CropPreview] {
    let s = try store.settings()
    return try ids.compactMap { id in
      guard let v = try store.video(id: id) else { return nil }
      return try plan(v, change, s)
    }
  }

  private func plan(_ v: Video, _ change: CropChange, _ s: Settings) throws -> CropPreview {
    var out = CropPreview(id: v.id, name: v.displayName, source: nil, crop: nil, changes: false, keepsOwn: false, hasOwn: false,
                          scheduled: false, skipped: nil, frameTime: 0)
    guard v.type == .short else { out.skipped = "Long-form clips have no crop"; return out }
    if v.missing { out.skipped = "Its file is missing"; return out }
    let posts = try store.posts(where: "video_id=?", [v.id], order: "id")
    if let why = CaptionParts.lockReason(posts: posts) { out.skipped = "This clip has gone out, so its crop stays"; _ = why; return out }
    guard let size = try cachedOrProbedSize(v) else { out.skipped = "Can't read the clip's size"; return out }
    let e = try store.edit(videoId: v.id)
    let re = EditResolver.resolve(e, video: v, defaults: s.defaults, sourceSize: size,
                                  lastUsedCrop: s.defaults.cropAnchor == .lastUsed ? try store.lastCropCentre() : nil)
    out.source = size
    out.frameTime = re.coverTime
    out.hasOwn = e.crop != nil
    out.scheduled = !posts.isEmpty && posts.contains { ![PostState.failed, .skipped].contains($0.state) }
    guard let base = e.crop ?? re.crop else { out.skipped = "Can't place a crop on this clip"; return out }
    if e.crop != nil, !change.movesOwnCrops, change.overrides[v.id] == nil {
      out.crop = e.crop
      out.keepsOwn = true
      return out
    }
    let next = CropChange.moved(base, offset: change.offset(for: v.id), source: size)
    out.crop = next
    out.changes = next != e.crop
    return out
  }
}
