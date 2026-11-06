import AppKit
import DJQCore
import SwiftUI

/// One crop offset for the selected clips (round 15), then a flip through each: the whole frame with the crop on it, and the clip
/// as it will post beside it. The slider moves every clip; dragging the crop moves this clip alone. Nothing is written until
/// Apply, which is one batch with one Undo.
struct BulkCropDialog: View {
  @Bindable var model: AppModel
  let ids: [String]
  @State private var change = CropChange()
  @State private var previews: [CropPreview] = []
  @State private var index = 0
  @State private var job: Task<Void, Never>?
  @State private var frames: [String: CGImage] = [:]
  @State private var loaded = false

  private static let reach = 0.40

  var body: some View {
    DSDialog("Crop for \(AppModel.pipelineClips(ids.count))", description: "Move them all, then check each one. Drag a crop to change just that clip",
             icon: "crop", width: 720, onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        stage
        walker
        slider
        notes
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, shortcut: "esc", action: close)
        .keyboardShortcut(.cancelAction)
      DSButton(verb, variant: .primary, disabledReason: disabledReason, tooltip: "You can undo this", shortcut: "↩", action: apply)
        .keyboardShortcut(.defaultAction)
        .background(ScriptAnchor("Apply crop"))
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .onAppear(perform: load)
    .onChange(of: change) { _, _ in refresh() }
    .onChange(of: index) { _, _ in loadFrames() }
  }

  private var current: CropPreview? { previews.indices.contains(index) ? previews[index] : previews.first }
  private var changing: Int { previews.filter(\.changes).count }
  private var verb: String { "Apply to \(AppModel.pipelineClips(max(changing, 1)))" }
  private var disabledReason: String? {
    if !loaded { return "Checking these clips…" }
    return changing == 0 ? "Nothing would change" : nil
  }

  private static func label(_ offset: Double) -> String {
    let pct = Int((abs(offset) * 100).rounded())
    return pct == 0 ? "Centre" : "\(offset < 0 ? "Left" : "Right") \(pct)%"
  }

  // MARK: The frame and the output

  @ViewBuilder private var stage: some View {
    HStack(alignment: .top, spacing: DS.space.md) {
      CropFrameView(image: current.flatMap { frames[$0.id] }, source: current?.source, crop: current?.crop,
                    canDrag: current?.skipped == nil, onMove: moveThisClip)
        .frame(width: 496, height: 279)
        .background(ScriptAnchor("Crop frame"))
      output.frame(width: 157, height: 279)
    }
  }

