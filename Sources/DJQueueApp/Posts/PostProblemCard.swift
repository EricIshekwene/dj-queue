import DJQCore
import SwiftUI

/// What a problem post allows, with the reason when not (DESIGN-v2 §1.6: disabled controls say why). Mirrors the
/// real PostActions rules (`fixed` = failed + unresolved, copyright = re-upload / skip / accept, reset = future posts).
@MainActor
struct PostFixes {
  let model: AppModel
  let post: PlatformPost

  private var copyrightOpen: Bool { post.state.isCopyright && post.resolution == nil }

  static func canRetry(_ p: PlatformPost) -> Bool { p.state == .failed && p.resolution == nil }

  /// Sent back to Edit: nothing of the clip may post until it's sent to the queue again.
  var heldReason: String? { model.heldReason(post.videoId) }

  var fixReason: String? {
    if let h = heldReason, Self.canRetry(post) { return h }
    if Self.canRetry(post) { return nil }
    if post.state.isCopyright { return "Copyright can't be fixed by editing — re-upload anyway, skip the platform or accept" }
    if model.postizState(post) == .inbox { return "In your TikTok inbox — finish it there, then Mark posted" }
    if post.state == .overdue { return "Nothing to fix — the slot was missed. Use Post now or Shift plan (⋯)" }
    return post.resolution.map { "Already handled (\($0))" } ?? "Only failed posts can be fixed"
  }

  var reuploadReason: String? {
    copyrightOpen ? heldReason : post.state.isCopyright ? "Already handled" : "Only for copyright problems"
  }
  var acceptReason: String? { copyrightOpen ? nil : post.state.isCopyright ? "Already handled" : "Only for copyright problems" }
  var skipReason: String? { model.canSkip(post) ? nil : "Already \(post.state.displayName.lowercased())" }

  var resetReason: String? {
    if model.canReset(post) { return nil }
    if let h = heldReason { return h }
    if post.scheduledAt <= model.now { return "Its time has passed — a reset would make it miss again" }
    return "Already planned"
  }
}

/// A Posts → Problems attention card (DESIGN-v2 §6.7): tint, r.lg. Platform glyph + name, clip, error type, message,
/// time, a "Raw response" disclosure and the fixes: **Fix in editor** (primary on the first fixable card) ·
/// Re-upload anyway ▾ · Skip platform · Accept · Reset — each disabled with its reason — plus ⋯ for the rest.
/// Clicking the card body opens the inspector.
struct PostProblemCard: View {
  @Bindable var model: AppModel
  let post: PlatformPost
  var isPrimary = false
  /// Inside a Posts group card (which already shows the clip): no clip name, tighter padding.
  var embedded = false
  @State private var showRaw = false

