import AppKit
import DJQCore
import SwiftUI

/// Today + menu bar helpers (Planning leaf). Pure reads of AppModel state, plus copy actions whose toasts use
/// platform names (never codes).
extension AppModel {
  /// One status for a post (Today rows, Week slot chips, menu bar).
  func postStatus(_ p: PlatformPost) -> DSXPostStatus {
    if let r = p.resolution { return .resolved(Self.resolutionLabel(r)) }
    switch p.state {
    case .posted: return .posted
    case .skipped: return .skipped
    case .failed: return .failed
    case .copyrightBlocked, .copyrightMuted, .removed: return .copyright
    case .overdue: return .late(Self.lateText(p.scheduledAt, now: now))
    case .due: return .dueNow
    case .rendering: return .rendering(renderFraction(p))
    case .rendered: return p.scheduledAt <= now ? .dueNow : .ready
    case .planned: return p.scheduledAt <= now ? .dueNow : .planned
    }
  }

  /// "accepted" → "Accepted" etc. (a handled problem: no live posting actions on that attempt).
  static func resolutionLabel(_ r: String) -> String {
    switch r {
    case "accepted": "Accepted"
    case "skipped": "Skipped"
    case "reuploaded": "Re-uploading"
    case "retried": "Re-queued"
    default: r.capitalized
    }
  }

  /// "2 h" / "35 m" / "1 d" since `d`.
  static func lateText(_ d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s >= 86400 { return "\(s / 86400) d" }
    if s >= 3600 { return "\(s / 3600) h" }
    return "\(max(1, s / 60)) m"
  }

  /// "2h 21m" / "21m" / "1d 4h" until `d` (menu bar + Next-up countdown).
  static func countdown(to d: Date, now: Date) -> String {
    let s = max(0, Int(d.timeIntervalSince(now)))
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "\(days)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(1, m))m"
  }

  /// True when Eric can act on the post right now (due, overdue, or its time has come).
  func isActionableNow(_ p: PlatformPost) -> Bool {
    guard p.resolution == nil, !p.state.isTerminal else { return false }
    return p.state == .due || p.state == .overdue || p.scheduledAt <= now
  }

  /// Today's posts in time order (overdue leftovers from earlier days first).
  var todayPosts: [PlatformPost] { dueToday.sorted { $0.scheduledAt < $1.scheduledAt } }

  /// The Next-up card: the first post due now, else the next one still to come today.
  var todayNextUp: PlatformPost? {
    let list = todayPosts
    return list.first(where: isActionableNow) ?? list.first { $0.resolution == nil && !$0.state.isTerminal }
  }

  /// "Tue 12:30 PM TikTok" for the next post after today (empty states).
  var nextAfterTodayText: String? {
    guard let n = posts.filter({ !$0.state.isTerminal && dm.key($0.scheduledAt) > todayKey }).min(by: { $0.scheduledAt < $1.scheduledAt })
    else { return nil }
    return "\(Fmt.day(n.scheduledAt, tz: tz, style: "EEE")) \(Self.clockText(n.scheduledAt, tz: tz)) \(n.platform.displayName)"
  }

  /// Copy caption with a platform-name toast ("TikTok caption copied").
  func copyCaptionNamed(_ post: PlatformPost) {
    Task {
      if let (c, _) = await captionAndTitle(post) {
        copy(c)
        show(DSToastModel(message: "\(post.platform.displayName) caption copied", tone: .success, duration: 3))
      }
    }
  }

  /// YouTube title (the Shorts upload page has a separate title field).
  func copyTitleNamed(_ post: PlatformPost) {
    Task {
      if let (_, t) = await captionAndTitle(post), let t {
        copy(t)
        show(DSToastModel(message: "YouTube title copied", tone: .success, duration: 3))
      }
    }
  }
}

/// Copyright "Re-upload anyway" as one undoable step (AppModel.reupload predates the journal and isn't undoable).
extension AppModel {
  /// Same / later version: resolves the claim and queues a new attempt on the next day's slot. New version: copies
  /// the latest version as vN+1, resolves the claim with it, then opens the editor. Both show "… · Undo" (⌘Z).
  func reuploadAnyway(_ post: PlatformPost, version: Int?, newVersion: Bool = false) {
    if newVersion {
      let ok = undoable("Re-uploading as a new version — edit it now", "reupload-new-version", ids: [post.videoId], plan: true) {
        let vs = try store.versions(videoId: post.videoId)
        var v = vs.last ?? Version(number: 1)
        v.number = (vs.map(\.number).max() ?? 0) + 1
        try store.save(v, videoId: post.videoId)
        try postActions.resolveCopyright(postId: post.id, .reuploadAnyway(versionNo: v.number))
      }
      if ok { openEditor(post.videoId) }
    } else {
      undoable("Re-upload queued\(version.map { " (v\($0))" } ?? "")", "reupload", ids: [post.videoId], plan: true) {
        try postActions.resolveCopyright(postId: post.id, .reuploadAnyway(versionNo: version))
      }
    }
  }
}
