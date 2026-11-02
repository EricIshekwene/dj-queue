import AVFoundation
import AppKit
import DJQCore
import SwiftUI

/// AVPlayerLayer inside a clipping view. `visible` (source pixels) is scaled to fill the view's
/// bounds, so the crop rect fills the preview exactly like the export.
struct EditorPlayerSurface: NSViewRepresentable {
  var player: AVPlayer
  var source: CGSize
  var visible: CGRect

  func makeNSView(context: Context) -> SurfaceView {
    let v = SurfaceView()
    v.playerLayer.player = player
    return v
  }

  func updateNSView(_ v: SurfaceView, context: Context) {
    if v.playerLayer.player !== player { v.playerLayer.player = player }
    v.source = source
    v.visible = visible
    v.needsLayout = true
  }

  final class SurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    var source = CGSize(width: 3840, height: 2160)
    var visible = CGRect(x: 0, y: 0, width: 3840, height: 2160)

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer = CALayer()
      layer?.masksToBounds = true
      layer?.backgroundColor = NSColor.black.cgColor
      playerLayer.videoGravity = .resize
      layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // SwiftUI overlays handle gestures

    override func layout() {
      super.layout()
      guard visible.width > 0 else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      // Layer coordinates are bottom-left; `visible` is top-left.
      playerLayer.frame = EditorGeometry.pictureFrame(visible: visible, source: source, bounds: bounds.size)
      CATransaction.commit()
    }
  }
}

/// Still-frame stand-in for the player (snapshot mode — window snapshots can't draw AVPlayer).
struct EditorStillSurface: View {
  var image: CGImage?
  var source: CGSize
  var visible: CGRect
  var body: some View {
    EditorCroppedImage(image: image, crop: CropRect(x: visible.minX, y: visible.minY, w: visible.width, h: visible.height),
                       source: source)
  }
}

/// The clip's output frame: the cropped live video (or still) + the TextOverlay PNG while the text shows.
/// Fills whatever frame it's given — callers size it at the output aspect (preview == export).
struct EditorOutputMedia: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  /// Zones mode: text outside its timing stays visible, dimmed, so it can be positioned.
  var dimHiddenText = false
  /// Live offset while the text is dragged.
  var textOffset: CGSize = .zero

  var body: some View {
    let c = model.crop
    let visible = CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
    ZStack {
      if let p = playback.player, !model.snapshotMode {
        EditorPlayerSurface(player: p, source: model.sourceSize, visible: visible)
      } else {
        EditorStillSurface(image: playback.still, source: model.sourceSize, visible: visible)
      }
      if let img = model.overlay {
        let on = model.textVisible(at: playback.time) || textOffset != .zero
        Image(decorative: img, scale: 1).resizable()
          .offset(textOffset)
          .opacity(on ? 1 : (dimHiddenText ? 0.45 : 0))
      }
    }
    .clipped()
  }
}

// MARK: - Canvas

