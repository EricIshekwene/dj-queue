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
    return shots
  }

  private static func open(_ m: AppModel, _ s: SettingsSection) {
    SettingsUIState.shared.reset()
    m.screen = .queue
    m.settingsSection = s
    m.showSettings = true
  }
}
