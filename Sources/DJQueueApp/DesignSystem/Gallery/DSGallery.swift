import AppKit
import DJQCore
import SwiftUI

/// Every DS component in every state. Open it from anywhere (`DSGallery()`), or render it to PNGs with
/// `DSGallerySnapshot.run(outputDir:)` (`DJQ_SNAPSHOT_GALLERY=1 DJQueueApp --snapshot <dir>`).
enum DSGalleryPage: String, CaseIterable, Identifiable {
  case foundations, actions, inputs, status, surfaces, clips, single
  var id: String { rawValue }

  var title: String {
    switch self {
    case .foundations: "Foundations"
    case .actions: "Buttons"
    case .inputs: "Inputs & choice"
    case .status: "Status & data"
    case .surfaces: "Surfaces & overlays"
    case .clips: "Clip cards"
    case .single: "Clip · single"
    }
  }

  var icon: String {
    switch self {
    case .foundations: "paintpalette"
    case .actions: "button.horizontal"
    case .inputs: "slider.horizontal.3"
    case .status: "circle.badge.checkmark"
    case .surfaces: "square.on.square"
    case .clips: "rectangle.grid.1x2"
    case .single: "rectangle.portrait"
    }
  }

  var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct DSGallery: View {
  @State var page: DSGalleryPage = .foundations
  var media = DSGalleryMedia.load()

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      DSSeparator(vertical: true)
      VStack(spacing: 0) {
        DSToolbar(page.title, subtitle: "Design system · DESIGN-v2 tokens") {
          EmptyView()
        } trailing: {
          DSIconButton("circle.lefthalf.filled", tooltip: "Follows the system appearance", variant: .ghost) {}
        }
        // Two-axis scroll anchors oversize pages at top-leading instead of centring them under the sidebar.
        GeometryReader { g in
          ScrollView([.vertical, .horizontal]) {
            pageView.padding(DS.space.xl).frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading)
          }
          .scrollIndicators(.never)
        }
        .clipped()
      }
      .background(DS.color.background)
    }
    .background(DS.color.background)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.color.primaryText)
          .frame(width: 26, height: 26).background(DS.color.primary, in: Circle())
        Text("DJ Queue").font(DS.type.headline).foregroundStyle(DS.color.text)
      }
      .padding(.horizontal, 10).padding(.bottom, DS.space.sm).padding(.top, 6)
      GState("") { DSTextField(placeholder: "Search", text: $0, size: .sm, isSearch: true) }.padding(.horizontal, 4).padding(.bottom, DS.space.sm)
      DSEyebrow("Design system").padding(.horizontal, 10).padding(.bottom, 4)
      ForEach(DSGalleryPage.allCases) { p in
        DSSidebarItem(p.title, icon: p.icon, isSelected: p == page) { page = p }
      }
      Spacer()
      HStack(spacing: 8) {
        DSStatusDot(tone: .success, size: 7)
        Text("Running · next 7:00 PM TikTok").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      DSSidebarItem("Settings", icon: "gearshape") {}
    }
    .padding(DS.space.xs)
    .frame(width: DS.size.sidebarWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(DS.color.sidebar)
  }

  @ViewBuilder private var pageView: some View {
    switch page {
    case .foundations: GalleryFoundations()
    case .actions: GalleryButtons()
    case .inputs: GalleryInputs()
    case .status: GalleryStatus()
    case .surfaces: GallerySurfaces()
    case .clips: GalleryClips(media: media)
    case .single: GallerySingle(media: media)
    }
  }
}

// MARK: - Gallery helpers

/// Labelled cell: the component, with its state name underneath.
struct GCell<C: View>: View {
  let label: String
  var forced: DSInteraction? = nil
  @ViewBuilder var content: C
  init(_ label: String, forced: DSInteraction? = nil, @ViewBuilder content: () -> C) {
    self.label = label
    self.forced = forced
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      content.dsForcedState(forced)
      Text(label).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
  }
}

/// Section block with a title.
struct GSection<C: View>: View {
  let title: String
  var note: String? = nil
  @ViewBuilder var content: C
  init(_ title: String, note: String? = nil, @ViewBuilder content: () -> C) {
    self.title = title
    self.note = note
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title).font(DS.type.headline).foregroundStyle(DS.color.text)
        if let note { Text(note).font(DS.type.callout).foregroundStyle(DS.color.textTertiary) }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Holds @State for interactive gallery samples.
struct GState<T, C: View>: View {
  @State var value: T
  let content: (Binding<T>) -> C
  init(_ initial: T, @ViewBuilder content: @escaping (Binding<T>) -> C) {
    _value = State(initialValue: initial)
    self.content = content
  }
  var body: some View { content($value) }
}

// MARK: - Sample media (local only; never committed)

/// Posters + an optional proxy video for the clip-card pages. Uses `DJQ_GALLERY_MEDIA` (folder of .jpg/.png
/// covers, and .mp4 for autoplay) when set, else drawn placeholders. Nothing from here is committed.
struct DSGalleryMedia {
  var posters: [NSImage]
  var video: URL?

