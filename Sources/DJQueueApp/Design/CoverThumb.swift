import AppKit
import DJQCore
import Observation
import SwiftUI

/// Last edit time per video; covers reload when it changes (crop, aspect or cover time edited).
@MainActor
@Observable
final class ThumbStamps {
  static let shared = ThumbStamps()
  private(set) var stamps: [String: Double] = [:]
  func update(_ s: [String: Double]) { if s != stamps { stamps = s } }
  func key(_ videoId: String) -> String { "\(videoId)|\(stamps[videoId] ?? 0)" }
}

/// Loads covers off the main thread and keeps decoded images in memory, keyed by video id + edit stamp.
/// Short-form: `Media.thumbnail` at the editor's cover time (crop + aspect applied).
/// Long-form: a plain 16:9 frame (no 9:16 crop).
final class ThumbCache: @unchecked Sendable {
  static let shared = ThumbCache()
  private let cache = NSCache<NSString, NSImage>()
  private let q = DispatchQueue(label: "djq.thumbs", qos: .userInitiated, attributes: .concurrent)
  private let gate = DispatchSemaphore(value: 3)
  var store: Store?

  func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

  func load(_ video: Video, key: String) async -> NSImage? {
    if let i = cached(key) { return i }
    guard let store else { return nil }
    return await withCheckedContinuation { cont in
      q.async {
        self.gate.wait()
        defer { self.gate.signal() }
        let img = Self.make(store: store, video: video)
        if let img { self.cache.setObject(img, forKey: key as NSString) }
        cont.resume(returning: img)
      }
    }
  }

  static func make(store: Store, video: Video) -> NSImage? {
    if video.type == .long {
      guard let url = try? store.fileURL(for: video),
            let cg = Media.frame(url, at: min(60, max(0, video.duration / 2)), maxSize: CGSize(width: 480, height: 270)) else { return nil }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    let cover = (try? store.edit(videoId: video.id))?.coverTime
    return Media.thumbnail(store: store, video: video, at: cover).flatMap { NSImage(contentsOf: $0) }
  }

  /// Synchronous warm-up (snapshot mode).
  func warm(_ videos: [Video], keys: [String: String]) {
    guard let store else { return }
    DispatchQueue.concurrentPerform(iterations: videos.count) { i in
      let v = videos[i]
      guard let key = keys[v.id], cached(key) == nil else { return }
      if let img = Self.make(store: store, video: v) { cache.setObject(img, forKey: key as NSString) }
    }
  }

  /// Drops every cached cover of a video (all stamps).
  func invalidate(_ videoId: String) {
    lock.withLock { generation[videoId, default: 0] += 1 }
  }

  private let lock = NSLock()
  private var generation: [String: Int] = [:]
  func gen(_ videoId: String) -> Int { lock.withLock { generation[videoId] ?? 0 } }
}
