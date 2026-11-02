import DJQCore
import SwiftUI

/// What one platform's phone mock shows. Everything is real clip data (no invented content): the caption is
/// `Captions.caption(for:)`, the YouTube title `Captions.youtubeTitle`, the handle `PlatformUI.handle`.
struct PhoneMockContent: Equatable {
  var platform: Platform
  /// The full caption for this platform (the mock truncates it with `PlatformUI.previewCaption`).
  var caption: String
  /// YouTube Shorts shows this under the handle instead of the caption.
  var youtubeTitle: String
  var handle: String
  /// Display name for card layouts (X shows name + @handle).
  var displayName: String = "DJ Lovd"
  /// Music / sound line ("Original audio", or the Title's tracks).
  var soundLine: String = "Original audio"
  /// "0:21" — X duration badge.
  var durationText: String = ""
  /// The clip's output aspect (the `media` view is drawn at exactly this aspect).
  var aspect: Aspect = .r9x16
}

/// Generic phone mock of a platform's feed (TikTok, Instagram Reels, Facebook Reels, YouTube Shorts) or post card
/// (Threads, X), drawn from `PlatformUI` geometry (DESIGN-v2 §8). No logos, no brand colours.
///
/// Fills the width it's given at the phone aspect (9:19.5). `media` is the clip's output frame (video + overlay
/// text) and fills whatever frame it gets, so the mock always frames it at `content.aspect` and clips it.
///
/// Every element is placed from `PlatformUI.spec(p)` screen rects scaled to the mock's width; the right-rail
/// icon/count y positions (§8 "rail order") live in `MockRail`. Text sizes are §8's base sizes at 393 pt, scaled.
/// Feeds are white-on-video (always dark chrome); cards follow the system colour scheme.
struct EditorPhoneMock<Media: View>: View {
  let content: PhoneMockContent
  let media: Media

  init(content: PhoneMockContent, @ViewBuilder media: () -> Media) {
    self.content = content
    self.media = media()
  }

