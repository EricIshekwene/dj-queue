import AVFoundation
import DJQCore
import SwiftUI

/// Status capsule (DESIGN.md: 11 pt semibold, tinted background).
struct EditorPill: View {
  var text: String
  var color: Color = .secondary
  var systemImage: String?
  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
      Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
    }
    .foregroundStyle(color)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.14)))
  }
}

/// Inspector section: small eyebrow title + content.
struct EditorSection<Content: View, Accessory: View>: View {
  var title: String
  @ViewBuilder var accessory: Accessory
  @ViewBuilder var content: Content
  init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
    self.title = title; self.accessory = accessory(); self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        accessory
      }
      content
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }
}

/// "from v1" marker for carried-forward fields (E.S4).
struct EditorInheritedTag: View {
  var from: Int?
  var body: some View {
    if let from {
      Text("from v\(from)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
    }
  }
}

/// Monochrome platform badge (short name in a rounded square).
struct EditorPlatformBadge: View {
  var platform: Platform
  var color: Color = .secondary
  var body: some View {
    Text(platform.shortName).font(.system(size: 9, weight: .bold, design: .rounded))
      .frame(width: 20, height: 16)
      .foregroundStyle(color)
      .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
  }
}

/// Multi-line text field with a placeholder (TextEditor has none on macOS).
struct EditorTextArea: View {
  @Binding var text: String
  var placeholder: String
  var height: CGFloat
  var secondary = false
  var body: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .font(.system(size: 13))
        .foregroundStyle(secondary ? .secondary : .primary)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 4).padding(.vertical, 6)
      if text.isEmpty {
        Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
          .padding(.horizontal, 9).padding(.vertical, 6)
          .allowsHitTesting(false)
      }
    }
    .frame(height: height)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
  }
}

/// Wrapping layout for chips.
struct EditorFlowLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = proposal.width ?? 280
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
    for s in subviews {
      let z = s.sizeThatFits(.unspecified)
      if x > 0, x + z.width > w { x = 0; y += row + spacing; row = 0 }
      x += z.width + spacing
      row = max(row, z.height)
    }
    return CGSize(width: w, height: y + row)
  }
  func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = b.minX, y = b.minY, row: CGFloat = 0
    for s in subviews {
      let z = s.sizeThatFits(.unspecified)
      if x > b.minX, x + z.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
      s.place(at: CGPoint(x: x, y: y), proposal: .init(z))
      x += z.width + spacing
      row = max(row, z.height)
    }
  }
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
    let k = CGFloat(image.width) / source.width
    let r = CGRect(x: c.x * k, y: c.y * k, width: c.w * k, height: c.h * k).integral
    return image.cropping(to: r) ?? image
  }
}

/// Async, cached frame strips (AVAssetImageGenerator, tolerant seeks, small size).
@MainActor
final class EditorFrameStrip: ObservableObject {
  @Published private(set) var frames: [(time: Double, image: CGImage)] = []
  @Published private(set) var loading = false
  private static var cache: [String: [(Double, CGImage)]] = [:]
  private var task: Task<Void, Never>?

  func load(url: URL?, from a: Double, to b: Double, count: Int, sync: Bool = false) {
    task?.cancel()
    guard let url, b > a, count > 0 else { frames = []; return }
    let key = "\(url.path)|\(Int(a * 10))|\(Int(b * 10))|\(count)"
    if let c = Self.cache[key] { frames = c.map { (time: $0.0, image: $0.1) }; return }
    let times = (0..<count).map { a + (b - a) * (Double($0) + 0.5) / Double(count) }
    if sync {
      let out = Self.generate(url: url, times: times)
      Self.cache[key] = out
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
    Self.cache[key] = out
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
    return times.compactMap { t in
      (try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)).map { (t, $0) }
    }
  }
}
