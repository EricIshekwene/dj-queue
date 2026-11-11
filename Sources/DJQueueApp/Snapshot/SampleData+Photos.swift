import CoreGraphics
import DJQCore
import Foundation

/// Round 21: sample photo posts for the throwaway snapshot database. The pictures are frames cut from the dev clips
/// (Eric's own footage, the same clips every other shot shows), never a third-party picture.
extension SampleData {
  /// Writes `count` JPEGs into `dir` and returns them in order. `offset` picks other clips, so two posts differ.
  static func photoFiles(store: Store, count: Int, dir: URL, offset: Int = 0, name: String = "photo") throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let clips = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0 AND photos IS NULL")
      .sorted { ($0.part ?? 0, $0.start ?? 0, $0.id) < ($1.part ?? 0, $1.start ?? 0, $1.id) }
    return try (0..<count).map { i in
      let url = dir.appendingPathComponent("\(name)-\(i + 1).jpg")
      var image: CGImage?
      if !clips.isEmpty {
        let v = clips[(offset + i * 3) % clips.count]
        if let file = try store.fileURL(for: v) {
          image = Media.frame(file, at: max(0.5, v.duration * 0.5), maxSize: CGSize(width: 1920, height: 1920))
        }
      }
      try Media.writeJPEG(image ?? placeholder(i + offset), to: url)
      return url
    }
  }

  /// A plain two-tone picture for a run with no readable clip, so a check never fails for want of footage.
  private static func placeholder(_ i: Int) -> CGImage {
    let w = 1600, h = 1200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let hue = CGFloat((i * 47) % 360) / 360
    ctx.setFillColor(CGColor(red: 0.15 + 0.5 * hue, green: 0.2, blue: 0.55 - 0.3 * hue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
    return ctx.makeImage()!
  }

  /// Four photo posts, one in each place a photo can be: a 4-photo carousel and a single photo waiting in Edit, a
  /// 3-photo carousel in the Queue, and a single photo with a set time tomorrow at 3:15 PM. Does nothing when the
  /// database already has photo posts.
  static func addPhotoPosts(store: Store, now: Date, scratch: URL) throws {
    guard try store.videos(where: "photos IS NOT NULL").isEmpty else { return }
    let importer = PhotoImport(store: store)
    let actions = BulkActions(store: store)
    func post(_ name: String, _ count: Int, offset: Int, title: String) throws -> Video? {
      let files = try photoFiles(store: store, count: count, dir: scratch.appendingPathComponent(name), offset: offset, name: name)
      return try importer.add(files: files, mode: .carousel, title: title).posts.first
    }
    _ = try post("loft", 4, offset: 0, title: "Friday at the Loft")
    _ = try post("flyer", 1, offset: 5, title: "Saturday flyer")
    if let queued = try post("last-night", 3, offset: 9, title: "Last night") {
      try actions.sendToQueue([queued.id])
    }
    if let timed = try post("tonight", 1, offset: 14, title: "Doors at nine") {
      let settings = try store.settings()
      let dm = DayMath(settings: settings)
      let at = dm.at(dm.addDays(dm.key(now), 1), minutes: 15 * 60 + 15)
      do {
        try actions.postAt([timed.id], at: at)
      } catch {
        print("sample photos: no set time (\(error))")
      }
    }
  }
}