/// The centre canvas (`bg.canvas`): a Frame · Zones · Preview switch on top, the picture in the middle, and the
/// mode's chips underneath.
struct EditorCanvas: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback

  var body: some View {
    VStack(spacing: DS.space.sm) {
      DSSegmented(selection: $model.canvasMode, segments: [
        DSSegment(value: EditorCanvasMode.frame, title: "Frame", icon: "crop"),
        DSSegment(value: .zones, title: "Zones", icon: "rectangle.dashed"),
        DSSegment(value: .preview, title: "Preview", icon: "iphone"),
      ], size: .sm)
      .dsTooltip("Switch view: crop, safe zones or phone preview")
      .padding(.top, DS.space.sm)

      Group {
        if model.loading {
          DSSpinner(size: 18)
        } else if model.fileMissing || model.video == nil {
          missingState
        } else {
          switch model.canvasMode {
          case .frame: EditorFrameCanvas(model: model, playback: playback)
          case .zones: EditorZonesCanvas(model: model, playback: playback)
          case .preview: EditorPreviewCanvas(model: model, playback: playback)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      bottomBar.frame(height: 34).padding(.bottom, DS.space.xs)
    }
    .padding(.horizontal, DS.space.md)
  }

  @ViewBuilder private var bottomBar: some View {
    if model.loading || model.fileMissing || model.video == nil {
      Color.clear
    } else {
      switch model.canvasMode {
      case .frame: frameBar
      case .zones: EditorZoneChips(model: model)
      case .preview: EditorPreviewBar(model: model)
      }
    }
  }

  private var frameBar: some View {
    HStack(spacing: DS.space.xs) {
      if model.upscale > 1.01 {
        DSBadge(String(format: "Upscaled %.1f×", model.upscale), style: .soft(.warning), icon: "exclamationmark.triangle.fill")
      }
      if model.cropIsSet {
        DSBadge("Crop confirmed", style: .soft(.success), icon: "checkmark")
      } else {
        Text("Drag to move · scroll or pinch to zoom").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        DSButton("Use this crop", icon: "checkmark", variant: .outline, size: .sm,
                 disabledReason: model.readOnly ? "Editing is off for this clip" : nil,
                 tooltip: "Confirm this framing") { model.confirmCrop() }
      }
    }
  }

  private var missingState: some View {
    VStack(spacing: DS.space.sm) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 20, weight: .medium)).foregroundStyle(DS.color.danger)
        .frame(width: 40, height: 40).background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm))
      Text(model.video == nil ? "Clip not found" : "File missing").font(DS.type.headline).foregroundStyle(DS.color.text)
      if let u = model.fileURL {
        Text(u.path).font(DS.type.mono).foregroundStyle(DS.color.textSecondary)
          .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 420)
        DSButton("Show folder in Finder", variant: .outline, size: .sm, tooltip: "Open the folder where the file should be") {
          NSWorkspace.shared.activateFileViewerSelecting([u.deletingLastPathComponent()])
        }
      }
    }
  }
}

func editorFit(_ size: CGSize, in r: CGRect) -> CGRect {
  guard size.width > 0, size.height > 0, r.width > 0, r.height > 0 else { return .zero }
  let k = min(r.width / size.width, r.height / size.height)
  let w = (size.width * k).rounded(), h = (size.height * k).rounded()
  return CGRect(x: (r.midX - w / 2).rounded(), y: (r.midY - h / 2).rounded(), width: w, height: h)
}

// MARK: - Frame mode (E.S1: crop window on the dimmed full source)

