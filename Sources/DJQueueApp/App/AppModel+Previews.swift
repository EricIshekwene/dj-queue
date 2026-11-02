import AppKit
import DJQCore
import SwiftUI

/// What a list shows for one clip, or for one post's text version (round 4 S6: "lists show the edited clip").
///
/// Draw it like the editor does: loop `proxyURL` (crop + aspect + trim, 540 px) and put `overlay` on top only while
/// the player time is inside `textWindow`. Until the proxy lands show `cover` (cover frame + text when "cover
/// includes text" is on), and when `isUpdating` say so quietly — never loop an older proxy or the raw source.
/// `DSVideoPreview` / `DSClipCard` already do all of this from these fields.
struct ClipPreview {
  /// Preview identity: changes with any edit, text-version change, New-clip defaults change or clip-row change.
  /// Put it in every `.task(id:)` / cache key that loads or plays this clip's preview.
  var stamp: String
  /// The current proxy (nil while it is being made, or before it was asked for).
  var proxyURL: URL?
  /// The cover as posted (a current render's own cover for a post when there is one).
  var cover: NSImage?
  /// The on-video text, ≤540 px wide, transparent, at the clip's aspect (nil = no text, or not loaded yet).
  var overlay: CGImage?
  /// When `overlay` shows, in seconds of the proxy's own timeline (0 = the start of the loop).
  var textWindow: ClosedRange<Double>?
  /// The part of the proxy that loops (nil = the whole proxy, which is what every proxy is today).
  var loopRange: ClosedRange<Double>?
  /// The edit changed and its new proxy is still being made: show `cover` with an "Updating preview" state.
  var isUpdating: Bool
  /// `cover` is the current render's cover (Posts/Week).
  var isRenderCover = false
}

/// Resolved, per (clip, version, stamp): what the overlay and its timing need. Loaded off the main thread.
struct PreviewInfo: Sendable {
  var stamp: String
  var aspect: Aspect
  var trimIn: Double
  /// Relative to the trim start (the renderer's rule).
  var textWindow: ClosedRange<Double>?
  var textKey: String
  var version: ResolvedVersion?
  var overlayKey: String { "\(textKey)" }
}

extension AppModel {
  /// Overlay images (≤540 wide), least recently used evicted past 64 MB. Keyed by `PreviewKeys.textKey` (which
  /// covers text, style, size, position and aspect), so clips with the same text share one image.
  nonisolated static let overlayCache = CostCappedCache<String, CGImage>(costLimit: 64 << 20)
  /// Width of list overlays (the proxy width).
  nonisolated static let overlayWidth = Media.proxyWidth

  // MARK: Stamps

  /// The preview stamp of a clip at text `version` (1 for every list; the post's version for Posts/Week).
  func previewStamp(_ videoId: String, version: Int = 1) -> String {
    if version == 1, let s = ThumbStamps.shared.stamps[videoId] { return s }
    guard let v = videoById[videoId] else { return "" }
    return previewTable.stamp(for: v, version: version)
  }

  /// THE invalidation entry: these clips' previews changed (edit, text, defaults, file). Drops their proxy URL and
  /// cover at once (so nothing old shows), marks the ones that were playing as updating, and re-requests whatever
  /// was recently on screen. Called by `refresh()` for every clip whose stamp changed and when the editor closes
  /// (any path). Screens never need to call it.
  func previewChanged(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    for id in ids {
      ThumbStamps.shared.bump(id)
      if proxyURLs[id] != nil || proxyPending.contains(id) { previewUpdating.insert(id) }
      proxyURLs[id] = nil
      proxyPending.remove(id)
    }
    previewInfo = previewInfo.filter { k, _ in !ids.contains(String(k.split(separator: "|").first ?? "")) }
    renderCoverKeys = renderCoverKeys.filter { _, k in !ids.contains(String(k.split(separator: "|").dropFirst().first ?? "")) }
    let again = recentPreviewIds.filter(ids.contains)
    for id in again {
      guard let v = videoById[id] else { continue }
      requestPoster(v)
    }
    let playAgain = recentProxyIds.filter(ids.contains)
    if !playAgain.isEmpty { requestProxies(playAgain, keepOthersVisible: true) }
    // Nothing on screen is waiting for these: no "Updating" state lingers for clips no list will ask about.
    previewUpdating.subtract(ids.subtracting(playAgain))
  }

