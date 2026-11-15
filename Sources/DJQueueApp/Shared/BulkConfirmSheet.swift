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
    DSDialog(r.title, description: r.ids.count == 1 ? (model.video(r.ids[0]).map(model.displayName) ?? "1 selected") : "\(r.ids.count) selected", icon: "square.stack.3d.up",
             width: pending.preview?.outlook?.needTitle.isEmpty == false ? 560 : 480,
             onClose: { model.cancelPendingBulk() }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        // Round 33: a clip that goes out on its own swaps or replaces nothing, so the up-front rows don't apply.
        let alone = pending.preview?.onItsOwn?.isEmpty == false
        if !r.changes.isEmpty, !alone { DSChangeList(changes: r.changes) }
        if let p = pending.preview, let goes = p.goesOut, !goes.isEmpty { GoesOutSection(model: model, result: p) }
        if let scope = r.versionScope { BulkVersionNote(model: model, ids: r.ids, scope: scope, keepsWords: r.keepsWords) }
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
    if p.changed.isEmpty, p.videoIds.count == 1, let why = p.skipped.values.first { return why }
    return p.changed.isEmpty ? "Nothing would change" : nil
  }

  @ViewBuilder private var preview: some View {
    if let e = pending.error {
      Label(e, systemImage: DSTone.danger.symbol).font(DS.type.callout).foregroundStyle(DS.color.danger)
    } else if let p = pending.preview {
      let same = p.videoIds.count - p.changed.count - p.skipped.count
      // Round 33: one clip it can't do: the reason is the message, in plain view, never behind "Why skipped".
      if p.videoIds.count == 1, p.changed.isEmpty, let why = p.skipped.values.first {
        Label(why, systemImage: DSTone.warning.symbol).font(DS.type.callout).foregroundStyle(DS.color.text)
          .fixedSize(horizontal: false, vertical: true)
          .padding(DS.space.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
          .background(ScriptAnchor("Bulk refusal"))
      } else {
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
             ("\(o.other.count) other issue\(o.other.count == 1 ? "" : "s")", !o.other.isEmpty),
             ("\(o.needScore.count) still need\(o.needScore.count == 1 ? "s" : "") a score", !o.needScore.isEmpty)])
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

/// Round 20: the line every bulk dialog shows when the selection has clips with v2 or later, saying which versions the
/// change reaches (everything but captions applies to every version). Nothing when no clip has a second version.
struct BulkVersionNote: View {
  let model: AppModel
  let ids: [String]
  let scope: BulkVersionScope
  var keepsWords = false

  var body: some View {
    if let text = scope.note(multi: model.multiVersionCount(ids), keepsWords: keepsWords) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "square.stack").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.color.textSecondary)
        Text(text).font(DS.type.caption).foregroundStyle(DS.color.text).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, DS.space.sm).padding(.vertical, DS.space.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .background(ScriptAnchor("Bulk versions note"))
      .accessibilityElement(children: .combine)
    }
  }
}

/// Round 33: Post today's "Goes out" list, from Core's dry run: one row per platform with when it goes out ("Right away",
/// "9:30 PM"), and, in plain view under the rows, why a platform waits when Postiz is the reason and what happens next
/// (Square's publish dialog: the notice sits in the dialog, not behind a disclosure). Several clips: one row each.
struct GoesOutSection: View {
  let model: AppModel
  let result: BulkResult

  var body: some View {
    let ids = result.changed.filter { result.goesOut?[$0] != nil }
    let single = ids.count == 1 ? result.goesOut?[ids[0]] ?? [] : []
    let alone = Set(result.onItsOwn ?? [])
    VStack(alignment: .leading, spacing: DS.space.xs) {
      Text(alone.isEmpty ? (result.action == "post-today" ? StageWording.takesTodayNote : "When it goes out")
           : alone.count < ids.count ? "Today's slots are taken, so \(alone.count) of these go out now on their own."
           : StageWording.onItsOwnNote)
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
      if ids.count == 1 {
        DSChangeList(changes: single.map {
          .init(field: $0.platform.displayName, value: StageWording.goesOutWhen($0, now: model.now, settings: model.settings))
        })
        ForEach(single.filter { $0.wait != nil }, id: \.platform) { g in
          Label("\(g.platform.displayName) \(g.wait ?? "")", systemImage: "clock")
            .font(DS.type.callout).foregroundStyle(DS.color.text).fixedSize(horizontal: false, vertical: true)
            .padding(DS.space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        }
      } else {
        DSChangeList(changes: ids.prefix(8).map { id in
          let g = result.goesOut?[id] ?? []
          let now = g.filter(\.now).count
          let later = g.count - now
          let value = [now > 0 ? "\(now) right away" : nil, later > 0 ? "\(later) later" : nil].compactMap { $0 }.joined(separator: " · ")
          return .init(field: model.video(id).map(model.displayName) ?? id, value: value.isEmpty ? "Today" : value)
        })
      }
    }
    .background(ScriptAnchor("Post today goes out"))
  }
}
