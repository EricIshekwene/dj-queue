import AppKit
import DJQCore
import SwiftUI
import UniformTypeIdentifiers

/// The timeline of a photo post (round 21, D7 and D15), in the film track's place: the photos in posting order, one
/// tile each, ending in an Add tile; under them one bar per text over the photos it shows on. A click shows a photo on
/// the canvas, a drag reorders (the first photo is the cover), and image files dropped anywhere on it are added.
struct EditorPhotoTimeline: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  @ObservedObject var images: EditorPhotoImages
  /// The tile being dragged, how far, and the place it would drop at.
  @State private var drag: (id: String, dx: CGFloat, to: Int)?
  @State private var dropTargeted = false
  @State private var flashing = false

  static let tileH: CGFloat = 72, labelH: CGFloat = 16, tileGap: CGFloat = 6

  var body: some View {
    let bars = model.photoTextBars
    let m = PhotoStripMetrics(aspect: model.aspect, count: model.photoCount)
    let textBlock = EditorTextTrack.height(lanes: bars.laneCount)
    let height = Self.tileH + Self.labelH + EditorTimeline.gap + textBlock
    VStack(spacing: DS.space.xs) {
      header
      HStack(alignment: .top, spacing: 0) {
        gutter(textBlock: textBlock)
        ScrollViewReader { proxy in
          ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: EditorTimeline.gap) {
              tiles(m)
              if model.photoCount > 0 { textTrack(bars, m) }
            }
            .frame(width: m.contentWidth, alignment: .leading)
            .padding(.trailing, DS.space.sm)
          }
          .scrollIndicators(.automatic)
          .onChange(of: model.photoIndex) { _, _ in
            if let id = model.currentPhoto?.id { proxy.scrollTo(id, anchor: nil) }
          }
        }
      }
      .frame(height: height + 4, alignment: .top)
      .overlay {
        if flashing || dropTargeted {
          RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
            .strokeBorder(dropTargeted ? DS.color.text : DS.color.warning, lineWidth: 2).padding(-4).allowsHitTesting(false)
        }
      }
      .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in drop(providers) }
      .background(ScriptAnchor("Photos strip"))
    }
    .padding(.horizontal, DS.space.sm).padding(.top, DS.space.xs).padding(.bottom, DS.space.sm)
    .onChange(of: model.flashPhotos) { _, _ in flash() }
  }

  // MARK: Header: which photo, and stepping

  private var header: some View {
    let n = model.photoCount, i = model.photoIndex
    return ZStack {
      HStack(spacing: DS.space.xs) {
        Image(systemName: n > 1 ? "square.stack" : "photo").font(.system(size: 11)).foregroundStyle(DS.color.textTertiary)
        Text(n > 1 ? "Photo \(i + 1) of \(n)" : n == 1 ? "1 photo" : "No photos")
          .font(DS.type.captionMedium.monospacedDigit()).foregroundStyle(DS.color.text)
        Text(n > 1 ? "Drag to reorder. The first photo is the cover." : n == 1 ? "It is the cover. Add more to make a carousel." : "Add one to post.")
          .font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(1)
        Spacer()
      }
      HStack(spacing: 4) {
        DSIconButton("chevron.left", tooltip: "Previous photo", size: .sm, shortcut: "←",
                     disabledReason: i <= 0 ? (n > 1 ? "This is the first photo" : "The post has one photo") : nil) { model.stepPhoto(-1) }
          .background(ScriptAnchor("Previous photo"))
        DSIconButton("chevron.right", tooltip: "Next photo", size: .sm, shortcut: "→",
                     disabledReason: i >= n - 1 ? (n > 1 ? "This is the last photo" : "The post has one photo") : nil) { model.stepPhoto(1) }
          .background(ScriptAnchor("Next photo"))
      }
    }
    .frame(height: 34)
  }

  private func gutter(textBlock: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Image(systemName: "photo.on.rectangle").frame(height: Self.tileH).contentShape(Rectangle())
        .dsTooltip("The photos, in the order they post", side: .leading)
      Spacer().frame(height: Self.labelH + EditorTimeline.gap)
      Image(systemName: "textformat").frame(height: EditorTimeline.textH).contentShape(Rectangle())
        .dsTooltip("Text lane: the photos each text shows on", side: .leading)
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(DS.color.textTertiary)
    .frame(width: EditorTimeline.gutter, alignment: .topLeading)
  }

  // MARK: Tiles

  private func tiles(_ m: PhotoStripMetrics) -> some View {
    let list = model.photos
    // A row, so each tile has its real place for the strip to scroll to; only the dragged tile is moved by an offset.
    return HStack(alignment: .top, spacing: Self.tileGap) {
      ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
        let moving = drag?.id == p.id
        PhotoTile(model: model, photo: p, index: i, count: list.count, selected: i == model.photoIndex, thumb: images.thumbs[p.id]?.image,
                  metrics: m, moving: moving,
                  onPress: { model.selectPhoto(i) },
                  onDrag: { dx in drag = (p.id, dx, m.place(from: i, dx: dx)) },
                  onRelease: { moved in
                    let to = drag?.to
                    drag = nil
                    if moved, let to { model.movePhoto(p.id, to: to) }
                  })
          .offset(x: moving ? drag?.dx ?? 0 : 0)
          .zIndex(moving ? 2 : 0)
          .id(p.id)
      }
      addTile(m)
    }
    .overlay(alignment: .topLeading) {
      if let d = drag, let from = list.firstIndex(where: { $0.id == d.id }), d.to != from {
        // Where the dragged photo lands: a line in the gap before or after that place.
        Capsule().fill(DS.color.text).frame(width: 2, height: Self.tileH)
          .offset(x: m.x(d.to > from ? d.to + 1 : d.to) - Self.tileGap / 2 - 1)
          .allowsHitTesting(false)
      }
    }
    .frame(width: m.contentWidth, height: Self.tileH + Self.labelH, alignment: .topLeading)
  }

  private func addTile(_ m: PhotoStripMetrics) -> some View {
    let off = model.addPhotosOffReason
    return VStack(spacing: 2) {
      Button { model.pickPhotos() } label: {
        ZStack {
          RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
            .strokeBorder(DS.color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          if model.photoBusy {
            DSSpinner(size: 14)
          } else {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.color.textSecondary)
          }
        }
        .frame(width: m.addW, height: Self.tileH)
        .contentShape(Rectangle())
      }
      .buttonStyle(EditorPressStyle())
      .disabled(off != nil)
      .opacity(off != nil && !model.photoBusy ? 0.5 : 1)
      .dsTooltip("Add photos: pick files here, or drop them on the strip", disabledReason: off)
      .background(ScriptAnchor("Add photos"))
      Text("Add").font(DS.type.micro).foregroundStyle(DS.color.textTertiary).frame(width: m.addW, height: Self.labelH - 2)
    }
  }

  // MARK: Text bars

  private func textTrack(_ bars: (bars: [EditorTimelineBar], laneCount: Int), _ m: PhotoStripMetrics) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(bars.bars) { bar in
        PhotoTextBar(model: model, bar: bar, metrics: m, count: model.photoCount, markSelected: bars.bars.count > 1)
          .offset(y: CGFloat(bar.lane) * (EditorTimeline.textH + EditorTextTrack.laneGap))
          .zIndex(bar.id == model.selectedText ? 1 : 0)
      }
    }
    .frame(width: m.contentWidth, height: EditorTextTrack.height(lanes: bars.laneCount), alignment: .topLeading)
  }

  // MARK: Drop and flash

  /// Image files dropped on the strip go where the Add tile's picker sends them.
  private func drop(_ providers: [NSItemProvider]) -> Bool {
    let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !files.isEmpty, model.addPhotosOffReason == nil else { return false }
    let group = DispatchGroup()
    let box = DroppedFiles()
    for (i, p) in files.enumerated() {
      group.enter()
      _ = p.loadObject(ofClass: URL.self) { url, _ in
        if let url { box.add(url, at: i) }
        group.leave()
      }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { model.addPhotos(box.ordered) } }
    return true
  }

  private func flash() {
    flashing = true
    Task {
      try? await Task.sleep(for: .milliseconds(1400))
      flashing = false
    }
  }
}

