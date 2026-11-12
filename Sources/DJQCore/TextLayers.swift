import Foundation

// Round 16: timed text overlays and the per-text look. The first text stays in the existing `Version` fields (so
// Title-follow and `{text}` keep working); every further text is a `TextLayer` in `Version.moreText`. Nothing here
// draws: `TextOverlay` draws a layer, `PreviewKeys.layerWindows` says when it shows.

/// The curated fonts for on-video text: system designs and fonts that ship with macOS. A font that is missing on this
/// Mac falls back to the system font (`TextOverlay.font`), and a raw value this build doesn't know decodes to nil.
public enum TextFont: String, Codable, Sendable, CaseIterable, Identifiable {
  case standard = "default", rounded, serif, mono
  case impact, futura, avenirNext = "avenir-next", helveticaNeue = "helvetica-neue", arialBlack = "arial-black"
  case georgia, didot, markerFelt = "marker-felt", americanTypewriter = "american-typewriter"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .standard: "Default"
    case .rounded: "Rounded"
    case .serif: "Serif"
    case .mono: "Mono"
    case .impact: "Impact"
    case .futura: "Futura"
    case .avenirNext: "Avenir Next"
    case .helveticaNeue: "Helvetica Neue"
    case .arialBlack: "Arial Black"
    case .georgia: "Georgia"
    case .didot: "Didot"
    case .markerFelt: "Marker Felt"
    case .americanTypewriter: "American Typewriter"
    }
  }

  /// The installed face to load; nil for the system designs.
  public var postScriptName: String? {
    switch self {
    case .standard, .rounded, .serif, .mono: nil
    case .impact: "Impact"
    case .futura: "Futura-Bold"
    case .avenirNext: "AvenirNext-Heavy"
    case .helveticaNeue: "HelveticaNeue-Bold"
    case .arialBlack: "Arial-Black"
    case .georgia: "Georgia-Bold"
    case .didot: "Didot-Bold"
    case .markerFelt: "MarkerFelt-Wide"
    case .americanTypewriter: "AmericanTypewriter-Bold"
    }
  }
}

/// How one text looks beyond its style. Every field nil = today's look. Encoding omits nils, so a default look adds
/// nothing to stored JSON or to the edit hash.
public struct TextLook: Codable, Sendable, Hashable {
  /// Glyph colour, "#RRGGBB".
  public var color: String?
  /// "#RRGGBB": the box fill, the outline colour or the shadow colour, by style.
  public var accent: String?
  public var font: TextFont?
  /// The whole text together (box, outline, glyphs, emoji), `opacityRange`.
  public var opacity: Double?
  /// Letter spacing as a share of the font size, `trackingRange`.
  public var tracking: Double?

