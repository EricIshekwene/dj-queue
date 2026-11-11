import AppKit
import DJQCore
import SwiftUI

/// The pictures of a photo post in the editor (round 21): each photo decoded once at canvas size, the strip's
/// thumbnails, and the current photo composed by `PhotoRenderer.compose`, the function the final JPEGs come from, so
/// the canvas is what posts. Everything is read and drawn off the main thread; typing never waits for a photo.
@MainActor
final class EditorPhotoImages: ObservableObject {
  /// One photo to draw: its file, its crop in its own pixels and the post's shape.
  struct Job: @unchecked Sendable {
    var photo: PhotoItem
    var url: URL
    var crop: CropRect
    var aspect: Aspect
    var key: String { EditorPhotoImages.composeKey(photo, crop: crop, aspect: aspect) }
  }

  /// A strip tile's picture: the photo as it posts, without text.
  struct Thumb {
    var key: String
    var image: CGImage
  }

  /// By photo id. A tile keeps its old picture until the new one lands, so a crop drag doesn't blink.
  @Published private(set) var thumbs: [String: Thumb] = [:]
  /// The current photo as the export draws it under the texts.
  @Published private(set) var composed: (key: String, image: CGImage)?

  private var wantedComposite: String?
  private var composeTask: Task<Void, Never>?
  private var thumbTask: Task<Void, Never>?
  private var thumbRun = 0
  /// The tiles being drawn right now, so a refresh that asks for the same ones leaves that work alone.
  private var thumbPending: [String] = []

  /// The longer side a photo is decoded at for the canvas: enough for the 1080-wide output at twice zoom.
  nonisolated static let canvasPixels = 2560
  /// The longer side for a strip tile.
  nonisolated static let thumbPixels = 480
  /// A tile's picture height in pixels (72 pt at 2×).
  nonisolated static let thumbHeight = 144

  /// Decoded photos at canvas size (about 20 MB each), least recently used out first.
  nonisolated static let canvas = CostCappedCache<String, CGImage>(costLimit: 240 << 20)
  nonisolated static let small = CostCappedCache<String, CGImage>(costLimit: 48 << 20)

  /// A decoded photo's identity: the file and its content.
  nonisolated static func key(_ p: PhotoItem, url: URL) -> String { "\(url.path)|\(p.fingerprint ?? "")" }

  nonisolated static func composeKey(_ p: PhotoItem, crop c: CropRect, aspect: Aspect) -> String {
    "\(p.id)|\(p.fingerprint ?? p.file)|\(aspect.rawValue)|\(c.x),\(c.y),\(c.w),\(c.h)"
  }

  /// The photo upright at `maxPixel`, opaque on white (what `PhotoRenderer.compose` puts under a see-through photo).
  nonisolated static func decode(_ url: URL, key: String, maxPixel: Int, into cache: CostCappedCache<String, CGImage>) -> CGImage? {
    if let hit = cache.value(key) { return hit }
    guard let raw = PhotoRenderer.load(url, maxPixel: maxPixel) else { return nil }
    let img = flattened(raw)
    cache.set(img, for: key, cost: img.bytesPerRow * img.height)
    return img
  }

  private nonisolated static func flattened(_ img: CGImage) -> CGImage {
    switch img.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return img
    default: break
    }
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
    let frame = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(frame)
    ctx.draw(img, in: frame)
    return ctx.makeImage() ?? img
  }

  /// A new post is opening: nothing of the last one stays on screen.
  func reset() {
    composeTask?.cancel()
    thumbTask?.cancel()
    thumbRun &+= 1
    thumbPending = []
    wantedComposite = nil
    composed = nil
    thumbs = [:]
  }

  // MARK: The canvas picture

  /// Composes `job`'s photo from `image` (that photo, decoded) at the output size.
  func compose(_ job: Job, from image: CGImage, sync: Bool) {
    let key = job.key
    wantedComposite = key
    guard composed?.key != key else { return }
    composeTask?.cancel()
    if sync {
      composed = Self.draw(job, from: image, height: nil).map { (key, $0) }
      return
    }
    let source = Unchecked(image)
    composeTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard !Task.isCancelled, let img = Self.draw(job, from: source.value, height: nil) else { return }
      await self?.composedLanded(key, Unchecked(img))
    }
  }

  private func composedLanded(_ key: String, _ img: Unchecked<CGImage>) {
    if wantedComposite == key { composed = (key, img.value) }
  }

  /// `PhotoRenderer.compose` at the output size, or scaled to `height` pixels for a tile. No text: the canvas draws
  /// each text over it, so one can be dragged.
  private nonisolated static func draw(_ job: Job, from image: CGImage, height: Int?) -> CGImage? {
    let out = job.aspect.outputSize
    let size = height.map { CGSize(width: max(2, Int((Double($0) * job.aspect.ratio).rounded())), height: $0) }
      ?? CGSize(width: out.w, height: out.h)
    return PhotoRenderer.compose(image, sourceSize: CGSize(width: job.photo.width, height: job.photo.height), crop: job.crop,
                                 aspect: job.aspect, size: size)
  }

  // MARK: The strip's thumbnails

  /// Draws the tiles whose photo, crop or shape changed, and drops those of photos that left.
  func refreshThumbs(_ jobs: [Job], sync: Bool) {
    let ids = Set(jobs.map(\.photo.id))
    if thumbs.keys.contains(where: { !ids.contains($0) }) { thumbs = thumbs.filter { ids.contains($0.key) } }
    let stale = jobs.filter { thumbs[$0.photo.id]?.key != $0.key }
    guard Set(stale.map(\.key)) != Set(thumbPending) else { return }
    thumbTask?.cancel()
    thumbRun &+= 1
    thumbPending = sync ? [] : stale.map(\.key)
    guard !stale.isEmpty else { return }
    if sync {
      for j in stale { if let img = Self.thumb(j) { thumbs[j.photo.id] = Thumb(key: j.key, image: img) } }
      return
    }
    let run = thumbRun
    thumbTask = Task.detached(priority: .utility) { [weak self] in
      for j in stale {
        if Task.isCancelled { return }
        await self?.thumbLanded(j, Self.thumb(j).map { Unchecked($0) }, run: run)
      }
    }
  }

  private func thumbLanded(_ job: Job, _ img: Unchecked<CGImage>?, run: Int) {
    guard run == thumbRun else { return }
    thumbPending.removeAll { $0 == job.key }
    if let img { thumbs[job.photo.id] = Thumb(key: job.key, image: img.value) }
  }

  private nonisolated static func thumb(_ job: Job) -> CGImage? {
    guard let small = decode(job.url, key: key(job.photo, url: job.url), maxPixel: thumbPixels, into: small) else { return nil }
    return draw(job, from: small, height: thumbHeight)
  }

  /// A picture handed between threads: a `CGImage` is immutable once made.
  struct Unchecked<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
  }
}

/// A photo post's picture in the output frame: the composed photo (`PhotoRenderer.compose`, the export's own drawing)
/// once it's ready for this photo, crop and shape; until then, and while a crop is dragged, the same crop of the decoded
/// photo, so the canvas never waits.
struct EditorPhotoSurface: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  @ObservedObject var images: EditorPhotoImages

  var body: some View {
    if let c = images.composed, c.key == model.photoCanvasKey {
      Image(decorative: c.image, scale: 1).resizable().interpolation(.high)
    } else {
      let c = model.crop
      EditorStillSurface(image: playback.still, source: model.sourceSize, visible: CGRect(x: c.x, y: c.y, width: c.w, height: c.h))
    }
  }
}
