import DJQCore
import Foundation

/// `DJQ_SNAPSHOT_EDITOR=1 DJQ_PHOTO_EDITOR_SCRIPT=<dir> DJQueueApp --snapshot <dir>` (round 21): the photo editor end to
/// end in the real editor window. STUB from the session parent; the editor's owner writes the script (see
/// `Editor/EditorCaptionScript.swift` and `Editor/TextLayersScript.swift` for the shape). The store already holds the
/// sample photo posts (`SampleData.addPhotoPosts`).
@MainActor
enum PhotoEditorScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    print("photo-editor-script: FAIL not written yet")
    return 1
  }
}
