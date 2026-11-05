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
    // v0.8.1: a group used by a clip with a planned post and by one without. Deleting from the editor's chip asks in the
    // app's own dialog, over the editor, with the counts; Settings says the same under the group's row.
    let group = HashtagSet(id: "r7-piano", name: "Piano", category: "My groups", tags: ["#amapiano", "#piano"], sort: 0)
    let seedUse: (AppModel) -> String? = { m in
      try? m.store.save(group)
      var used = Version(number: 1)
      used.hashtagSetIds = [group.id]
      if let planned = c.firstPlannedId { try? m.store.save(used, videoId: planned) }
      let other = m.videos.first { $0.type == .short && $0.id != c.firstPlannedId && !$0.excluded }?.id
      if let other { try? m.store.save(used, videoId: other) }
      m.refreshNow()
      return other
    }
    shots.append(c.main("46c-editor-delete-group-confirm") { m in
      if let id = seedUse(m) { m.openEditor(id) }
      m.confirmDeleteGroup(group, undoHint: "Undo on the message that follows brings it back.")
    })
    shots.append(c.main("46d-settings-group-reach") { m in
      _ = seedUse(m)
      open(m, .captions)
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
