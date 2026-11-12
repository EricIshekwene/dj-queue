import DJQCore
import SwiftUI

/// Round 29: "Make default…" at the foot of the Caption section. One checkbox per part of this clip's caption setup;
/// what's ticked becomes what new clips start with. Clips that already exist keep theirs unless Eric turns on the one
/// switch that says how many would follow. Same inline pattern as the New group and template forms.
struct EditorDefaultsArea: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    if let form = model.defaultsForm {
      EditorDefaultsFormView(model: model, form: form)
        .background(ScriptAnchor("Defaults form"))
    } else {
      DSButton("Make default for new \(model.noun)s…", icon: "star", variant: .ghost, size: .sm, disabledReason: model.defaultsOffReason,
               tooltip: "Save this \(model.noun)'s caption setup as what new \(model.noun)s start with") {
        dsWithAnimation { model.openDefaultsForm() }
      }
      .background(ScriptAnchor("Make default"))
    }
  }
}

struct EditorDefaultsFormView: View {
  @ObservedObject var model: EditorModel
  let form: EditorDefaultsForm

  private var rows: [EditorDefaultRow] { model.defaultRows }
  private var choice: CaptionDefaults.Choice { model.defaultsChoice(form.picked) }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Make default for new \(model.noun)s").font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        Text("New \(model.noun)s start with what you tick. You can still change any \(model.noun) on its own.")
          .font(DS.type.caption).foregroundStyle(DS.color.textTertiary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: DS.space.xs) {
        ForEach(rows) { row in
          DSCheckbox(isOn: form.picked.contains(row.part) && row.offReason == nil && !row.isDefault, label: row.part.label,
                     description: row.offReason == nil ? (row.isDefault ? "\(row.value) · already the default" : row.value) : nil,
                     disabledReason: row.offReason ?? (row.isDefault ? "\(row.value) is already the default" : nil)) {
            model.toggleDefaultPart(row.part)
          }
          .background(ScriptAnchor("Default \(row.part.rawValue)"))
        }
      }
      existing
      HStack(spacing: DS.space.xxs) {
        Spacer(minLength: 0)
        DSButton("Cancel", variant: .ghost, size: .sm, tooltip: "Close without changing the defaults", shortcut: "esc") {
          dsWithAnimation { model.defaultsForm = nil }
        }
        .keyboardShortcut(.cancelAction)
        DSButton("Make default", variant: .primary, size: .sm,
                 disabledReason: choice.isEmpty ? "Tick something that isn't the default yet" : nil,
                 tooltip: "Save the ticked parts as New clip defaults (⌘Z undoes)") {
          dsWithAnimation { _ = model.saveDefaultsForm() }
        }
        .background(ScriptAnchor("Save defaults"))
      }
    }
    .padding(DS.space.sm)
    .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  /// What happens to clips that exist: kept by default; the switch shows only when some would follow.
  @ViewBuilder private var existing: some View {
    let follow = form.reach.follow.count, held = form.reach.held.count
    if !choice.isEmpty {
      if follow > 0 {
        DSToggle("Also update \(follow) clip\(follow == 1 ? "" : "s") that use the current defaults",
                 description: held == 0 ? "Off: they keep their captions and platforms. Only new clips change."
                   : "Off: they keep their captions and platforms. \(held) with scheduled or posted posts always keep theirs.",
                 isOn: Binding(get: { form.updateExisting }, set: { v in model.defaultsForm?.updateExisting = v }), size: .sm)
          .background(ScriptAnchor("Update existing"))
      } else if held > 0 {
        EditorHint("\(held) clip\(held == 1 ? "" : "s") with scheduled or posted posts keep\(held == 1 ? "s" : "") theirs.", icon: "info.circle")
      } else {
        EditorHint("No clip you already have changes.", icon: "info.circle")
      }
    }
  }
}
