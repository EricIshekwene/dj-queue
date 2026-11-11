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

/// Round 22: the one item for a Postiz channel whose sign-in broke (Meetup's single "Disconnected" pill + one Reconnect
/// action; Searchable's one callout with a sentence of what to do). Its posts wait and go out by themselves, so they
/// don't each show a failure: this card is all Eric sees about it. One action, Open Postiz, where the channel is
/// reconnected; the "how it works" line says the rest.
struct PostizSignInCard: View {
  let model: AppModel
  let item: PostizSignInProblem

  var body: some View {
    DSCard(variant: .outline, padding: DS.space.sm) {
      HStack(alignment: .center, spacing: DS.space.sm) {
        DSPlatformIcon(platform: item.platform, size: 32)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(item.title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(1)
            DSBadge("Disconnected", style: .soft(.danger), icon: "bolt.horizontal",
                    help: (item.channelName.map { "Channel \($0). " } ?? "")
                      + (item.message.map { "Postiz said: \($0)" } ?? "Postiz lists the channel as needing a new sign-in"))
          }
          Text("\(item.waitingText). \(PostizSignInProblem.howItWorks)")
            .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        DSButton("Open Postiz", icon: "arrow.up.right.square", variant: .outline, size: .sm,
                 tooltip: "Reconnect \(item.platform.displayName) there; its posts go out by themselves after") { model.openPostiz() }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(item.summary)
  }
}