  /// Stamps from the database right now (after the editor's saves land) for `ids`; clips whose stamp moved get
  /// `previewChanged` at once instead of at the next refresh.
  func refreshPreviewStamps(_ ids: [String]) {
    guard let table = try? store.previewStampTable() else { previewChanged(Set(ids)); return }
    var changed = Set<String>()
    var s1: [String: String] = ThumbStamps.shared.stamps
    for id in ids {
      guard let v = (try? store.video(id: id)) ?? videoById[id] else { continue }
      let new = table.stamp(for: v, version: .max)
      if previewAllStamps[id] != new { changed.insert(id) }
      previewAllStamps[id] = new
      s1[id] = table.stamp(for: v, version: 1)
    }
    previewTable = table
    previewStampsAt = Date()
    ThumbStamps.shared.update(s1)
    previewChanged(changed)
  }

  // MARK: Reading (no I/O)

  /// The clip's preview at text `version` (cover, proxy, overlay, timing, updating). Call `requestPreview` (or
  /// `requestPoster`, which does it) when the clip appears.
  func clipPreview(_ v: Video, version: Int = 1) -> ClipPreview {
    let stamp = previewStamp(v.id, version: version)
    let proxy = v.missing || v.type != .short ? nil : proxyURLs[v.id]
    var p = ClipPreview(stamp: stamp, proxyURL: proxy, cover: version == 1 ? poster(v) : poster(v, version: version),
                        overlay: nil, textWindow: nil, loopRange: nil,
                        isUpdating: proxy == nil && previewUpdating.contains(v.id))
    if v.type == .short, let info = previewInfo[Self.infoKey(v.id, version)], info.stamp == stamp, info.textKey != "none" {
      p.overlay = Self.overlayCache.value(info.overlayKey)
      let offset = playback.loop == .wholeFile ? info.trimIn : 0
      p.textWindow = info.textWindow.map { ($0.lowerBound + offset)...($0.upperBound + offset) }
    }
    return p
  }

  /// A post's preview: its own text version, and its current render's cover when the render is current (editHash
  /// matches and the file exists). Call `requestPreview(post:)` when it appears.
  func clipPreview(post: PlatformPost) -> ClipPreview? {
    guard let v = videoById[post.videoId] else { return nil }
    var p = clipPreview(v, version: post.versionNo)
    if let k = renderCoverKeys[post.id], k.hasSuffix("|\(p.stamp)"), let img = posters[k] {
      p.cover = img
      p.isRenderCover = true
    }
    return p
  }

  // MARK: Loading

  /// Loads what `clipPreview(v, version:)` needs off the main thread: the cover, the text timing and the overlay.
  /// Cheap to call repeatedly (onAppear, `.task(id: stamp)`). The proxy is asked for separately (`requestProxies`).
  func requestPreview(_ v: Video, version: Int = 1) {
    if version == 1 { requestPoster(v) } else { requestPoster(v, version: version) }
  }

