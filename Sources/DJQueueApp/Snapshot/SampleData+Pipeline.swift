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
