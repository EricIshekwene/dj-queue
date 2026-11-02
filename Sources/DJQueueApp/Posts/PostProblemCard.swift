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
            DSBadge(PostText.problemType(post), style: .soft(tone), icon: post.state.isCopyright ? "c.circle" : nil)
            if post.versionNo != 1 || post.attemptNo != 1 || post.kind != .regular {
              Text("v\(post.versionNo) · \(PostText.attempt(post))").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            }
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
      HStack(spacing: DS.space.xs) {
        if post.state == .overdue {
          // A missed slot has nothing to edit: its two real fixes take the first places.
          DSButton("Post now", icon: "bolt", variant: .outline, size: .sm, disabledReason: fixes.heldReason,
                   tooltip: "Make it due now on today's \(post.platform.displayName) slot") { model.postNow(post) }
          DSButton("Shift plan", icon: "calendar.badge.clock", variant: .ghost, size: .sm, disabledReason: fixes.heldReason,
                   tooltip: "Move it to the next free \(post.platform.displayName) slot") { model.shiftPlan(post) }
        } else {
          DSButton("Fix in editor", icon: "slider.horizontal.below.rectangle", variant: isPrimary ? .primary : .outline, size: .sm,
                   disabledReason: fixes.fixReason, tooltip: "Open the editor; when you close it the post is tried again") {
            model.openEditor(post.videoId, fixPostId: post.id)
          }
          reupload(fixes)
        }
        DSButton("Skip platform", variant: .ghost, size: .sm, disabledReason: fixes.skipReason,
                 tooltip: "Don't post this clip on \(post.platform.displayName)") { model.skip(post) }
        DSButton("Accept", variant: .ghost, size: .sm, disabledReason: fixes.acceptReason,
                 tooltip: "Leave it as it is (e.g. muted audio is fine)") { model.resolve(post, .accept) }
        DSButton("Reset", variant: .ghost, size: .sm, disabledReason: fixes.resetReason,
                 tooltip: "Back to planned, error cleared") { model.reset(post) }
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
        Button("Same version (v\(post.versionNo))") { model.reupload(post, version: post.versionNo) }
        ForEach(Array(stride(from: post.versionNo + 1, through: versions, by: 1)), id: \.self) { n in
          Button("v\(n)") { model.reupload(post, version: n) }
        }
        Divider()
        Button("New version (v\(versions + 1))…") { model.reupload(post, version: nil, newVersion: true) }
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
      .dsTooltip("Try again on the next day: same version, a later one, or a new one")
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
        Button("Try again on the next slot", systemImage: "arrow.clockwise") { model.fixed(post.id) }
          .disabled(model.heldReason(post.videoId) != nil)
          .help(model.heldReason(post.videoId) ?? "A new attempt on the platform's next slot")
      }
      if !post.state.isTerminal { Button("Mark posted…", systemImage: "checkmark.circle") { model.markPostedTarget = post } }
      if !post.state.isTerminal || post.state == .posted {
        Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
      }
      Button("Copy details", systemImage: "doc.on.doc") {
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
    .dsTooltip("More actions")
  }
}
