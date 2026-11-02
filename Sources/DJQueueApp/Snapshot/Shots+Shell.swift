import DJQCore
import SwiftUI

/// FOUNDATION shots (prefix 0x): sidebar + attention cards, compact sidebar, bulk bar, confirmation sheet, toast,
/// editor takeover, shortcuts.
extension SnapshotShots {
  static func shell(_ c: SnapshotContext) -> [Shot] {
    [
      c.main("00-shell-queue") { m in m.screen = .queue },
      c.main("01-shell-paused-attention") { m in
        m.update { $0.paused = true }; m.toast = nil  // setup, not an action shown in the shot
        m.screen = .edit
      },
      c.main("02-shell-bulk-bar") { m in
        m.update { $0.paused = false }; m.toast = nil  // setup, not an action shown in the shot
        m.screen = .edit
        m.visibleIds[.edit] = m.editList.map(\.id)
        m.setSelection(m.editList.prefix(3).map(\.id), screen: .edit)
      },
      c.main("03-shell-bulk-confirm") { m in
        m.screen = .edit
        let ids = m.editList.map(\.id)
        m.visibleIds[.edit] = ids
        m.setSelection(ids, screen: .edit)
        let bulk = m.bulk
        m.requestBulk(BulkRequest(title: "Send \(ids.count) clips to the Queue?", verb: "Send to Queue", ids: ids,
                                  changes: [.init(field: "Crop", value: "Default anchor, confirmed"),
                                            .init(field: "Text, caption, cover", value: "Defaults")]) { dry in
          try bulk.makeReadyWithDefaults(ids, dryRun: dry)
        })
        // Snapshot: show the dry-run line without waiting for the background check.
        if let r = try? bulk.makeReadyWithDefaults(ids, dryRun: true) { m.pendingBulk?.preview = r }
      },
      c.main("04-shell-toast-undo") { m in
        m.screen = .queue
        m.show(DSToastModel(message: "Updated 9 clips", tone: .success, actionTitle: "Undo", action: {}))
      },
      c.main("05-shell-sidebar-compact") { m in
        m.sidebarCollapsed = true
        m.screen = .library
      },
      c.main("06-shell-editor") { m in
        if let id = m.queueClips.first?.id { m.openEditor(id, in: m.queueClips.map(\.id)) }
      },
      c.main("07-shell-shortcuts") { m in m.showShortcuts = true },
    ]
  }
}