  var body: some View {
    GeometryReader { proxy in
      let g = MockGeo(w: proxy.size.width)
      let spec = PlatformUI.spec(content.platform)
      let feed = spec.layout == .feed
      ZStack(alignment: .topLeading) {
        if feed { feedScreen(g, spec) } else { cardScreen(g, spec) }
        MockStatusBar(g: g, ink: feed ? .white : MockInk.text)
        Capsule()
          .fill(feed ? Color.white : MockInk.text)
          .frame(width: g.pt(134), height: max(2, g.pt(5)))
          .position(x: g.w / 2, y: g.y(98.2))
      }
      .frame(width: g.w, height: g.h)
      .clipShape(RoundedRectangle(cornerRadius: g.pt(44), style: .continuous))
      .overlay {
        // Thin device bezel (inside the screen edge, so the mock stays exactly 9:19.5) + a hairline that keeps the
        // edge visible on the dark canvas.
        RoundedRectangle(cornerRadius: g.pt(44), style: .continuous)
          .strokeBorder(MockInk.bezel, lineWidth: max(2, g.pt(5)))
        RoundedRectangle(cornerRadius: g.pt(44), style: .continuous)
          .strokeBorder(DS.color.borderStrong, lineWidth: 1)
      }
    }
    .aspectRatio(CGFloat(PlatformUI.screenAspect), contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(content.platform.displayName) preview")
  }

  // MARK: - Feeds (TikTok, Instagram Reels, Facebook Reels, YouTube Shorts)

  @ViewBuilder private func feedScreen(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let cb = g.h * CGFloat(spec.contentBottom)
    let a = CGFloat(content.aspect.ratio)
    // 9:16 is aspect-filled into the content area (crops the sides); other aspects sit full-width, centred on black.
    let mw = content.aspect == .r9x16 ? max(g.w, cb * a) : g.w
    let nav = g.rect(spec.el(.bottomNav))
    Color.black
    ZStack { media.frame(width: mw, height: mw / a).clipped() }
      .frame(width: g.w, height: cb)
      .clipped()
      .position(x: g.w / 2, y: cb / 2)
    // Legibility scrims: §8 bottom gradient (lowest 35 % of content) + a faint top one for the status/top bar.
    LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
      .frame(width: g.w, height: cb * 0.16)
      .position(x: g.w / 2, y: cb * 0.08)
    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
      .frame(width: g.w, height: cb * 0.35)
      .position(x: g.w / 2, y: cb - cb * 0.175)
    ZStack(alignment: .topLeading) {
      feedTopBar(g, spec)
      feedRail(g, spec)
      feedHandleRow(g, spec)
      feedSoundLine(g, spec)
      feedCaption(g, spec)
    }
    .frame(width: g.w, height: g.h)
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.4), radius: g.pt(1.2), x: 0, y: g.pt(1))
    if content.platform == .youtube {
      // 2 pt progress bar just above the nav (white, never brand red).
      let y = g.y(89.8)
      Rectangle().fill(.white.opacity(0.3)).frame(width: g.w, height: max(1.5, g.pt(2))).position(x: g.w / 2, y: y)
      Rectangle().fill(.white).frame(width: g.w * 0.38, height: max(1.5, g.pt(2))).position(x: g.w * 0.19, y: y)
    }
    Color.black.frame(width: nav.width, height: nav.height).position(x: nav.midX, y: nav.midY)
    MockNavBar(g: g, rect: nav, items: MockNav.items(content.platform), ink: .white, dim: .white.opacity(0.92))
  }

  @ViewBuilder private func feedTopBar(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let tb = g.rect(spec.el(.topBar))
    switch content.platform {
    case .tiktok:
      Text("LIVE")
        .font(.system(size: g.pt(9.5), weight: .heavy))
        .padding(.horizontal, g.pt(3.5))
        .padding(.vertical, g.pt(3))
        .overlay(RoundedRectangle(cornerRadius: g.pt(5)).strokeBorder(.white, lineWidth: max(1, g.pt(1.8))))
        .fixedSize()
        .position(x: g.x(7), y: tb.midY)
      HStack(spacing: g.pt(18)) {
        Text("Following").font(g.font(17, .semibold)).opacity(0.62)
        Text("For You").font(g.font(17, .bold))
      }
      .fixedSize()
      .position(x: g.x(50.5), y: tb.midY)
      Image(systemName: "magnifyingglass").font(g.font(22, .semibold)).position(x: g.x(93), y: tb.midY)
    case .instagram:
      Image(systemName: "plus").font(g.font(24, .regular)).position(x: g.x(7), y: tb.midY)
      HStack(spacing: g.pt(14)) {
        Text("Reels").font(g.font(21, .bold))
        Text("Friends").font(g.font(21, .bold)).opacity(0.55)
      }
      .fixedSize()
      .position(x: g.x(49.5), y: tb.midY)
      Image(systemName: "slider.horizontal.3").font(g.font(21, .regular)).position(x: g.x(92), y: tb.midY)
    case .facebook:
      Text("Reels").font(g.font(28, .bold)).fixedSize().frame(width: tb.width, height: tb.height, alignment: .leading)
        .position(x: tb.midX, y: tb.midY)
    default:  // YouTube: right side only
      Image(systemName: "magnifyingglass").font(g.font(22, .medium)).position(x: g.x(81), y: tb.midY)
      Image(systemName: "ellipsis").font(g.font(20, .bold)).rotationEffect(.degrees(90)).position(x: g.x(93.5), y: tb.midY)
    }
  }

  @ViewBuilder private func feedRail(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let rail = MockRail.for(content.platform)
    let cx = g.rect(spec.el(.rightRail)).midX
    ForEach(Array(rail.items.enumerated()), id: \.offset) { _, it in
      MockRailGlyph(glyph: it.glyph, size: g.pt(rail.icon), initials: initials, g: g)
        .position(x: cx, y: g.y(it.y))
      if let label = it.label {
        Text(label).font(g.font(rail.count, rail.countWeight)).monospacedDigit().fixedSize()
          .position(x: cx, y: g.y(it.labelY))
      }
    }
  }

  @ViewBuilder private func feedHandleRow(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let hr = g.rect(spec.el(.handleRow))
    let name = handleWithoutAt
    switch content.platform {
    case .tiktok:
      Text(name).font(g.font(17, .bold)).lineLimit(1)
        .frame(width: hr.width, height: hr.height, alignment: .leading).position(x: hr.midX, y: hr.midY)
    case .instagram:
      // Avatar (36 pt, ring) spans both lines; handle + Follow sit on the line above the audio line.
      let music = g.rect(spec.el(.musicTicker))
      MockFeedAvatar(initials: initials, size: g.pt(34), ring: g.pt(1.8)).position(x: hr.minX + g.pt(17), y: hr.midY)
      HStack(spacing: g.pt(10)) {
        Text(name).font(g.font(14, .semibold)).lineLimit(1)
        MockCapsuleButton(title: "Follow", g: g, style: .outline)
      }
      .frame(width: hr.maxX - music.minX, alignment: .leading)
      .position(x: (music.minX + hr.maxX) / 2, y: (hr.minY + music.minY) / 2)
    case .facebook:
      let music = g.rect(spec.el(.musicTicker))
      MockFeedAvatar(initials: initials, size: g.pt(32), corner: g.pt(7), ring: 0).position(x: hr.minX + g.pt(16), y: hr.midY)
      Text(content.displayName).font(g.font(15, .semibold)).lineLimit(1)
        .frame(width: g.x(58) - music.minX, alignment: .leading)
        .position(x: (music.minX + g.x(58)) / 2, y: (hr.minY + music.minY) / 2)
      MockCapsuleButton(title: "Follow", g: g, style: .translucent).position(x: g.x(69), y: hr.midY)
    default:  // YouTube
      HStack(spacing: g.pt(8)) {
        MockFeedAvatar(initials: initials, size: g.pt(32), ring: 0)
        Text(content.handle).font(g.font(15, .medium)).lineLimit(1).fixedSize()
        MockCapsuleButton(title: "Subscribe", g: g, style: .solid).padding(.leading, g.pt(2))
      }
      .fixedSize()
      .frame(width: hr.width, height: hr.height, alignment: .leading)
      .position(x: hr.midX, y: hr.midY)
    }
  }

  @ViewBuilder private func feedSoundLine(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let r = g.rect(spec.el(.musicTicker))
    let p = content.platform
    let size: CGFloat = p == .tiktok ? 14 : p == .youtube ? 13 : 12
    let text = p == .instagram && content.soundLine == "Original audio" ? "\(handleWithoutAt) · Original audio" : content.soundLine
    HStack(spacing: g.pt(5)) {
      Image(systemName: "music.note").font(g.font(size - 1, .semibold))
      Text(text).font(g.font(size, .regular)).lineLimit(1)
    }
    .frame(width: r.width, height: r.height, alignment: .leading)
    .position(x: r.midX, y: r.midY)
  }

  @ViewBuilder private func feedCaption(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let r = g.rect(spec.el(.caption))
    let p = content.platform
    let size: CGFloat = p == .tiktok || p == .youtube ? 15 : 14
    // Real line height ≈ 1.25 em; let multi-line captions grow downwards from the rect's top.
    Text(captionAttributed(dim: .white.opacity(0.75)))
      .font(g.font(size, p == .youtube ? .medium : .regular))
      .lineLimit(spec.captionLines)
      .minimumScaleFactor(0.8)
      .lineSpacing(g.pt(1))
      .frame(width: r.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: r.width, height: r.height, alignment: spec.captionLines > 1 ? .topLeading : .leading)
      .position(x: r.midX, y: r.midY)
  }

  // MARK: - Cards (Threads, X)

  @ViewBuilder private func cardScreen(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let x = content.platform == .x
    let cb = g.h * CGFloat(spec.contentBottom)
    let nav = g.rect(spec.el(.bottomNav))
    MockInk.background
    ZStack(alignment: .topLeading) {
      if x { xTopBar(g, spec) } else { threadsTopBar(g, spec) }
      cardPost(g, spec)
    }
    .frame(width: g.w, height: cb, alignment: .topLeading)
    .clipped()
    .position(x: g.w / 2, y: cb / 2)
    if x {
      let fab = g.rect(spec.el(.fab))
      Image(systemName: "plus")
        .font(g.font(24, .semibold))
        .foregroundStyle(MockInk.background)
        .frame(width: g.pt(56), height: g.pt(56))
        .background(MockInk.text, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: g.pt(6), x: 0, y: g.pt(3))
        .position(x: fab.midX, y: fab.midY)
    }
    MockInk.background.frame(width: nav.width, height: nav.height).position(x: nav.midX, y: nav.midY)
    if x { Rectangle().fill(MockInk.hairline).frame(width: g.w, height: 0.5).position(x: g.w / 2, y: nav.minY) }
    MockNavBar(g: g, rect: nav, items: MockNav.items(content.platform), ink: MockInk.text, dim: MockInk.tertiary)
  }

  @ViewBuilder private func threadsTopBar(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let tb = g.rect(spec.el(.topBar))
    // Generic app mark: a plain ring (no logo).
    Circle().strokeBorder(MockInk.text, lineWidth: max(1.5, g.pt(3)))
      .frame(width: tb.height * 0.82, height: tb.height * 0.82)
      .position(x: g.w / 2, y: tb.midY)
  }

  @ViewBuilder private func xTopBar(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let tb = g.rect(spec.el(.topBar))
    let rowY = g.y(9.25), tabsY = g.y(14.6)
    DSAvatar(name: content.displayName, size: g.pt(32)).position(x: g.x(8), y: rowY)
    RoundedRectangle(cornerRadius: g.pt(6), style: .continuous)
      .strokeBorder(MockInk.text, lineWidth: max(1.5, g.pt(2.5)))
      .frame(width: g.pt(26), height: g.pt(26))
      .position(x: g.w / 2, y: rowY)
    Image(systemName: "person.badge.plus").font(g.font(20, .regular)).foregroundStyle(MockInk.text).position(x: g.x(92), y: rowY)
    Text("For you").font(g.font(15, .bold)).foregroundStyle(MockInk.text).fixedSize().position(x: g.w * 0.25, y: tabsY)
    Text("Following").font(g.font(15, .medium)).foregroundStyle(MockInk.secondary).fixedSize().position(x: g.w * 0.75, y: tabsY)
    Capsule().fill(MockInk.text).frame(width: g.pt(56), height: max(2, g.pt(4))).position(x: g.w * 0.25, y: tb.maxY - g.pt(2))
    Rectangle().fill(MockInk.hairline).frame(width: g.w, height: 0.5).position(x: g.w / 2, y: tb.maxY)
  }

  /// Header, text, video and actions flow down from the §8 header top; the avatar column (Threads: with the
  /// thread line) runs beside them. Video size = `PlatformUI.cardMediaFrame`.
  @ViewBuilder private func cardPost(_ g: MockGeo, _ spec: PlatformUISpec) -> some View {
    let x = content.platform == .x
    let header = g.rect(spec.el(.postHeader)), textRect = g.rect(spec.el(.postText))
    let avatar = g.pt(x ? 40 : 36)
    let avatarCX = g.x(8)
    let mf = PlatformUI.cardMediaFrame(content.platform, aspect: content.aspect) ?? spec.el(.media)
    let mediaW = mf.width * g.w, mediaH = mf.height * g.h
    HStack(alignment: .top, spacing: 0) {
      VStack(spacing: g.pt(6)) {
        DSAvatar(name: content.displayName, size: avatar)
        if !x { Capsule().fill(MockInk.threadLine).frame(width: max(1.5, g.pt(2))).frame(maxHeight: .infinity) }
      }
      .padding(.top, g.pt(x ? 0 : 4))
      .frame(width: avatar)
      .padding(.leading, avatarCX - avatar / 2)
      .frame(width: textRect.minX, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) {
        cardHeader(g, x: x)
        Text(captionAttributed(dim: MockInk.secondary))
          .font(g.font(15))
          .lineSpacing(g.pt(3))
          .foregroundStyle(MockInk.text)
          .lineLimit(6)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, g.pt(2))
        cardMedia(g, w: mediaW, h: mediaH, radius: g.pt(x ? 16 : 8), x: x)
          .padding(.top, g.pt(10))
        cardActions(g, x: x, bodyX: textRect.minX)
          .padding(.top, g.pt(x ? 10 : 12))
      }
      .frame(width: textRect.width, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: g.w, alignment: .topLeading)
    .offset(y: header.minY)
  }

  @ViewBuilder private func cardHeader(_ g: MockGeo, x: Bool) -> some View {
    HStack(spacing: g.pt(4)) {
      if x {
        Text(content.displayName).font(g.font(15, .bold)).foregroundStyle(MockInk.text).lineLimit(1).layoutPriority(1)
        Text("\(content.handle) · 7h").font(g.font(15)).foregroundStyle(MockInk.secondary).lineLimit(1)
      } else {
        Text(handleWithoutAt).font(g.font(15, .semibold)).foregroundStyle(MockInk.text).lineLimit(1)
      }
      Spacer(minLength: g.pt(4))
      if !x { Text("7h").font(g.font(15)).foregroundStyle(MockInk.tertiary).padding(.trailing, g.pt(10)) }
      Image(systemName: "ellipsis").font(g.font(15, .semibold)).foregroundStyle(x ? MockInk.secondary : MockInk.text)
    }
    .frame(height: g.pt(22))
  }

  @ViewBuilder private func cardMedia(_ g: MockGeo, w: CGFloat, h: CGFloat, radius: CGFloat, x: Bool) -> some View {
    let a = CGFloat(content.aspect.ratio)
    let mw = max(w, h * a)  // aspect-fill the box (X crops tall clips to 4:5)
    ZStack { media.frame(width: mw, height: mw / a).clipped() }
      .frame(width: w, height: h)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(MockInk.hairline, lineWidth: 0.5))
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: "speaker.slash.fill")
          .font(.system(size: g.pt(11), weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: g.pt(24), height: g.pt(24))
          .background(.black.opacity(0.62), in: Circle())
          .padding(g.pt(x ? 10 : 8))
      }
      .overlay(alignment: .bottomLeading) {
        if x && !content.durationText.isEmpty {
          Text(content.durationText)
            .font(.system(size: g.pt(11), weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, g.pt(6))
            .padding(.vertical, g.pt(2))
            .background(.black.opacity(0.63), in: Capsule())
            .padding(g.pt(10))
        }
      }
  }

  @ViewBuilder private func cardActions(_ g: MockGeo, x: Bool, bodyX: CGFloat) -> some View {
    if x {
      // §8.6 fixed columns (screen %), measured from the body's left edge.
      let cols: [(String, String?, CGFloat)] = [
        ("bubble.left", "24", 15.5), ("arrow.2.squarepath", "61", 34), ("heart", "389", 50),
        ("chart.bar.xaxis", "12K", 67), ("bookmark", nil, 85), ("square.and.arrow.up", nil, 92.5),
      ]
      ZStack(alignment: .leading) {
        ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
          HStack(spacing: g.pt(4)) {
            Image(systemName: c.0).font(g.font(16))
            if let n = c.1 { Text(n).font(g.font(13)).monospacedDigit() }
          }
          .fixedSize()
          .offset(x: g.x(c.2) - bodyX)
        }
      }
      .foregroundStyle(MockInk.secondary)
      .frame(height: g.pt(22), alignment: .leading)
    } else {
      HStack(spacing: g.pt(16)) {
        ForEach(Array([("heart", "128"), ("bubble.right", "14"), ("arrow.2.squarepath", "9"), ("paperplane", "3")].enumerated()), id: \.offset) { _, c in
          HStack(spacing: g.pt(5)) {
            Image(systemName: c.0).font(g.font(19))
            Text(c.1).font(g.font(13)).monospacedDigit().foregroundStyle(MockInk.secondary)
          }
        }
      }
      .foregroundStyle(MockInk.text)
      .frame(height: g.pt(24), alignment: .leading)
    }
  }

  // MARK: - Text helpers

  private var handleWithoutAt: String { content.handle.hasPrefix("@") ? String(content.handle.dropFirst()) : content.handle }

  private var initials: String {
    let s = content.displayName.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    return s.isEmpty ? "DL" : s
  }

  /// `PlatformUI.previewCaption` exactly as returned, with the "more" label styled (bolder; cards: dimmer) and,
  /// on Facebook, bold hashtags.
  private func captionAttributed(dim: Color) -> AttributedString {
    let p = content.platform
    let spec = PlatformUI.spec(p)
    let raw = spec.showsTitle ? content.youtubeTitle : content.caption
    let (text, truncated) = PlatformUI.previewCaption(raw, for: p)
    var body = text, more = ""
    let label = spec.moreLabel
    if truncated, label != "…", text.hasSuffix(label) {
      body = String(text.dropLast(label.count))
      if label.hasPrefix("…") { body += "… "; more = String(label.dropFirst()).trimmingCharacters(in: .whitespaces) } else { more = label }
    }
    var out = AttributedString()
    if p == .facebook {
      let words = body.components(separatedBy: " ")
      for (i, w) in words.enumerated() {
        var run = AttributedString(w + (i < words.count - 1 ? " " : ""))
        if w.hasPrefix("#") { run.inlinePresentationIntent = .stronglyEmphasized }
        out += run
      }
    } else {
      out = AttributedString(body)
    }
    if !more.isEmpty {
      var run = AttributedString(more)
      run.inlinePresentationIntent = .stronglyEmphasized
      if spec.layout == .postCard { run.foregroundColor = dim }
      out += run
    }
    return out
  }
}

