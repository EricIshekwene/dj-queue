import DJQCore
import Foundation

/// `DJQ_POST_AT_SCRIPT=1 DJQueueApp --snapshot <dir>` (round 21): "Post at a set time" and the Calendar, in the real main
/// window on the throwaway sample. STUB from the session parent; the dialog's owner writes the script (see
/// `Snapshot/SendToQueueScript.swift` for the shape). `clock` is the sample's fixed clock.
@MainActor
enum PostAtScript {
  static func run(model: AppModel, store: Store, clock: FixedClock, out: URL) async -> Int32 {
    print("post-at-script: FAIL not written yet")
    return 1
  }
}
