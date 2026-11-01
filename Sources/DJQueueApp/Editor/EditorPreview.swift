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
      let s = bounds.width / visible.width
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      // Layer coordinates are bottom-left; `visible` is top-left.
      playerLayer.frame = CGRect(x: -visible.minX * s, y: -(source.height - visible.maxY) * s,
                                 width: source.width * s, height: source.height * s)
      CATransaction.commit()
    }
  }
}

/// Still-frame stand-in for the player (snapshot mode — ImageRenderer/caching can't draw AVPlayer).
struct EditorStillSurface: View {
  var image: CGImage?
  var source: CGSize
  var visible: CGRect
  var body: some View {
    EditorCroppedImage(image: image, crop: CropRect(x: visible.minX, y: visible.minY, w: visible.width, h: visible.height),
                       source: source)
  }
}

/// The centre canvas: the output-aspect preview (or, on the Frame tab, the whole frame with the crop window).
struct EditorPreview: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  @State private var cropDragStart: CropRect?
  @State private var textDrag: CGSize = .zero
  @State private var textDragStart: (x: Double, y: Double)?
  @State private var snapX = false
  @State private var snapY = false
  @State private var pinchStart: Double?

  private var frameMode: Bool { model.tab == .frame }

  var body: some View {
    GeometryReader { geo in
      let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 20)
      let full = fit(model.sourceSize, in: area)
      let out = fit(CGSize(width: model.edit.aspect.ratio, height: 1), in: area)
      let crop = model.crop
      let cropR = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
      let surface = frameMode ? full : out
      let visible = frameMode ? CGRect(origin: .zero, size: model.sourceSize) : cropR
      let s = full.width / model.sourceSize.width
      let window = CGRect(x: full.minX + cropR.minX * s, y: full.minY + cropR.minY * s,
                          width: cropR.width * s, height: cropR.height * s)
      let textRect = frameMode ? window : out

      ZStack(alignment: .topLeading) {
        Color.clear
        if model.fileMissing || model.video == nil {
          missingState.frame(width: geo.size.width, height: geo.size.height)
        } else {
          media(visible: visible)
            .frame(width: surface.width, height: surface.height)
            .offset(x: surface.minX, y: surface.minY)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)

          if frameMode { cropOverlay(full: full, window: window) }

          textLayer(in: textRect)

          if !frameMode && model.safeZonesVisible {
            EditorSafeZones(zone: model.safeZone)
              .frame(width: out.width, height: out.height)
              .offset(x: out.minX, y: out.minY)
              .allowsHitTesting(false)
          }
          if !frameMode && (snapX || snapY) { guides(in: out) }
          if !playback.ready { ProgressView().controlSize(.small).position(x: geo.size.width / 2, y: geo.size.height / 2) }
        }
      }
      .contentShape(Rectangle())
      .background(EditorScrollCatcher { dy in if frameMode { model.setZoom(model.zoom * (1 + dy * 0.01)) } })
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .topTrailing) { if !frameMode { safeZoneControl.padding(12) } }
    .overlay(alignment: .topLeading) { if frameMode { framingBadges.padding(12) } }
    .clipped()
  }

  // MARK: Media

  @ViewBuilder private func media(visible: CGRect) -> some View {
    if let p = playback.player, !model.snapshotMode {
      EditorPlayerSurface(player: p, source: model.sourceSize, visible: visible)
    } else {
      EditorStillSurface(image: playback.still, source: model.sourceSize, visible: visible)
    }
  }

  // MARK: Crop window (E.S1)

  private func cropOverlay(full: CGRect, window: CGRect) -> some View {
    ZStack(alignment: .topLeading) {
      Path { p in
        p.addRect(CGRect(x: full.minX, y: full.minY, width: full.width, height: max(0, window.minY - full.minY)))
        p.addRect(CGRect(x: full.minX, y: window.maxY, width: full.width, height: max(0, full.maxY - window.maxY)))
        p.addRect(CGRect(x: full.minX, y: window.minY, width: max(0, window.minX - full.minX), height: window.height))
        p.addRect(CGRect(x: window.maxX, y: window.minY, width: max(0, full.maxX - window.maxX), height: window.height))
      }
      .fill(Color.black.opacity(0.62))
      .allowsHitTesting(false)
      Path { p in
        for i in 1...2 {
          let x = window.minX + window.width * CGFloat(i) / 3, y = window.minY + window.height * CGFloat(i) / 3
          p.move(to: CGPoint(x: x, y: window.minY)); p.addLine(to: CGPoint(x: x, y: window.maxY))
          p.move(to: CGPoint(x: window.minX, y: y)); p.addLine(to: CGPoint(x: window.maxX, y: y))
        }
      }
      .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
      Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
        .frame(width: window.width, height: window.height)
        .offset(x: window.minX, y: window.minY)
      cornerHandles(window)
      Color.white.opacity(0.001)
        .frame(width: full.width, height: full.height)
        .offset(x: full.minX, y: full.minY)
        .gesture(cropDrag(scale: full.width / model.sourceSize.width))
        .simultaneousGesture(MagnifyGesture()
          .onChanged { v in
            if pinchStart == nil { pinchStart = model.zoom }
            model.setZoom((pinchStart ?? 1) * v.magnification)
          }
          .onEnded { _ in pinchStart = nil })
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
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

  private var framingBadges: some View {
    HStack(spacing: 6) {
      if model.upscale > 1.01 {
        EditorPill(text: String(format: "Upscaled %.1f×", model.upscale), color: .orange, systemImage: "exclamationmark.triangle.fill")
      }
      if !model.cropIsSet {
        EditorPill(text: "Crop not set", color: .orange)
        Button("Use this crop") { model.confirmCrop() }.controlSize(.small).buttonStyle(.borderedProminent)
      }
    }
  }

  // MARK: Text (E.S5 — the TextOverlay PNG at preview scale, draggable)

  @ViewBuilder private func textLayer(in r: CGRect) -> some View {
    if let img = model.overlay {
      let visible = model.textVisible(at: playback.time) || model.tab == .text || textDragStart != nil
      Image(decorative: img, scale: 1).resizable()
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX + textDrag.width, y: r.minY + textDrag.height)
        .opacity(visible ? (model.textVisible(at: playback.time) ? 1 : 0.45) : 0)
        .allowsHitTesting(false)
      if !frameMode, let b = model.textBoundsUnit {
        let hit = CGRect(x: r.minX + b.minX * r.width + textDrag.width, y: r.minY + b.minY * r.height + textDrag.height,
                         width: b.width * r.width, height: b.height * r.height)
        Rectangle()
          .strokeBorder(Color.accentColor.opacity(model.tab == .text || textDragStart != nil ? 0.9 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .contentShape(Rectangle())
          .frame(width: hit.width, height: hit.height)
          .offset(x: hit.minX, y: hit.minY)
          .gesture(textDragGesture(size: r.size))
          .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
          .help("Drag to move the text")
      }
    }
  }

  private func textDragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { v in
        if textDragStart == nil { textDragStart = (model.resolved.posX, model.resolved.posY) }
        guard let st = textDragStart else { return }
        let (nx, sx) = EditorGeometry.snapCentre(st.x + v.translation.width / size.width)
        let (ny, sy) = EditorGeometry.snapCentre(st.y + v.translation.height / size.height)
        snapX = sx; snapY = sy
        textDrag = CGSize(width: (nx - st.x) * size.width, height: (ny - st.y) * size.height)
      }
      .onEnded { _ in
        guard let st = textDragStart else { return }
        let nx = min(max(st.x + textDrag.width / size.width, 0.05), 0.95)
        let ny = min(max(st.y + textDrag.height / size.height, 0.05), 0.95)
        model.updateVersion { $0.posX = nx; $0.posY = ny }
        textDrag = .zero; textDragStart = nil; snapX = false; snapY = false
      }
  }

  private func guides(in r: CGRect) -> some View {
    Path { p in
      if snapX { p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)) }
      if snapY { p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
    }
    .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    .allowsHitTesting(false)
  }

  // MARK: Safe zones (E.S6)

  private var safeZoneControl: some View {
    HStack(spacing: 4) {
      Toggle(isOn: Binding(get: { model.safeZonesVisible }, set: { model.safeZonesWanted = $0 })) {
        Label("Safe zones", systemImage: "rectangle.dashed")
      }
      .toggleStyle(.button)
      .disabled(model.tab == .text)
      .help(model.tab == .text ? "Safe zones stay on while editing text" : "Show platform UI")
      Picker("", selection: $model.safeZone) {
        ForEach(EditorSafeZone.allCases) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden().fixedSize()
    }
    .controlSize(.small)
    .padding(4)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: Missing file (E.states Er)

  private var missingState: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(.red)
      Text(model.video == nil ? "Video not found" : "File missing").font(.system(size: 15, weight: .semibold))
      if let u = model.fileURL {
        Text(u.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 420)
        Button("Show folder in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([u.deletingLastPathComponent()])
        }
      }
    }
  }

  private func fit(_ size: CGSize, in r: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, r.width > 0, r.height > 0 else { return .zero }
    let k = min(r.width / size.width, r.height / size.height)
    let w = (size.width * k).rounded(), h = (size.height * k).rounded()
    return CGRect(x: (r.midX - w / 2).rounded(), y: (r.midY - h / 2).rounded(), width: w, height: h)
  }
}