// MARK: - Geometry

/// The phone at a given width: screen-% → points, and §8 base sizes (at 393 pt) → scaled points.
private struct MockGeo {
  let w: CGFloat
  var h: CGFloat { w / CGFloat(PlatformUI.screenAspect) }
  var s: CGFloat { w / 393 }
  func pt(_ v: CGFloat) -> CGFloat { v * s }
  func x(_ pct: CGFloat) -> CGFloat { w * pct / 100 }
  func y(_ pct: CGFloat) -> CGFloat { h * pct / 100 }
  func rect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h) }
  func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * s, weight: weight) }
}

private extension PlatformUISpec {
  func el(_ kind: OverlayKind) -> CGRect { elements.first { $0.kind == kind }?.screen ?? .zero }
}

/// Phone-interior colours (generic app imitation, not DJ Queue chrome). Cards follow the system appearance.
private enum MockInk {
  static let background = Color(light: 0xFFFFFF, dark: 0x0A0A0A)
  static let text = Color(light: 0x0D0D0D, dark: 0xF3F3F3)
  static let secondary = Color(light: 0x5E5E5E, dark: 0x9A9A9A)
  static let tertiary = Color(light: 0x9A9A9A, dark: 0x6E6E6E)
  static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.16)
  static let threadLine = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.18)
  static let bezel = Color(light: 0x1C1C1E, dark: 0x050505)
  static let avatarFill = Color(white: 0.36)
}

