import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

@Suite struct EditorLogicTests {
  let src = CGSize(width: 3840, height: 2160)

  // MARK: Crop

  @Test func defaultCropIsTheExportsEvenCentredFullHeight916() {
    let c = EditorLogic.defaultCrop(source: src, aspect: .r9x16)
    #expect(c == CropRect(x: 1312, y: 0, w: 1216, h: 2160))
    let r = Media.pixelCrop(c, sourceWidth: 3840, sourceHeight: 2160)
    #expect(CGRect(x: c.x, y: c.y, width: c.w, height: c.h) == r)  // preview rect == export rect
  }

  @Test func everyAspectDefaultFitsAndIsEven() {
    for a in Aspect.allCases {
      let c = EditorLogic.defaultCrop(source: src, aspect: a)
      #expect(c.x >= 0 && c.y >= 0 && c.x + c.w <= 3840 && c.y + c.h <= 2160)
      #expect([c.x, c.y, c.w, c.h].allSatisfy { Int($0) % 2 == 0 })
      #expect(abs(c.w / c.h - a.ratio) < 0.01)
    }
  }

  @Test func zoomRoundTripKeepsCentreAndStaysInside() {
    let c0 = EditorLogic.defaultCrop(source: src, aspect: .r9x16)
    let z = EditorLogic.crop(c0, zoom: 2, source: src, aspect: .r9x16)
    #expect(abs(EditorLogic.zoom(of: z, source: src, aspect: .r9x16) - 2) < 0.01)
    #expect(abs((z.x + z.w / 2) - (c0.x + c0.w / 2)) <= 2)
    let back = EditorLogic.crop(z, zoom: 1, source: src, aspect: .r9x16)
    #expect(back == c0)
    #expect(EditorLogic.crop(c0, zoom: 99, source: src, aspect: .r9x16).h == 540)  // capped at 4×
  }

  @Test func clampKeepsCropInsideSource() {
    let c = EditorLogic.clamp(CropRect(x: 3500, y: -40, w: 1216, h: 2160), source: src)
    #expect(c == CropRect(x: 2624, y: 0, w: 1216, h: 2160))
  }

  @Test func aspectChangeKeepsZoom() {
    let z = EditorLogic.crop(EditorLogic.defaultCrop(source: src, aspect: .r9x16), zoom: 1.5, source: src, aspect: .r9x16)
    let sq = EditorLogic.crop(z, aspect: .r1x1, from: .r9x16, source: src)
    #expect(abs(sq.w - sq.h) <= 2)
    #expect(abs(EditorLogic.zoom(of: sq, source: src, aspect: .r1x1) - 1.5) < 0.01)
  }

  @Test func upscaleFactor() {
    #expect(EditorLogic.upscale(CropRect(x: 0, y: 0, w: 1216, h: 2160), aspect: .r9x16) < 1)
    #expect(abs(EditorLogic.upscale(CropRect(x: 0, y: 0, w: 810, h: 1440), aspect: .r9x16) - 1.333) < 0.01)
  }

  // MARK: Crop ↔ preview mapping

  @Test func pictureFrameMapsCropOntoBounds() {
    let crop = CGRect(x: 1312, y: 0, width: 1216, height: 2160)
    let b = CGSize(width: 333, height: 591.5)
    let f = EditorLogic.pictureFrame(visible: crop, source: src, bounds: b)
    let s = 333 / 1216.0
    #expect(abs(f.width - 3840 * s) < 0.001 && abs(f.height - 2160 * s) < 0.001)
    // The crop's top-left lands on the view's top-left; in bottom-left coords its bottom lands on y 0.
    #expect(abs(f.minX + 1312 * s) < 0.001)
    #expect(abs(f.minY) < 0.001)
    // A crop lower in the frame moves the picture up (bottom-left coordinates).
    let low = EditorLogic.pictureFrame(visible: CGRect(x: 2116, y: 360, width: 810, height: 1440), source: src,
                                       bounds: CGSize(width: 333, height: 592))
    let k = 333 / 810.0
    #expect(abs(low.minY + (2160 - 1800) * k) < 0.001)
    let flipped = EditorLogic.pictureFrame(visible: CGRect(x: 2116, y: 360, width: 810, height: 1440), source: src,
                                           bounds: CGSize(width: 333, height: 592), flipped: true)
    #expect(abs(flipped.minY + 360 * k) < 0.001)
  }