/// Translucent platform-UI overlay for a 9:16 frame (normalised to the preview box).
struct EditorSafeZones: View {
  var zone: EditorSafeZone
  var body: some View {
    GeometryReader { g in
      let W = g.size.width, H = g.size.height
      ZStack(alignment: .topLeading) {
        ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.red.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.red.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .frame(width: r.width * W, height: r.height * H)
            .offset(x: r.minX * W, y: r.minY * H)
        }
        Text("\(zone.rawValue) UI").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
          .padding(.horizontal, 5).padding(.vertical, 2).background(Color.red.opacity(0.55), in: Capsule())
          .offset(x: 6, y: rects.last.map { $0.minY * H + 6 } ?? 6)
      }
    }
  }
  /// Top bar, right rail, bottom caption area (normalised, top-left origin).
  private var rects: [CGRect] {
    switch zone {
    case .tiktok: [CGRect(x: 0, y: 0, width: 1, height: 0.085), CGRect(x: 0.855, y: 0.40, width: 0.145, height: 0.44),
                   CGRect(x: 0, y: 0.80, width: 1, height: 0.20)]
    case .reels: [CGRect(x: 0, y: 0, width: 1, height: 0.075), CGRect(x: 0.87, y: 0.50, width: 0.13, height: 0.36),
                  CGRect(x: 0, y: 0.82, width: 1, height: 0.18)]
    case .shorts: [CGRect(x: 0, y: 0, width: 1, height: 0.065), CGRect(x: 0.86, y: 0.48, width: 0.14, height: 0.36),
                   CGRect(x: 0, y: 0.78, width: 1, height: 0.22)]
    }
  }
}

/// Catches scroll-wheel / trackpad scroll over the canvas (zoom on the Frame tab).
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
