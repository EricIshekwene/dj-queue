import DJQCore
import Foundation

/// Round 24: timeline zoom, Eric's markers and the selected trim handle. The rules live in DJQCore (`TimelineTools`).
extension EditorModel {
  /// What the timeline shows: the whole file until a clip zooms (a long file opens on its trim).
  var viewport: TimelineViewport { (viewportRaw ?? .fit(duration)).clamped(duration) }
  var timelineZoomed: Bool { viewport.isZoomed(duration) }
  var marks: [Double] { edit.marks }

  func setViewport(_ v: TimelineViewport) {
    let c = v.clamped(duration)
    if c != viewportRaw { viewportRaw = c }
  }

  /// `d` > 0 zooms in, < 0 out, around `t` (the playhead unless a pinch says where).
  func zoomTimeline(_ d: Int, around t: Double? = nil) {
    guard !isPhoto, duration > 0 else { return }
    let f = d > 0 ? TimelineViewport.step : 1 / TimelineViewport.step
    setViewport(viewport.zoomed(by: f, around: t ?? playback.time, duration: duration))
  }

  /// Any zoom factor (a pinch), kept around `t`.
  func zoomTimeline(by factor: Double, around t: Double) {
    guard !isPhoto, duration > 0, factor > 0 else { return }
    setViewport(viewport.zoomed(by: factor, around: t, duration: duration))
  }

  func fitTimeline() { setViewport(.fit(duration)) }

  /// The trim with room either side (the zoom a long file opens at, for any file).
  func zoomToTrim() {
    let t = trim, pad = max(t.duration * 0.35, 1.5)
    setViewport(TimelineViewport(start: t.start - pad, end: t.end + pad))
  }

  func panTimeline(by dt: Double) { setViewport(viewport.panned(by: dt, duration: duration)) }

  /// Keeps `t` on screen when zoomed (playback, a dragged or nudged handle).
  func revealOnTimeline(_ t: Double) {
    guard timelineZoomed else { return }
    let v = viewport.revealing(t, duration: duration)
    if v != viewport { setViewport(v) }
  }

  // MARK: Markers

  /// M: a marker at the playhead, or the one it's on goes. Undo takes it back.
  func toggleMarker(at t: Double? = nil) {
    guard !isPhoto, !readOnly, video != nil, duration > 0 else { return }
    let r = TimelineMarks.toggled(edit.marks, at: t ?? playback.time, fps: fps, duration: duration)
    updateEdit { $0.marks = r.marks }
  }

  func moveMarker(from old: Double, to new: Double) {
    guard !readOnly, video != nil else { return }
    updateEdit { $0.marks = TimelineMarks.moved($0.marks, from: old, to: new, duration: duration) }
  }

  func removeMarker(_ t: Double) {
    guard let i = TimelineMarks.index(near: t, in: edit.marks, tolerance: 0.0005) else { return }
    updateEdit { $0.marks.remove(at: i) }
  }

  func clearMarkers() { updateEdit { $0.marks = [] } }

  // MARK: Trim handles

  func selectTrimEdge(_ e: TrimEdge?) { if trimEdge != e { trimEdge = e } }

  /// Sets one edge, kept at least half a second from the other.
  func setTrimEdge(_ e: TrimEdge, _ t: Double, live: Bool = false) {
    let v = TrimRules.clampedEdge(e, t, trim: trim, duration: duration)
    if e == .start { setTrimIn(v, live: live) } else { setTrimOut(v, live: live) }
  }

  /// ← / → with a handle selected: the arrow step (⇧ one frame); the playhead shows the frame it lands on.
  func nudgeTrim(_ d: Int, fine: Bool) {
    guard let e = trimEdge, !isPhoto else { return }
    let t = TrimRules.nudged(e, trim: trim, step: arrowStep, fps: fps, direction: d, fine: fine, duration: duration)
    setTrimEdge(e, t)
    playback.pause()
    playback.seek(t, exact: true)
    revealOnTimeline(t)
  }

  /// What the trim handles snap to.
  var trimSnapTargets: [Double] {
    TrimRules.snapTargets(duration: duration, markers: [video?.markerIn, video?.markerOut], marks: edit.marks)
  }
}
