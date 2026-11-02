import DJQCore
import Foundation

/// BROWSE leaf sample data (throwaway snapshot DB only): a posted long-form part for the Library "Posted" filter.
extension SampleData {
  static let sampleLongformURL = "https://www.youtube.com/watch?v=sample0001"

  @MainActor static func markSampleLongformPosted(_ m: AppModel) {
    guard let v = m.libraryAll.first(where: { $0.type == .long }) else { return }
    try? m.store.setLongformURL(v.id, sampleLongformURL)
    try? m.store.refreshState(videoId: v.id)
    m.refreshNow()
  }

  @MainActor static func unmarkSampleLongform(_ m: AppModel) {
    guard let v = m.libraryAll.first(where: { $0.type == .long }) else { return }
    try? m.store.setLongformURL(v.id, nil)
    try? m.store.refreshState(videoId: v.id)
    m.refreshNow()
  }
}
