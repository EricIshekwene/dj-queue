import DJQCore
import SwiftUI

/// SETTINGS leaf shots (prefix 4x): the in-window Settings modal on every section (40–49), plus New clip defaults
/// scrolled to Caption/Posting (44b) and with unsaved changes (44c).
extension SnapshotShots {
  static func settings(_ c: SnapshotContext) -> [Shot] {
    var shots = SettingsSection.allCases.enumerated().map { i, s in
      c.main("4\(i)-settings-\(s.rawValue)") { m in open(m, s) }
    }
    shots.append(c.main("44b-settings-newClipDefaults-caption") { m in
      open(m, .newClipDefaults)
      SettingsUIState.shared.scrollTarget = NewClipDefaultsSettings.captionAnchor
    })
    shots.append(c.main("44c-settings-newClipDefaults-unsaved") { m in
      open(m, .newClipDefaults)
      var d = m.settings.defaults
      d.textStyle = .outline
      d.textPosY = 0.32
      d.extraSecondsBefore = 1.5
      SettingsUIState.shared.draft = d
    })
    // Round 7: Eric's own hashtag groups and a second YouTube title template (seeded into the snapshot store).
    shots.append(c.main("46b-settings-captions-groups") { m in
      try? m.store.save(HashtagSet(id: "r7-piano", name: "Piano", category: "My groups", tags: ["#amapiano", "#piano"], sort: 0))
      try? m.store.save(HashtagSet(id: "r7-sa", name: "Piano · SA", category: "My groups", tags: ["#amapianosa", "#yanos"], sort: 1))
      if var st = try? m.store.settings(), !st.youtubeTitleTemplates.contains(where: { $0.id == "r7-live" }) {
        st.youtubeTitleTemplates.append(TitleTemplate(id: "r7-live", name: "Live set", template: "{text} (live set) | DJ Lovd"))
        try? m.store.save(st)
      }
      m.refreshNow()
      open(m, .captions)
    })
    shots.append(c.main("44d-settings-newClipDefaults-caption-groups") { m in
      open(m, .newClipDefaults)  // after 46b, which made the groups
      SettingsUIState.shared.scrollTarget = NewClipDefaultsSettings.captionAnchor
    })
    // v0.8.1: deleting a group from the editor's chip asks in the app's own dialog, over the editor.
    shots.append(c.main("46c-editor-delete-group-confirm") { m in
      let group = HashtagSet(id: "r7-piano", name: "Piano", category: "My groups", tags: ["#amapiano", "#piano"], sort: 0)
      try? m.store.save(group)
      m.refreshNow()
      if let id = m.videos.first(where: { $0.type == .short })?.id { m.openEditor(id) }
      m.confirmDeleteGroup(group, undoHint: "Undo on the message that follows brings it back.")
    })
    return shots
  }

  private static func open(_ m: AppModel, _ s: SettingsSection) {
    SettingsUIState.shared.reset()
    m.screen = .queue
    m.settingsSection = s
    m.showSettings = true
  }
}
