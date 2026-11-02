import AVFoundation
import DJQCore
import SwiftUI

// MARK: - Inspector building blocks (DESIGN-v2 §7, built from DS components)

/// "Custom" tag + ↺ reset, shown only when a field differs from its default (decision #10). Nothing otherwise.
/// `inheritedFrom` shows "from v1" instead when a later version carries an earlier version's value.
struct EditorCustomTag: View {
  var isCustom: Bool
  var inheritedFrom: Int? = nil
  var resetHelp = "Reset to the default"
  /// nil = the value is inherited, so there's nothing on this version to reset.
  var onReset: (() -> Void)?

  var body: some View {
    HStack(spacing: 2) {
      if let v = inheritedFrom {
        DSBadge("from v\(v)", style: .outline, size: .sm)
          .help("Carried forward from v\(v) — change it here to make this version different")
      } else if isCustom {
        DSBadge("Custom", style: .soft(.neutral), size: .sm)
          .help("Changed from your New clip defaults")
        if let onReset {
          DSIconButton("arrow.uturn.backward", tooltip: resetHelp, size: .sm, action: onReset)
            .scaleEffect(0.86)
        }
      }
    }
    .frame(height: 22)
  }
}

/// One labelled field in an inspector section: label (callout medium) + Custom tag on the right, then the control.
struct EditorField<Content: View>: View {
  var label: String
  var help: String? = nil
  var isCustom = false
  var inheritedFrom: Int? = nil
  var resetHelp = "Reset to the default"
  var onReset: (() -> Void)? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(label).font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
          .help(help ?? "")
        Spacer(minLength: 0)
        EditorCustomTag(isCustom: isCustom, inheritedFrom: inheritedFrom, resetHelp: resetHelp, onReset: onReset)
      }
      content
    }
  }
}

/// Inspector section: `headline` title + optional trailing accessory, content below, 24 pt between sections.
struct EditorSectionView<Content: View, Accessory: View>: View {
  var section: EditorSection
  @ViewBuilder var accessory: Accessory
  @ViewBuilder var content: Content

  init(_ section: EditorSection, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
    self.section = section; self.accessory = accessory(); self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      HStack(spacing: 6) {
        Text(section.rawValue).font(DS.type.headline).foregroundStyle(DS.color.text)
        Spacer(minLength: 0)
        accessory
      }
      content
    }
    .padding(.horizontal, DS.space.md)
    .id(section)
  }
}

/// Small helper line under a control (`caption`, secondary).
struct EditorHint: View {
  var text: String
  var icon: String? = nil
  var tone: DSTone? = nil
  init(_ text: String, icon: String? = nil, tone: DSTone? = nil) { self.text = text; self.icon = icon; self.tone = tone }
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let icon { Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)) }
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .font(DS.type.caption)
    .foregroundStyle(tone?.color ?? DS.color.textSecondary)
  }
}

extension Platform {
  /// Subtle, non-brand tint for this platform's safe-zone overlay (hues chosen to stay distinct when stacked;
  /// never the platform's own brand colour).
  var editorZoneTint: Color {
    switch self {
    case .tiktok: Color(light: 0x7C5CFA, dark: 0x9B85FF)
    case .instagram: Color(light: 0x0F9F8F, dark: 0x2DD4BF)
    case .facebook: Color(light: 0xD97706, dark: 0xF5A524)
    case .youtube: Color(light: 0x16A34A, dark: 0x4ADE80)
    case .threads: Color(light: 0xDB2777, dark: 0xF472B6)
    case .x: Color(light: 0x0891B2, dark: 0x22D3EE)
    }
  }

  /// Short label for chips in tight rows ("YouTube" instead of "YouTube Shorts").
  var editorShortName: String { self == .youtube ? "YouTube" : displayName }
}

/// Shows the part of a full-frame still that `crop` (source pixels) selects.
struct EditorCroppedImage: View {
  var image: CGImage?
  var crop: CropRect?
  var source: CGSize
  var body: some View {
    if let img = cropped {
      Image(decorative: img, scale: 1).resizable().interpolation(.medium)
    } else {
      Rectangle().fill(Color.black.opacity(0.85))
    }
  }
  private var cropped: CGImage? {
    guard let image else { return nil }
    guard let c = crop, source.width > 0 else { return image }
    // Same even-pixel rect as the export (Media.pixelCrop), scaled to this still's size.
    let r = EditorGeometry.imageRect(EditorGeometry.even(c, source: source), source: source,
                                     imageSize: CGSize(width: image.width, height: image.height))
    return image.cropping(to: r) ?? image
  }
}

/// Async, cached frame strips (AVAssetImageGenerator, tolerant seeks, small size).
@MainActor
final class EditorFrameStrip: ObservableObject {
  @Published private(set) var frames: [(time: Double, image: CGImage)] = []
  @Published private(set) var loading = false
  /// Bounded cache (~160 MB of decoded frames); older strips are evicted.
  private final class Entry { let frames: [(Double, CGImage)]; init(_ f: [(Double, CGImage)]) { frames = f } }
  private static let cache: NSCache<NSString, Entry> = {
    let c = NSCache<NSString, Entry>()
    c.totalCostLimit = 160 * 1024 * 1024
    return c
  }()
  private static func store(_ out: [(Double, CGImage)], key: String) {
    cache.setObject(Entry(out), forKey: key as NSString, cost: out.reduce(0) { $0 + $1.1.bytesPerRow * $1.1.height })
  }
  private var task: Task<Void, Never>?

  func load(url: URL?, from a: Double, to b: Double, count: Int, sync: Bool = false) {
    task?.cancel()
    guard let url, b > a, count > 0 else { frames = []; return }
    let key = "\(url.path)|\(Int(a * 10))|\(Int(b * 10))|\(count)"
    if let c = Self.cache.object(forKey: key as NSString) { frames = c.frames.map { (time: $0.0, image: $0.1) }; return }
    let times = (0..<count).map { a + (b - a) * (Double($0) + 0.5) / Double(count) }
    if sync {
      let out = Self.generate(url: url, times: times)
      Self.store(out, key: key)
      frames = out.map { (time: $0.0, image: $0.1) }
      return
    }
    loading = true
    frames = []
    task = Task.detached(priority: .utility) { [weak self] in
      let out = Self.generate(url: url, times: times)
      guard !Task.isCancelled else { return }
      await self?.finish(out, key: key)
    }
  }

  private func finish(_ out: [(Double, CGImage)], key: String) {
    Self.store(out, key: key)
    frames = out.map { (time: $0.0, image: $0.1) }
    loading = false
  }

  nonisolated static func generate(url: URL, times: [Double]) -> [(Double, CGImage)] {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 480, height: 270)
    let tol = CMTime(seconds: 0.4, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tol
    gen.requestedTimeToleranceAfter = tol
    // Async image(at:) (copyCGImage is deprecated); this function is synchronous for its callers, so wait here.
    // The work runs on a detached task, never on the calling thread, so waiting can't deadlock.
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: [(Double, CGImage)] = []
    Task.detached {
      for t in times {
        if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append((t, img)) }
      }
      sem.signal()
    }
    sem.wait()
    return out
  }
}
