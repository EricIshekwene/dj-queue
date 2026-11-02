import AppKit
import DJQCore
import SwiftUI

/// Video → `DSClip` (the design system's card model). One mapping for every screen so cards read the same
/// everywhere; screens may post-process the result (e.g. set `position`, add `tags`).
extension AppModel {
  /// The card model for `v` on `screen`.
  ///
  /// - title: `displayName` (Title, else the raw tag verbatim); subtitle: session name.
  /// - poster: cached cover (call `requestPoster(v)` to load it; ClipCollection does); proxyURL: `proxyURLs[v.id]`.
  /// - kind: only "Talking" (DJ vid shows nothing). Never the version.
  /// - issues (warning chips) / blocks (danger chips) from `issuesByVideo`, as short text ("No crop",
  ///   "Too long for X · 2:32 > 2:20").
  /// - suggestions: up to 3, only on Score/Edit and only while the clip has no Title.
  /// - platforms: only planned/posted ones (latest attempt per platform); never on Score/Edit.
  /// - dateText: Queue only ("Today" / "Thu 5 Nov" / "Not scheduled").
  func dsClip(_ v: Video, for screen: Screen) -> DSClip {
    var c = DSClip(id: v.id, title: displayName(v))
    let session = sessionName(v)
    c.subtitle = session.isEmpty ? nil : session
    applyPreview(clipPreview(v), to: &c)
    c.durationText = Fmt.duration(clipDuration(v))
    c.kind = v.kind == .talking ? "Talking" : nil
    c.score = v.score
    c.isMissing = v.missing
    c.isPinned = nextSlotByVideo[v.id]?.pinned ?? false
    let chips = issueChips(issuesByVideo[v.id] ?? [])
    c.issues = chips.issues
    c.blocks = chips.blocks
    if (screen == .score || screen == .edit) && v.titleText == nil {
      c.suggestions = (suggestionsByVideo[v.id] ?? []).prefix(3).map { DSTitleSuggestion(text: $0.text, detail: Self.tracksText($0.tracks)) }
    }
    if screen != .score && screen != .edit { c.platforms = platformStates(v.id) }
    if screen == .queue { c.dateText = dateText(v) }
    return c
  }

  /// The card model for `v` showing text `version` (Posts/Week: the post's version).
  func dsClip(_ v: Video, for screen: Screen, version: Int) -> DSClip {
    var c = dsClip(v, for: screen)
    if version != 1 { applyPreview(clipPreview(v, version: version), to: &c) }
    return c
  }

  /// The card model for a post: its version's text, and its current render's cover when there is one.
  func dsClip(_ v: Video, for screen: Screen, post: PlatformPost) -> DSClip {
    var c = dsClip(v, for: screen)
    if let p = clipPreview(post: post) { applyPreview(p, to: &c) }
    return c
  }

  /// Copies a `ClipPreview` into the card model (S6).
  func applyPreview(_ p: ClipPreview, to c: inout DSClip) {
    c.poster = p.cover
    c.proxyURL = p.proxyURL
    c.overlay = p.overlay
    c.textWindow = p.textWindow
    c.loopRange = p.loopRange
    c.isUpdatingPreview = p.isUpdating
    c.previewStamp = p.stamp
  }

  /// Length shown on cards: Eric's markers when set (the default trim), else the clip file.
  func clipDuration(_ v: Video) -> Double {
    if let i = v.markerIn, let o = v.markerOut, o > i { return o - i }
    return v.duration
  }

  /// "Today" / "Thu 5 Nov" for the clip's next planned day, "Not scheduled" otherwise.
  func dateText(_ v: Video) -> String {
    guard let s = nextSlotByVideo[v.id] else { return "Not scheduled" }
    return s.date == todayKey ? "Today" : Fmt.day(dm.date(s.date), tz: tz, style: "EEE d MMM")
  }

  /// Platforms with a post (latest attempt), in Settings order. Empty when the clip isn't planned.
  func platformStates(_ videoId: String) -> [DSClipPlatform] {
    let latest = latestPosts(videoId)
    return Platform.allCases.compactMap { p in latest[p].map { DSClipPlatform(platform: p, state: Self.platformState($0.state)) } }
  }

  static func platformState(_ s: PostState) -> DSPlatformState {
    switch s {
    case .posted: .posted
    case .skipped: .skipped
    case .due, .overdue: .due
    case .planned, .rendering, .rendered: .planned
    default: s.isProblem || s.isCopyright ? .failed : .planned
    }
  }

  /// Chip text for validation issues, from the core stage wording (`ValidationIssue.chipText` / `chipDetail`,
  /// `Kind.isBlock`, `chipOrder`): missing pieces → warning chips, hard blocks → danger chips ("Too long for X ·
  /// 2:32 > 2:20"). A missing file is left out: `DSClip.isMissing` draws its own "File missing" chip.
  func issueChips(_ list: [ValidationIssue]) -> (issues: [String], blocks: [String]) {
    var issues: [String] = [], blocks: [String] = [], seen = Set<String>()
    for i in list.sorted(by: { $0.kind.chipOrder < $1.kind.chipOrder }) where i.kind != .missingFile {
      let text = i.chipText + (i.chipDetail.map { " · \($0)" } ?? "")
      guard seen.insert(text).inserted else { continue }
      if i.kind.isBlock { blocks.append(text) } else { issues.append(text) }
    }
    return (issues, blocks)
  }

  /// "Song – Artist · Song 2" (tertiary detail on suggestion chips).
  static func tracksText(_ tracks: [Track]) -> String? {
    guard !tracks.isEmpty else { return nil }
    return tracks.map { t in t.artist.map { "\(t.title) – \($0)" } ?? t.title }.joined(separator: " · ")
  }

  // MARK: Posters

  /// ThumbCache key for a clip's current cover at text `version` (preview stamp + invalidation generation).
  func posterKey(_ id: String, version: Int = 1) -> String {
    let g = "|g\(ThumbStamps.shared.gen(id))"
    return version == 1 ? ThumbStamps.shared.key(id) + g : "\(id)|\(previewStamp(id, version: version))|v\(version)" + g
  }

  /// The decoded cover if loaded (no I/O). Never an older cover: a changed clip shows nothing until its new one lands.
  func poster(_ v: Video, version: Int = 1) -> NSImage? {
    let k = posterKey(v.id, version: version)
    return posters[k] ?? ThumbCache.shared.cached(k)
  }

  /// Loads a cover (and the overlay + text timing, S6) off-main once; `posters` updates when it lands.
  func requestPoster(_ v: Video, version: Int = 1) {
    notePreviewShown(v.id)
    requestPreviewInfo(v, version: version)
    let k = posterKey(v.id, version: version)
    guard posters[k] == nil, ThumbCache.shared.cached(k) == nil, !posterPending.contains(k) else { return }
    if frozen {  // snapshot: deterministic, load now
      if let store = ThumbCache.shared.store, let img = ThumbCache.make(store: store, video: v, version: version) { posters[k] = img }
      return
    }
    posterPending.insert(k)
    Task {
      let img = await ThumbCache.shared.load(v, key: k, version: version)
      posterPending.remove(k)
      if let img { posters[k] = img }
    }
  }
}