// MARK: - Status bar

private struct MockStatusBar: View {
  let g: MockGeo
  let ink: Color

  var body: some View {
    let y = g.y(2.9)
    Text("9:41").font(.system(size: g.pt(17), weight: .semibold).monospacedDigit()).foregroundStyle(ink)
      .fixedSize().position(x: g.x(17.5), y: y)
    HStack(spacing: g.pt(5)) {
      Image(systemName: "cellularbars")
      Image(systemName: "wifi")
      Image(systemName: "battery.100").font(.system(size: g.pt(17), weight: .regular))
    }
    .font(.system(size: g.pt(14), weight: .semibold))
    .foregroundStyle(ink)
    .fixedSize()
    .position(x: g.x(83), y: y)
  }
}

// MARK: - Feed parts

private struct MockFeedAvatar: View {
  let initials: String
  let size: CGFloat
  var corner: CGFloat? = nil
  var ring: CGFloat = 1.5

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: corner ?? size / 2, style: .continuous)
    Text(initials)
      .font(.system(size: size * 0.38, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(MockInk.avatarFill, in: shape)
      .overlay { if ring > 0 { shape.strokeBorder(.white, lineWidth: ring) } }
  }
}

private struct MockCapsuleButton: View {
  enum Style { case outline, translucent, solid }
  let title: String
  let g: MockGeo
  let style: Style

