import DJQCore
import Foundation

/// Round 21, "Post at a set time" (DECISIONS-R21.md D12–D14). STUB from the session parent: the dialog's owner fills
/// this file and `Shared/PostAtDialog.swift`. Every entry point (stage control, menus, Calendar, ⌘K) calls `askPostAt`.
struct PostAtRequest: Identifiable, Equatable {
  let id = UUID()
  /// The items to give a time (one, or a selection).
  var videoIds: [String]
}

extension AppModel {
  /// Opens the dialog for these items.
  func askPostAt(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    postAtRequest = PostAtRequest(videoIds: ids)
  }
}
