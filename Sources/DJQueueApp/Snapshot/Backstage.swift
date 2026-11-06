import AVFoundation
import AppKit

/// Where snapshot runs, probes and scripts put their windows: far off every display, so verification never shows on the
/// screen or takes focus. Windows there are still real: the window server keeps drawing them (live player, materials and
/// tooltips included) and capturing them needs no permission. Clicks, keys and hovers are events sent to the window, so
/// the user's pointer and keyboard stay out of it.
///
/// Things to know. Nothing ticks an animation here, so `dsAnimationsOff` is on for these runs. Capture one window at a time (`WindowCapture`): a region capture of this area comes back empty.
/// A real `.sheet` pulls its parent onto a display, and so does a real `NSMenu`, so checks stand in for those.
/// Players stay at volume 0 in these runs (`silenceForChecks`): state checks read `isMuted`, and nobody hears a run.
@MainActor
enum Backstage {
  /// Stands in for a display: probes centre windows in it and push them against its edges, and tooltips are placed inside it.
  static let stage = CGRect(x: -24_000, y: -24_000, width: 1800, height: 1100)

  /// Puts the window on the stage and orders it in, without activating the app.
  static func show(_ w: NSWindow) {
    w.setFrameOrigin(NSPoint(x: stage.midX - w.frame.width / 2, y: stage.midY - w.frame.height / 2))
    front(w)
  }

  /// Keeps a run's players silent without changing what `isMuted` reports.
  static func silenceForChecks(_ player: AVPlayer) {
    if AppModel.isSnapshotRun { player.volume = 0 }
  }

  /// Orders in a window that's already on the stage, keeping its place.
  static func front(_ w: NSWindow) { w.orderFrontRegardless() }
}
