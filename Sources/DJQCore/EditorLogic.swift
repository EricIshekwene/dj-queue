import CoreGraphics
import Foundation

/// Pure crop / preview-mapping / snapping / timing math for the editor (UI-EDITOR owns this file).
/// Lives in DJQCore so `swift test` covers it; no UI, no I/O.
public enum EditorLogic {
  public static let maxZoom = 4.0

  // MARK: ⌘Z / ⇧⌘Z

  public enum UndoKey: Equatable, Sendable { case ignore, fieldUndo, fieldRedo, undo, redo }

  /// What a key press means in the editor. `covered`: an overlay (Settings, a dialog) is over the editor, so the key is
  /// the overlay's and the hidden clip's history stays put. Matched on the character so other keyboard layouts work.
  public static func undoKey(characters: String?, command: Bool, shift: Bool, option: Bool, control: Bool,
                             textEditing: Bool, covered: Bool) -> UndoKey {
    guard !covered, command, !option, !control, characters?.lowercased() == "z" else { return .ignore }
    if textEditing { return shift ? .fieldRedo : .fieldUndo }
    return shift ? .redo : .undo
  }

  // MARK: Crop (source pixels, always the renderer's even-pixel rect)

  /// The rect the export crops with (`Media.pixelCrop`), as a CropRect.
  public static func even(_ c: CropRect, source: CGSize) -> CropRect {
    let r = Media.pixelCrop(c, sourceWidth: Int(source.width), sourceHeight: Int(source.height))
    return CropRect(x: r.minX, y: r.minY, w: r.width, h: r.height)
  }

  /// Largest rect of `aspect` inside the source (zoom 1).
  public static func maxCropSize(source: CGSize, aspect: Aspect) -> CGSize {
    let r = aspect.ratio
    if source.width / source.height > r { return CGSize(width: source.height * r, height: source.height) }
    return CGSize(width: source.width, height: source.width / r)
  }

  /// Default crop for a new edit: centred, full height (9:16 on 3840×2160 → 1216×2160 at x 1312).
  public static func defaultCrop(source: CGSize, aspect: Aspect) -> CropRect {
    even(Media.centredCrop(aspect: aspect, sourceWidth: Int(source.width), sourceHeight: Int(source.height)), source: source)
  }

  public static func zoom(of c: CropRect, source: CGSize, aspect: Aspect) -> Double {
    max(1, maxCropSize(source: source, aspect: aspect).height / max(c.h, 1))
  }

  /// Crop at `zoom`, keeping its centre, inside the source, even pixels.
  public static func crop(_ c: CropRect, zoom: Double, source: CGSize, aspect: Aspect) -> CropRect {
    let z = min(max(zoom, 1), maxZoom)
    let m = maxCropSize(source: source, aspect: aspect)
    let w = m.width / z, h = m.height / z
    return clamp(CropRect(x: c.x + c.w / 2 - w / 2, y: c.y + c.h / 2 - h / 2, w: w, h: h), source: source)
  }

  /// Re-fit a crop to a new aspect, keeping centre and zoom.
  public static func crop(_ c: CropRect, aspect new: Aspect, from old: Aspect, source: CGSize) -> CropRect {
    crop(c, zoom: zoom(of: c, source: source, aspect: old), source: source, aspect: new)
  }

  /// Moved/zoomed crops stay inside the source and snap to the export's even pixels.
  public static func clamp(_ c: CropRect, source: CGSize) -> CropRect {
    var c = c
    c.w = min(c.w, source.width); c.h = min(c.h, source.height)
    c.x = min(max(0, c.x), source.width - c.w)
    c.y = min(max(0, c.y), source.height - c.h)
    return even(c, source: source)
  }

  /// > 1 when the crop has fewer source pixels than the 1080-wide output.
  public static func upscale(_ c: CropRect, aspect: Aspect) -> Double { Double(aspect.outputSize.w) / max(c.w, 1) }

  // MARK: Preview mapping (preview == export)

  /// Frame of the full source picture inside a view whose bounds show exactly `visible` (source pixels,
  /// top-left origin). `flipped == false` returns AppKit/CALayer bottom-left coordinates.
  public static func pictureFrame(visible: CGRect, source: CGSize, bounds: CGSize, flipped: Bool = false) -> CGRect {
    guard visible.width > 0 else { return .zero }
    let s = bounds.width / visible.width
    let y = flipped ? -visible.minY * s : -(source.height - visible.maxY) * s
    return CGRect(x: -visible.minX * s, y: y, width: source.width * s, height: source.height * s)
  }

  /// `CropRect` (source px) → rect in an image of `imageSize` that has the source's aspect.
  public static func imageRect(_ c: CropRect, source: CGSize, imageSize: CGSize) -> CGRect {
    let k = imageSize.width / max(source.width, 1)
    return CGRect(x: c.x * k, y: c.y * k, width: c.w * k, height: c.h * k).integral
  }

  // MARK: Snapping

  /// Snap `t` to the nearest candidate within `tolerance`.
  public static func snap(_ t: Double, to candidates: [Double], tolerance: Double) -> (value: Double, snapped: Bool) {
    guard let best = candidates.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= tolerance else { return (t, false) }
    return (best, true)
  }

  /// Snap targets for dragging a trim handle: markers and clip ends, never the playhead (it follows the handle).
  public static func trimSnapTargets(duration: Double, markers: [Double?]) -> [Double] {
    [0, duration] + markers.compactMap { $0 }.filter { $0 >= 0 && $0 <= duration }
  }

