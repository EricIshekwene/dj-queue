import DJQCore
import SwiftUI

/// PIPELINE leaf shots (prefix 1x): Score, Edit, Queue and their empty states.
extension SnapshotShots {
  static func pipeline(_ c: SnapshotContext) -> [Shot] {
    [
      c.main("10-score") { m in m.screen = .score },
      c.main("11-edit") { m in m.screen = .edit },
      c.main("12-queue") { m in m.screen = .queue },
      c.main("13-empty-edit", c.empty) { m in m.screen = .edit },
    ]
  }
}
