import DJQCore
import SwiftUI

/// BROWSE leaf shots (prefix 3x): Library, Posts, Health, ⌘K, empty states.
extension SnapshotShots {
  static func browse(_ c: SnapshotContext) -> [Shot] {
    [
      c.main("30-library") { m in m.screen = .library },
      c.main("31-posts") { m in m.screen = .posts },
      c.main("32-health") { m in m.screen = .health; m.doctorReport = Doctor(store: m.store).run() },
      c.main("33-command-palette") { m in m.screen = .queue; m.showPalette = true },
      c.main("34-empty-library", c.empty) { m in m.screen = .library },
    ]
  }
}
