import DJQCore
import Foundation

/// `DJQ_PHOTO_IMPORT_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 21): the photo import, in the real main window on the
/// throwaway sample. STUB from the session parent; the import's owner writes the script (see
/// `Snapshot/SendToQueueScript.swift` for the shape). `scratch` is a folder for the pictures the script "picks".
@MainActor
enum PhotoImportScript {
  static func run(model: AppModel, store: Store, out: URL, scratch: URL) async -> Int32 {
    print("photo-import-script: FAIL not written yet")
    return 1
  }
}