  public static let opacityRange = 0.1...1.0
  public static let trackingRange = -0.1...0.5
  /// The preset swatches (S2-R2).
  public static let swatches = ["#FFFFFF", "#000000", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#007AFF", "#AF52DE", "#FF2D92"]

  public init(color: String? = nil, accent: String? = nil, font: TextFont? = nil, opacity: Double? = nil, tracking: Double? = nil) {
    self.color = color; self.accent = accent; self.font = font; self.opacity = opacity; self.tracking = tracking
  }

  enum CodingKeys: String, CodingKey { case color, accent, font, opacity, tracking }

  /// Tolerant: a value this build can't read means "default", never an unreadable version.
  public init(from dec: Decoder) throws {
    let c = try dec.container(keyedBy: CodingKeys.self)
    color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil
    accent = (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? nil
    font = (try? c.decodeIfPresent(TextFont.self, forKey: .font)) ?? nil
    opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? nil
    tracking = (try? c.decodeIfPresent(Double.self, forKey: .tracking)) ?? nil
  }

  /// The canonical form of this look (valid colours, values in range, no-ops dropped), or nil when it changes nothing.
  /// Everything downstream (drawing, keys, the edit hash) reads this, so "#fff", "#FFFFFF" and 100 % opacity can't
  /// cause a re-render.
  public var normalized: TextLook? {
    var l = TextLook(color: Self.hex(color), accent: Self.hex(accent))
    l.font = font == .standard ? nil : font
    if let o = opacity {
      let c = min(max(o, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
      l.opacity = c >= 1 ? nil : c
    }
    if let t = tracking {
      let c = min(max(t, Self.trackingRange.lowerBound), Self.trackingRange.upperBound)
      l.tracking = c == 0 ? nil : c
    }
    return l == TextLook() ? nil : l
  }

  public var isDefault: Bool { normalized == nil }

  /// "#RRGGBB" (uppercase) from "#rgb", "rgb", "#rrggbb" or "rrggbb"; nil when it isn't a colour.
  public static func hex(_ s: String?) -> String? {
    guard var h = s?.trimmingCharacters(in: .whitespaces) else { return nil }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else { return nil }
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    return h.count == 6 ? "#" + h.uppercased() : nil
  }

  /// sRGB components 0…1 of a colour `hex` accepts.
  public static func rgb(_ s: String?) -> (r: Double, g: Double, b: Double)? {
    guard let h = hex(s), let n = Int(h.dropFirst(), radix: 16) else { return nil }
    return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
  }

  /// What the glyphs are drawn in with no custom colour.
  public static func defaultColor(_ style: TextStyle) -> String { style == .box ? "#000000" : "#FFFFFF" }
  /// What the box, outline or shadow is drawn in with no custom colour (the shadow keeps its 75 % strength either way).
  public static func defaultAccent(_ style: TextStyle) -> String { style == .box ? "#FFFFFF" : "#000000" }
}

/// One text on the video. The first text is presented as a layer too (`ResolvedVersion.firstLayer`, id `firstId`).
public struct TextLayer: Codable, Sendable, Hashable, Identifiable {
  /// The id of the first text, which lives in the `Version` fields rather than in `moreText`.
  public static let firstId = "first"

  /// Stable across edits, so a selection survives reorders and undo.
  public var id: String
  public var text: String
  public var style: TextStyle
  public var size: Double  // points at 1080-wide output
  public var posX: Double  // normalised centre in output frame
  public var posY: Double
  public var align: TextAlign
  /// Seconds from the trim start. nil = from the start of the trim / to its end.
  public var start: Double?
  public var end: Double?
  public var look: TextLook?
  /// Round 26: a countdown text shows `countdown`, …, 2, 1 in equal steps across its window (one second each when its
  /// window is `countdown` seconds long), in one slot. "{n}" in its text is where the number goes; with no "{n}" the
  /// number shows alone. nil for every other text (and absent from stored JSON). Never on the first text.
  public var countdown: Int?

  /// How far a countdown can count from.
  public static let countdownRange = 2...10
  /// Where the number goes in a countdown's text.
  public static let countdownToken = "{n}"

  public init(id: String = TextLayer.newId(), text: String, style: TextStyle = .box, size: Double = 64, posX: Double = 0.5,
              posY: Double = 0.5, align: TextAlign = .center, start: Double? = nil, end: Double? = nil, look: TextLook? = nil,
              countdown: Int? = nil) {
    self.id = id; self.text = text; self.style = style; self.size = size; self.posX = posX; self.posY = posY
    self.align = align; self.start = start; self.end = end; self.look = look; self.countdown = countdown
  }

  enum CodingKeys: String, CodingKey { case id, text, style, size, posX, posY, align, start, end, look, countdown }

  /// Tolerant: a layer with a value this build can't read keeps the rest, so one field never loses the version.
  public init(from dec: Decoder) throws {
    let c = try dec.container(keyedBy: CodingKeys.self)
    id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? Self.newId()
    text = ((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? ""
    style = ((try? c.decodeIfPresent(TextStyle.self, forKey: .style)) ?? nil) ?? .box
    size = ((try? c.decodeIfPresent(Double.self, forKey: .size)) ?? nil) ?? 64
    posX = ((try? c.decodeIfPresent(Double.self, forKey: .posX)) ?? nil) ?? 0.5
    posY = ((try? c.decodeIfPresent(Double.self, forKey: .posY)) ?? nil) ?? 0.5
    align = ((try? c.decodeIfPresent(TextAlign.self, forKey: .align)) ?? nil) ?? .center
    start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? nil
    end = (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? nil
    look = (try? c.decodeIfPresent(TextLook.self, forKey: .look)) ?? nil
    countdown = ((try? c.decodeIfPresent(Int.self, forKey: .countdown)) ?? nil).map {
      min(max($0, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
    }
  }

  public static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

  /// Nothing to draw (empty texts stay stored but never show). A countdown always has its number to draw.
  public var isBlank: Bool { countdown == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// What a countdown shows at `number`: its text with "{n}" replaced, else the number alone.
  public func countdownText(_ number: Int) -> String {
    text.contains(Self.countdownToken) ? text.replacingOccurrences(of: Self.countdownToken, with: "\(number)") : "\(number)"
  }

  /// A countdown as the plain texts it draws, one per number, each with its step of `window` (seconds from the trim
  /// start, `PreviewKeys.layerWindows`' rule): `countdown` equal steps from its high number down to 1. Each step but the
  /// last ends `stepGap` before the next begins, so two numbers never share a frame (the renderer's windows include
  /// both ends) and no frame falls between them (frames are 33 ms apart; `Renderer.overlayGraph` keeps the digits).
  /// Every other text is itself, with `window`.
  public func steps(in window: ClosedRange<Double>, trimDuration d: Double) -> [(layer: TextLayer, window: ClosedRange<Double>)] {
    guard let n = countdown else { return [(self, window)] }
    let a = window.lowerBound, b = max(a, min(window.upperBound, d))
    let len = (b - a) / Double(n)
    guard len > 0 else { return [] }
    // Inner boundaries on the millisecond, so the renderer's three-decimal times are exact and the gap stays `stepGap`.
    func boundary(_ k: Int) -> Double { k == 0 ? a : ((a + Double(k) * len) * 1000).rounded() / 1000 }
    return (0..<n).map { k in
      var l = self
      l.countdown = nil
      l.text = countdownText(n - k)
      let s = boundary(k)
      let e = k == n - 1 ? window.upperBound : max(s, boundary(k + 1) - Self.stepGap)
      return (l, s...e)
    }
  }

  /// How much earlier than the next number a countdown's number ends: far below a frame, so no frame falls between.
  public static let stepGap = 0.00001
}

extension ResolvedVersion {
  /// The first text as a layer. Its look is the version's `textLook`.
  public var firstLayer: TextLayer {
    TextLayer(id: TextLayer.firstId, text: text, style: style, size: size, posX: posX, posY: posY, align: align,
              start: textStart, end: textEnd, look: textLook)
  }

  /// Every text on the clip in order, first text first, including empty ones and whatever "No text" hides: the list the
  /// editor and `djq overlay list` number.
  public var allLayers: [TextLayer] { [firstLayer] + moreText }

  /// What is drawn, first text first (overlaps stack in this order): nothing with "No text", and never an empty text.
  public var layers: [TextLayer] { noText ? [] : allLayers.filter { !$0.isBlank } }

  /// True when anything shows on the video. `hasText` still means the first text, so captions, prompts and titles read
  /// the same; "No text" in Health asks this one, because a clip whose first text is empty can still show its others.
  public var hasDrawnText: Bool { !noText && (hasText || moreText.contains { !$0.isBlank }) }
}

/// Pure edits of a version's texts, shared by the editor and `djq overlay`. Each takes the raw version being edited and
/// its resolved form, and returns the raw version to save. A list change always writes the whole list into that
/// version: `moreText` carries forward as one value (nil inherits, [] = explicitly none).
public enum TextLayers {
  /// Most texts on a clip, the first text included.
  public static let maxCount = 32
  /// An end past any trim, for "to the end of the clip" where nil would inherit one. `PreviewKeys.textWindow` and
  /// `EditorLogic.clampTextTiming` bring it back to the trim.
  public static let farEnd = 86_400.0

  public static func canAdd(_ r: ResolvedVersion) -> Bool { r.allLayers.count < maxCount }

  /// A new text that looks like `like` (its style, size, position, alignment and look), with its own id and window.
  public static func new(text: String, like: TextLayer, start: Double? = nil, end: Double? = nil) -> TextLayer {
    var l = like
    l.id = TextLayer.newId(); l.text = text; l.start = start; l.end = end; l.countdown = nil
    return l
  }

  /// `ref` as `djq overlay` takes it: a layer id, else a number (1 = the first text). Ids come first because an id can be
  /// all digits.
  public static func layer(_ ref: String, in r: ResolvedVersion) -> TextLayer? {
    let all = r.allLayers
    if let l = all.first(where: { $0.id == ref }) { return l }
    return Int(ref).flatMap { all.indices.contains($0 - 1) ? all[$0 - 1] : nil }
  }

  /// `v` with `layer` appended; nil at the cap.
  public static func adding(_ layer: TextLayer, to v: Version, resolved r: ResolvedVersion) -> Version? {
    guard canAdd(r) else { return nil }
    var out = v
    out.moreText = r.moreText + [layer]
    return out
  }

  /// `v` with the text `id` changed. For the first text only what `change` actually changed is written, so everything
  /// else keeps following its default or the earlier version (Title-follow survives). Changing the first text's words
  /// is the same as `djq text`: it turns "No text" off. A window is written whole, because setting one end stops the
  /// other following the default.
  public static func updating(_ id: String, in v: Version, resolved r: ResolvedVersion, _ change: (inout TextLayer) -> Void) -> Version {
    var out = v
    if id == TextLayer.firstId {
      let old = r.firstLayer
      var l = old
      change(&l)
      if l.text != old.text { out.text = l.text; out.noText = false }
      if l.style != old.style { out.style = l.style }
      if l.size != old.size { out.size = l.size }
      if l.posX != old.posX { out.posX = l.posX }
      if l.posY != old.posY { out.posY = l.posY }
      if l.align != old.align { out.align = l.align }
      if l.start != old.start || l.end != old.end { out.textStart = l.start; out.textEnd = l.end }
      if l.look != old.look { out.textLook = l.look ?? TextLook() }
    } else {
      guard let i = r.moreText.firstIndex(where: { $0.id == id }) else { return v }
      var list = r.moreText
      change(&list[i])
      out.moreText = list
    }
    return out
  }

  /// `v` without the text `id`. Removing the first text promotes the next one (`promotingNext`); nil when it's the only
  /// text with words, or `id` isn't there: use "No text" for that.
  public static func removing(_ id: String, from v: Version, resolved r: ResolvedVersion) -> Version? {
    if id == TextLayer.firstId { return promotingNext(v, resolved: r) }
    guard r.moreText.contains(where: { $0.id == id }) else { return nil }
    var out = v
    out.moreText = r.moreText.filter { $0.id != id }
    return out
  }

  /// The first text is gone: the next text with words moves into the first-text fields (S1-R7), look and window
  /// included, and leaves the list. "No text" stays as it was. nil when no other text has words. A countdown is never
  /// promoted (the first text can't count down).
  public static func promotingNext(_ v: Version, resolved r: ResolvedVersion) -> Version? {
    guard let next = r.moreText.first(where: { !$0.isBlank && $0.countdown == nil }) else { return nil }
    var out = v
    out.text = next.text
    if r.noText { out.noText = true }
    out.style = next.style; out.size = next.size; out.posX = next.posX; out.posY = next.posY; out.align = next.align
    // nil would fall back to the default or an earlier version's timing: a start of 0 stops that for the default, and
    // an explicit far end stops an end carrying over.
    out.textStart = next.start ?? 0
    out.textEnd = next.end ?? (r.textEnd == nil ? nil : farEnd)
    out.textLook = next.look ?? TextLook()
    out.moreText = r.moreText.filter { $0.id != next.id }
    return out
  }

  /// A countdown's window for `count` from a text's current `span` (seconds from the trim start, `TextTimeline.span`)
  /// in a trim of `d` seconds: one second a number, ending where the text ends, or from the start of the trim when
  /// there's no room before that end.
  public static func countdownWindow(_ count: Int, span: TextTimeline.Span, trimDuration d: Double) -> TextTimeline.Span {
    let len = min(Double(count), d)
    let end = min(span.end, d)
    if end - len >= 0 { return (end - len, end) }
    return (0, len)
  }

  /// How a countdown reads in a list or on its timeline bar: "3 · 2 · 1", or "10 … 1" past five, with its words when
  /// it has any around the number.
  public static func countdownLabel(_ l: TextLayer, from n: Int) -> String {
    let numbers = n <= 5 ? (1...n).reversed().map(String.init).joined(separator: " · ") : "\(n) … 1"
    return l.text.contains(TextLayer.countdownToken) ? l.text.replacingOccurrences(of: TextLayer.countdownToken, with: numbers)
      .split(whereSeparator: \.isNewline).joined(separator: " ") : numbers
  }

  /// For a new version copied from `r`: its texts and look stay what `r` shows, even when a later version changed them
  /// (`moreText` and `textLook` would otherwise inherit from the version before the new one).
  public static func copyAdvanced(into v: inout Version, from r: ResolvedVersion) {
    v.moreText = r.moreText
    v.textLook = r.textLook ?? TextLook()
  }
}