  static func load() -> DSGalleryMedia {
    let env = ProcessInfo.processInfo.environment
    var posters: [NSImage] = []
    var video: URL?
    if let dir = env["DJQ_GALLERY_MEDIA"] {
      let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
      for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        switch f.pathExtension.lowercased() {
        case "jpg", "jpeg", "png": if let i = NSImage(contentsOf: f) { posters.append(i) }
        case "mp4", "mov": if video == nil { video = f }
        default: break
        }
      }
    }
    if posters.isEmpty { posters = (0..<6).map(placeholder) }
    return DSGalleryMedia(posters: posters, video: video)
  }

  func poster(_ i: Int) -> NSImage { posters[i % posters.count] }

  /// Soft "club light" gradient 9:16 placeholder.
  static func placeholder(_ i: Int) -> NSImage {
    let hues: [(CGFloat, CGFloat)] = [(0.72, 0.55), (0.52, 0.85), (0.93, 0.62), (0.6, 0.12), (0.8, 0.45), (0.08, 0.9)]
    let (a, b) = hues[i % hues.count]
    return NSImage(size: NSSize(width: 270, height: 480), flipped: false) { r in
      let g = NSGradient(colors: [NSColor(hue: a, saturation: 0.55, brightness: 0.35, alpha: 1),
                                  NSColor(hue: b, saturation: 0.5, brightness: 0.75, alpha: 1)])
      g?.draw(in: r, angle: 70)
      NSColor(white: 1, alpha: 0.12).setFill()
      NSBezierPath(ovalIn: NSRect(x: r.width * 0.2, y: r.height * 0.28, width: r.width * 0.6, height: r.width * 0.6)).fill()
      NSColor(white: 0, alpha: 0.25).setFill()
      NSBezierPath(roundedRect: NSRect(x: r.width * 0.12, y: r.height * 0.08, width: r.width * 0.76, height: r.height * 0.16),
                   xRadius: 12, yRadius: 12).fill()
      return true
    }
  }
}

/// Sample clips (fictional titles; covers come from local media only).
enum DSGallerySamples {
  static func clips(_ m: DSGalleryMedia, autoplayVideo: Bool) -> [DSClip] {
    let v = autoplayVideo ? m.video : nil
    return [
      DSClip(id: "a", title: "Chanel x Ke Star", subtitle: "Afroween Jazz Piano", poster: m.poster(0), proxyURL: v, durationText: "0:14",
             kind: "Talking", score: 41, position: 1,
             platforms: [.init(platform: .tiktok, state: .posted), .init(platform: .instagram, state: .due), .init(platform: .youtube, state: .planned),
                         .init(platform: .x, state: .failed)],
             dateText: "Today"),
      DSClip(id: "b", title: "Bacardi via Sadongo x Teze", subtitle: "Afroween Jazz Piano", poster: m.poster(1), durationText: "0:22",
             kind: "DJ vid", score: 45, position: 2,
             platforms: [.init(platform: .tiktok, state: .planned), .init(platform: .instagram, state: .planned)], dateText: "Thu 5 Nov",
             isPinned: true),
      DSClip(id: "c", title: "forgiveness x why love", subtitle: "Afroween Jazz Piano", poster: m.poster(2), durationText: "2:32",
             kind: "DJ vid", score: 52, issues: ["No crop", "No text"], blocks: ["Too long for X · 2:32 > 2:20"],
             suggestions: [DSTitleSuggestion(text: "Forgiveness x Why Love", detail: "Asake · Tems")]),
      DSClip(id: "d", title: "Wadibusa x Bele", subtitle: "Lagos Rooftop", poster: m.poster(3), durationText: "0:31", kind: "DJ vid",
             score: 49, status: DSClipTag(text: "Posted", style: .soft(.success), icon: "checkmark"),
             platforms: Platform.allCases.sorted { $0.displayName < $1.displayName }.map { .init(platform: $0, state: .posted) },
             dateText: "Sun 1 Nov"),
      DSClip(id: "e", title: "bb lifestyle x gimmi date ting", subtitle: "Afroween Jazz Piano", poster: m.poster(4), durationText: "0:19",
             kind: "DJ vid", score: 38, dateText: "Not scheduled", isMissing: true),
    ]
  }
}