struct EditorFrameCanvas: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  @State private var cropDragStart: CropRect?
  @State private var pinchStart: Double?

  var body: some View {
    GeometryReader { geo in
      let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8)
      let full = editorFit(model.sourceSize, in: area)
      let c = model.crop
      let s = full.width / max(model.sourceSize.width, 1)
      let window = CGRect(x: full.minX + c.x * s, y: full.minY + c.y * s, width: c.w * s, height: c.h * s)
      ZStack(alignment: .topLeading) {
        Color.clear
        Group {
          if let p = playback.player, !model.snapshotMode {
            EditorPlayerSurface(player: p, source: model.sourceSize, visible: CGRect(origin: .zero, size: model.sourceSize))
          } else {
            EditorStillSurface(image: playback.still, source: model.sourceSize, visible: CGRect(origin: .zero, size: model.sourceSize))
          }
        }
        .frame(width: full.width, height: full.height)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        .offset(x: full.minX, y: full.minY)
        if let img = model.overlay, model.textVisible(at: playback.time) {
          Image(decorative: img, scale: 1).resizable()
            .frame(width: window.width, height: window.height).offset(x: window.minX, y: window.minY)
            .allowsHitTesting(false)
        }
        cropOverlay(full: full, window: window)
      }
      .contentShape(Rectangle())
      .background(EditorScrollCatcher { dy in model.setZoom(model.zoom * (1 + dy * 0.01)) })
    }
  }

  private func cropOverlay(full: CGRect, window: CGRect) -> some View {
    ZStack(alignment: .topLeading) {
      Path { p in
        p.addRect(CGRect(x: full.minX, y: full.minY, width: full.width, height: max(0, window.minY - full.minY)))
        p.addRect(CGRect(x: full.minX, y: window.maxY, width: full.width, height: max(0, full.maxY - window.maxY)))
        p.addRect(CGRect(x: full.minX, y: window.minY, width: max(0, window.minX - full.minX), height: window.height))
        p.addRect(CGRect(x: window.maxX, y: window.minY, width: max(0, full.maxX - window.maxX), height: window.height))
      }
      .fill(Color.black.opacity(0.6))
      .allowsHitTesting(false)
      Path { p in
        for i in 1...2 {
          let x = window.minX + window.width * CGFloat(i) / 3, y = window.minY + window.height * CGFloat(i) / 3
          p.move(to: CGPoint(x: x, y: window.minY)); p.addLine(to: CGPoint(x: x, y: window.maxY))
          p.move(to: CGPoint(x: window.minX, y: y)); p.addLine(to: CGPoint(x: window.maxX, y: y))
        }
      }
      .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
      .allowsHitTesting(false)
      RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white, lineWidth: 1.5)
        .frame(width: window.width, height: window.height)
        .offset(x: window.minX, y: window.minY)
        .allowsHitTesting(false)
      cornerHandles(window).allowsHitTesting(false)
      Color.white.opacity(0.001)
        .frame(width: full.width, height: full.height)
        .offset(x: full.minX, y: full.minY)
        .gesture(cropDrag(scale: full.width / max(model.sourceSize.width, 1)))
        .simultaneousGesture(MagnifyGesture()
          .onChanged { v in
            if pinchStart == nil { pinchStart = model.zoom }
            model.setZoom((pinchStart ?? 1) * v.magnification)
          }
          .onEnded { _ in pinchStart = nil })
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .dsTooltip("Drag to move the crop; scroll or pinch to zoom")
    }
  }

  private func cornerHandles(_ r: CGRect) -> some View {
    let L: CGFloat = 14
    return Path { p in
      for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                          (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
        p.move(to: CGPoint(x: c.x + L * dx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + L * dy))
      }
    }
    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
  }

  private func cropDrag(scale: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { v in
        if cropDragStart == nil { cropDragStart = model.crop }
        guard var c = cropDragStart else { return }
        c.x += v.translation.width / scale
        c.y += v.translation.height / scale
        model.setCrop(c)
      }
      .onEnded { _ in cropDragStart = nil }
  }
}

// MARK: - Zones mode (output preview + per-platform safe zones + draggable text)