/// The dropped files, in the order they were dropped (providers answer in any order).
private final class DroppedFiles: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [Int: URL] = [:]
  func add(_ url: URL, at i: Int) { lock.withLock { urls[i] = url } }
  var ordered: [URL] { lock.withLock { urls.sorted { $0.key < $1.key }.map(\.value) } }
}

/// Where tiles and text bars sit: one column per photo, as wide as the post's shape makes a tile.
struct PhotoStripMetrics {
  var tileW: CGFloat
  var addW: CGFloat
  var count: Int

  init(aspect: Aspect, count: Int) {
    tileW = min(max((EditorPhotoTimeline.tileH * CGFloat(aspect.ratio)).rounded(), 46), 128)
    addW = max(tileW, 58)
    self.count = count
  }

  var pitch: CGFloat { tileW + EditorPhotoTimeline.tileGap }
  /// Left edge of column `i` (the Add tile is column `count`).
  func x(_ i: Int) -> CGFloat { CGFloat(i) * pitch }
  var contentWidth: CGFloat { x(count) + addW }

  /// The place a tile dragged `dx` points from place `from` would drop at.
  func place(from: Int, dx: CGFloat) -> Int { min(max(0, from + Int((dx / pitch).rounded())), max(0, count - 1)) }
}

/// One photo of the post: its picture as it posts, its number, "Cover" on the first, a mark when its shape needs a
/// look, and a remove button while it's selected or under the pointer.
private struct PhotoTile: View {
  @ObservedObject var model: EditorModel
  var photo: PhotoItem
  var index: Int
  var count: Int
  var selected: Bool
  var thumb: CGImage?
  var metrics: PhotoStripMetrics
  var moving: Bool
  var onPress: () -> Void
  var onDrag: (CGFloat) -> Void
  var onRelease: (Bool) -> Void
  @State private var hovering = false

