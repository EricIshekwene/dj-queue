import DJQCore
import Foundation

/// PIPELINE leaf sample data for the Edit shots (throwaway snapshot DB only, made-up values): one clip with no
/// Title and no suggestions at the top of Edit (shows "Add title" + "Ask an agent"), and a chosen cover on the
/// too-long clip ("Cover" badge). `pipelineRevert` undoes both so later shots (and other leaves) see the seed.
@MainActor
extension SampleData {
  private static var pipelineScored: String?
  private static var pipelineCover: String?

  static func pipelineEditExtras(_ m: AppModel) {
    let s = m.store
    if pipelineScored == nil,
       let v = m.scoreList.first(where: { $0.titleText == nil && (m.suggestionsByVideo[$0.id] ?? []).isEmpty }) {
      try? s.setScore(v.id, 26)
      try? s.refreshState(videoId: v.id)
      pipelineScored = v.id
    }
    if pipelineCover == nil,
       let v = m.editList.first(where: { (m.issuesByVideo[$0.id] ?? []).contains { $0.kind == .tooLong } }),
       var e = try? s.edit(videoId: v.id), e.coverTime == nil {
      e.coverTime = 4
      try? s.save(e, videoId: v.id)
      pipelineCover = v.id
    }
    m.refreshNow()
  }

  private static var pipelineMissingId: String?

  /// Marks the first Edit clip's file missing (on) or puts it back (off) — the missing-file Edit card shot.
  static func pipelineMissing(_ m: AppModel, _ on: Bool) {
    let s = m.store
    if on, pipelineMissingId == nil, var v = m.editList.first(where: { !$0.missing }) {
      v.missing = true
      try? s.save(v)
      try? s.refreshState(videoId: v.id)
      pipelineMissingId = v.id
    } else if !on, let id = pipelineMissingId, var v = try? s.video(id: id) {
      v.missing = false
      try? s.save(v)
      try? s.refreshState(videoId: id)
      pipelineMissingId = nil
    }
    m.refreshNow()
  }

  static func pipelineRevert(_ m: AppModel) {
    let s = m.store
    if let id = pipelineScored {
      try? s.setScore(id, nil)
      try? s.refreshState(videoId: id)
      pipelineScored = nil
    }
    if let id = pipelineCover, var e = try? s.edit(videoId: id) {
      e.coverTime = nil
      try? s.save(e, videoId: id)
      pipelineCover = nil
    }
    m.refreshNow()
  }
}
