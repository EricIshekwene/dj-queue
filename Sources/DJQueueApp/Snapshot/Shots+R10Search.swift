import DJQCore
import SwiftUI

/// Round 10 shots (prefix 90): ⌘K searching the whole app, and the lists' "Search everywhere". The real-window proof
/// with keys is `SearchProbe`; these are the screens at rest.
extension SnapshotShots {
  static func r10search(_ c: SnapshotContext) -> [Shot] {
    func palette(_ m: AppModel, _ text: String, scope: SearchScope = .all) {
      BrowseUI.shared.reset()
      BrowseUI.shared.paletteQuery = text
      BrowseUI.shared.paletteScope = scope
      m.showPalette = true
    }
    func nothingFits(_ m: AppModel, _ s: Screen) {
      BrowseUI.shared.reset()
      m.screen = s
      if let p = ListPage.of(s) { ListPrefs.shared.setSearch(p, "who knows") }
    }
    return [
      c.main("90-search-resting") { m in palette(m, "") },
      c.main("90-search-mixed") { m in palette(m, "blend") },
      c.main("90-search-week") { m in
        palette(m, Fmt.day(m.dm.date(m.dm.addDays(m.thisWeek, 9)), tz: m.tz, style: "d MMM").lowercased())
      },
      c.main("90-search-settings-first") { m in palette(m, "captions") },
      c.main("90-search-clips-chip") { m in palette(m, "blend", scope: .clips) },
      c.main("90-search-nothing") { m in palette(m, "no such thing") },
      c.main("90-search-over-settings") { m in
        m.settingsSection = .schedule
        m.showSettings = true
        palette(m, "late grace")
      },
      c.main("91-search-everywhere-score") { m in nothingFits(m, .score) },
      c.main("91-search-everywhere-edit") { m in nothingFits(m, .edit) },
      c.main("91-search-everywhere-queue") { m in nothingFits(m, .queue) },
      c.main("91-search-everywhere-library") { m in nothingFits(m, .library) },
      c.main("91-search-everywhere-posts") { m in nothingFits(m, .posts) },
    ]
  }
}
