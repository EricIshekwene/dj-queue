import DJQCore
import SwiftUI

/// PLANNING leaf shots (prefix 2x): Week, Today, menu bar.
extension SnapshotShots {
  static func planning(_ c: SnapshotContext) -> [Shot] {
    let model = c.model
    return [
      c.main("20-week") { m in m.screen = .week },
      c.main("21-today") { m in m.screen = .today },
      c.view("22-menubar", width: 320) { AnyView(MenuBarView(model: model)) },
      c.view("23-menubar-icons", width: 360) { AnyView(MenuBarIconSheet()) },
    ]
  }
}

/// MB.ICON states side by side (the real status item lives in the system menu bar).
struct MenuBarIconSheet: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DSEyebrow("Menu-bar icon states")
      row("Normal", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: false))
      row("Errors", MenuBarIcon.image(days: 5, errors: 2, engineOn: true, paused: false))
      row("Paused", MenuBarIcon.image(days: 5, errors: 0, engineOn: true, paused: true))
      row("Engine stopped", MenuBarIcon.image(days: 1, errors: 0, engineOn: false, paused: false))
    }
    .padding(16)
  }

  private func row(_ t: String, _ img: NSImage) -> some View {
    HStack {
      Text(t).font(DS.type.body).foregroundStyle(DS.color.text).frame(width: 120, alignment: .leading)
      Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original).foregroundStyle(DS.color.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.xs))
    }
  }
}