  var body: some View {
    Text(title)
      .font(g.font(style == .solid ? 13 : 14, .semibold))
      .foregroundStyle(style == .solid ? Color.black : .white)
      .padding(.horizontal, g.pt(style == .solid ? 13 : 11))
      .frame(height: g.pt(style == .solid ? 30 : 26))
      .background {
        switch style {
        case .outline: Capsule().strokeBorder(.white.opacity(0.85), lineWidth: max(1, g.pt(1.2)))
        case .translucent: Capsule().fill(.white.opacity(0.22))
        case .solid: Capsule().fill(.white)
        }
      }
      .fixedSize()
  }
}

/// Right-rail entries per feed platform (§8 "rail order": icon centre y / count y, screen %).
private struct MockRail {
  enum Glyph { case symbol(String), avatarFollow, disc, tile(CGFloat) }
  struct Item {
    var glyph: Glyph
    var y: CGFloat
    var label: String? = nil
    var labelY: CGFloat = 0
  }

  var items: [Item]
  /// Icon size (pt at 393 wide).
  var icon: CGFloat
  var count: CGFloat
  var countWeight: Font.Weight = .semibold

  // Counts are neutral, made-up placeholders.
  static func `for`(_ p: Platform) -> MockRail {
    switch p {
    case .tiktok:
      MockRail(items: [
        Item(glyph: .avatarFollow, y: 47.5),
        Item(glyph: .symbol("heart.fill"), y: 55, label: "24.8K", labelY: 57.7),
        Item(glyph: .symbol("ellipsis.message.fill"), y: 62.7, label: "312", labelY: 65.6),
        Item(glyph: .symbol("bookmark.fill"), y: 70.4, label: "1,204", labelY: 72.9),
        Item(glyph: .symbol("arrowshape.turn.up.right.fill"), y: 77.5, label: "2,031", labelY: 80.1),
        Item(glyph: .disc, y: 86.3),
      ], icon: 30, count: 12.5)
    case .instagram:
      MockRail(items: [
        Item(glyph: .symbol("heart"), y: 47, label: "18.2K", labelY: 50.6),
        Item(glyph: .symbol("message"), y: 55.7, label: "214", labelY: 58.9),
        Item(glyph: .symbol("arrow.2.squarepath"), y: 64.7, label: "96", labelY: 68.1),
        Item(glyph: .symbol("paperplane"), y: 73, label: "1,027", labelY: 76.2),
        Item(glyph: .symbol("ellipsis"), y: 80.8),
        Item(glyph: .tile(30), y: 86.3),
      ], icon: 25, count: 12, countWeight: .medium)
    case .facebook:
      MockRail(items: [
        Item(glyph: .symbol("hand.thumbsup"), y: 53.5, label: "12K", labelY: 56.8),
        Item(glyph: .symbol("message"), y: 62, label: "148", labelY: 65.2),
        Item(glyph: .symbol("arrowshape.turn.up.right"), y: 70.7, label: "63", labelY: 73.7),
        Item(glyph: .symbol("bookmark"), y: 79, label: "89", labelY: 82.2),
        Item(glyph: .symbol("ellipsis"), y: 86.8),
      ], icon: 25, count: 12, countWeight: .medium)
    default:  // YouTube Shorts
      MockRail(items: [
        Item(glyph: .symbol("hand.thumbsup.fill"), y: 41, label: "31K", labelY: 44.2),
        Item(glyph: .symbol("hand.thumbsdown.fill"), y: 50, label: "Dislike", labelY: 53.2),
        Item(glyph: .symbol("text.bubble.fill"), y: 59, label: "402", labelY: 62.2),
        Item(glyph: .symbol("arrowshape.turn.up.right.fill"), y: 68, label: "Share", labelY: 71.2),
        Item(glyph: .symbol("arrow.triangle.2.circlepath"), y: 77, label: "117", labelY: 80.2),
        Item(glyph: .tile(36), y: 86),
      ], icon: 27, count: 12, countWeight: .medium)
    }
  }
}

