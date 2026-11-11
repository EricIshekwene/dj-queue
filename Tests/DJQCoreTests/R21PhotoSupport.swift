import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import DJQCore

/// Round 21 test images, drawn here with CoreGraphics and written with ImageIO into the fixture's temp folder (never a
/// third-party picture). `halves` paints the stored pixels' left half one colour and the right half another, so a
/// crop, an order or an orientation shows up as a colour at a known place.
enum PhotoImages {
  struct RGB: Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int
    static let red = RGB(r: 220, g: 30, b: 30), blue = RGB(r: 30, g: 30, b: 220), green = RGB(r: 30, g: 200, b: 30)
    static let yellow = RGB(r: 230, g: 220, b: 30), grey = RGB(r: 128, g: 128, b: 128), white = RGB(r: 255, g: 255, b: 255)
    var description: String { "(\(r),\(g),\(b))" }
    /// Close enough after JPEG and a colour-managed draw.
    func near(_ o: RGB, _ tolerance: Int = 40) -> Bool {
      abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
    }
  }

  static func image(width: Int, height: Int, left: RGB, right: RGB) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func fill(_ c: RGB, _ r: CGRect) {
      ctx.setFillColor(CGColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
      ctx.fill(r)
    }
    fill(left, CGRect(x: 0, y: 0, width: width / 2, height: height))
    fill(right, CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return ctx.makeImage()!
  }

  /// Writes a picture; false when this Mac has no encoder for `type` (HEIC on some machines).
  @discardableResult
  static func write(_ url: URL, width: Int = 400, height: Int = 300, left: RGB = .red, right: RGB = .blue,
                    type: UTType = .jpeg, orientation: Int? = nil, gps: Bool = false) -> Bool {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    if gps {
      props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N",
                                              kCGImagePropertyGPSLongitude: 74.0, kCGImagePropertyGPSLongitudeRef: "W"]
    }
    CGImageDestinationAddImage(dest, image(width: width, height: height, left: left, right: right), props as CFDictionary)
    return CGImageDestinationFinalize(dest)
  }

  /// The pixels of a picture file as it is stored (no orientation applied), top-left origin.
  struct Bitmap {
    var width: Int, height: Int
    var data: [UInt8]
    subscript(x: Int, y: Int) -> RGB {
      let i = (y * width + x) * 4
      return RGB(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
    }
    /// Pixels that differ from `o` by more than a JPEG's noise.
    func difference(_ o: Bitmap, in rows: Range<Int>? = nil) -> Int {
      guard width == o.width, height == o.height else { return Int.max }
      var n = 0
      for y in rows ?? 0..<height {
        for x in 0..<width where !self[x, y].near(o[x, y], 24) { n += 1 }
      }
      return n
    }
  }

  static func bitmap(_ image: CGImage) -> Bitmap {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buf in
      let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Bitmap(width: w, height: h, data: data)
  }

  static func bitmap(_ url: URL) -> Bitmap? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return bitmap(img)
  }

  static func properties(_ url: URL) -> [CFString: Any] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
  }
}

extension Fixture {
  /// Where a test keeps the pictures "Eric picked" (outside DJ Video, like Downloads).
  var inbox: URL { dir.appendingPathComponent("inbox") }

  /// Writes `names` as 400×300 pictures in the inbox, each with its own colours, and returns their URLs.
  @discardableResult
  func pictures(_ names: [String], width: Int = 400, height: Int = 300) -> [URL] {
    let colours: [(PhotoImages.RGB, PhotoImages.RGB)] = [(.red, .blue), (.green, .yellow), (.blue, .red), (.yellow, .green),
                                                         (.grey, .red), (.red, .grey), (.green, .blue), (.blue, .green)]
    return names.enumerated().map { i, n in
      let url = inbox.appendingPathComponent(n)
      let c = colours[i % colours.count]
      PhotoImages.write(url, width: width, height: height, left: c.0, right: c.1,
                        type: n.lowercased().hasSuffix(".png") ? .png : .jpeg)
      return url
    }
  }

  /// A photo post made from `count` fresh pictures ("<name>-1.jpg", …), as a carousel.
  @discardableResult
  func photoPost(_ name: String = "night", count: Int = 3, title: String? = nil, width: Int = 400, height: Int = 300) throws -> Video {
    let files = pictures((1...count).map { "\(name)-\($0).jpg" }, width: width, height: height)
    return try requireValue(try PhotoImport(store: store).add(files: files, title: title).posts.first)
  }

  /// Send to Queue, as Eric does.
  @discardableResult
  func send(_ id: String) throws -> BulkResult { try BulkActions(store: store).sendToQueue([id]) }
}

struct MissingValue: Error {}

/// `#require` for helpers outside a test body.
func requireValue<T>(_ v: T?) throws -> T {
  guard let v else { throw MissingValue() }
  return v
}
