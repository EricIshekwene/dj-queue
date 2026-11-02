import DJQCore
import SwiftUI

/// BROWSE leaf shots (prefix 3x): Library (4 modes, filtered, bulk + confirmation, quick look, mark posted, empty),
/// Posts (problems, all + inspector, empty), Health (healthy, needs attention), ⌘K (query, clip page).
extension SnapshotShots {
  static func browse(_ c: SnapshotContext) -> [Shot] {
    let ui = BrowseUI.shared
    let probe = HealthProbe.shared
    func prep(_ m: AppModel) {
      ui.reset()
      probe.override = nil
      m.postsSelection = nil
      m.librarySession = nil
    }
    func library(_ m: AppModel, _ mode: DSViewMode) {
      prep(m)
      m.setViewMode(mode, for: .library)
      m.screen = .library
    }
    return [
      c.main("30-library-grid") { m in library(m, .grid) },
      c.main("31-library-cards") { m in library(m, .wide) },
      c.main("32-library-list") { m in library(m, .list) },
      c.main("33-library-posted") { m in
        library(m, .grid)
        SampleData.markSampleLongformPosted(m)
        ui.filter = .posted
      },
      c.main("34-library-bulk-confirm") { m in
        library(m, .grid)
        let ids = m.libraryAll.filter { $0.type == .short && $0.score != nil && !$0.excluded }.prefix(4).map(\.id)
        m.visibleIds[.library] = m.libraryAll.filter { $0.type == .short }.map(\.id)
        m.setSelection(ids, screen: .library)
        let bulk = m.bulk
        m.requestBulk(BulkRequest(title: "Exclude \(ids.count) clips?", verb: "Exclude", ids: Array(ids),
                                  changes: [.init(field: "Posting", value: "Excluded")]) { dry in
          try bulk.setExcluded(Array(ids), true, dryRun: dry)
        })
        if let r = try? bulk.setExcluded(Array(ids), true, dryRun: true) { m.pendingBulk?.preview = r }
      },
      c.main("35-library-empty", c.empty) { m in library(m, .grid) },
      c.main("36-posts-problems") { m in
        prep(m)
        ui.postsTab = .problems
        m.screen = .posts
      },
      c.main("37-posts-all-inspector") { m in
        prep(m)
        ui.postsTab = .all
        m.postsSelection = (m.posts.first { $0.state == .posted && $0.metrics != nil } ?? m.posts.first)?.id
        m.screen = .posts
      },
      c.main("38-posts-empty", c.empty) { m in
        prep(m)
        m.screen = .posts
      },
      c.main("39-health") { m in
        prep(m)
        let r = Doctor(store: m.store).run()
        m.doctorReport = DoctorReport(generatedAt: m.now, findings: [],
                                      passed: (r.passed + r.findings.map(\.id)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
        probe.override = .init(agentLoaded: true, diskFree: 412_000_000_000, lastBackup: m.now.addingTimeInterval(-5 * 3600))
        m.screen = .health
      },
      c.main("3a-health-attention") { m in
        prep(m)
        m.doctorReport = Doctor(store: m.store).run()
        probe.override = .init(agentLoaded: false, diskFree: 38_000_000_000, lastBackup: nil)
        m.screen = .health
      },
      c.main("3b-command-palette") { m in
        prep(m)
        m.screen = .library
        ui.paletteQuery = "midnight"
        m.showPalette = true
      },
      c.main("3c-command-palette-clip") { m in
        prep(m)
        m.screen = .queue
        ui.paletteClipId = m.queueList.first?.id
        m.showPalette = true
      },
      c.main("3d-library-missing-quicklook") { m in
        library(m, .grid)
        ui.quickLook = m.libraryAll.first { m.libraryIsMissing($0) }
      },
      c.main("3e-library-longform-posted") { m in
        library(m, .grid)
        SampleData.unmarkSampleLongform(m)
        ui.longformTargets = m.libraryAll.filter { $0.type == .long }
      },
    ]
  }
}