private struct MockRailGlyph: View {
  let glyph: MockRail.Glyph
  let size: CGFloat
  let initials: String
  let g: MockGeo

  var body: some View {
    switch glyph {
    case .symbol(let name):
      Image(systemName: name).font(.system(size: size, weight: .regular)).frame(width: size * 1.4, height: size * 1.2)
    case .avatarFollow:
      // Avatar 46 pt + follow badge: white circle with a black ＋ (no brand red).
      MockFeedAvatar(initials: initials, size: g.pt(46), ring: max(1, g.pt(1.5)))
        .overlay(alignment: .bottom) {
          Image(systemName: "plus")
            .font(.system(size: g.pt(11), weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: g.pt(20), height: g.pt(20))
            .background(.white, in: Circle())
            .offset(y: g.pt(10))
        }
    case .disc:
      MockFeedAvatar(initials: initials, size: g.pt(22), ring: 0)
        .frame(width: g.pt(42), height: g.pt(42))
        .background(Color(white: 0.13), in: Circle())
        .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: g.pt(5)).padding(g.pt(2)))
    case .tile(let side):
      Image(systemName: "music.note")
        .font(.system(size: g.pt(side * 0.45), weight: .semibold))
        .frame(width: g.pt(side), height: g.pt(side))
        .background(MockInk.avatarFill, in: RoundedRectangle(cornerRadius: g.pt(side * 0.22), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: g.pt(side * 0.22), style: .continuous).strokeBorder(.white, lineWidth: max(1, g.pt(2))))
    }
  }
}