struct EditorZonesCanvas: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  @State private var textDrag: CGSize = .zero
  @State private var textDragStart: (x: Double, y: Double, ex: Double, ey: Double)?
  @State private var textDragValue: (x: Double, y: Double)?
  @State private var snapX = false
  @State private var snapY = false
  /// Pointer over the text: shows the dashed outline so the drag target is visible before dragging.
  @State private var textHover = false

  var body: some View {
    GeometryReader { geo in
      let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 4)
      let out = editorFit(CGSize(width: model.aspect.ratio, height: 1), in: area)
      ZStack(alignment: .topLeading) {
        Color.clear
        EditorOutputMedia(model: model, playback: playback, dimHiddenText: true, textOffset: textDrag)
          .frame(width: out.width, height: out.height)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
          .dsElevation(DS.elevation.e1)
          .offset(x: out.minX, y: out.minY)
        EditorSafeZones(platforms: model.zonePlatforms, aspect: model.aspect)
          .frame(width: out.width, height: out.height)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
          .offset(x: out.minX, y: out.minY)
          .allowsHitTesting(false)
        textHandle(in: out)
        if snapX || snapY { guides(in: out) }
        if !playback.ready { DSSpinner(size: 16).position(x: geo.size.width / 2, y: geo.size.height / 2) }
      }
    }
  }

  @ViewBuilder private func textHandle(in r: CGRect) -> some View {
    if let b = model.textBoundsUnit, !model.readOnly {
      let hit = CGRect(x: r.minX + b.minX * r.width + textDrag.width, y: r.minY + b.minY * r.height + textDrag.height,
                       width: b.width * r.width, height: b.height * r.height)
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(Color.white.opacity(textDragStart != nil ? 0.95 : textHover ? 0.6 : 0.0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .contentShape(Rectangle())
        .frame(width: hit.width, height: hit.height)
        .offset(x: hit.minX, y: hit.minY)
        .gesture(textDragGesture(size: r.size))
        .onHover { inside in
          textHover = inside
          if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .dsTooltip("Drag to move the text")
    }
  }

  private func textDragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { v in
        if textDragStart == nil, let b = model.textBoundsUnit {
          textDragStart = (Double(b.midX), Double(b.midY), Double(b.width), Double(b.height))
        }
        guard let st = textDragStart else { return }
        let (nx, sx) = EditorGeometry.textCentre(st.x + v.translation.width / size.width, extent: st.ex)
        let (ny, sy) = EditorGeometry.textCentre(st.y + v.translation.height / size.height, extent: st.ey)
        snapX = sx; snapY = sy
        textDragValue = (nx, ny)
        textDrag = CGSize(width: (nx - st.x) * size.width, height: (ny - st.y) * size.height)
      }
      .onEnded { _ in
        if let v = textDragValue { model.updateVersion { $0.posX = v.x; $0.posY = v.y } }
        textDrag = .zero; textDragStart = nil; textDragValue = nil; snapX = false; snapY = false
      }
  }

  private func guides(in r: CGRect) -> some View {
    Path { p in
      if snapX { p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)) }
      if snapY { p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
    }
    .stroke(DS.color.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    .allowsHitTesting(false)
  }
}

// MARK: - Preview mode (phone mocks)

struct EditorPreviewCanvas: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback

  private var platforms: [Platform] {
    guard model.compare else { return [model.previewPlatform] }
    let list = EditorPlatforms.order
    let i = list.firstIndex(of: model.previewPlatform) ?? 0
    return (0..<3).map { list[(i + $0) % list.count] }
  }

  var body: some View {
    GeometryReader { geo in
      let n = CGFloat(platforms.count)
      let gap: CGFloat = 28
      let byHeight = geo.size.height * 9 / 19.5
      let byWidth = (geo.size.width - gap * (n - 1)) / n
      let w = min(byHeight, byWidth, model.compare ? 300 : 320)
      HStack(alignment: .top, spacing: gap) {
        ForEach(platforms, id: \.self) { p in
          VStack(spacing: 6) {
            EditorPhoneMock(content: model.phoneContent(p)) {
              EditorOutputMedia(model: model, playback: playback)
            }
            .frame(width: w)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            if model.compare {
              Text(p.displayName + (model.posting(p) ? "" : " · not posting"))
                .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
            }
          }
          .onTapGesture { if model.compare { model.previewPlatform = p } }
          .dsTooltip(model.compare && p != model.previewPlatform ? "Start the comparison from \(p.displayName)" : nil)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }
}

struct EditorPreviewBar: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    HStack(spacing: DS.space.xs) {
      DSIconButton("chevron.left", tooltip: "Previous platform", variant: .ghost, size: .sm) { model.stepPreview(-1) }
      ForEach(EditorPlatforms.order) { p in
        DSChip(p.editorShortName, icon: p == .x ? nil : p.dsSymbol, isSelected: model.previewPlatform == p, showsCheck: false, size: .sm) {
          model.previewPlatform = p
        }
        .dsTooltip(model.posting(p) ? "Preview on \(p.displayName)" : "Preview on \(p.displayName) (not posting there)")
      }
      DSIconButton("chevron.right", tooltip: "Next platform", variant: .ghost, size: .sm) { model.stepPreview(1) }
      DSSeparator(vertical: true).frame(height: 18).padding(.horizontal, 4)
      DSSegmented(selection: $model.compare, segments: [
        DSSegment(value: false, title: "One"), DSSegment(value: true, title: "Compare 3"),
      ], size: .sm)
      .dsTooltip("Show one phone, or three side by side")
    }
  }
}

/// Catches scroll-wheel / trackpad scroll over the canvas (zoom in Frame mode).
struct EditorScrollCatcher: NSViewRepresentable {
  var onScroll: (CGFloat) -> Void
  func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onScroll = onScroll; return v }
  func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }
  final class CatcherView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
        guard let self, let w = self.window, e.window === w else { return e }
        let p = self.convert(e.locationInWindow, from: nil)
        guard self.bounds.contains(p) else { return e }
        self.onScroll?(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8))
        return nil
      }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
  }
}