  private var h: CGFloat { EditorPhotoTimeline.tileH }

  var body: some View {
    let notice = model.missingPhotos.contains(photo.id) ? nil : model.photoNotice(photo)
    VStack(spacing: 2) {
      ZStack(alignment: .topTrailing) {
        picture
          .frame(width: metrics.tileW, height: h)
          .background(DS.color.surfaceSunken)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
            .strokeBorder(selected ? DS.color.text : DS.color.border, lineWidth: selected ? 2 : 1))
          .dsElevation(moving ? DS.elevation.e2 : DS.elevation.e0)
          .overlay {
            EditorDragSurface(cursor: count > 1 ? .openHand : .arrow, slop: 4, onPress: onPress,
                              onDrag: { d in if count > 1 { onDrag(d.width) } }, onRelease: { moved in onRelease(moved && count > 1) })
          }
          .dsTooltip(model.missingPhotos.contains(photo.id) ? "This photo's file is missing. Put it back, or remove the photo."
                     : count > 1 ? "Photo \(index + 1): click to show it, drag to reorder" : "The photo of this post")
          .probeFrame("photo-tile-\(index + 1)")
        if let notice {
          Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(DS.color.warning)
            .frame(width: 14, height: 14).background(DS.color.surfaceRaised, in: Circle())
            .contentShape(Circle())
            .dsTooltip(notice)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(3)
        }
        if selected || hovering {
          DSIconButton("xmark", tooltip: "Remove this photo from the post", variant: .secondary, size: .sm,
                       disabledReason: model.removePhotoOffReason) { model.removePhoto(photo.id) }
            .scaleEffect(0.72)
            .background(DS.color.surfaceRaised, in: Circle())
            .background(ScriptAnchor("Remove photo \(index + 1)").id(index))  // an anchor keeps its first name: a moved tile gets a new one
            .offset(x: 3, y: -3)
        }
      }
      .frame(width: metrics.tileW, height: h)
      Text(index == 0 ? "1 · Cover" : "\(index + 1)").font(DS.type.micro.monospacedDigit())
        .foregroundStyle(selected ? DS.color.text : DS.color.textTertiary).lineLimit(1).fixedSize()
        .frame(width: metrics.tileW, height: EditorPhotoTimeline.labelH - 2)
    }
    .onHover { hovering = $0 }
  }

  @ViewBuilder private var picture: some View {
    if model.missingPhotos.contains(photo.id) {
      // Its file is gone (a picture read earlier may still be in memory; it isn't what would post).
      Image(systemName: "questionmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.color.danger)
    } else if let thumb {
      Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
    } else {
      DSSpinner(size: 12)
    }
  }
}

/// A text over the photos it shows on. The grips change its first and last photo, the body moves it keeping its length,
/// all in whole photos; a click that doesn't move opens the text in the inspector.
private struct PhotoTextBar: View {
  @ObservedObject var model: EditorModel
  var bar: EditorTimelineBar
  var metrics: PhotoStripMetrics
  var count: Int
  var markSelected: Bool
  /// The range when a drag started, and whether it has written anything: a press that moves nothing writes nothing.
  @State private var origin: (first: Int, last: Int, wrote: Bool)?
  private let h = EditorTimeline.textH

  private var first: Int { Int(bar.span.start.rounded()) + 1 }
  private var last: Int { max(first, Int(bar.span.end.rounded())) }

