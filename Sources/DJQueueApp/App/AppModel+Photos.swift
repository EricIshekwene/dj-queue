import DJQCore
import Foundation

/// Round 21, photo import (DECISIONS-R21.md D2, D3). STUB from the session parent: the import's owner fills this file
/// and `Shared/PhotoImportSheet.swift`. The file picker, a drop, the sheet and the check script all end in `importPhotos`.
struct PhotoImportRequest: Identifiable, Equatable {
  let id = UUID()
  /// The picked or dropped files, in order.
  var files: [URL]
}

extension AppModel {
  /// Opens the import sheet for these files.
  func askImportPhotos(_ files: [URL]) {
    guard !files.isEmpty else { return }
    photoImportRequest = PhotoImportRequest(files: files)
  }
}
