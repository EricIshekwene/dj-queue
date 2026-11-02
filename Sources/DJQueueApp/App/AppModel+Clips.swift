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
    c.poster = poster(v)
    c.proxyURL = v.missing ? nil : proxyURLs[v.id]
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

  /// Short chip text for validation issues: missing pieces → warning chips, hard platform blocks → danger chips.
  func issueChips(_ list: [ValidationIssue]) -> (issues: [String], blocks: [String]) {
    var issues: [String] = [], blocks: [String] = []
    for i in list {
      let p = i.platform?.displayName ?? ""
      switch i.kind {
      case .heldInEdit: issues.append("Sent back from Queue")
      case .noCrop: issues.append("No crop")
      case .noText: issues.append("No text")
      case .noCaption: issues.append("No caption")
      case .noTitle: issues.append("No title")
      case .missingFile: break  // DSClip.isMissing draws its own chip
      case .tooLong:
        let detail = i.count.flatMap { c in i.limit.map { " · \(Validation.fmt(c)) > \(Validation.fmt($0))" } } ?? ""
        blocks.append("Too long for \(p)\(detail)")
      case .tooLarge: blocks.append("Too large for \(p)")
      case .captionTooLong:
        let detail = i.count.flatMap { c in i.limit.map { " · \(Int(c))/\(Int($0))" } } ?? ""
        blocks.append("Caption too long for \(p)\(detail)")
      case .titleTooLong: blocks.append("YouTube title too long")
      case .corrupt: blocks.append("Edit unreadable")
      }
    }
    return (issues, blocks)
  }

  /// "Song – Artist · Song 2" (tertiary detail on suggestion chips).
  static func tracksText(_ tracks: [Track]) -> String? {
    guard !tracks.isEmpty else { return nil }
    return tracks.map { t in t.artist.map { "\(t.title) – \($0)" } ?? t.title }.joined(separator: " · ")
  }

  // MARK: Posters

  /// ThumbCache key for a clip's current cover (edit stamp + invalidation generation).
  func posterKey(_ id: String) -> String { "\(ThumbStamps.shared.key(id))|g\(ThumbCache.shared.gen(id))" }

  /// The decoded cover if loaded (no I/O).
  func poster(_ v: Video) -> NSImage? {
    let k = posterKey(v.id)
    return posters[k] ?? ThumbCache.shared.cached(k)
  }

  /// Loads a cover off-main once; `posters` updates when it lands (cards re-render).
  func requestPoster(_ v: Video) {
    let k = posterKey(v.id)
    guard posters[k] == nil, ThumbCache.shared.cached(k) == nil, !posterPending.contains(k) else { return }
    if frozen {  // snapshot: deterministic, load now
      if let store = ThumbCache.shared.store, let img = ThumbCache.make(store: store, video: v) { posters[k] = img }
      return
    }
    posterPending.insert(k)
    Task {
      let img = await ThumbCache.shared.load(v, key: k)
      posterPending.remove(k)
      if let img { posters[k] = img }
    }
  }
}
