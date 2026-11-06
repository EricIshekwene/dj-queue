import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Overlay text renderer — the single source of truth for on-video text (spec §6
/// "Preview must equal the final export"). The editor shows `image(for:aspect:)` over the
/// player, and the export composites the very same pixels (`write(for:aspect:to:)` → PNG
/// → ffmpeg `overlay`). Never ffmpeg `drawtext`.
///
/// Geometry (all in output pixels, 1080 wide):
/// - `size` is the font size in points at 1080-wide output.
/// - `posX`/`posY` are the normalised centre of the text block; the block is kept inside the frame.
/// - Lines wrap so the block (including the box padding) is at most 82 % of the frame width.
/// - `.box`: white rounded box behind each line, boxes stacked so they touch and merge (TikTok style).
/// - `.outline`: white heavy text, black outline outside the glyphs (emoji are not outlined).
/// - `.shadow`: white bold text with a soft shadow.
///
/// Round 16: a clip can have several texts. Each `TextLayer` is drawn on its own, and a `TextLook` changes the colours,
/// font, spacing and opacity through this same path; with no look the pixels are exactly the ones above. The
/// `ResolvedVersion` variants mean the first text.
public enum TextOverlay {
  /// Width of the text block relative to the frame width.
  public static let maxBlockWidthFraction: CGFloat = 0.82

  // MARK: Public API

  /// Transparent RGBA image at `aspect.outputSize`, or nil when the version has no text.
  public static func image(for v: ResolvedVersion, aspect: Aspect) -> CGImage? {
    guard v.hasText else { return nil }
    return image(for: v.firstLayer, aspect: aspect)
  }

  /// One text on a transparent RGBA image at `aspect.outputSize`, or nil when it is blank.
  public static func image(for layer: TextLayer, aspect: Aspect) -> CGImage? {
    Layout(layer, aspect: aspect)?.draw()
  }

  /// `layers` stacked in order on one image; nil when none draws anything. One layer is exactly `image(for:aspect:)`.
  public static func image(for layers: [TextLayer], aspect: Aspect) -> CGImage? {
    let images = layers.compactMap { image(for: $0, aspect: aspect) }
    guard images.count > 1 else { return images.first }
    let (w, h) = aspect.outputSize
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    for img in images { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    return ctx.makeImage()
  }

  /// `image(for: layer, aspect:)` scaled to at most `maxWidth` wide, for list previews.
  public static func image(for layer: TextLayer, aspect: Aspect, maxWidth: Int) -> CGImage? {
    image(for: layer, aspect: aspect).flatMap { scaled($0, maxWidth: maxWidth) }
  }

  /// `image(for:aspect:)` scaled down to at most `maxWidth` pixels wide (aspect kept, high-quality interpolation) —
  /// the same pixels, smaller, for list previews (S6). Nil when the version has no text.
  public static func image(for v: ResolvedVersion, aspect: Aspect, maxWidth: Int) -> CGImage? {
    guard let full = image(for: v, aspect: aspect) else { return nil }
    return scaled(full, maxWidth: maxWidth)
  }

  /// `img` scaled to at most `maxWidth` wide (returned as is when already that small).
  public static func scaled(_ img: CGImage, maxWidth: Int) -> CGImage? {
    guard maxWidth > 0, img.width > maxWidth else { return img }
    let w = maxWidth, h = max(1, Int((Double(img.height) * Double(maxWidth) / Double(img.width)).rounded()))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }

  /// PNG bytes of `image(for:aspect:)` (deterministic: same input → identical bytes).
  public static func png(for v: ResolvedVersion, aspect: Aspect) -> Data? {
    guard let img = image(for: v, aspect: aspect) else { return nil }
    return pngData(img)
  }

  /// PNG bytes of one text.
  public static func png(for layer: TextLayer, aspect: Aspect) -> Data? {
    image(for: layer, aspect: aspect).flatMap(pngData)
  }

  /// Writes the PNG to `url`. Returns false (and writes nothing) when the version has no text.
  @discardableResult
  public static func write(for v: ResolvedVersion, aspect: Aspect, to url: URL) throws -> Bool {
    try write(png(for: v, aspect: aspect), to: url)
  }

  /// Writes one text's PNG to `url`. Returns false (and writes nothing) when it is blank.
  @discardableResult
  public static func write(for layer: TextLayer, aspect: Aspect, to url: URL) throws -> Bool {
    try write(png(for: layer, aspect: aspect), to: url)
  }

  private static func write(_ data: Data?, to url: URL) throws -> Bool {
    guard let data else { return false }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return true
  }

  /// The text block (box union / outlined text) in output pixels with a top-left origin,
  /// for hit-testing drags in the editor. Nil when the version has no text.
  public static func textBounds(for v: ResolvedVersion, aspect: Aspect) -> CGRect? {
    v.hasText ? textBounds(for: v.firstLayer, aspect: aspect) : nil
  }

  /// One text's block in output pixels with a top-left origin, for hit-testing. Nil when it is blank.
  public static func textBounds(for layer: TextLayer, aspect: Aspect) -> CGRect? {
    Layout(layer, aspect: aspect)?.blockTL
  }

  /// The font a layer draws with: the look's font, the system font when it has none or this Mac doesn't have it.
  static func font(_ f: TextFont?, size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    switch f {
    case nil, .standard: return system as CTFont
    case .rounded: return designed(system, .rounded, size) as CTFont
    case .serif: return designed(system, .serif, size) as CTFont
    case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
    case let named?: return (font(named: named.postScriptName, size: size) ?? system) as CTFont
    }
  }

  /// nil when this Mac doesn't have the face.
  static func font(named name: String?, size: CGFloat) -> NSFont? { name.flatMap { NSFont(name: $0, size: size) } }

  private static func designed(_ f: NSFont, _ design: NSFontDescriptor.SystemDesign, _ size: CGFloat) -> NSFont {
    f.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? f
  }

  private static func cgColor(_ hex: String?, alpha: CGFloat = 1) -> CGColor? {
    TextLook.rgb(hex).map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: alpha) }
  }

  /// PNG encoding without metadata (ImageIO writes no timestamps for PNG).
  public static func pngData(_ img: CGImage) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }

  // MARK: Layout

  struct Line {
    var ctLine: CTLine?  // nil = empty line (blank paragraph)
    var width: CGFloat  // typographic width without trailing whitespace
  }

  struct Layout {
    let W: CGFloat, H: CGFloat
    let style: TextStyle
    let align: TextAlign
    let size: CGFloat
    let lines: [Line]
    let font: CTFont
    // Vertical metrics of one line slot (top-left coordinates relative to the slot top).
    let pitch: CGFloat  // distance between consecutive line tops
    let baselineInSlot: CGFloat
    let padX: CGFloat  // box horizontal padding
    let radius: CGFloat
    let outlineWidth: CGFloat
    let blockTL: CGRect  // block rect, top-left origin
    let contentWidth: CGFloat  // widest line box (block width)
    let look: TextLook?  // normalised; nil = the plain style

    init?(_ v: TextLayer, aspect: Aspect) {
      guard !v.isBlank else { return nil }
      let (w, h) = aspect.outputSize
      W = CGFloat(w); H = CGFloat(h)
      style = v.style
      align = v.align
      size = CGFloat(min(max(v.size, 8), 400))
      look = v.look?.normalized
      let weight: NSFont.Weight = style == .shadow ? .bold : .heavy
      font = TextOverlay.font(look?.font, size: size, weight: weight)

      let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), cap = CTFontGetCapHeight(font)
      switch style {
      case .box:
        // Box hugs cap height + descenders with even visual padding; slots touch.
        let padV = size * 0.22
        padX = size * 0.34
        baselineInSlot = padV + cap
        pitch = padV + cap + descent + padV * 0.55
        radius = size * 0.26
        outlineWidth = 0
      case .outline:
        padX = 0
        outlineWidth = max(2, (size * 0.09).rounded())
        baselineInSlot = ascent
        pitch = (ascent + descent) * 0.98
        radius = 0
      case .shadow:
        padX = 0
        outlineWidth = 0
        baselineInSlot = ascent
        pitch = (ascent + descent) * 0.98
        radius = 0
      }

      // Wrap.
      let maxBlock = W * TextOverlay.maxBlockWidthFraction
      let maxText = max(size, maxBlock - 2 * padX - 2 * outlineWidth)
      // Glyph colour comes from the context fill colour (emoji keep their own colours).
      var attrs: [NSAttributedString.Key: Any] = [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
      ]
      var kern: CGFloat = 0
      if let t = look?.tracking {
        kern = CGFloat(t) * size
        attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern
      }
      var out: [Line] = []
      let paragraphs = v.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
      // Drop leading/trailing blank lines; keep inner blank lines as gaps.
      var paras = paragraphs.map { $0.trimmingCharacters(in: .whitespaces) }
      while paras.first?.isEmpty == true { paras.removeFirst() }
      while paras.last?.isEmpty == true { paras.removeLast() }
      for p in paras {
        if p.isEmpty { out.append(Line(ctLine: nil, width: 0)); continue }
        let a = NSAttributedString(string: p, attributes: attrs) as CFAttributedString
        let ts = CTTypesetterCreateWithAttributedString(a)
        let len = CFAttributedStringGetLength(a)
        var start = 0
        while start < len {
          var count = CTTypesetterSuggestLineBreak(ts, start, Double(maxText))
          if count <= 0 { count = max(1, CTTypesetterSuggestClusterBreak(ts, start, Double(maxText))) }
          let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
          let full = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
          let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
          // The last letter's spacing is empty air: left in, it would push the text off centre.
          out.append(Line(ctLine: line, width: max(0, full - trailing - kern).rounded(.up)))
          start += count
        }
      }
      lines = out
      guard lines.contains(where: { $0.ctLine != nil }) else { return nil }

      let widest = lines.map(\.width).max() ?? 0
      contentWidth = widest + 2 * padX + 2 * outlineWidth
      let blockH = pitch * CGFloat(lines.count) + 2 * outlineWidth
      // Centre at (posX, posY), kept inside the frame; snapped to whole pixels for stable output.
      var x = (CGFloat(v.posX) * W - contentWidth / 2).rounded()
      var y = (CGFloat(v.posY) * H - blockH / 2).rounded()
      x = contentWidth >= W ? ((W - contentWidth) / 2).rounded() : min(max(0, x), W - contentWidth)
      y = blockH >= H ? ((H - blockH) / 2).rounded() : min(max(0, y), H - blockH)
      blockTL = CGRect(x: x, y: y, width: contentWidth, height: blockH)
    }

    /// Horizontal extent [left, right] of line `i`'s box (top-left coords).
    func lineBox(_ i: Int) -> (CGFloat, CGFloat) {
      let w = lines[i].width + 2 * padX + 2 * outlineWidth
      switch align {
      case .left: return (blockTL.minX, blockTL.minX + w)
      case .right: return (blockTL.maxX - w, blockTL.maxX)
      case .center:
        let l = (blockTL.midX - w / 2).rounded()
        return (l, l + w)
      }
    }

    func lineTop(_ i: Int) -> CGFloat { blockTL.minY + outlineWidth + pitch * CGFloat(i) }

    func draw() -> CGImage? {
      let w = Int(W), h = Int(H)
      guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
      ctx.setAllowsAntialiasing(true)
      ctx.setShouldAntialias(true)
      ctx.setAllowsFontSmoothing(false)
      ctx.setShouldSmoothFonts(false)
      ctx.textMatrix = .identity
      ctx.interpolationQuality = .high

      let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
      let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
      let textColor = TextOverlay.cgColor(look?.color)
      let accent = TextOverlay.cgColor(look?.accent)
      // Top-left → Core Graphics (bottom-left) transform.
      let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)

      // Opacity fades the text as one piece, so a box or outline doesn't show through the glyphs on top of it.
      if let o = look?.opacity {
        ctx.setAlpha(CGFloat(o))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      }

      switch style {
      case .box:
        let path = CGMutablePath()
        for group in boxGroups() { path.addPath(roundedPolygon(group, r: radius), transform: flip) }
        ctx.setFillColor(accent ?? white)
        ctx.addPath(path)
        ctx.fillPath()
        drawText(ctx, color: textColor ?? black)
      case .outline:
        let glyphs = glyphOutlines()
        ctx.saveGState()
        ctx.setStrokeColor(accent ?? black)
        ctx.setLineWidth(outlineWidth * 2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(glyphs)
        ctx.strokePath()
        ctx.addPath(glyphs)  // also fill the inside black so thin counters never show video through AA seams
        ctx.setFillColor(accent ?? black)
        ctx.fillPath()
        ctx.restoreGState()
        drawText(ctx, color: textColor ?? white)
      case .shadow:
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -(size * 0.06).rounded()), blur: (size * 0.28).rounded(),
                      color: TextOverlay.cgColor(look?.accent, alpha: 0.75) ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        drawText(ctx, color: textColor ?? white)
        ctx.restoreGState()
      }
      if look?.opacity != nil { ctx.endTransparencyLayer() }
      return ctx.makeImage()
    }

    /// Text drawn line by line in `color`. Color glyphs (emoji) keep their own colours.
    func drawText(_ ctx: CGContext, color: CGColor) {
      ctx.setFillColor(color)
      for (i, l) in lines.enumerated() {
        guard let ct = l.ctLine else { continue }
        let (left, _) = lineBox(i)
        let baselineTL = lineTop(i) + baselineInSlot
        ctx.textPosition = CGPoint(x: left + padX + outlineWidth, y: H - baselineTL)
        CTLineDraw(ct, ctx)
      }
    }

    /// Union outline of all non-emoji glyphs, in CG (bottom-left) coordinates.
    func glyphOutlines() -> CGPath {
      let path = CGMutablePath()
      for (i, l) in lines.enumerated() {
        guard let ct = l.ctLine else { continue }
        let (left, _) = lineBox(i)
        let origin = CGPoint(x: left + padX + outlineWidth, y: H - (lineTop(i) + baselineInSlot))
        for run in CTLineGetGlyphRuns(ct) as! [CTRun] {
          let attrs = CTRunGetAttributes(run) as NSDictionary
          let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
          if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { continue }
          let n = CTRunGetGlyphCount(run)
          var glyphs = [CGGlyph](repeating: 0, count: n)
          var pos = [CGPoint](repeating: .zero, count: n)
          CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
          CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
          for k in 0..<n {
            guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[k], nil) else { continue }
            path.addPath(gp, transform: CGAffineTransform(translationX: origin.x + pos[k].x, y: origin.y + pos[k].y))
          }
        }
      }
      return path
    }

    /// Per-line boxes grouped into runs of consecutive non-empty lines. Each group is a list of
    /// (left, right, top, bottom) with small edge steps snapped so the merged outline stays clean.
    func boxGroups() -> [[(CGFloat, CGFloat, CGFloat, CGFloat)]] {
      var groups: [[(CGFloat, CGFloat, CGFloat, CGFloat)]] = []
      var cur: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
      for i in lines.indices {
        if lines[i].ctLine == nil {
          if !cur.isEmpty { groups.append(cur); cur = [] }
          continue
        }
        let (l, r) = lineBox(i)
        cur.append((l, r, lineTop(i), lineTop(i) + pitch))
      }
      if !cur.isEmpty { groups.append(cur) }
      // Snap edges whose step is smaller than the corner radius (avoids tiny notches).
      let snap = radius * 1.2
      return groups.map { g in
        var g = g
        var changed = true
        while changed {
          changed = false
          for k in 0..<(max(0, g.count - 1)) {
            if g[k].0 != g[k + 1].0, abs(g[k].0 - g[k + 1].0) < snap {
              let m = min(g[k].0, g[k + 1].0); g[k].0 = m; g[k + 1].0 = m; changed = true
            }
            if g[k].1 != g[k + 1].1, abs(g[k].1 - g[k + 1].1) < snap {
              let m = max(g[k].1, g[k + 1].1); g[k].1 = m; g[k + 1].1 = m; changed = true
            }
          }
        }
        return g
      }
    }

    /// Outline of stacked rectangles with every corner (convex or concave) rounded, top-left coords.
    func roundedPolygon(_ g: [(CGFloat, CGFloat, CGFloat, CGFloat)], r: CGFloat) -> CGPath {
      var pts: [CGPoint] = []
      for b in g { pts.append(CGPoint(x: b.1, y: b.2)); pts.append(CGPoint(x: b.1, y: b.3)) }
      for b in g.reversed() { pts.append(CGPoint(x: b.0, y: b.3)); pts.append(CGPoint(x: b.0, y: b.2)) }
      // Remove duplicates and collinear points.
      var clean: [CGPoint] = []
      for p in pts where clean.last != p { clean.append(p) }
      if clean.first == clean.last, clean.count > 1 { clean.removeLast() }
      var changed = true
      while changed, clean.count > 4 {
        changed = false
        for i in clean.indices {
          let a = clean[(i + clean.count - 1) % clean.count], b = clean[i], c = clean[(i + 1) % clean.count]
          if (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) || a == b {
            clean.remove(at: i); changed = true; break
          }
        }
      }
      let n = clean.count
      let path = CGMutablePath()
      guard n >= 3 else { return path }
      func len(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
      let start = CGPoint(x: (clean[0].x + clean[1].x) / 2, y: (clean[0].y + clean[1].y) / 2)
      path.move(to: start)
      for k in 1...n {
        let p = clean[k % n], prev = clean[k - 1], next = clean[(k + 1) % n]
        let rr = min(r, len(prev, p) / 2, len(p, next) / 2)
        path.addArc(tangent1End: p, tangent2End: next, radius: rr)
      }
      path.closeSubpath()
      return path
    }
  }
}