// MARK: - Bottom nav

private struct MockNav {
  enum Kind { case symbol(String), create, ytCreate, avatar }
  struct Item {
    var kind: Kind
    var label: String? = nil
    var active = false
  }

  static func items(_ p: Platform) -> [Item] {
    switch p {
    case .tiktok:
      [Item(kind: .symbol("house.fill"), label: "Home", active: true), Item(kind: .symbol("person.2"), label: "Friends"),
       Item(kind: .create), Item(kind: .symbol("tray"), label: "Inbox"), Item(kind: .symbol("person"), label: "Profile")]
    case .instagram:
      [Item(kind: .symbol("house")), Item(kind: .symbol("play.rectangle.fill"), active: true), Item(kind: .symbol("paperplane")),
       Item(kind: .symbol("magnifyingglass")), Item(kind: .symbol("person.crop.circle"))]
    case .facebook:
      [Item(kind: .symbol("house"), label: "Home"), Item(kind: .symbol("play.rectangle.fill"), label: "Reels", active: true),
       Item(kind: .symbol("person.2"), label: "Friends"), Item(kind: .symbol("person.crop.circle"), label: "Profile"),
       Item(kind: .symbol("bell"), label: "Notifications"), Item(kind: .symbol("line.3.horizontal"), label: "Menu")]
    case .youtube:
      [Item(kind: .symbol("house"), label: "Home"), Item(kind: .symbol("play.square.stack.fill"), label: "Shorts", active: true),
       Item(kind: .ytCreate), Item(kind: .symbol("rectangle.stack.badge.play"), label: "Subscriptions"),
       Item(kind: .avatar, label: "You")]
    case .threads:
      [Item(kind: .symbol("house.fill"), active: true), Item(kind: .symbol("magnifyingglass")), Item(kind: .symbol("square.and.pencil")),
       Item(kind: .symbol("heart")), Item(kind: .symbol("person"))]
    case .x:
      [Item(kind: .symbol("house.fill"), active: true), Item(kind: .symbol("magnifyingglass")), Item(kind: .symbol("sparkle")),
       Item(kind: .symbol("bell")), Item(kind: .symbol("envelope"))]
    }
  }
}

private struct MockNavBar: View {
  let g: MockGeo
  let rect: CGRect
  let items: [MockNav.Item]
  let ink: Color
  let dim: Color