  var body: some View {
    let fixes = PostFixes(model: model, post: post)
    let v = model.video(post.videoId)
    let tone: DSTone = post.state == .overdue ? .warning : .danger
    VStack(alignment: .leading, spacing: DS.space.sm) {
      HStack(alignment: .top, spacing: DS.space.sm) {
        DSPlatformIcon(platform: post.platform, state: .failed, size: 32)
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(post.platform.displayName).font(DS.type.headline).foregroundStyle(DS.color.text)
            if !embedded {
              Text(v.map(model.displayName) ?? post.videoId).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: DS.space.xs)
            Text(Fmt.relative(post.updatedAt, now: model.now)).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
              .dsTooltip(Fmt.day(post.updatedAt, tz: model.tz, style: "EEE d MMM, h:mm a"))
          }
          HStack(spacing: 6) {
            DSBadge(model.postizState(post) == .unconfirmed ? "Unconfirmed in Postiz" : PostText.problemType(post), style: .soft(tone), icon: post.state.isCopyright ? "c.circle" : nil,
                    help: post.state.isCopyright ? "The platform flagged the audio — copyright blocks are never retried automatically" : "What went wrong — the actions on the right fix it")
            if post.versionNo != 1 || post.attemptNo != 1 || post.kind != .regular {
              Text("v\(post.versionNo) · \(PostText.attempt(post))").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            }
            if let pz = model.postizState(post) {
              switch pz {
              case .failed, .copyright:
                DSBadge("via Postiz", style: .outline, icon: "paperplane", help: "Postiz reported this; the message is Postiz's or the platform's")
              case .inbox, .fellBack, .unconfirmed:
                PostizBadge(model: model, post: post, state: pz)
              default: EmptyView()
              }
            }
            if model.isTestRun(post) { TestRunBadge() }
          }
          Text(message).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
          if let raw = post.rawResponse, !raw.isEmpty {
            Button {
              dsWithAnimation { showRaw.toggle() }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showRaw ? 90 : 0))
                Text("Raw response").font(DS.type.captionMedium)
              }
              .foregroundStyle(DS.color.textSecondary)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsTooltip(showRaw ? "Hide what the platform answered" : "Show what the platform answered")
            if showRaw {
              Text(raw).font(DS.type.mono).foregroundStyle(DS.color.textSecondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.space.sm)
                .background(DS.color.background.opacity(0.7), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
            }
          }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { dsWithAnimation { model.postsSelection = model.postsSelection == post.id ? nil : post.id } }
      .dsTooltip("Click for details and attempt history")
      HStack(spacing: DS.space.xs) {
        if model.postizState(post) == .unconfirmed {
          DSButton("It's in Postiz", icon: "checkmark.circle", variant: .outline, size: .sm,
                   tooltip: "Keep it as Postiz's; it's never sent again") { model.resolveUnconfirmed(post, inPostiz: true) }
          DSButton("Not in Postiz — post it myself", variant: .ghost, size: .sm,
                   tooltip: "Post it by hand from the Calendar (asks first)") { model.resolveUnconfirmed(post, inPostiz: false) }
            .fixedSize()
        } else if model.postizState(post) == .inbox {
          // Already uploaded to the TikTok inbox: finishing it there is the fix; a second upload would double-post.
          DSButton("Mark posted…", icon: "checkmark.circle", variant: .outline, size: .sm,
                   tooltip: "Finish it in the TikTok app, then paste its link") { model.markPostedTarget = post }
        } else if post.state == .overdue {
          // A missed slot has nothing to edit: its two real fixes take the first places.
          DSButton("Post now", icon: "bolt", variant: .outline, size: .sm, disabledReason: fixes.heldReason,
                   tooltip: "Make it due now and open the Calendar") { model.postNow(post) }
          DSButton("Shift plan", icon: "calendar.badge.clock", variant: .ghost, size: .sm, disabledReason: fixes.heldReason,
                   tooltip: "Move it to the next free \(post.platform.displayName) slot") { model.shiftPlan(post) }
        } else {
          DSButton("Fix in editor", icon: "slider.horizontal.below.rectangle", variant: isPrimary ? .primary : .outline, size: .sm,
                   disabledReason: fixes.fixReason, tooltip: "Edit it; closing the editor re-queues it") {
            model.openEditor(post.videoId, fixPostId: post.id)
          }
          reupload(fixes)
        }
        DSButton("Skip \(post.platform.dsxCompactName)", variant: .ghost, size: .sm, disabledReason: fixes.skipReason,
                 tooltip: "Don't post this clip on \(post.platform.displayName)") { model.skip(post) }
        if model.postizState(post) != .unconfirmed {  // room for the two answers; neither applies to it
          DSButton("Accept claim", variant: .ghost, size: .sm, disabledReason: fixes.acceptReason,
                   tooltip: "Leave the post as it is (e.g. muted)") { model.resolve(post, .accept) }
          DSButton("Reset", variant: .ghost, size: .sm, disabledReason: fixes.resetReason,
                   tooltip: "Back to Planned, error cleared") { model.reset(post) }
        }
        Spacer(minLength: 0)
        PostMoreMenu(model: model, post: post)
      }
      .padding(.leading, 44)
    }
    .padding(embedded ? DS.space.sm : DS.space.md)
    .background(DS.color.tint(tone), in: RoundedRectangle(cornerRadius: embedded ? DS.radius.md : DS.radius.lg, style: .continuous))
    .overlay {
      if model.postsSelection == post.id {
        RoundedRectangle(cornerRadius: embedded ? DS.radius.md : DS.radius.lg, style: .continuous).strokeBorder(DS.color.text, lineWidth: 2)
      }
    }
  }

  private var message: String {
    if let m = post.errorMessage, !m.isEmpty { return m }
    if model.postizState(post) == .unconfirmed { return AppModel.unconfirmedText }
    if model.postizState(post) == .inbox { return "Postiz sent it to your TikTok inbox. Finish it in the TikTok app, then Mark posted with its link." }
    if post.state == .overdue {
      return "The \(AppModel.clockText(post.scheduledAt, tz: model.tz)) slot on \(Fmt.day(post.scheduledAt, tz: model.tz)) passed without a post."
    }
    return "No message from the platform."
  }

  @ViewBuilder private func reupload(_ fixes: PostFixes) -> some View {
    if let why = fixes.reuploadReason {
      DSButton("Re-upload anyway", trailingIcon: "chevron.down", variant: .ghost, size: .sm, disabledReason: why) {}
    } else {
      let versions = max(1, model.versionCounts[post.videoId] ?? 1)
      Menu {
        ReuploadItems(model: model, post: post, versions: versions)
      } label: {
        HStack(spacing: 6) {
          Text("Re-upload anyway")
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
        }
      }
      .menuStyle(.button)
      .buttonStyle(DSButtonStyle(variant: .outline, size: .sm))
      .menuIndicator(.hidden)
      .fixedSize()
      .dsTooltip("Upload again despite the claim; pick a version")
    }
  }
}

/// ⋯ on a problem card / in the inspector: the remaining post actions.
struct PostMoreMenu: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    Menu {
      if PostFixes.canRetry(post) {
        // Disabled native menu items can't show a tooltip: the reason goes in the title.
        let held = model.heldReason(post.videoId) != nil
        Button(held ? "Try again on the next slot — sent back to Edit" : "Try again on the next slot", systemImage: "arrow.clockwise") {
          model.fixed(post.id)
        }
        .disabled(held)
      }
      if !post.state.isTerminal { Button("Mark posted…", systemImage: "checkmark.circle") { model.markPostedTarget = post } }
      if !post.state.isTerminal || post.state == .posted {
        Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
      }
      Button("Copy details (platform, error, raw response)", systemImage: "doc.on.doc") {
        model.copy("\(post.platform.displayName) · \(PostText.problemType(post))\n\(post.errorMessage ?? "")\n\(post.rawResponse ?? "")")
        model.show("Details copied")
      }
      Divider()
      Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(post.videoId) }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
    }
    .menuStyle(.button)
    .buttonStyle(DSButtonStyle(variant: .ghost, size: .sm, iconOnly: true))
    .menuIndicator(.hidden)
    .fixedSize()
    .dsTooltip("Retry, mark posted, report or copy details")
    .accessibilityLabel("More post actions")
  }
}
