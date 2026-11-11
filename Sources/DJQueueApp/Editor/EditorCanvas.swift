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

/// The clip's output frame: the cropped live video (or still) + each text's TextOverlay PNG while it shows, stacked in list
/// order. Fills whatever frame it's given — callers size it at the output aspect (preview == export).
struct EditorOutputMedia: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  /// Zones mode: the selected text outside its timing stays visible, dimmed, so it can be positioned.
  var dimHiddenText = false
  /// The text being dragged and its live offset.
  var dragging: String? = nil
  var textOffset: CGSize = .zero

  var body: some View {
    let c = model.crop
    let visible = CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
    ZStack {
      if model.isPhoto {
        EditorPhotoSurface(model: model, playback: playback, images: model.photoImages)
      } else if let p = playback.player, !model.snapshotMode {
        EditorPlayerSurface(player: p, source: model.sourceSize, visible: visible)
      } else {
        EditorStillSurface(image: playback.still, source: model.sourceSize, visible: visible)
      }
      ForEach(model.textImages) { t in
        let moving = t.id == dragging
        let on = t.shows(at: playback.time) || moving
        Image(decorative: t.image, scale: 1).resizable()
          .offset(moving ? textOffset : .zero)
          .opacity(on ? 1 : (dimHiddenText && t.id == model.selectedText ? 0.45 : 0))
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
        DSSegment(value: EditorCanvasMode.frame, title: "Frame", icon: "crop",
                  tooltip: model.isPhoto ? "Crop this photo to the post's shape" : "Crop the 9:16 frame on the 4K source"),
        DSSegment(value: .zones, title: "Zones", icon: "rectangle.dashed", tooltip: "Check text against each platform's UI zones"),
        DSSegment(value: .preview, title: "Preview", icon: "iphone", tooltip: "See it in a phone mock with the real caption"),
      ], size: .sm)
      .padding(.top, DS.space.sm)
      .background(ScriptAnchor("Canvas mode"))

      Group {
        if model.loading {
          DSSpinner(size: 18)
        } else if model.video == nil || (model.isPhoto ? model.currentPhotoMissing : model.fileMissing) {
          // A photo post says which photo is gone, and still shows the ones that are there.
          missingState
        } else if model.isPhoto && model.photos.isEmpty {
          noPhotosState
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
    if model.loading || model.video == nil || (model.isPhoto ? model.currentPhotoMissing || model.photos.isEmpty : model.fileMissing) {
      Color.clear
    } else {
      switch model.canvasMode {
      case .frame: if model.isPhoto { EditorPhotoFrameBar(model: model) } else { frameBar }
      case .zones: EditorZoneChips(model: model)
      case .preview: EditorPreviewBar(model: model)
      }
    }
  }

  private var frameBar: some View {
    HStack(spacing: DS.space.xs) {
      if model.upscale > 1.01 {
        DSBadge(String(format: "Upscaled %.1f×", model.upscale), style: .soft(.warning), icon: "exclamationmark.triangle.fill",
                help: "Zoomed past the source's resolution — it may look soft")
      }
      if model.cropIsSet {
        DSBadge("Crop confirmed", style: .soft(.success), icon: "checkmark", help: "This frame is saved as the clip's crop")
      } else {
        Text("Drag to move · scroll or pinch to zoom").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        DSButton("Use this crop", icon: "checkmark", variant: .outline, size: .sm,
                 disabledReason: model.readOnly ? "Editing is off for this clip" : nil,
                 tooltip: "Confirm this framing") { model.confirmCrop() }
      }
    }
  }

  /// A photo post whose photo list is empty (a broken row; the app can't make one): the strip's Add tile fixes it.
  private var noPhotosState: some View {
    VStack(spacing: DS.space.sm) {
      Image(systemName: "photo.badge.plus").font(.system(size: 20, weight: .medium)).foregroundStyle(DS.color.textSecondary)
        .frame(width: 40, height: 40).background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm))
      Text("No photos in this post").font(DS.type.headline).foregroundStyle(DS.color.text)
      Text("Add one with the Add tile below.").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
    }
  }

  private var missingState: some View {
    VStack(spacing: DS.space.sm) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 20, weight: .medium)).foregroundStyle(DS.color.danger)
        .frame(width: 40, height: 40).background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm))
      Text(model.video == nil ? "Clip not found" : model.isPhoto ? "Photo \(model.photoIndex + 1)'s file is missing" : "File missing")
        .font(DS.type.headline).foregroundStyle(DS.color.text)
      if model.isPhoto && model.video != nil {
        Text("Put the file back, or remove this photo from the strip below.").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
      }
      if let u = model.isPhoto ? model.currentPhotoURL : model.fileURL {
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
        ForEach(model.textImages.filter { $0.shows(at: playback.time) }) { t in
          Image(decorative: t.image, scale: 1).resizable()
            .frame(width: window.width, height: window.height).offset(x: window.minX, y: window.minY)
            .allowsHitTesting(false)
        }
        cropOverlay(full: full, window: window)
      }
      .contentShape(Rectangle())
      .background(EditorScrollCatcher { dy in model.setZoom(model.zoom * (1 + dy * 0.01)) })
      // A photo's crop surface is an AppKit view, which takes the drag; the pinch is recognised here around it. A clip
      // keeps its own pinch on its surface (`including: .subviews` leaves this one out).
      .simultaneousGesture(MagnifyGesture()
        .onChanged { v in
          if pinchStart == nil { pinchStart = model.zoom }
          model.setZoom((pinchStart ?? 1) * v.magnification)
        }
        .onEnded { _ in pinchStart = nil }, including: model.isPhoto ? .all : .subviews)
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
      if model.isPhoto {
        // Round 21: the same drag through AppKit, so a check can send it to the window (a SwiftUI gesture never sees
        // those events). Pinch is on the whole canvas, below.
        photoCropSurface(scale: full.width / max(model.sourceSize.width, 1))
          .frame(width: full.width, height: full.height)
          .probeFrame("frame-source")
          .dsTooltip("Drag to move the crop; scroll or pinch to zoom")
          .offset(x: full.minX, y: full.minY)
      } else {
        videoCropSurface(full: full)
      }
    }
  }

  private func photoCropSurface(scale: CGFloat) -> some View {
    EditorDragSurface(cursor: .openHand, onPress: { cropDragStart = model.crop }, onDrag: { d in
      guard var c = cropDragStart else { return }
      c.x += d.width / scale
      c.y += d.height / scale
      model.setCrop(c)
    }, onRelease: { _ in cropDragStart = nil })
  }

  private func videoCropSurface(full: CGRect) -> some View {
    Group {
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
  /// The text under a press, where its block started, and what it would drop at.
  @State private var drag: (id: String, x: Double, y: Double, ex: Double, ey: Double)?
  @State private var textDragValue: (x: Double, y: Double)?
  @State private var snapX = false
  @State private var snapY = false
  /// The text under the pointer: shows the dashed outline so the drag target is visible before dragging.
  @State private var hovered: String?

  var body: some View {
    GeometryReader { geo in
      let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 4)
      let out = editorFit(CGSize(width: model.aspect.ratio, height: 1), in: area)
      ZStack(alignment: .topLeading) {
        Color.clear
        EditorOutputMedia(model: model, playback: playback, dimHiddenText: !model.plainCanvasForScript, dragging: drag?.id, textOffset: textDrag)
          .frame(width: out.width, height: out.height)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
          .dsElevation(DS.elevation.e1)
          .probeFrame("canvas-output")
          .offset(x: out.minX, y: out.minY)
        EditorSafeZones(platforms: model.zonePlatforms, aspect: model.aspect)
          .frame(width: out.width, height: out.height)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
          .offset(x: out.minX, y: out.minY)
          .allowsHitTesting(false)
        // The selected text when it's hidden goes under the rest, then the showing ones in stacking order: the pointer goes to
        // what's on screen, topmost first.
        if !model.readOnly && !model.plainCanvasForScript {
          let on = model.textImages.filter { $0.shows(at: playback.time) }
          let dimmed = model.textImages.filter { !$0.shows(at: playback.time) && ($0.id == model.selectedText || $0.id == drag?.id) }
          ForEach(dimmed + on) { t in textHandle(t, in: out) }
        }
        if snapX || snapY { guides(in: out) }
        if !playback.ready { DSSpinner(size: 16).position(x: geo.size.width / 2, y: geo.size.height / 2) }
      }
    }
  }

  private func textHandle(_ t: EditorTextImage, in r: CGRect) -> some View {
    let b = t.bounds
    let moving = drag?.id == t.id
    let shift = moving ? textDrag : .zero
    let hit = CGRect(x: r.minX + b.minX * r.width + shift.width, y: r.minY + b.minY * r.height + shift.height,
                     width: b.width * r.width, height: b.height * r.height)
    let chosen = model.texts.count > 1 && t.id == model.selectedText
    return RoundedRectangle(cornerRadius: 4)
      .strokeBorder(Color.white.opacity(moving ? 0.95 : chosen ? 0.75 : hovered == t.id ? 0.6 : 0.0), style: StrokeStyle(lineWidth: 1, dash: chosen && !moving ? [] : [4, 3]))
      .contentShape(Rectangle())
      .frame(width: hit.width, height: hit.height)
      .overlay { textSurface(t, size: r.size) }
      .probeFrame("canvas-text-\(t.id)")
      .onHover { inside in hovered = inside ? t.id : (hovered == t.id ? nil : hovered) }
      .dsTooltip("Drag to move the text")
      .offset(x: hit.minX, y: hit.minY)
  }

  private func textSurface(_ t: EditorTextImage, size: CGSize) -> some View {
    EditorDragSurface(cursor: .openHand, onPress: {
      // A text removed mid-drag never saw its release, so nothing from that drag may carry over.
      textDrag = .zero
      textDragValue = nil
      let b = t.bounds
      drag = (t.id, Double(b.midX), Double(b.midY), Double(b.width), Double(b.height))
      model.selectText(t.id)
    }, onDrag: { v in
      guard let st = drag else { return }
      let (nx, sx) = EditorGeometry.textCentre(st.x + v.width / size.width, extent: st.ex)
      let (ny, sy) = EditorGeometry.textCentre(st.y + v.height / size.height, extent: st.ey)
      snapX = sx; snapY = sy
      textDragValue = (nx, ny)
      textDrag = CGSize(width: (nx - st.x) * size.width, height: (ny - st.y) * size.height)
    }, onRelease: { _ in
      if let v = textDragValue { model.moveText(t.id, x: v.x, y: v.y) } else { model.scrollTarget = .text }
      textDrag = .zero; drag = nil; textDragValue = nil; snapX = false; snapY = false
    })
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
    let list = model.previewOrder
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
      ForEach(model.previewOrder) { p in
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