  var body: some View {
    let a = metrics.x(first - 1), b = metrics.x(last) - EditorPhotoTimeline.tileGap
    let selected = bar.draggable && bar.id == model.selectedText
    ZStack(alignment: .leading) {
      fill(selected: selected)
        .frame(width: max(14, b - a), height: h)
        .overlay { moveSurface }
        .dsTooltip(bar.draggable ? "Click to edit this text, drag to move it to other photos" : "Edit the text on the photo")
        .probeFrame("text-bar-\(bar.number)")
        .offset(x: a)
      if bar.draggable {
        grip(selected: selected, leading: true).probeFrame("text-start-\(bar.number)").offset(x: a)
        grip(selected: selected, leading: false).probeFrame("text-end-\(bar.number)").offset(x: b - 6)
      }
    }
    .frame(width: metrics.contentWidth, height: h, alignment: .leading)
  }

  private func steps(_ d: CGSize) -> Int { Int((d.width / metrics.pitch).rounded()) }

  private var moveSurface: some View {
    EditorDragSurface(cursor: bar.draggable ? .openHand : .arrow, slop: 3, onPress: {
      model.selectText(bar.id)
      if bar.draggable { origin = (first, last, false) }
    }, onDrag: { d in
      guard let o = origin else { return }
      let length = o.last - o.first
      let start = min(max(1, o.first + steps(d)), max(1, count - length))
      write(start, start + length)
    }, onRelease: { moved in
      origin = nil
      if !moved { model.scrollTarget = .text }
    })
  }

  private func gripSurface(leading: Bool) -> some View {
    EditorDragSurface(cursor: .resizeLeftRight, onPress: {
      origin = (first, last, false)
      model.selectText(bar.id)
    }, onDrag: { d in
      guard let o = origin else { return }
      if leading { write(min(max(1, o.first + steps(d)), o.last), o.last) } else { write(o.first, min(max(o.first, o.last + steps(d)), count)) }
    }, onRelease: { _ in origin = nil })
  }

  private func write(_ a: Int, _ b: Int) {
    guard let o = origin, o.wrote || a != o.first || b != o.last else { return }
    origin?.wrote = true
    model.setTextRange(bar.id, a...b)
  }

  private func fill(selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
      .fill(bar.on ? DS.color.selected : DS.color.surfaceSunken)
      .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
        .strokeBorder(selected && markSelected ? DS.color.text : bar.on ? DS.color.borderStrong : DS.color.border,
                      lineWidth: selected && markSelected ? 2 : 1))
      .overlay(alignment: .leading) {
        Text(bar.label).font(DS.type.micro).lineLimit(1)
          .foregroundStyle(bar.on ? DS.color.text : DS.color.textTertiary)
          .padding(.leading, 10).padding(.trailing, 8)
      }
      .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
  }

  private func grip(selected: Bool, leading: Bool) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(DS.color.text.opacity(selected || !markSelected ? 0.7 : 0.3)).frame(width: 6, height: h)
      .overlay { gripSurface(leading: leading) }
      .dsTooltip(leading ? "Drag to set the first photo this text shows on" : "Drag to set the last photo this text shows on")
  }
}

/// Under the canvas in Frame view, for a photo: zoom out, the zoom slider, zoom in, and back to the centred crop.
struct EditorPhotoFrameBar: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let off: String? = model.readOnly ? "Editing is off for this post" : nil
    let z = model.zoom
    HStack(spacing: DS.space.xs) {
      if model.upscale > 1.01 {
        DSBadge(String(format: "Upscaled %.1f×", model.upscale), style: .soft(.warning), icon: "exclamationmark.triangle.fill",
                help: "Zoomed past the photo's resolution, so it may look soft")
      }
      DSIconButton("minus.magnifyingglass", tooltip: "Zoom out", size: .sm,
                   disabledReason: off ?? (z <= 1.001 ? "The crop is as wide as it goes" : nil)) { model.setZoom(z / 1.25) }
        .background(ScriptAnchor("Zoom out"))
      DSSlider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }), range: 1...EditorGeometry.maxZoom, step: 0.05,
               format: { String(format: "%.2f×", $0) }, showsValue: false, disabledReason: off, accessibilityName: "Zoom")
        .frame(width: 150)
      DSIconButton("plus.magnifyingglass", tooltip: "Zoom in", size: .sm,
                   disabledReason: off ?? (z >= EditorGeometry.maxZoom - 0.001 ? "This is the closest zoom" : nil)) { model.setZoom(z * 1.25) }
        .background(ScriptAnchor("Zoom in"))
      Text(String(format: "%.2f×", z)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        .frame(width: 40, alignment: .leading)
      DSButton("Reset crop", icon: "arrow.counterclockwise", variant: .ghost, size: .sm,
               disabledReason: off ?? (model.cropIsSet ? nil : "This photo has the centred crop"),
               tooltip: "Back to the centred crop for this photo") { model.resetPhotoCrop() }
        .background(ScriptAnchor("Reset crop"))
    }
  }
}