  /// The clip as it will post, fitted inside a fixed box, so any aspect stays put.
  private var output: some View {
    ZStack {
      if let p = current, let image = frames[p.id], let source = p.source, let crop = p.crop, crop.h > 0,
         let cut = Self.cut(image, crop, source: source) {
        ZStack {
          Image(decorative: cut, scale: 1).resizable()
          if let v = model.video(p.id), let overlay = model.clipPreview(v).overlay {
            Image(decorative: overlay, scale: 1).resizable()
          }
        }
        .aspectRatio(crop.w / crop.h, contentMode: .fit)
        .clipped()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
  }

  /// The crop out of a frame that may be smaller than the source.
  static func cut(_ image: CGImage, _ crop: CropRect, source: CGSize) -> CGImage? {
    let k = CGFloat(image.width) / source.width
    return image.cropping(to: CGRect(x: crop.x * k, y: crop.y * k, width: crop.w * k, height: crop.h * k).integral)
  }

  private func moveThisClip(_ offset: Double) {
    guard let id = current?.id else { return }
    change.overrides[id] = min(max(-Self.reach, offset), Self.reach)
  }

  // MARK: Controls

  @ViewBuilder private var walker: some View {
    if let p = current {
      HStack(spacing: DS.space.xxs) {
        Text(p.name).font(DS.type.captionMedium).foregroundStyle(DS.color.text).lineLimit(1)
        if let own = change.overrides[p.id] {
          Text("· \(Self.label(own)), this clip only").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
          DSButton(p.hasOwn && !change.movesOwnCrops ? "Back to its crop" : "Use the slider", variant: .ghost, size: .sm,
                   tooltip: p.hasOwn && !change.movesOwnCrops ? "This clip keeps the crop it had" : "This clip follows the slider again") {
            change.overrides[p.id] = nil
          }
        } else if p.keepsOwn {
          Text("· keeps its own crop").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        } else if let why = p.skipped {
          Text("· \(why)").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        }
        Spacer(minLength: DS.space.sm)
        if previews.count > 1 {
          Text("\(index + 1) of \(previews.count)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary)
          DSIconButton("chevron.left", tooltip: "Previous clip", size: .sm, shortcut: "←",
                       disabledReason: index == 0 ? "This is the first clip" : nil) { index -= 1 }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .background(ScriptAnchor("Previous clip"))
          DSIconButton("chevron.right", tooltip: "Next clip", size: .sm, shortcut: "→",
                       disabledReason: index == previews.count - 1 ? "This is the last clip" : nil) { index += 1 }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .background(ScriptAnchor("Next clip"))
        }
      }
    }
  }

  private var slider: some View {
    DSSlider(label: "All clips", value: Binding(get: { change.offset }, set: { change.offset = $0 }), range: -Self.reach...Self.reach, step: 0.01,
             format: { Self.label($0) }, disabledReason: loaded ? nil : "Checking these clips…", accessibilityName: "Crop offset for all clips")
      .background(ScriptAnchor("All clips"))
  }

  @ViewBuilder private var notes: some View {
    let own = previews.filter(\.hasOwn).count
    let held = previews.filter { $0.skipped != nil }.count
    let scheduled = previews.filter { $0.changes && $0.scheduled }.count
    VStack(alignment: .leading, spacing: 4) {
      if own > 0 {
        DSChip("Also move the \(own == 1 ? "clip" : "\(own) clips") with a crop already", isSelected: change.movesOwnCrops, size: .sm,
               tooltip: "Off: they keep their crop unless you drag it here") { change.movesOwnCrops.toggle() }
          .background(ScriptAnchor("Also move"))
      }
      if scheduled > 0 {
        EditorHint("\(AppModel.pipelineClips(scheduled)) already scheduled will render again and update in Postiz. That can take hours, so do it well before the first slot", icon: "info.circle")
      }
      if held > 0 { EditorHint(held == 1 ? "1 clip stays as it is" : "\(held) clips stay as they are", icon: "lock") }
    }
  }

  // MARK: Data

  /// Starts from where Eric's own crops sit, so a mixed selection opens close to right.
  private func load() {
    let b = model.bulk, ids = ids
    Task.detached(priority: .userInitiated) {
      let list = (try? b.previewCrop(ids, CropChange())) ?? []
      let own = list.compactMap { p -> Double? in
        guard p.hasOwn, let c = p.crop, let s = p.source else { return nil }
        return CropChange.offset(of: c, source: s)
      }.sorted()
      await MainActor.run {
        previews = list
        loaded = true
        if !own.isEmpty { change.offset = (own[own.count / 2] * 100).rounded() / 100 }
        loadFrames()
      }
    }
  }

  /// The newest change wins; an older answer never lands over it.
  private func refresh() {
    job?.cancel()
    let b = model.bulk, ids = ids, change = change
    job = Task.detached(priority: .userInitiated) {
      let list = (try? b.previewCrop(ids, change)) ?? []
      guard !Task.isCancelled else { return }
      await MainActor.run { if self.change == change { previews = list } }
    }
  }

  /// This clip and its neighbours, so a flip through is instant.
  private func loadFrames() {
    let wanted = previews.indices.filter { abs($0 - index) <= 2 }.map { previews[$0] }.filter { frames[$0.id] == nil && $0.source != nil }
    for p in wanted {
      guard let v = model.video(p.id), let url = model.clipURL(v) else { continue }
      model.requestPreview(v)
      let at = p.frameTime, id = p.id
      Task.detached(priority: .userInitiated) {
        let image = Media.frame(url, at: at, maxSize: CGSize(width: 1280, height: 720))
        await MainActor.run { if let image { frames[id] = image } }
      }
    }
  }

  private func close() { model.cropDialogIds = nil }

  private func apply() {
    let b = model.bulk, ids = ids, change = change
    model.cropDialogIds = nil
    model.apply(BulkRequest(title: "", verb: "", ids: ids, doneMessage: "Crop moved for \(AppModel.pipelineClips(changing))") { dry in
      try b.setCropOffset(ids, change, dryRun: dry)
    })
  }
}

/// The whole frame with the crop on it. Outside the crop is dimmed; dragging the crop moves it left or right.
private struct CropFrameView: View {
  let image: CGImage?
  let source: CGSize?
  let crop: CropRect?
  let canDrag: Bool
  let onMove: (Double) -> Void
  @State private var start: Double?

  /// The picture at its own shape, centred in `box`.
  static func fitted(_ source: CGSize?, in box: CGSize) -> CGRect {
    guard let source, source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: box) }
    let k = min(box.width / source.width, box.height / source.height)
    let w = source.width * k, h = source.height * k
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
  }

  var body: some View {
    GeometryReader { geo in
      let fit = Self.fitted(source, in: geo.size)
      let k = source.map { fit.width / max($0.width, 1) } ?? 1
      ZStack(alignment: .topLeading) {
        Color.black
        if let image {
          Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
        }
        if let crop {
          let box = CGRect(x: fit.minX + crop.x * k, y: fit.minY + crop.y * k, width: crop.w * k, height: crop.h * k)
          Path { p in
            p.addRect(fit)
            p.addRect(box)
          }
          .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
          Rectangle().strokeBorder(Color.white, lineWidth: 2)
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
        }
      }
      .overlay {
        CropDragSurface { dx in
          guard canDrag, let source, let crop, source.width > 0 else { return }
          let from = start ?? CropChange.offset(of: crop, source: source)
          start = from
          onMove(from + dx / max(fit.width, 1))
        } onEnd: { start = nil }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    .accessibilityLabel("The whole frame with the crop on it. Drag to move this clip only")
  }
}

/// Takes the mouse over the frame, in AppKit, so a press lands here whatever sits under the dialog.
private struct CropDragSurface: NSViewRepresentable {
  let onDrag: (CGFloat) -> Void
  let onEnd: () -> Void

  final class Surface: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var startX: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { onDrag(event.locationInWindow.x - startX) }
    override func mouseUp(with event: NSEvent) { onEnd() }
  }

  func makeNSView(context: Context) -> Surface { Surface() }

  func updateNSView(_ v: Surface, context: Context) {
    v.onDrag = onDrag
    v.onEnd = onEnd
  }
}
