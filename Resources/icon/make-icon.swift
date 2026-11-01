// Renders the DJ Queue app icon with Core Graphics into an .iconset folder.
// Usage: swift Resources/icon/make-icon.swift <out.iconset>   then   iconutil -c icns <out.iconset>
// Design: indigo→violet squircle, three fanned 9:16 cards (the queue), a play mark on the front card.
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: s / 1024, y: s / 1024)
  // macOS icon grid: 824 pt artwork centred on a 1024 canvas.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
  ctx.addPath(tilePath)
  ctx.setFillColor(CGColor(red: 0.16, green: 0.13, blue: 0.42, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(tilePath)
  ctx.clip()
  let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.42, green: 0.22, blue: 0.95, alpha: 1),
    CGColor(red: 0.16, green: 0.12, blue: 0.45, alpha: 1),
  ] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
  // Three fanned 9:16 cards.
  let cw: CGFloat = 270, ch: CGFloat = 480
  let centre = CGPoint(x: 512, y: 500)
  for (i, angle) in [(-14.0), (0.0), (14.0)].enumerated() {
    ctx.saveGState()
    ctx.translateBy(x: centre.x + CGFloat(i - 1) * 120, y: centre.y + (i == 1 ? 20 : 0))
    ctx.rotate(by: CGFloat(-angle) * .pi / 180)
    let r = CGRect(x: -cw / 2, y: -ch / 2, width: cw, height: ch)
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: i == 1 ? 1 : 0.55))
    ctx.fillPath()
    ctx.restoreGState()
  }
  // Play mark on the front card.
  ctx.saveGState()
  ctx.translateBy(x: 512, y: 520)
  let tri = CGMutablePath()
  tri.move(to: CGPoint(x: -46, y: 70))
  tri.addLine(to: CGPoint(x: 78, y: 0))
  tri.addLine(to: CGPoint(x: -46, y: -70))
  tri.closeSubpath()
  ctx.addPath(tri)
  ctx.setFillColor(CGColor(red: 0.36, green: 0.2, blue: 0.9, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()
  // Queue lines under the play mark.
  ctx.setFillColor(CGColor(red: 0.36, green: 0.2, blue: 0.9, alpha: 0.35))
  for (k, w) in [(0, 150.0), (1, 110.0)] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 512 - w / 2, y: 380 - CGFloat(k) * 44, width: w, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()
  }
  ctx.restoreGState()
  let img = ctx.makeImage()!
  return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset: \(out.path)")
