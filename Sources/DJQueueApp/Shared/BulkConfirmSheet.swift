import DJQCore
import SwiftUI

/// The shared bulk confirmation (DESIGN-v2 §5): an in-window e3 dialog, 480 wide, over the scrim. Title, the
/// change list, the dry-run line ("7 will change · 2 skipped" with the skipped reasons disclosed), Cancel and the
/// primary verb. Presented by MainWindowView while `model.pendingBulk` is set.
struct BulkConfirmSheet: View {
  @Bindable var model: AppModel
  let pending: PendingBulk
  @State private var showSkipped = false

  var body: some View {
    let r = pending.request
    DSDialog(r.title, description: r.ids.count == 1 ? (model.video(r.ids[0]).map(model.displayName) ?? "1 clip") : "\(r.ids.count) clips selected", icon: "square.stack.3d.up",
             width: pending.preview?.outlook?.needTitle.isEmpty == false ? 560 : 480,
             onClose: { model.cancelPendingBulk() }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        if !r.changes.isEmpty { DSChangeList(changes: r.changes) }
        if let p = pending.preview, let lines = r.previewLines?(p), !lines.isEmpty { previewList(r.previewTitle, lines, icon: r.previewIcon) }
        preview
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, shortcut: "esc") { model.cancelPendingBulk() }
        .keyboardShortcut(.cancelAction)
      DSButton(r.verb, variant: .primary, isLoading: pending.applying, disabledReason: disabledReason,
               tooltip: r.ids.count == 1 ? "Apply it (you can undo)" : "Apply to \(r.ids.count) clips (you can undo)", shortcut: "↩") {
        model.confirmPendingBulk()
      }
      .keyboardShortcut(.defaultAction)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private var disabledReason: String? {
    if pending.error != nil { return "The check failed — see the message above" }
    guard let p = pending.preview else { return "Checking what will change…" }
    return p.changed.isEmpty ? "Nothing would change" : nil
  }

  @ViewBuilder private var preview: some View {
    if let e = pending.error {
      Label(e, systemImage: DSTone.danger.symbol).font(DS.type.callout).foregroundStyle(DS.color.danger)
    } else if let p = pending.preview {
      let same = p.videoIds.count - p.changed.count - p.skipped.count
      VStack(alignment: .leading, spacing: DS.space.xs) {
        if let o = p.outlook { outlook(o) }
        HStack(spacing: DS.space.xs) {
          Text(([("\(p.changed.count) will change" + (p.outlook == nil ? "" : " (crop confirmed)"), true)] + [(same > 0 ? "\(same) already so" : "", same > 0),
                (p.skipped.isEmpty ? "" : "\(p.skipped.count) skipped", !p.skipped.isEmpty)])
            .filter(\.1).map(\.0).joined(separator: " · "))
            .font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
          Spacer(minLength: 0)
          if !p.skipped.isEmpty {
            DSButton(showSkipped ? "Hide reasons" : "Why skipped", trailingIcon: showSkipped ? "chevron.up" : "chevron.down",
                     variant: .ghost, size: .sm) { dsWithAnimation { showSkipped.toggle() } }
          }
        }
        if showSkipped {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(p.skipped.sorted { $0.key < $1.key }, id: \.key) { id, why in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.video(id).map(model.displayName) ?? id).font(DS.type.captionMedium).foregroundStyle(DS.color.text).lineLimit(1)
                Text(why).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(2)
              }
            }
          }
          .padding(DS.space.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        }
      }
    } else {
      HStack(spacing: DS.space.xs) {
        DSSpinner(size: 12, color: DS.color.textSecondary)
        Text("Checking what will change…").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
      }
    }
  }

  /// The dry run's own list (e.g. the scheduled days Remove from queue takes out), one line each.
  private func previewList(_ title: String?, _ lines: [String], icon: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let title { Text(title).font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary) }
      ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { _, l in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.color.textTertiary)
          Text(l).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(2)
        }
      }
      if lines.count > 12 {
        Text("+\(lines.count - 12) more").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      }
    }
    .padding(DS.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  /// Make-ready's real outcome per clip, and — when clips still need a title — the two explicit ways to give them
  /// one (the app never invents a title: an agent suggests, or Eric takes the raw tag as it is).
  @ViewBuilder private func outlook(_ o: ReadyOutlook) -> some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      Text(([("\(o.ready.count) go\(o.ready.count == 1 ? "es" : "") to the Queue", true),
             ("\(o.needTitle.count) still need\(o.needTitle.count == 1 ? "s" : "") a title", !o.needTitle.isEmpty),
             ("\(o.other.count) other issue\(o.other.count == 1 ? "" : "s")", !o.other.isEmpty)])
        .filter(\.1).map(\.0).joined(separator: " · "))
        .font(DS.type.bodyMedium).foregroundStyle(DS.color.text)
      if !o.needTitle.isEmpty {
        let m = o.needTitle.count
        VStack(alignment: .leading, spacing: DS.space.xs) {
          Text("Their text comes from the title, so they stay in Edit until they have one.")
            .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          HStack(spacing: DS.space.xs) {
            DSButton("Ask an agent for these \(m)", icon: "doc.on.clipboard", variant: .outline, size: .sm,
                     tooltip: "Copy a title prompt for your agent") {
              model.copyAgentPrompt(o.needTitle)
            }
            DSButton("Use raw tag as title for these \(m)", icon: "tag", variant: .outline, size: .sm,
                     disabledReason: pending.applying ? "Applying…" : nil,
                     tooltip: "Set each title to its marker tag (undoable)") {
              model.useRawTagAsTitle(o.needTitle)
            }
          }
        }
        .padding(DS.space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      }
    }
  }
}