  /// `requestPreview` for a post's version, plus its current render's cover.
  func requestPreview(post: PlatformPost) {
    guard let v = videoById[post.videoId] else { return }
    requestPreview(v, version: post.versionNo)
    let stamp = previewStamp(v.id, version: post.versionNo)
    let pending = "render|\(post.id)|\(stamp)"
    if let k = renderCoverKeys[post.id], k.hasSuffix("|\(stamp)") { return }
    guard post.renderId != nil, !posterPending.contains(pending) else { return }
    posterPending.insert(pending)
    let r = renderer, pid = post.id, vid = v.id, n = post.versionNo, plat = post.platform
    let load: @Sendable () -> NSImage? = {
      guard let render = try? r.currentRender(videoId: vid, versionNo: n, platform: plat), let path = render.coverPath,
            FileManager.default.fileExists(atPath: path) else { return nil }
      return Self.loadImage(URL(fileURLWithPath: path), maxPixel: 640)
    }
    let land: (NSImage?) -> Void = { img in
      self.posterPending.remove(pending)
      guard let img else { return }
      let key = "render|\(vid)|\(pid)|\(stamp)"
      self.posters[key] = img
      self.renderCoverKeys[pid] = key
    }
    if frozen { land(load()); return }
    Task.detached(priority: .utility) {
      let img = load()
      await MainActor.run { land(img) }
    }
  }

  /// Loads (or refreshes after a cache eviction) the overlay + timing of `v` at `version`.
  func requestPreviewInfo(_ v: Video, version: Int) {
    guard v.type == .short, !v.missing else { return }
    let key = Self.infoKey(v.id, version)
    let stamp = previewStamp(v.id, version: version)
    if let i = previewInfo[key], i.stamp == stamp, i.textKey == "none" || Self.overlayCache.value(i.overlayKey) != nil { return }
    let pending = "\(key)|\(stamp)"
    guard !previewInfoPending.contains(pending) else { return }
    previewInfoPending.insert(pending)
    let s = store, id = v.id
    let land: (PreviewInfo?) -> Void = { info in
      self.previewInfoPending.remove(pending)
      guard let info, self.previewStamp(id, version: version) == info.stamp else { return }
      self.previewInfo[key] = info
    }
    if frozen { land(Self.loadPreviewInfo(store: s, videoId: id, version: version, stamp: stamp)); return }
    Task.detached(priority: .userInitiated) {
      let info = Self.loadPreviewInfo(store: s, videoId: id, version: version, stamp: stamp)
      await MainActor.run { land(info) }
    }
  }

  nonisolated static func infoKey(_ id: String, _ version: Int) -> String { "\(id)|v\(version)" }

  /// Resolves the edit + version and draws the overlay into `overlayCache` (if not there yet).
  nonisolated static func loadPreviewInfo(store: Store, videoId: String, version: Int, stamp: String) -> PreviewInfo? {
    guard let settings = try? store.settings(), let re = try? store.resolvedEdit(videoId: videoId, settings: settings) else { return nil }
    let rv = (try? store.resolvedVersion(videoId: videoId, number: version, settings: settings)) ?? nil
    let trim = re.trim()
    let textKey = PreviewKeys.textKey(rv, aspect: re.aspect)
    let info = PreviewInfo(stamp: stamp, aspect: re.aspect, trimIn: trim.start,
                           textWindow: PreviewKeys.textWindow(rv, trimDuration: trim.end - trim.start), textKey: textKey, version: rv)
    if let rv, textKey != "none", overlayCache.value(info.overlayKey) == nil,
       let img = TextOverlay.image(for: rv, aspect: re.aspect, maxWidth: overlayWidth) {
      overlayCache.set(img, for: info.overlayKey, cost: img.bytesPerRow * img.height)
    }
    return info
  }

  /// A JPEG/PNG decoded at most `maxPixel` on its long side.
  nonisolated static func loadImage(_ url: URL, maxPixel: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }

  /// Remembers clips recently shown (bounded), so `previewChanged` can re-request exactly those.
  func notePreviewShown(_ id: String) {
    if let i = recentPreviewIds.firstIndex(of: id) { recentPreviewIds.remove(at: i) }
    recentPreviewIds.append(id)
    if recentPreviewIds.count > 160 { recentPreviewIds.removeFirst(recentPreviewIds.count - 160) }
  }
}
