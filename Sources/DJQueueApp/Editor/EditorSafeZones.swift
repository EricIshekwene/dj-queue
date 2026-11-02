import DJQCore
import SwiftUI

/// Safe zones (#4): where each selected platform's UI covers the video, from `PlatformUI` (DESIGN-v2 §8 frame rects),
/// tinted per platform and labelled. Card platforms cover nothing; X crops portrait clips to ≈ 4:5, so it shows
/// the parts it cuts off.
struct EditorSafeZones: View {
  var platforms: Set<Platform>
  var aspect: Aspect

  private var ordered: [Platform] { EditorPlatforms.order.filter { platforms.contains($0) } }

  var body: some View {
    GeometryReader { g in
      let W = g.size.width, H = g.size.height
      ZStack(alignment: .topLeading) {
        ForEach(ordered, id: \.self) { p in
          let tint = p.editorZoneTint
          ForEach(Array(PlatformUI.overlays(p, aspect: aspect).enumerated()), id: \.offset) { _, e in
            if let r = e.frame {
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tint.opacity(0.24))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(tint.opacity(0.85), lineWidth: 1))
                .frame(width: r.width * W, height: r.height * H)
                .offset(x: r.minX * W, y: r.minY * H)
            }
          }
          if p == .x, let band = xCrop {
            hatch(tint).frame(width: W, height: band.minY * H)
            hatch(tint).frame(width: W, height: (1 - band.maxY) * H).offset(y: band.maxY * H)
          }
        }
        ForEach(Array(labels(W: W, H: H).enumerated()), id: \.offset) { _, l in
          label(l.text, tint: l.platform.editorZoneTint)
            .offset(x: l.point.x, y: l.point.y)
        }
      }
    }
  }

  /// X shows portrait clips at ≈ 4:5: the visible band, normalised (nil when the clip is already that wide).
  private var xCrop: CGRect? {
    guard let crop = PlatformUI.spec(.x).cardCrop, aspect.ratio < crop.ratio else { return nil }
    let h = aspect.ratio / crop.ratio
    return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
  }

  private func hatch(_ tint: Color) -> some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tint.opacity(0.14)))
      var p = Path()
      var x: CGFloat = -size.height
      while x < size.width { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 8 }
      ctx.stroke(p, with: .color(tint.opacity(0.45)), lineWidth: 1)
    }
  }

  private struct Label { var platform: Platform; var text: String; var point: CGPoint }

  /// One name tag per platform at the top-left of its lowest block (handle/caption), stacked upwards so they never
  /// overlap. Platforms that cover nothing get a note at the top.
  private func labels(W: CGFloat, H: CGFloat) -> [Label] {
    var out: [Label] = []
    var bottomY = CGFloat.infinity
    var topY: CGFloat = 8
    for p in ordered.reversed() {
      let blocks = PlatformUI.overlays(p, aspect: aspect).filter { [.handleRow, .caption, .musicTicker].contains($0.kind) }
      if let first = blocks.compactMap(\.frame).min(by: { $0.minY < $1.minY }) {
        var y = first.minY * H - 22
        if y > bottomY - 22 { y = bottomY - 22 }
        bottomY = y
        out.append(Label(platform: p, text: p.editorShortName, point: CGPoint(x: max(6, first.minX * W), y: max(4, y))))
      } else {
        let text: String
        switch p {
        case .x: text = xCrop == nil ? "X shows the whole video" : "X crops tall clips to 4:5"
        case .threads: text = "Threads shows the whole video"
        default: text = aspect == .r16x9 ? "\(p.editorShortName): 16:9 isn't a feed format" : "\(p.editorShortName): nothing over the picture"
        }
        let y = p == .x && xCrop != nil ? (xCrop!.minY * H + 6) : topY
        out.append(Label(platform: p, text: text, point: CGPoint(x: 6, y: y)))
        if !(p == .x && xCrop != nil) { topY += 24 }
      }
    }
    return out
  }

  private func label(_ text: String, tint: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(tint).frame(width: 6, height: 6)
      Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
    }
    .padding(.horizontal, 7).frame(height: 18)
    .background(Color.black.opacity(0.55), in: Capsule())
    .fixedSize()
  }
}

/// Multi-select safe-zone chips (all six or None) under the Zones canvas. Each chip carries its overlay tint as a
/// legend dot. Remembered per aspect (Settings → New clip defaults sets the starting selection).
struct EditorZoneChips: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    HStack(spacing: 6) {
      Text("Safe zones").font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
        .help("Show where each app's buttons and text cover the video (\(model.aspect.rawValue) clips remember their own choice)")
      chip(title: "None", tint: nil, selected: model.zonePlatforms.isEmpty) { model.zonePlatforms = [] }
      ForEach(EditorPlatforms.order) { p in
        chip(title: p.editorShortName, tint: p.editorZoneTint, selected: model.zonePlatforms.contains(p)) {
          var s = model.zonePlatforms
          if s.contains(p) { s.remove(p) } else { s.insert(p) }
          model.zonePlatforms = s
        }
        .help(model.zonePlatforms.contains(p) ? "Hide \(p.displayName)'s safe zones" : "Show \(p.displayName)'s safe zones")
      }
    }
  }

  /// DSChip anatomy (capsule, border.strong, selected = fill.selected + ring) with a tint legend dot.
  private func chip(title: String, tint: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
    EditorTintChip(title: title, tint: tint, selected: selected, action: action)
  }
}

struct EditorTintChip: View {
  var title: String
  var tint: Color?
  var selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button { dsWithAnimation { action() } } label: {
      HStack(spacing: 5) {
        if let tint {
          Circle().fill(selected ? tint : tint.opacity(0.35)).frame(width: 8, height: 8)
        } else if selected {
          Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
        }
        Text(title).lineLimit(1)
      }
      .font(DS.type.caption)
      .foregroundStyle(selected ? DS.color.text : DS.color.textSecondary)
      .padding(.horizontal, 10).frame(height: 26)
      .background(selected ? DS.color.selected : (hovering ? DS.color.hover : .clear), in: Capsule())
      .overlay(Capsule().strokeBorder(selected ? DS.color.text.opacity(0.35) : DS.color.borderStrong, lineWidth: selected ? 1.2 : 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}
