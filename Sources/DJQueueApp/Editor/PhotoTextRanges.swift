import DJQCore
import Foundation

// Round 21: the rule that keeps a text on photos that exist is `PhotoTextRanges` in DJQCore (the editor and
// `PhotoImport.remove` share it).

/// Undo and redo of a photo-list change: the stored list goes back to one the post had, with the same photo ids and
/// files (a removed photo's copy stays in `Originals/` for exactly this), so nothing is copied and each photo's own
/// crop still belongs to it. Core's `PhotoImport.setPhotos` is the one write.
enum PhotoListRestore {
  @discardableResult
  static func set(_ photos: [PhotoItem], videoId: String, store: Store) throws -> Video {
    try PhotoImport(store: store).setPhotos(photos, videoId: videoId)
  }
}
