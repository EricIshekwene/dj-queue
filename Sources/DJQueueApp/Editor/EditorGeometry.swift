import CoreGraphics
import DJQCore
import Foundation

/// Pure crop / time / snapping math for the editor (no UI, no I/O).
enum EditorGeometry {
  static let maxZoom = 4.0

  /// Largest rect of `aspect` that fits inside the source (zoom 1).
  static func maxCropSize(source: CGSize, aspect: Aspect) -> CGSize {
    let r = aspect.ratio
    if source.width / source.height > r {
      return CGSize(width: (source.height * r).rounded(), height: source.height)
    }
    return CGSize(width: source.width, height: (source.width / r).rounded())
  }

  /// Default crop for a new edit: centred, full height (9:16 on 3840×2160 → 1215×2160).
  static func defaultCrop(source: CGSize, aspect: Aspect) -> CropRect {
    let m = maxCropSize(source: source, aspect: aspect)
    return CropRect(x: ((source.width - m.width) / 2).rounded(), y: ((source.height - m.height) / 2).rounded(),
                    w: m.width, h: m.height)
  }

  static func zoom(of c: CropRect, source: CGSize, aspect: Aspect) -> Double {
    let m = maxCropSize(source: source, aspect: aspect)
    return max(1, m.height / max(c.h, 1))
  }

  /// Crop with the given zoom, keeping its centre, clamped to the source.
  static func crop(_ c: CropRect, zoom: Double, source: CGSize, aspect: Aspect) -> CropRect {
    let z = min(max(zoom, 1), maxZoom)
    let m = maxCropSize(source: source, aspect: aspect)
    let w = (m.width / z).rounded(), h = (m.height / z).rounded()
    let cx = c.x + c.w / 2, cy = c.y + c.h / 2
    return clamp(CropRect(x: cx - w / 2, y: cy - h / 2, w: w, h: h), source: source)
  }

  /// Re-fit a crop to a new aspect, keeping its centre and zoom.
  static func crop(_ c: CropRect, aspect new: Aspect, from old: Aspect, source: CGSize) -> CropRect {
    let z = zoom(of: c, source: source, aspect: old)
    let m = maxCropSize(source: source, aspect: new)
    let w = (m.width / z).rounded(), h = (m.height / z).rounded()
    return clamp(CropRect(x: c.x + c.w / 2 - w / 2, y: c.y + c.h / 2 - h / 2, w: w, h: h), source: source)
  }

  static func clamp(_ c: CropRect, source: CGSize) -> CropRect {
    var c = c
    c.w = min(c.w, source.width); c.h = min(c.h, source.height)
    c.x = min(max(0, c.x), source.width - c.w).rounded()
    c.y = min(max(0, c.y), source.height - c.h).rounded()
    return c
  }

  /// > 1 when the crop has fewer source pixels than the 1080-wide output.
  static func upscale(_ c: CropRect, aspect: Aspect) -> Double {
    Double(aspect.outputSize.w) / max(c.w, 1)
  }

  /// Snap `t` to the nearest candidate within `tolerance`.
  static func snap(_ t: Double, to candidates: [Double], tolerance: Double) -> (Double, Bool) {
    guard let best = candidates.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= tolerance else { return (t, false) }
    return (best, true)
  }

  /// Snap a normalised centre to 0.5 (centre line) within `tolerance`.
  static func snapCentre(_ v: Double, tolerance: Double = 0.015) -> (Double, Bool) {
    abs(v - 0.5) <= tolerance ? (0.5, true) : (v, false)
  }

  static func time(_ s: Double, tenths: Bool = false) -> String {
    let s = max(0, s)
    if tenths {
      let m = Int(s) / 60
      return String(format: "%d:%04.1f", m, s - Double(m * 60))
    }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
  }
}
