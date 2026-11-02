import DJQCore
import SwiftUI

/// PIPELINE leaf shots (prefix 1x): Score, Edit, Queue in their view modes, bulk bars, the confirmation sheet and
/// the empty states. View modes live on the shared model, so every shot sets its own and the last one resets them.
extension SnapshotShots {
  static func pipeline(_ c: SnapshotContext) -> [Shot] {
    func mode(_ m: AppModel, _ s: Screen, _ v: DSViewMode) {
      m.viewModes[s] = v
      m.screen = s
    }
    return [
      c.main("10-score-single") { m in
        PipelineUIState.shared.typedScores = [:]
        mode(m, .score, .single)
      },
      // After ↩: the toast sits above the control pill, never over it.
      c.main("10b-score-after-save") { m in
        PipelineUIState.shared.typedScores = [:]
        mode(m, .score, .single)
        m.show(DSToastModel(message: "Saved 1 score", tone: .success, actionTitle: "Undo", action: {}, duration: 6))
      },
      c.main("11-score-grid") { m in
        mode(m, .score, .grid)
        let ids = m.scoreList.prefix(3).map(\.id)
        PipelineUIState.shared.typedScores = Dictionary(uniqueKeysWithValues: zip(ids, ["72", "64", "81"]))
        m.visibleIds[.score] = m.scoreList.map(\.id)
        m.setSelection(ids, screen: .score)
      },
      c.main("12-score-empty", c.empty) { m in
        PipelineUIState.shared.typedScores = [:]
        mode(m, .score, .single)
      },
      c.main("13-edit-cards") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .wide)
      },
      c.main("14-edit-grid") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .grid)
      },
      c.main("15-edit-list") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .list)
      },
      c.main("16-edit-bulk-confirm") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .wide)
        let ids = Array(m.editList.prefix(3).map(\.id))
        m.visibleIds[.edit] = m.editList.map(\.id)
        m.setSelection(ids, screen: .edit)
        let bulk = m.bulk
        m.pipelineBulk("Send \(AppModel.pipelineClips(ids.count)) to the Queue?", verb: "Send to Queue", ids: ids,
                       changes: [.init(field: "Crop", value: "Default anchor, confirmed where missing"),
                                 .init(field: "Text, caption, cover", value: "Keep following New clip defaults"),
                                 .init(field: "Title", value: "Not set by this — clips without one still need text")]) { b, dry in
          try b.makeReadyWithDefaults(ids, dryRun: dry)
        }
        // Snapshot: show the dry-run line without waiting for the background check.
        if let r = try? bulk.makeReadyWithDefaults(ids, dryRun: true) { m.pendingBulk?.preview = r }
      },
      // The toast stacks above the bulk bar (here a selection is still showing) and states make-ready's real result.
      c.main("16b-edit-toast-sent-to-queue") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .wide)
        let ids = m.editList.map(\.id)
        m.visibleIds[.edit] = ids
        m.setSelection(Array(ids.prefix(2)), screen: .edit)
        if let r = try? m.bulk.makeReadyWithDefaults(ids, dryRun: true), let o = r.outlook {
          m.show(DSToastModel(message: AppModel.outlookMessage(o, changed: r.changed.count),
                              tone: o.needTitle.isEmpty && o.other.isEmpty ? .success : .neutral, actionTitle: "Undo", action: {}))
        }
      },
      c.main("17-edit-empty", c.empty) { m in mode(m, .edit, .wide) },
      c.main("1e-edit-single") { m in
        SampleData.pipelineEditExtras(m)
        mode(m, .edit, .single)
      },
      c.main("18-queue-cards") { m in
        SampleData.pipelineRevert(m)
        mode(m, .queue, .wide)
      },
      c.main("19-queue-grid") { m in
        SampleData.pipelineRevert(m)
        mode(m, .queue, .grid)
      },
      c.main("1a-queue-single") { m in
        SampleData.pipelineRevert(m)
        mode(m, .queue, .single)
      },
      c.main("1b-queue-list") { m in
        SampleData.pipelineRevert(m)
        mode(m, .queue, .list)
      },
      c.main("1c-queue-bulk") { m in
        SampleData.pipelineRevert(m)
        mode(m, .queue, .wide)
        let ids = m.queueClips.dropFirst(7).prefix(3).map(\.id)
        m.visibleIds[.queue] = m.queueClips.map(\.id)
        m.setSelection(ids, screen: .queue)
      },
      // Round 4 S1: a scored clip whose file went missing sits in Edit — "File missing" chip, Relink, no autoplay,
      // stage moves blocked with the core reason (throwaway DB; put back right after).
      c.main("1f-edit-missing-file") { m in
        SampleData.pipelineMissing(m, true)
        mode(m, .edit, .wide)
      },
      c.view("1f-edit-missing-file-revert", width: 10, height: 10) {
        SampleData.pipelineMissing(c.model, false)
        return AnyView(Color.clear)
      },
      // Round 4 S4: applied filters on a real screen (Kind + Score chips, Clear all, Filters count).
      c.main("1g-library-filters-applied") { m in
        mode(m, .library, .grid)
        ListPrefs.shared.setFilter(.library, ListFilterKey.kind, Kind.djVid.rawValue)
        ListPrefs.shared.setFilter(.library, ListFilterKey.score, LibraryScoreFilter.middle.rawValue)
      },
      c.main("1d-queue-empty", c.empty) { m in
        mode(m, .queue, .wide)
        // Leave the shared sample model as the seed left it.
        SampleData.pipelineRevert(c.model)
        for s in [Screen.score, .edit, .queue] { c.model.viewModes[s] = nil }
        PipelineUIState.shared.typedScores = [:]
      },
    ]
  }
}
