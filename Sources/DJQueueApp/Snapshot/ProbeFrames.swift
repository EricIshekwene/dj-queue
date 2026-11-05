import SwiftUI

/// Where a marked view sits, for the evidence probes: a row scrolled out of a lazy list has no frame here. Records
/// only in snapshot runs; in the app `probeFrame` adds nothing to the view.
@MainActor
enum ProbeFrames {
  static var frames: [String: CGRect] = [:]
}

extension View {
  @ViewBuilder func probeFrame(_ key: String) -> some View {
    if AppModel.isSnapshotRun {
      background {
        GeometryReader { g in
          Color.clear
            .onChange(of: g.frame(in: .global), initial: true) { _, f in ProbeFrames.frames[key] = f }
            .onDisappear { ProbeFrames.frames[key] = nil }
        }
      }
    } else {
      self
    }
  }
}
