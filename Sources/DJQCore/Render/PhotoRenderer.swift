import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// The picture side of a photo post (round 21, D6 and D7): read a photo upright, cut it to its crop, scale it to the
/// post's aspect and draw the texts that show on it. The editor's canvas, list thumbnails and the final JPEGs all go
/// through `compose`, so what Eric sees is what posts.
public enum PhotoRenderer {
  /// Bump when a photo render's pixels change (every photo edit hash changes). Separate from `Renderer.pipelineVersion`,
  /// so video hashes never move with it.
  public static let pipelineVersion = "photo-1"

  /// JPEG quality of a rendered photo (D6).
  public static let quality = 0.9

  // MARK: Reading

  /// The photo's pixel size the way it's seen: EXIF orientation applied. nil when ImageIO can't read it.
  public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
    let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    return (5...8).contains(o) ? (h, w) : (w, h)  // 5–8 are the quarter turns
  }

  /// The photo upright (EXIF orientation applied), at full size or scaled so its longer side is at most `maxPixel`.
  public static func load(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let size = pixelSize(of: url) else { return nil }
    let full = max(size.width, size.height)
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(full, max(2, maxPixel ?? full)),
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
  }

  // MARK: Composing (pure)

  /// One photo as it posts: `image` (upright; full size, or a smaller load of a `sourceSize` photo) cut to `crop` (in
  /// the photo's own pixels), scaled into `size` and the `layers` drawn on top. Opaque sRGB.
  public static func compose(_ image: CGImage, sourceSize: CGSize, crop: CropRect, aspect: Aspect, size: CGSize,
                             layers: [TextLayer] = []) -> CGImage? {
    var c = crop
    if sourceSize.width > 0, Double(sourceSize.width) != Double(image.width) {
      let k = Double(image.width) / Double(sourceSize.width)
      c = CropRect(x: c.x * k, y: c.y * k, w: c.w * k, h: c.h * k)
    }
    let r = Media.pixelCrop(c, sourceWidth: image.width, sourceHeight: image.height)
    guard let cropped = image.cropping(to: r) else { return nil }
    let w = Int(size.width), h = Int(size.height)
    guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let frame = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))  // under a photo with see-through parts
    ctx.fill(frame)
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: frame)
    if let overlay = TextOverlay.image(for: layers, aspect: aspect) { ctx.draw(overlay, in: frame) }
    return ctx.makeImage()
  }

  /// Photo `index` of a post from values in hand (the editor's unsaved edit and version): `image` is that photo
  /// upright. `version` nil = without text.
  public static func image(_ image: CGImage, photo: PhotoItem, index: Int, count: Int, edit: Edit, version: ResolvedVersion?,
                           defaults: NewClipDefaults, size: CGSize? = nil) -> CGImage? {
    let aspect = PhotoRules.aspect(edit, defaults: defaults)
    let out = aspect.outputSize
    return compose(image, sourceSize: CGSize(width: photo.width, height: photo.height),
                   crop: PhotoRules.crop(for: photo, edit: edit, aspect: aspect), aspect: aspect,
                   size: size ?? CGSize(width: out.w, height: out.h),
                   layers: PhotoRules.layers(version, onPhoto: index, of: count))
  }

  /// Photo `index` of a saved post at `size` (nil = the output size), with or without its text. The same code as the
  /// render, so it is what posts. nil when the photo can't be read.
  public static func preview(store: Store, video: Video, index: Int, size: CGSize? = nil, withText: Bool = true,
                             version: Int = 1) -> CGImage? {
    guard let photos = video.photos, photos.indices.contains(index), let url = try? store.photoURL(photos[index], of: video),
          let settings = try? store.settings(), let edit = try? store.edit(videoId: video.id) else { return nil }
    let photo = photos[index]
    let aspect = PhotoRules.aspect(edit, defaults: settings.defaults)
    let crop = PhotoRules.crop(for: photo, edit: edit, aspect: aspect)
    guard let img = load(url, maxPixel: size.map { loadSize(photo, crop: crop, target: $0) }) else { return nil }
    let rv = withText ? (try? store.resolvedVersion(videoId: video.id, number: version, settings: settings)) ?? nil : nil
    return image(img, photo: photo, index: index, count: photos.count, edit: edit, version: rv, defaults: settings.defaults, size: size)
  }

  /// The longer side to load a photo at so its crop still has every pixel `target` needs.
  static func loadSize(_ photo: PhotoItem, crop: CropRect, target: CGSize) -> Int {
    let k = max(Double(target.width) / max(1, crop.w), Double(target.height) / max(1, crop.h))
    let full = max(photo.width, photo.height)
    return min(full, Int((Double(full) * min(1, k)).rounded(.up)) + 2)
  }

  /// A JPEG of `img` with nothing but the picture in it: no EXIF, no location, sRGB.
  static func writeJPEG(_ img: CGImage, to url: URL) throws { try Media.writeJPEG(img, to: url, quality: quality) }
}