  @Test func imageRectScalesCropToStill() {
    let r = EditorLogic.imageRect(CropRect(x: 1312, y: 0, w: 1216, h: 2160), source: src,
                                  imageSize: CGSize(width: 1920, height: 1080))
    #expect(r == CGRect(x: 656, y: 0, width: 608, height: 1080))
  }

  // MARK: Snapping

  @Test func snapWithinTolerance() {
    #expect(EditorLogic.snap(4.1, to: [0, 4.0, 27], tolerance: 0.2) == (4.0, true))
    #expect(EditorLogic.snap(4.5, to: [0, 4.0, 27], tolerance: 0.2) == (4.5, false))
  }

  @Test func trimTargetsNeverIncludeThePlayhead() {
    // A trim handle drag seeks the playhead to the handle; if the playhead were a target the handle
    // would stick to its own last position. Successive small moves must therefore move freely.
    let targets = EditorLogic.trimSnapTargets(duration: 158, markers: [3.2, nil, 400])
    #expect(targets == [0, 158, 3.2])
    var t = 20.0
    for _ in 0..<10 {
      t = EditorLogic.snap(t + 0.1, to: targets, tolerance: 0.9).value
    }
    #expect(abs(t - 21.0) < 0.0001)
  }

  @Test func textCentreSnapsAndKeepsBlockInside() {
    #expect(EditorLogic.textCentre(0.51, extent: 0.4) == (0.5, true))
    #expect(EditorLogic.textCentre(0.95, extent: 0.6).value == 0.7)  // wide block can't leave the frame
    #expect(EditorLogic.textCentre(0.02, extent: 0.2).value == 0.1)
    #expect(EditorLogic.textCentre(0.3, extent: 1.2) == (0.5, true))
    #expect(EditorLogic.textCentre(0.3, extent: 0.2) == (0.3, false))
  }

  // MARK: Trim-dependent values

  @Test func textTimingStaysInsideNewTrim() {
    #expect(EditorLogic.clampTextTiming(start: 2, end: 12, trimDuration: 30) == (2, 12))
    #expect(EditorLogic.clampTextTiming(start: 2, end: 12, trimDuration: 8) == (2, nil))  // end → clip end
    let r = EditorLogic.clampTextTiming(start: 25, end: nil, trimDuration: 10)
    #expect(r.start == 9.7 && r.end == nil)
    #expect(EditorLogic.clampTextTiming(start: 0, end: 30, trimDuration: 30) == (nil, nil))
  }

  @Test func coverStaysInsideTrim() {
    let t = TrimRange(start: 5, end: 20)
    #expect(EditorLogic.clampCover(nil, trim: t) == nil)
    #expect(EditorLogic.clampCover(2, trim: t) == nil)  // before the trim → first frame
    #expect(EditorLogic.clampCover(12, trim: t) == 12)
    #expect(EditorLogic.clampCover(40, trim: t) == 19.95)
  }

  // MARK: Safe zones

  @Test func safeZonesFollowAspect() {
    let phone = [CGRect(x: 0, y: 0, width: 1, height: 0.085), CGRect(x: 0, y: 0.80, width: 1, height: 0.20)]
    #expect(EditorLogic.safeZones(phone, aspect: .r9x16) == phone)
    #expect(EditorLogic.safeZones(phone, aspect: .r16x9).isEmpty)
    // 4:5 sits in the middle of the phone screen: the top bar falls outside, the caption area clips its bottom.
    let p45 = EditorLogic.safeZones(phone, aspect: .r4x5)
    #expect(p45.count == 1)
    #expect(abs(p45[0].maxY - 1) < 0.0001 && abs(p45[0].minY - 0.926) < 0.01)
    // A 1:1 video sits between the top bar and the caption area: neither covers it.
    #expect(EditorLogic.safeZones(phone, aspect: .r1x1).isEmpty)
  }
}
