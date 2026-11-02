import AppKit
import DJQCore
import Observation
import SwiftUI

/// Preview stamp (version 1) and invalidation generation per video (S6). Covers reload when either changes: any
/// edit, text, New-clip defaults or clip-row change moves the stamp; `AppModel.previewChanged` bumps the generation.
@MainActor
@Observable
final class ThumbStamps {
  static let shared = ThumbStamps()
  private(set) var stamps: [String: String] = [:]
  private(set) var generation: [String: Int] = [:]
  func update(_ s: [String: String]) { if s != stamps { stamps = s } }
  func key(_ videoId: String) -> String { "\(videoId)|\(stamps[videoId] ?? "")" }
  func gen(_ videoId: String) -> Int { generation[videoId] ?? 0 }
  func bump(_ videoId: String) { generation[videoId, default: 0] += 1 }
}

/// Loads covers off the main thread and keeps decoded images in memory, keyed by video id + edit stamp.
/// Short-form: `Media.thumbnail` — the cover as posted (cover frame, crop, aspect, and the text when "cover
/// includes text" is on) at text `version`.
/// Long-form: a plain 16:9 frame (no 9:16 crop).
final class ThumbCache: @unchecked Sendable {
  static let shared = ThumbCache()
  private let cache = NSCache<NSString, NSImage>()
  private let q = DispatchQueue(label: "djq.thumbs", qos: .userInitiated, attributes: .concurrent)
  private let gate = DispatchSemaphore(value: 3)
  var store: Store?

  func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

  func load(_ video: Video, key: String, version: Int = 1) async -> NSImage? {
    if let i = cached(key) { return i }
    guard let store else { return nil }
    return await withCheckedContinuation { cont in
      q.async {
        self.gate.wait()
        defer { self.gate.signal() }
        let img = Self.make(store: store, video: video, version: version)
        if let img { self.cache.setObject(img, forKey: key as NSString) }
        cont.resume(returning: img)
      }
    }
  }

  static func make(store: Store, video: Video, version: Int = 1) -> NSImage? {
    if video.type == .long {
      guard let url = try? store.fileURL(for: video),
            let cg = Media.frame(url, at: min(60, max(0, video.duration / 2)), maxSize: CGSize(width: 480, height: 270)) else { return nil }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    return Media.thumbnail(store: store, video: video, version: version).flatMap { NSImage(contentsOf: $0) }
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
}
