// TEMPORARY stand-ins for the RENDER agent's `TextOverlay` and `Media` (Sources/DJQCore/Render/).
// Signatures match ARCHITECTURE.md exactly. The parent deletes this file at merge; nothing else in
// the editor depends on these implementations, only on the public names.
import AppKit
import AVFoundation
import DJQCore
import Foundation

public struct ProbeInfo: Sendable, Hashable, Codable {
  public var duration: Double
  public var width: Int
  public var height: Int
  public var fps: Double
  public var hasAudio: Bool
  public var size: Int64
  public var videoCodec: String
  public var audioCodec: String?
}

public enum TextOverlay {
  static func layout(for v: ResolvedVersion, aspect: Aspect) -> (attr: NSAttributedString, text: CGRect, box: CGRect, size: CGSize)? {
    guard v.hasText else { return nil }
    let (W, H) = aspect.outputSize
    let size = CGFloat(v.size)
    let para = NSMutableParagraphStyle()
    para.alignment = v.align == .left ? .left : v.align == .right ? .right : .center
    para.lineHeightMultiple = 0.95
    let weight: NSFont.Weight = v.style == .shadow ? .bold : .heavy
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: para,
      .foregroundColor: v.style == .box ? NSColor.black : NSColor.white,
    ]
    let maxW = CGFloat(W) * 0.815
    let s = NSAttributedString(string: v.text, attributes: attrs)
    let b = s.boundingRect(with: NSSize(width: maxW, height: 4000), options: [.usesLineFragmentOrigin])
    let tw = ceil(b.width), th = ceil(b.height)
    let cx = CGFloat(v.posX) * CGFloat(W), cy = CGFloat(v.posY) * CGFloat(H)  // top-left origin
    let text = CGRect(x: cx - tw / 2, y: cy - th / 2, width: tw, height: th)
    let pad = v.style == .box ? size * 0.35 : size * 0.15
    let box = text.insetBy(dx: -pad, dy: v.style == .box ? -pad * 0.6 : -pad)
    return (s, text, box, CGSize(width: W, height: H))
  }

  public static func image(for v: ResolvedVersion, aspect: Aspect) -> CGImage? {
    guard let l = layout(for: v, aspect: aspect) else { return nil }
    let W = Int(l.size.width), H = Int(l.size.height)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.translateBy(x: 0, y: CGFloat(H))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let size = CGFloat(v.size)
    let drawRect = l.text.insetBy(dx: -2, dy: 0)
    switch v.style {
    case .box:
      NSColor.white.setFill()
      NSBezierPath(roundedRect: l.box, xRadius: size * 0.28, yRadius: size * 0.28).fill()
      l.attr.draw(with: drawRect, options: [.usesLineFragmentOrigin])
    case .outline:
      let m = NSMutableAttributedString(attributedString: l.attr)
      m.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 14.0 * 100 / size], range: NSRange(location: 0, length: m.length))
      m.draw(with: drawRect, options: [.usesLineFragmentOrigin])
      l.attr.draw(with: drawRect, options: [.usesLineFragmentOrigin])
    case .shadow:
      let m = NSMutableAttributedString(attributedString: l.attr)
      let sh = NSShadow()
      sh.shadowColor = NSColor.black.withAlphaComponent(0.75)
      sh.shadowBlurRadius = 18
      sh.shadowOffset = NSSize(width: 0, height: 4)
      m.addAttribute(.shadow, value: sh, range: NSRange(location: 0, length: m.length))
      m.draw(with: drawRect, options: [.usesLineFragmentOrigin])
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
  }

  public static func png(for v: ResolvedVersion, aspect: Aspect) -> Data? {
    guard let img = image(for: v, aspect: aspect) else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
  }

  @discardableResult public static func write(for v: ResolvedVersion, aspect: Aspect, to url: URL) throws -> Bool {
    guard let d = png(for: v, aspect: aspect) else { return false }
    try d.write(to: url)
    return true
  }

  public static func textBounds(for v: ResolvedVersion, aspect: Aspect) -> CGRect? {
    layout(for: v, aspect: aspect)?.box
  }
}

public enum Media {
  public static func probe(_ url: URL) throws -> ProbeInfo {
    let asset = AVURLAsset(url: url)
    let v = asset.tracks(withMediaType: .video).first
    let size = v.map { $0.naturalSize.applying($0.preferredTransform) } ?? .zero
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    return ProbeInfo(duration: asset.duration.seconds, width: Int(abs(size.width)), height: Int(abs(size.height)),
                     fps: Double(v?.nominalFrameRate ?? 0), hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
                     size: bytes, videoCodec: "hevc", audioCodec: nil)
  }

  public static func thumbnail(store: Store, video: Video, at seconds: Double? = nil, maxHeight: Int = 320) -> URL? {
    guard let url = try? store.fileURL(for: video) else { return nil }
    let out = store.paths.thumbs.appendingPathComponent("\(video.id)-\(Int((seconds ?? 0) * 1000))-\(maxHeight).jpg")
    if FileManager.default.fileExists(atPath: out.path) { return out }
    guard let img = frame(url, at: seconds ?? 0, maxSize: CGSize(width: maxHeight * 2, height: maxHeight)),
          let d = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [:]) else { return nil }
    try? d.write(to: out)
    return out
  }

  public static func frame(_ url: URL, at seconds: Double, maxSize: CGSize) -> CGImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = maxSize
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    return try? gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
  }
}
