import AppKit
import DJQCore
import SwiftUI

/// "Update ready" / "Update blocked" (round 4 S5): one slim row, full width at the top of the content column, in the
/// calm DESIGN-v2 style (sunken fill + hairline, no loud colour). Its buttons are outline/ghost: each screen keeps its
/// single primary capsule. Reads `AutoUpdateUI.shared`; shows nothing when there is no update news.
///
/// - Ready: "Update ready: 0.6.0" · What's new (popover) · Restart & update · Later.
/// - Working (after Restart & update, or while the runner installs): the runner's phase with a spinner, e.g.
///   "Waiting for a render to finish" — that's how "Restart & update waits for an idle engine" shows (S5-R3).
/// - Blocked: "Update blocked: 0.6.0" + the reason · Show log · dismiss.
struct UpdateBanner: View {
  var updates = AutoUpdateUI.shared

  var body: some View {
    if let b = updates.banner {
      UpdateBannerRow(updates: updates, banner: b)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
  }
}

struct UpdateBannerRow: View {
  let updates: AutoUpdateUI
  let banner: AutoUpdateUI.Banner
  @State private var showWhatsNew = false

  var body: some View {
    HStack(spacing: DS.space.sm) {
      switch banner {
      case .ready(let r): ready(r)
      case .working(let label, let version): working(label, version)
      case .blocked(let b): blocked(b)
      }
    }
    .padding(.leading, DS.space.md)
    .padding(.trailing, DS.space.sm)
    .frame(height: 40)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.surfaceSunken)
    .overlay(alignment: .bottom) { DSSeparator() }
    .accessibilityElement(children: .contain)
  }

  // MARK: Ready

  @ViewBuilder private func ready(_ r: AutoUpdateCandidate) -> some View {
    DSStatusDot(tone: .accent, size: 7)
    Text("Update ready: \(r.version)").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
    Text(changes(r.whatsNew.count)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
    Spacer(minLength: DS.space.sm)
    DSButton("What's new", variant: .ghost, size: .sm, disabledReason: r.whatsNew.isEmpty ? "No commit list for this build." : nil,
             tooltip: "List what changed since the build you're running") { showWhatsNew.toggle() }
      .popover(isPresented: $showWhatsNew, arrowEdge: .bottom) { WhatsNewPopover(candidate: r) }
    DSButton("Later", variant: .ghost, size: .sm, disabledReason: updates.actionBlockedReason,
             tooltip: "Install \(r.version) when you close this window") { updates.later() }
    DSButton("Restart & update", icon: "arrow.clockwise", variant: .outline, size: .sm, disabledReason: updates.actionBlockedReason,
             tooltip: "Restart DJ Queue now and install \(r.version). Waits for any render to finish.") { updates.restartAndUpdate() }
  }

  // MARK: Working

  @ViewBuilder private func working(_ label: String, _ version: String?) -> some View {
    DSSpinner(size: 12, color: DS.color.textSecondary)
    Text(version.map { "Updating to \($0)" } ?? "Updating").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
    Text(label).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
      .contentTransition(.opacity)
    Spacer(minLength: DS.space.sm)
    let why = "The update is already under way; DJ Queue restarts when it's installed."
    DSButton("Later", variant: .ghost, size: .sm, disabledReason: why) {}
    DSButton("Restart & update", icon: "arrow.clockwise", variant: .outline, size: .sm, isLoading: true, disabledReason: why) {}
  }

  // MARK: Blocked

  @ViewBuilder private func blocked(_ b: AutoUpdateBlock) -> some View {
    Image(systemName: DSTone.warning.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.color.warning)
    Text("Update blocked: \(b.version)").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
    Text(b.reason).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1).truncationMode(.tail)
      .dsTooltip("\(b.reason). Nothing was installed; you're still on the build you had.")
    Spacer(minLength: DS.space.sm)
    DSButton("Show log", variant: .ghost, size: .sm, disabledReason: updates.logURL == nil ? "No log written yet." : nil,
             tooltip: "Open the full test and build output") { updates.openLog() }
    DSIconButton("xmark", tooltip: "Hide until the next update is blocked", size: .sm) { updates.dismissBlocked() }
  }

  private func changes(_ n: Int) -> String {
    n == 0 ? "" : "\(n) change\(n == 1 ? "" : "s") since your build"
  }
}

/// "What's new in 0.6.0": first-parent commit subjects on main since the installed build, newest first.
struct WhatsNewPopover: View {
  let candidate: AutoUpdateCandidate

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      Text("What's new in \(candidate.version)").font(DS.type.headline).foregroundStyle(DS.color.text)
      ScrollView {
        VStack(alignment: .leading, spacing: DS.space.xs) {
          ForEach(candidate.whatsNew, id: \.sha) { c in
            HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
              Text(String(c.sha.prefix(7))).font(DS.type.mono).foregroundStyle(DS.color.textTertiary)
              Text(c.subject).font(DS.type.callout).foregroundStyle(DS.color.text).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(DS.space.md)
    .frame(width: 360, alignment: .leading)
  }
}
