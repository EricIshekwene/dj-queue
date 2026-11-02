import DJQCore
import SwiftUI

/// SETTINGS leaf shots (prefix 4x): the in-window Settings modal, one shot per section.
extension SnapshotShots {
  static func settings(_ c: SnapshotContext) -> [Shot] {
    SettingsSection.allCases.enumerated().map { i, s in
      c.main("4\(min(i, 9))-settings-\(s.rawValue)") { m in
        m.screen = .queue
        m.settingsSection = s
        m.showSettings = true
      }
    }
  }
}