  /// Text centre (normalised) while dragging: snapped to the centre line, then kept so the whole block
  /// (normalised `extent`) stays inside the frame — exactly how TextOverlay places it.
  public static func textCentre(_ v: Double, extent: Double, snapTolerance: Double = 0.015) -> (value: Double, snapped: Bool) {
    var (x, s) = abs(v - 0.5) <= snapTolerance ? (0.5, true) : (v, false)
    if extent >= 1 { return (0.5, true) }
    x = min(max(x, extent / 2), 1 - extent / 2)
    return (x, s && x == 0.5)
  }

  // MARK: Trim-dependent values

  /// Text timing (relative to the trim start) kept inside a trim of `duration`. Explicit values stay explicit
  /// (an end past the trim becomes the trim length, never nil = "whole clip"); nil stays nil.
  /// Apply once when a trim change is committed (drag end, I/O keys, trim buttons), not on every drag tick.
  public static func clampTextTiming(start: Double?, end: Double?, trimDuration d: Double) -> (start: Double?, end: Double?) {
    guard d > 0 else { return (start, end) }
    let minLen = min(0.3, d)
    let s = start.map { min(max(0, $0), d - minLen) }
    let e = end.map { min(max($0, (s ?? 0) + minLen), d) }
    return (s, e)
  }

  /// Text timing and cover after a committed trim change. A cover still inside the trim is kept as is.
  public static func afterTrimCommit(textStart: Double?, textEnd: Double?, cover: Double?, trim: TrimRange)
    -> (textStart: Double?, textEnd: Double?, cover: Double?) {
    let (s, e) = clampTextTiming(start: textStart, end: textEnd, trimDuration: trim.duration)
    let inside = cover.map { $0 >= trim.start && $0 <= trim.end } ?? true
    return (s, e, inside ? cover : clampCover(cover, trim: trim))
  }

  /// `layer`'s window after a committed trim change (`d` = the trim's length): the first text's rule, so an extra the
  /// trim would drop moves inside it instead. Per-platform trims don't come through here: there the text just isn't
  /// drawn (`PreviewKeys.layerWindows`). An inverted extra is never drawn and stays as it is, so a trim can't make it appear.
  public static func clampLayer(_ layer: TextLayer, trimDuration d: Double) -> TextLayer {
    if let e = layer.end, e <= max(0, layer.start ?? 0) { return layer }
    var l = layer
    (l.start, l.end) = clampTextTiming(start: layer.start, end: layer.end, trimDuration: d)
    return l
  }

  /// Cover time (absolute) kept inside the trim; nil = first frame of the trim.
  public static func clampCover(_ t: Double?, trim: TrimRange) -> Double? {
    guard let t else { return nil }
    let c = min(max(t, trim.start), max(trim.start, trim.end - 0.05))
    return abs(c - trim.start) < 0.01 ? nil : c
  }

  // MARK: Safe zones

  /// Maps platform-UI rects drawn on a 9:16 phone screen (normalised, top-left) onto a video of `aspect`
  /// shown full-width and vertically centred on that screen; parts outside the video are dropped.
  /// 16:9 isn't shown in the vertical feed, so it gets none.
  public static func safeZones(_ phone: [CGRect], aspect: Aspect) -> [CGRect] {
    guard aspect != .r16x9 else { return [] }
    if aspect == .r9x16 { return phone }
    let screenH = 16.0 / 9, videoH = 1 / aspect.ratio
    let top = (screenH - videoH) / 2
    return phone.compactMap { r in
      let y0 = (r.minY * screenH - top) / videoH, y1 = (r.maxY * screenH - top) / videoH
      let a = max(0, y0), b = min(1, y1)
      return b - a > 0.005 ? CGRect(x: r.minX, y: a, width: r.width, height: b - a) : nil
    }
  }

  // MARK: Round 2 — overrides on top of New clip defaults

  /// An edited value that equals its default is stored as nil ("follows the default"), so the editor's "Custom"
  /// tag only appears for real changes.
  public static func override(_ value: Double, default d: Double, tolerance: Double = 0.01) -> Double? {
    abs(value - d) < tolerance ? nil : value
  }

  /// Turns posting on/off for one platform as an override on top of `defaults.platforms`
  /// (skip a default platform, or include one the defaults leave out).
  public static func setPosting(_ e: inout Edit, _ p: Platform, _ on: Bool, defaults: NewClipDefaults) {
    if on {
      e.skippedPlatforms.remove(p)
      if !defaults.platforms.contains(p) { e.includedPlatforms.insert(p) }
    } else {
      e.includedPlatforms.remove(p)
      if defaults.platforms.contains(p) { e.skippedPlatforms.insert(p) }
    }
  }

  public enum LengthLevel: Sendable, Equatable { case ok, near, over }

  /// Caption length against a platform limit: near from 90 %, over past the limit (the editor warns only then).
  public static func lengthLevel(count: Int, limit: Int) -> LengthLevel {
    if count > limit { return .over }
    return Double(count) >= Double(limit) * 0.9 ? .near : .ok
  }

  /// Grace zones on the timeline: the seconds the clip file keeps before the in marker and after the out marker.
  /// Empty for a side without a marker or with no grace.
  public static func graceZones(duration: Double, markerIn: Double?, markerOut: Double?) -> [TrimRange] {
    var out: [TrimRange] = []
    if let a = markerIn, a > 0.01 { out.append(TrimRange(start: 0, end: min(a, duration))) }
    if let b = markerOut, b < duration - 0.01 { out.append(TrimRange(start: max(0, b), end: duration)) }
    return out
  }

  // MARK: Formatting

  public static func time(_ s: Double, tenths: Bool = false) -> String {
    let s = max(0, s)
    if tenths {
      // Round to tenths first, so 179.97 s reads 3:00.0, not 2:60.0.
      let d = Int((s * 10).rounded())
      return String(format: "%d:%02d.%d", d / 600, (d % 600) / 10, d % 10)
    }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
  }
}
