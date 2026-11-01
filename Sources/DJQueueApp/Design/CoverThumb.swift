import AppKit
import DJQCore
import SwiftUI

/// Loads cover thumbnails off the main thread via `Media.thumbnail` and keeps decoded images in memory.
final class ThumbCache: @unchecked Sendable {
  static let shared = ThumbCache()
  private let cache = NSCache<NSString, NSImage>()
  private let q = DispatchQueue(label: "djq.thumbs", qos: .userInitiated, attributes: .concurrent)
  private let gate = DispatchSemaphore(value: 3)
  var store: Store?

  func cached(_ videoId: String) -> NSImage? { cache.object(forKey: videoId as NSString) }

  func load(_ video: Video) async -> NSImage? {
    if let i = cached(video.id) { return i }
    guard let store else { return nil }
    return await withCheckedContinuation { cont in
      q.async {
        self.gate.wait()
        defer { self.gate.signal() }
        let img = Media.thumbnail(store: store, video: video).flatMap { NSImage(contentsOf: $0) }
        if let img { self.cache.setObject(img, forKey: video.id as NSString) }
        cont.resume(returning: img)
      }
    }
  }

  /// Synchronous warm-up (snapshot mode).
  func warm(_ videos: [Video]) {
    guard let store else { return }
    DispatchQueue.concurrentPerform(iterations: videos.count) { i in
      let v = videos[i]
      if cached(v.id) != nil { return }
      if let u = Media.thumbnail(store: store, video: v), let img = NSImage(contentsOf: u) {
        cache.setObject(img, forKey: v.id as NSString)
      }
    }
  }

  func invalidate(_ videoId: String) { cache.removeObject(forKey: videoId as NSString) }
}

/// The video's cover (9:16, 4 pt radius). Any source aspect is filled into the box.
struct CoverThumb: View {
  let video: Video?
  var width: CGFloat = DS.queueThumb.width
  var height: CGFloat = DS.queueThumb.height
  var radius: CGFloat = DS.Radius.thumb
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      Rectangle().fill(Color.primary.opacity(0.08))
      if let img = image ?? video.flatMap({ ThumbCache.shared.cached($0.id) }) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else if video?.missing == true {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: min(width, height) * 0.35))
      } else {
        Image(systemName: "film").foregroundStyle(.tertiary).font(.system(size: min(width, height) * 0.3))
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    .task(id: video?.id) {
      guard let v = video, image == nil else { return }
      image = await ThumbCache.shared.load(v)
    }
  }
}
