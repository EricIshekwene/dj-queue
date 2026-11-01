import CoreGraphics
import Foundation
import Testing
@testable import DJQCore

func resolved(_ text: String = "Yayo x Johnny 🔥", style: TextStyle = .box, size: Double = 64, posX: Double = 0.5,
              posY: Double = 0.5, align: TextAlign = .center, noText: Bool = false,
              textStart: Double? = nil, textEnd: Double? = nil) -> ResolvedVersion {
  var v = Version(number: 1)
  v.text = text; v.style = style; v.size = size; v.posX = posX; v.posY = posY; v.align = align; v.noText = noText
  v.textStart = textStart; v.textEnd = textEnd
  return VersionResolver.resolve([v], number: 1, settings: Settings())
}

/// RGBA8 pixel access for assertions.
struct Pixels {
  let w: Int, h: Int
  let data: [UInt8]
  init(_ img: CGImage) {
    w = img.width; h = img.height
    var d = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    data = d
  }
  /// (r, g, b, a) at top-left coordinates.
  func at(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let i = (y * w + x) * 4
    return (data[i], data[i + 1], data[i + 2], data[i + 3])
  }
  func alphaSum(in r: CGRect) -> Int {
    var s = 0
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { s += Int(at(x, y).3) } }
    return s
  }
}

@Suite struct RenderOverlayTests {
  @Test func nilWhenNoText() {
    #expect(TextOverlay.image(for: resolved(noText: true), aspect: .r9x16) == nil)
    #expect(TextOverlay.image(for: resolved("   \n "), aspect: .r9x16) == nil)
    #expect(TextOverlay.png(for: resolved(""), aspect: .r9x16) == nil)
    #expect(TextOverlay.textBounds(for: resolved(noText: true), aspect: .r9x16) == nil)
  }

  @Test func deterministicBytes() throws {
    for style in TextStyle.allCases {
      let v = resolved("Song One\nx\nSong Two 🔥", style: style)
      let a = try #require(TextOverlay.png(for: v, aspect: .r9x16))
      let b = try #require(TextOverlay.png(for: v, aspect: .r9x16))
      #expect(a == b)
    }
  }

  @Test func outputSizeMatchesAspect() throws {
    for aspect in Aspect.allCases {
      let img = try #require(TextOverlay.image(for: resolved(), aspect: aspect))
      #expect(img.width == aspect.outputSize.w && img.height == aspect.outputSize.h)
    }
  }

  @Test func alphaOnlyWhereTheTextIs() throws {
    let v = resolved()
    let img = try #require(TextOverlay.image(for: v, aspect: .r9x16))
    let b = try #require(TextOverlay.textBounds(for: v, aspect: .r9x16))
    // Centred at (0.5, 0.5) of 1080×1920.
    #expect(abs(b.midX - 540) <= 1 && abs(b.midY - 960) <= 1)
    let px = Pixels(img)
    // Box style: the box centre is opaque, far corners are transparent.
    #expect(px.at(Int(b.minX) + 4, Int(b.midY)).3 == 255)
    #expect(px.at(5, 5).3 == 0 && px.at(1075, 1915).3 == 0)
    // Nothing outside the bounds.
    let outside = px.alphaSum(in: CGRect(x: 0, y: 0, width: 1080, height: b.minY - 1))
      + px.alphaSum(in: CGRect(x: 0, y: b.maxY + 1, width: 1080, height: 1920 - b.maxY - 1))
    #expect(outside == 0)
    // Box is white, text is black somewhere inside.
    let c = px.at(Int(b.minX) + 4, Int(b.midY))
    #expect(c.0 == 255 && c.1 == 255 && c.2 == 255)
    var dark = 0
    for x in stride(from: Int(b.minX), to: Int(b.maxX), by: 2) where px.at(x, Int(b.midY)).0 < 40 { dark += 1 }
    #expect(dark > 10)
  }

  @Test func positionMovesTheBlockAndStaysInFrame() throws {
    let top = try #require(TextOverlay.textBounds(for: resolved(posY: 0.2), aspect: .r9x16))
    #expect(abs(top.midY - 384) <= 1)
    let edge = try #require(TextOverlay.textBounds(for: resolved(posX: 0.0, posY: 1.0), aspect: .r9x16))
    #expect(edge.minX == 0 && edge.maxY == 1920)
  }

  @Test func longTextWrapsWithinMaxWidth() throws {
    let v = resolved("A Collision of Two Worlds and Then Some More Words Here", size: 80)
    let b = try #require(TextOverlay.textBounds(for: v, aspect: .r9x16))
    #expect(b.width <= 1080 * TextOverlay.maxBlockWidthFraction + 1)
    let one = try #require(TextOverlay.textBounds(for: resolved("Short", size: 80), aspect: .r9x16))
    #expect(b.height > one.height * 2)
  }

  @Test func sizeScalesTheBlock() throws {
    let s = try #require(TextOverlay.textBounds(for: resolved(size: 48), aspect: .r9x16))
    let l = try #require(TextOverlay.textBounds(for: resolved(size: 96), aspect: .r9x16))
    #expect(l.height > s.height * 1.8 && l.width > s.width * 1.8)
  }

  @Test func outlineAndShadowAreWhiteText() throws {
    for style in [TextStyle.outline, .shadow] {
      let v = resolved("HHHH", style: style, size: 120)
      let px = Pixels(try #require(TextOverlay.image(for: v, aspect: .r9x16)))
      let b = try #require(TextOverlay.textBounds(for: v, aspect: .r9x16))
      var white = 0
      for x in Int(b.minX)..<Int(b.maxX) {
        let p = px.at(x, Int(b.midY))
        if p.0 > 250 && p.3 == 255 { white += 1 }
      }
      #expect(white > 20, "style \(style)")
    }
  }

  @Test func alignmentChangesLineOrigins() throws {
    let text = "Mabalabala\nx\nA Collision of Two Worlds"
    let l = Pixels(try #require(TextOverlay.image(for: resolved(text, align: .left), aspect: .r9x16)))
    let r = Pixels(try #require(TextOverlay.image(for: resolved(text, align: .right), aspect: .r9x16)))
    let b = try #require(TextOverlay.textBounds(for: resolved(text, align: .left), aspect: .r9x16))
    // Middle line ("x"): left-aligned box starts at the block's left edge, right-aligned ends at its right edge.
    let y = Int(b.midY)
    #expect(l.at(Int(b.minX) + 6, y).3 == 255 && l.at(Int(b.maxX) - 6, y).3 == 0)
    #expect(r.at(Int(b.maxX) - 6, y).3 == 255 && r.at(Int(b.minX) + 6, y).3 == 0)
  }

  /// Writes sample overlays composited on design frames for eyeballing (DJQ_SAMPLES=<dir>).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJQ_SAMPLES"] != nil))
  func writeSamples() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJQ_SAMPLES"]!)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cases: [(String, ResolvedVersion)] = [
      ("box-one", resolved()),
      ("box-three", resolved("Mabalabala\nx\nA Collision of Two Worlds")),
      ("box-three-left", resolved("Song One\nx\nSong Two 🔥", align: .left)),
      ("box-wrap", resolved("Evil Jingle x Mnike x Escaladizzy x Something Longer 🔥")),
      ("outline", resolved(style: .outline)),
      ("shadow", resolved(style: .shadow)),
      ("box-small-top", resolved(size: 48, posY: 0.2)),
    ]
    for (name, v) in cases {
      try TextOverlay.write(for: v, aspect: .r9x16, to: dir.appendingPathComponent("\(name).png"))
    }
  }
}
