// Design prototype of the overlay-text renderer (spec §6): draws text with AppKit/Core Text
// (SF Pro + Apple Color Emoji fallback) into a transparent 1080×1920 PNG.
// Usage: swift textpng.swift <style: outline|box|shadow> <text> <centerY 0..1> <size pt> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 6 else { print("usage: style text centerY size out.png"); exit(1) }
let style = args[1], text = args[2], centerY = CGFloat(Double(args[3])!), size = CGFloat(Double(args[4])!)
let out = URL(fileURLWithPath: args[5])
let W = 1080, H = 1920, maxTextWidth: CGFloat = 880

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let para = NSMutableParagraphStyle()
para.alignment = .center
para.lineHeightMultiple = 0.95
let weight: NSFont.Weight = style == "shadow" ? .bold : .heavy
var attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: size, weight: weight),
  .paragraphStyle: para,
  .foregroundColor: style == "box" ? NSColor.black : NSColor.white,
]
let bounds = (text as NSString).boundingRect(with: NSSize(width: maxTextWidth, height: 2000),
                                             options: [.usesLineFragmentOrigin], attributes: attrs)
let rect = NSRect(x: (CGFloat(W) - maxTextWidth) / 2,
                  y: CGFloat(H) * (1 - centerY) - bounds.height / 2,
                  width: maxTextWidth, height: bounds.height)

switch style {
case "box":
  let pad: CGFloat = size * 0.35
  let boxW = bounds.width + pad * 2
  let box = NSRect(x: (CGFloat(W) - boxW) / 2, y: rect.minY - pad * 0.6, width: boxW, height: bounds.height + pad * 1.2)
  NSColor.white.setFill()
  NSBezierPath(roundedRect: box, xRadius: size * 0.28, yRadius: size * 0.28).fill()
  (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
case "outline":
  // Stroke pass then fill pass, so the outline sits outside the glyphs.
  var strokeAttrs = attrs
  strokeAttrs[.strokeColor] = NSColor.black
  strokeAttrs[.strokeWidth] = 14.0 * 100 / size  // percent of font size → ~14 px
  (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: strokeAttrs)
  (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
default:
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
  shadow.shadowBlurRadius = 18
  shadow.shadowOffset = NSSize(width: 0, height: -4)
  attrs[.shadow] = shadow
  (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
