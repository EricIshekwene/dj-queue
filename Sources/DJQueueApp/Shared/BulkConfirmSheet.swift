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
    DSDialog(r.title, description: "\(r.ids.count) clips selected", icon: "square.stack.3d.up", width: 480,
             onClose: { model.cancelPendingBulk() }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        if !r.changes.isEmpty { DSChangeList(changes: r.changes) }
        preview
      }
    } footer: {
      DSButton("Cancel", variant: .ghost) { model.cancelPendingBulk() }
        .keyboardShortcut(.cancelAction)
      DSButton(r.verb, variant: .primary, isLoading: pending.applying, disabledReason: disabledReason) {
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
        HStack(spacing: DS.space.xs) {
          Text(([("\(p.changed.count) will change", true)] + [(same > 0 ? "\(same) already so" : "", same > 0),
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
}