// MARK: - Rendering a photo post (the photo half of `RenderService`)

extension Renderer {
  /// "<video name> – v<n> – 01.jpg" (1-based, two digits).
  public static func photoOutputName(video: Video, versionNo: Int, index: Int) -> String {
    let base = (outputName(video: video, versionNo: versionNo, platform: nil) as NSString).deletingPathExtension
    return "\(base) – \(String(format: "%02d", index + 1)).jpg"
  }

  struct PhotoPlan {
    var video: Video
    var photos: [PhotoItem]
    var edit: Edit
    var aspect: Aspect
    var version: ResolvedVersion
    var hash: String
  }

  /// Everything in a photo post's files, canonically encoded for `editHash`: the photos in order (by content), the
  /// aspect, each photo's crop, and the texts with their look and windows.
  struct PhotoHashInput: Codable {
    var pipeline: String
    var photos: [String]
    var aspect: String
    var crops: [CropRect]
    var texts: [HashInput.Text]
  }

  func photoPlan(_ video: Video, versionNo: Int) throws -> PhotoPlan {
    let settings = try store.settings()
    guard let version = try store.resolvedVersion(videoId: video.id, number: versionNo, settings: settings) else {
      throw RenderError("\(video.name) has no version \(versionNo)")
    }
    let photos = video.photos ?? []
    let edit = try store.edit(videoId: video.id)
    let aspect = PhotoRules.aspect(edit, defaults: settings.defaults)
    let input = PhotoHashInput(
      pipeline: PhotoRenderer.pipelineVersion, photos: photos.map { $0.fingerprint ?? $0.file }, aspect: aspect.rawValue,
      crops: photos.map { PhotoRules.crop(for: $0, edit: edit, aspect: aspect) },
      texts: PreviewKeys.layerWindows(version, trimDuration: Double(photos.count)).map { HashInput.Text($0.layer) })
    let hash = SHA256.hash(data: try JSONCoding.encoder.encode(input)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return PhotoPlan(video: video, photos: photos, edit: edit, aspect: aspect, version: version, hash: hash)
  }

  /// The finished render for this plan whose every file is still there, newest first.
  func photoCurrent(_ p: PhotoPlan) throws -> Render? {
    try store.renders(where: "video_id=? AND version_no=? AND edit_hash=? AND scope='all' AND status='done' AND deleted_at IS NULL",
                      [p.video.id, p.version.number, p.hash])
      .last { r in !r.allPaths.isEmpty && r.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
  }

  /// `ensureRender` for a photo post (called with `renderLock` held): the same row, claim and cross-process lock as a
  /// video render.
  func ensurePhotoRender(_ video: Video, versionNo: Int) throws -> Render {
    let p = try photoPlan(video, versionNo: versionNo)
    if let r = try photoCurrent(p) { return r }
    guard !p.photos.isEmpty else { throw RenderError("Can't render \(video.name): it has no photos") }
    let deadline = Date().addingTimeInterval(waitForOtherProcess)
    while true {
      let row = try candidateRow(videoId: video.id, versionNo: versionNo, hash: p.hash, scope: "all")
      if try acquireLock(row.id) {
        defer { releaseLock(row.id) }
        if let r = try photoCurrent(p) { return r }
        try store.resetStaleRender(id: row.id)
        guard try store.claimRender(id: row.id) else { throw RenderError("Render \(row.id) is being rendered elsewhere") }
        return try renderPhotos(p, row: row)
      }
      if Date() > deadline { throw RenderError("Timed out waiting for another process to render \(video.name)") }
      Thread.sleep(forTimeInterval: 0.25)
      if let r = try photoCurrent(p) { return r }
    }
  }

  private func renderPhotos(_ p: PhotoPlan, row: Render) throws -> Render {
    do {
      let started = Date()
      let files = try performPhotos(p, renderId: row.id)
      let paths = files.map(\.path)
      let size = files.reduce(Int64(0)) { $0 + max(0, Intake.size($1)) }
      try store.finishRender(id: row.id, outputPath: paths[0], coverPath: nil, loudness: nil, duration: 0, size: size)
      try store.setRenderMorePaths(id: row.id, Array(paths.dropFirst()))
      // Rows whose files were just replaced (same names) or that this render supersedes (same key) are retired, and
      // the files this one didn't replace go with them (a carousel that lost a photo would otherwise leave its last
      // file in Ready to Post).
      for old in try store.renders(where: "deleted_at IS NULL AND id<>? AND video_id=? AND version_no=? AND scope='all'",
                                   [row.id, p.video.id, p.version.number])
      where old.status != .rendering && (old.editHash == p.hash || old.allPaths.contains { paths.contains($0) }) {
        for path in old.allPaths where !paths.contains(path) && isAppOutput(URL(fileURLWithPath: path)) {
          try? FileManager.default.removeItem(atPath: path)
        }
        try store.markRenderDeleted(id: old.id)
      }
      let secs = String(format: "%.1f", Date().timeIntervalSince(started))
      try? store.logEvent("render", "Rendered \(files.count) photo\(files.count == 1 ? "" : "s") of \(p.video.name) in \(secs) s",
                          videoId: p.video.id)
      onProgress?(row.id, 1)
      guard let r = try store.render(id: row.id) else { throw RenderError("Render \(row.id) vanished") }
      return r
    } catch {
      try? store.setRenderStatus(id: row.id, status: .failed, error: "\(error)")
      try? store.logEvent("render_failed", "Render failed for \(p.video.name) v\(p.version.number): \(error)", videoId: p.video.id)
      throw error
    }
  }

  /// One JPEG per photo, written to the work folder first and moved into place only when every photo rendered.
  func performPhotos(_ p: PhotoPlan, renderId: String) throws -> [URL] {
    let fm = FileManager.default
    let work = store.paths.work
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    let (ow, oh) = p.aspect.outputSize
    var tmps: [URL] = []
    defer { for u in tmps { try? fm.removeItem(at: u) } }
    onProgress?(renderId, 0)
    for (i, photo) in p.photos.enumerated() {
      let src = try store.photoURL(photo, of: p.video)
      guard fm.fileExists(atPath: src.path) else { throw RenderError("Photo \(i + 1) of \(p.video.name) is missing") }
      guard let img = PhotoRenderer.load(src) else { throw RenderError("Photo \(i + 1) of \(p.video.name) can't be read") }
      guard let out = PhotoRenderer.compose(img, sourceSize: CGSize(width: photo.width, height: photo.height),
                                            crop: PhotoRules.crop(for: photo, edit: p.edit, aspect: p.aspect), aspect: p.aspect,
                                            size: CGSize(width: ow, height: oh),
                                            layers: PhotoRules.layers(p.version, onPhoto: i, of: p.photos.count)) else {
        throw RenderError("Photo \(i + 1) of \(p.video.name) can't be cropped")
      }
      let tmp = work.appendingPathComponent("\(renderId)-\(getpid())-\(i).jpg")
      tmps.append(tmp)
      try PhotoRenderer.writeJPEG(out, to: tmp)
      onProgress?(renderId, Double(i + 1) / Double(p.photos.count) * 0.95)
    }
    let dir = try destinationDir(p.video)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var placed: [URL] = []
    for (i, tmp) in tmps.enumerated() {
      let dest = dir.appendingPathComponent(Self.photoOutputName(video: p.video, versionNo: p.version.number, index: i))
      try place(tmp, at: dest)
      placed.append(dest)
    }
    return placed
  }
}
