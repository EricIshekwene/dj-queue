import CoreGraphics
import Foundation

/// Pure crop / preview-mapping / snapping / timing math for the editor (UI-EDITOR owns this file).
/// Lives in DJQCore so `swift test` covers it; no UI, no I/O.
public enum EditorLogic {
  public static let maxZoom = 4.0

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

  /// Text timing (relative to the trim start) kept inside a trim of `duration`; nil = edge of the clip.
  public static func clampTextTiming(start: Double?, end: Double?, trimDuration d: Double) -> (start: Double?, end: Double?) {
    guard d > 0 else { return (nil, nil) }
    let minLen = min(0.3, d)
    var s = start.map { min(max(0, $0), d - minLen) }
    var e = end.map { min(max($0, (s ?? 0) + minLen), d) }
    if let x = s, x <= 0.01 { s = nil }
    if let x = e, x >= d - 0.01 { e = nil }
    return (s, e)
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

  // MARK: Formatting

  public static func time(_ s: Double, tenths: Bool = false) -> String {
    let s = max(0, s)
    if tenths {
      let m = Int(s) / 60
      return String(format: "%d:%04.1f", m, s - Double(m * 60))
    }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
  }
}