  var body: some View {
    let labelled = items.contains { $0.label != nil }
    let iconY = rect.minY + g.pt(labelled ? 21 : 25)
    let step = rect.width / CGFloat(items.count)
    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
      let cx = rect.minX + step * (CGFloat(i) + 0.5)
      glyph(it).foregroundStyle(it.active ? ink : dim).position(x: cx, y: iconY)
      if let l = it.label {
        Text(l).font(.system(size: g.pt(10), weight: it.active ? .semibold : .regular)).foregroundStyle(it.active ? ink : dim)
          .lineLimit(1).fixedSize().position(x: cx, y: rect.minY + g.pt(41))
      }
    }
  }

  @ViewBuilder private func glyph(_ it: MockNav.Item) -> some View {
    switch it.kind {
    case .symbol(let name):
      Image(systemName: name).font(.system(size: g.pt(items.count > 5 ? 21 : 23), weight: .regular))
    case .create:
      Image(systemName: "plus").font(.system(size: g.pt(16), weight: .heavy)).foregroundStyle(.black)
        .frame(width: g.pt(44), height: g.pt(29))
        .background(.white, in: RoundedRectangle(cornerRadius: g.pt(8), style: .continuous))
    case .ytCreate:
      Image(systemName: "plus.circle").font(.system(size: g.pt(34), weight: .ultraLight)).offset(y: g.pt(8))
    case .avatar:
      MockFeedAvatar(initials: "DL", size: g.pt(24), ring: 0)
    }
  }
}

// MARK: - Preview harness

#if DEBUG
/// All six mocks at the editor's single-phone width (≈ 300 pt, 9:16) and at the compare-row width (≈ 230 pt,
/// mixed aspects). `PhoneMockGallery.run(outputDir:)` renders it in light + dark; `DJQ_MOCK_CLIP=<video>` supplies
/// a real still (centre-cropped to each aspect), otherwise a neutral placeholder frame is drawn.
@MainActor
enum PhoneMockGallery {
  static func run(outputDir: String) async -> Int32 {
    let out = URL(fileURLWithPath: outputDir)
    let still = ProcessInfo.processInfo.environment["DJQ_MOCK_CLIP"].flatMap {
      Media.frame(URL(fileURLWithPath: $0), at: 5, maxSize: CGSize(width: 1920, height: 1080))
    }
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      try await DSGallerySnapshot.render(AnyView(PhoneMockGalleryView(still: still)), size: CGSize(width: 2000, height: 1400),
                                         name: "phone-mocks", to: out)
      print("phone-mocks: wrote 2 PNGs to \(out.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("phone-mocks failed: \(error)\n".utf8))
      return 1
    }
  }
}

struct PhoneMockGalleryView: View {
  let still: CGImage?

  static let caption = "yayo x johnny\n\n🎧 Afroween Jazz Piano — full set on YouTube (link in bio)\n#amapiano #amapianomix #afrohouse #djlovd #dj #djlife #djmix #transition"
  static let order: [Platform] = [.tiktok, .instagram, .facebook, .youtube, .threads, .x]
  static let compareAspects: [Platform: Aspect] = [.tiktok: .r9x16, .instagram: .r4x5, .facebook: .r1x1, .youtube: .r16x9,
                                                    .threads: .r16x9, .x: .r9x16]

  static func content(_ p: Platform, aspect: Aspect) -> PhoneMockContent {
    PhoneMockContent(platform: p, caption: caption, youtubeTitle: "yayo x johnny | DJ Lovd", handle: PlatformUI.handle(p),
                     durationText: "0:21", aspect: aspect)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      row(width: 300, aspects: [:])
      row(width: 230, aspects: Self.compareAspects)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DS.color.canvas)
  }

  private func row(width: CGFloat, aspects: [Platform: Aspect]) -> some View {
    HStack(alignment: .top, spacing: 24) {
      ForEach(Self.order) { p in
        let a = aspects[p] ?? .r9x16
        VStack(alignment: .leading, spacing: 8) {
          Text("\(p.displayName) · \(a.rawValue)").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          EditorPhoneMock(content: Self.content(p, aspect: a)) { mediaView(a) }
            .frame(width: width)
        }
      }
    }
  }

  @ViewBuilder private func mediaView(_ a: Aspect) -> some View {
    if let img = still.flatMap({ Self.crop($0, to: a.ratio) }) {
      Image(decorative: img, scale: 1).resizable().scaledToFill()
    } else {
      LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
        .overlay(Text(a.rawValue).font(DS.type.title).foregroundStyle(.white.opacity(0.6)))
    }
  }

  /// Centre crop to width/height `ratio`.
  static func crop(_ img: CGImage, to ratio: Double) -> CGImage? {
    let w = Double(img.width), h = Double(img.height)
    let r = w / h > ratio ? CGRect(x: (w - h * ratio) / 2, y: 0, width: h * ratio, height: h)
                          : CGRect(x: 0, y: (h - w / ratio) / 2, width: w, height: w / ratio)
    return img.cropping(to: r.integral)
  }
}
#endif
