import DJQCore
import SwiftUI

/// The Postiz state of one post as a chip (Today, Posts, menu bar): "Scheduled in Postiz", "Draft in Postiz",
/// "Posting…", "Posted", "In your TikTok inbox", "Failed", "© Blocked", "Fell back to manual". Hover = the full line.
struct PostizBadge: View {
  let model: AppModel
  let post: PlatformPost
  let state: PostizPostState
  var size: DSBadgeSize = .md

  var body: some View {
    DSBadge(state.text, style: state.badgeStyle, icon: state.badgeIcon, size: size, help: model.postizLine(post, state))
  }
}

/// One caption line under a post's title: who delivers it and when, or Postiz's / the platform's message (red for
/// failures and copyright, amber for "finish it yourself").
struct PostizLine: View {
  let model: AppModel
  let post: PlatformPost
  let state: PostizPostState

  var body: some View {
    let line = model.postizLine(post, state)
    Text(state.isLoud ? "\(state == .copyright(line) ? "Copyright" : "Postiz"): \(line)" : line)
      .font(state.isLoud ? DS.type.captionMedium : DS.type.caption)
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .dsTooltip(state.isLoud || line.count > 48 ? line : nil)
  }

  private var color: Color {
    switch state {
    case .failed, .copyright: DS.color.danger
    case .inbox, .fellBack: DS.color.warning
    default: DS.color.textSecondary
    }
  }
}
