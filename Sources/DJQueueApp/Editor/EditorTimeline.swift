import DJQCore
import SwiftUI

/// Timeline card (DESIGN-v2 §7, #5): playback controls centred on top, one bar per text (overlapping texts take extra
/// lanes, S3-R5), then the filmstrip of the whole clip file with yellow trim handles that start on Eric's markers (the default trim). The grace seconds
/// beyond the markers are a striped, dimmed zone the handles can be dragged into. Per-platform trim lanes appear
/// only when used.
struct EditorTimeline: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @StateObject private var strip = EditorFrameStrip()

  static let gutter: CGFloat = 34
  static let textH: CGFloat = 20, filmH: CGFloat = 48, laneH: CGFloat = 18, gap: CGFloat = 8

  private var lanes: [Platform] { EditorPlatforms.order.filter { model.edit.platformTrims[$0] != nil } }
  /// Height of the text lanes.
  private var textBlock: CGFloat { EditorTextTrack.height(lanes: model.textBars.laneCount) }
  private var tracksHeight: CGFloat {
    textBlock + Self.gap + Self.filmH + (lanes.isEmpty ? 0 : Self.gap + CGFloat(lanes.count) * (Self.laneH + 4) - 4)
  }

  var body: some View {
    VStack(spacing: DS.space.xs) {
      EditorTransport(model: model, playback: playback)
      GeometryReader { g in
        let w = max(g.size.width - Self.gutter, 1)
        HStack(spacing: 0) {
          gutterLabels
          ZStack(alignment: .topLeading) {
            EditorTextTrack(model: model, playback: playback, width: w)
            EditorFilmTrack(model: model, playback: playback, strip: strip, width: w)
              .offset(y: textBlock + Self.gap)
            ForEach(Array(lanes.enumerated()), id: \.element) { i, p in
              EditorTrimLane(model: model, platform: p, width: w)
                .offset(y: textBlock + Self.gap + Self.filmH + Self.gap + CGFloat(i) * (Self.laneH + 4))
            }
            EditorPlayhead(playback: playback, duration: model.duration, width: w, height: tracksHeight)
              .allowsHitTesting(false)
          }
          .frame(width: w, alignment: .topLeading)
          .coordinateSpace(name: "track")
        }
      }
      .frame(height: tracksHeight)
      .dsAnimation(DS.motion.layout, value: textBlock)
    }
    .padding(.horizontal, DS.space.sm).padding(.top, DS.space.xs).padding(.bottom, DS.space.sm)
    .onAppear { reloadStrip() }
    .onChange(of: model.videoId) { _, _ in reloadStrip() }
    .onChange(of: model.fileURL) { _, _ in reloadStrip() }
  }

  private func reloadStrip() {
    strip.load(url: model.fileMissing ? nil : model.fileURL, from: 0, to: model.duration, count: 18, sync: model.snapshotMode)
  }

  private var gutterLabels: some View {
    VStack(alignment: .leading, spacing: 0) {
      Image(systemName: "textformat").frame(height: Self.textH).contentShape(Rectangle())
        .dsTooltip("Text lane: when each text shows", side: .leading)
      Spacer().frame(height: textBlock - Self.textH + Self.gap)
      Image(systemName: "film").frame(height: Self.filmH).contentShape(Rectangle())
        .dsTooltip("The clip file: trim, markers, grace", side: .leading)
      if !lanes.isEmpty { Spacer().frame(height: Self.gap) }
      ForEach(lanes, id: \.self) { p in
        DSPlatformIcon(platform: p, size: Self.laneH).frame(height: Self.laneH)
          .dsTooltip("\(p.displayName)-only trim", side: .leading).padding(.bottom, 4)
      }
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(DS.color.textTertiary)
    .frame(width: Self.gutter, alignment: .topLeading)
  }
}

/// Shared x ↔ time mapping and snapping for the tracks.
struct EditorTrackMath {
  var duration: Double
  var width: CGFloat
  var markers: [Double?]

  func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * width : 0 }
  func t(_ x: CGFloat) -> Double { min(max(Double(x / max(width, 1)) * duration, 0), duration) }

  /// Snap to markers and clip ends (plus `extra`) within 8 pt.
  func snapped(_ x: CGFloat, extra: [Double] = []) -> Double {
    let c = extra + EditorGeometry.trimSnapTargets(duration: duration, markers: markers)
    return EditorGeometry.snap(t(x), to: c, tolerance: Double(8 / max(width, 1)) * duration).value
  }
}

// MARK: - Transport

struct EditorTransport: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback

  var body: some View {
    let t = model.trim
    ZStack {
      HStack(spacing: DS.space.xs) {
        Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(DS.color.textTertiary)
        Text("\(EditorGeometry.time(t.start, tenths: true)) – \(EditorGeometry.time(t.end, tenths: true))")
          .font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        Text(String(format: "%.1f s", t.duration)).font(DS.type.captionMedium.monospacedDigit()).foregroundStyle(DS.color.text)
        if !model.trimIsDefault {
          DSBadge("Custom", style: .soft(.neutral), size: .sm)
            .dsTooltip(model.video?.markerIn != nil ? "Trim changed from your markers" : "Trim changed from the whole file")
        } else if model.video?.markerIn != nil {
          Text("· markers").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        }
        Spacer()
        if !model.trimIsDefault {
          DSButton(model.video?.markerIn != nil ? "Trim to markers" : "Whole file", icon: "arrow.uturn.backward", variant: .ghost,
                   size: .sm, tooltip: model.video?.markerIn != nil ? "Reset the trim to your in/out markers"
                                                                     : "Reset the trim to the whole file") {
            model.resetEdit(.trimIn, .trimOut); model.commitTrim()
          }
        }
      }
      HStack(spacing: 4) {
        DSIconButton("gobackward.5", tooltip: "Jump back 5 seconds", size: .sm) { playback.skip(-5) }
        DSIconButton(playback.isPlaying ? "pause.fill" : "play.fill", tooltip: playback.isPlaying ? "Pause" : "Play the trim",
                     variant: .secondary, size: .md, shortcut: "Space",
                     disabledReason: playback.player == nil ? "The clip isn't loaded" : nil) { playback.toggle() }
        DSIconButton("goforward.5", tooltip: "Jump forward 5 seconds", size: .sm) { playback.skip(5) }
        EditorTimeLabel(playback: playback, duration: model.duration).padding(.leading, 6)
      }
    }
    .frame(height: 34)
  }
}

private struct EditorTimeLabel: View {
  @ObservedObject var playback: EditorPlayback
  var duration: Double
  var body: some View {
    HStack(spacing: 3) {
      Text(EditorGeometry.time(playback.time, tenths: true)).foregroundStyle(DS.color.text)
      Text("/ \(EditorGeometry.time(duration, tenths: true))").foregroundStyle(DS.color.textTertiary)
    }
    .font(DS.type.caption.monospacedDigit())
  }
}

// MARK: - Filmstrip + trim + markers + grace zones

struct EditorFilmTrack: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @ObservedObject var strip: EditorFrameStrip
  var width: CGFloat

  private let h = EditorTimeline.filmH
  private static let handle = Color(light: 0xF5C400, dark: 0xFFD60A)

  var body: some View {
    let m = EditorTrackMath(duration: model.duration, width: width, markers: [model.video?.markerIn, model.video?.markerOut])
    let tr = model.trim
    let a = m.x(tr.start), b = m.x(tr.end)
    let grace = EditorGeometry.graceZones(duration: model.duration, markerIn: model.video?.markerIn, markerOut: model.video?.markerOut)
    ZStack(alignment: .topLeading) {
      EditorFilmstripImages(strip: strip, width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
        .contentShape(Rectangle())
        .gesture(scrub(m))
        .dsTooltip("Click or drag to move the playhead")
        .probeFrame("film-track")
      // Grace zones: the seconds the file keeps beyond the markers (striped; extendable). Hoverable for the tooltip;
      // they carry the same scrub gesture, so clicking/dragging on them still moves the playhead.
      ForEach(grace, id: \.start) { z in
        EditorGraceZone(width: max(1, m.x(z.end) - m.x(z.start)), height: h, leading: z.start < 0.01)
          .contentShape(Rectangle())
          .gesture(scrub(m))
          .dsTooltip(z.start < 0.01 ? "Grace: drag the trim start into these seconds"
                                    : "Grace: drag the trim end into these seconds")
          .offset(x: m.x(z.start))
      }
      // Dim outside the trim.
      Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, a), height: h).allowsHitTesting(false)
      Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, width - b), height: h).offset(x: b).allowsHitTesting(false)
      RoundedRectangle(cornerRadius: 3).stroke(Self.handle, lineWidth: 2.5)
        .frame(width: max(0, b - a), height: h - 2).offset(x: a, y: 1).allowsHitTesting(false)
      markerTicks(m)
      handleView(leading: true).offset(x: a - 11)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let nt = min(m.snapped(v.location.x), model.trim.end - 0.5)
          model.setTrimIn(nt, live: true)
          playback.pause(); playback.seek(nt)
        }.onEnded { _ in model.commitTrim() })
        .dsTooltip("Drag to set the start; snaps to your markers", shortcut: "I")
      handleView(leading: false).offset(x: b)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let nt = max(m.snapped(v.location.x), model.trim.start + 0.5)
          model.setTrimOut(nt, live: true)
          playback.pause(); playback.seek(nt)
        }.onEnded { _ in model.commitTrim() })
        .dsTooltip("Drag to set the end; snaps to your markers", shortcut: "O")
    }
    .frame(width: width, height: h, alignment: .topLeading)
  }

  /// Click or drag to move the playhead (the filmstrip, grace zones and marker ticks all scrub).
  private func scrub(_ m: EditorTrackMath) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
      .onChanged { v in playback.pause(); playback.seek(m.t(v.location.x)) }
      .onEnded { v in playback.seek(m.t(v.location.x), exact: true) }
  }

  private func handleView(leading: Bool) -> some View {
    UnevenRoundedRectangle(topLeadingRadius: leading ? 5 : 0, bottomLeadingRadius: leading ? 5 : 0,
                           bottomTrailingRadius: leading ? 0 : 5, topTrailingRadius: leading ? 0 : 5)
      .fill(Self.handle)
      .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 16))
      .frame(width: 11, height: h)
      .contentShape(Rectangle())
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
  }

  /// In/out marker ticks: hoverable for the tooltip, and they scrub like the filmstrip under them.
  @ViewBuilder private func markerTicks(_ m: EditorTrackMath) -> some View {
    let marks = [(model.video?.markerIn, "in"), (model.video?.markerOut, "out")]
      .compactMap { t, k in t.map { ($0, k) } }.filter { $0.0 >= 0 && $0.0 <= model.duration }
    ForEach(marks, id: \.1) { t, kind in
      VStack(spacing: 0) {
        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.white)
        Rectangle().fill(Color.white).frame(width: 1.5)
      }
      .shadow(color: .black.opacity(0.6), radius: 1)
      .frame(width: 10, height: h)
      .contentShape(Rectangle())
      .gesture(scrub(m))
      .dsTooltip("Your \(kind) marker at \(EditorGeometry.time(t, tenths: true)); the trim snaps here")
      .offset(x: m.x(t) - 5)
    }
  }
}

/// Striped band over the grace seconds beyond a marker.
struct EditorGraceZone: View {
  var width: CGFloat
  var height: CGFloat
  var leading: Bool

  var body: some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.25)))
      var p = Path()
      var x: CGFloat = -size.height
      while x < size.width { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 7 }
      ctx.stroke(p, with: .color(.white.opacity(0.28)), lineWidth: 1)
    }
    .overlay(alignment: leading ? .bottomLeading : .bottomTrailing) {
      if width > 46 {
        Text("Grace").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 5).padding(.vertical, 1).background(Color.black.opacity(0.45), in: Capsule()).padding(4)
      }
    }
    .frame(width: width, height: height)
    .clipShape(UnevenRoundedRectangle(topLeadingRadius: leading ? 6 : 0, bottomLeadingRadius: leading ? 6 : 0,
                                      bottomTrailingRadius: leading ? 0 : 6, topTrailingRadius: leading ? 0 : 6))
  }
}

// MARK: - Text bars (S3-R5)

/// One bar per text. Grips set when it starts and ends, the body moves it keeping its length, and a click selects it.
struct EditorTextTrack: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  var width: CGFloat

  static let laneGap: CGFloat = 2
  static func height(lanes: Int) -> CGFloat { CGFloat(max(1, lanes)) * EditorTimeline.textH + CGFloat(max(1, lanes) - 1) * laneGap }

  var body: some View {
    let bars = model.textBars
    ZStack(alignment: .topLeading) {
      ForEach(bars.bars) { bar in
        EditorTextBar(model: model, playback: playback, bar: bar, others: bars.bars.filter { $0.id != bar.id }, width: width,
                      markSelected: bars.bars.count > 1)
          .offset(y: CGFloat(bar.lane) * (EditorTimeline.textH + Self.laneGap))
      }
    }
    .frame(width: width, height: Self.height(lanes: bars.laneCount), alignment: .topLeading)
  }
}

/// What the text track shows: `layer` nil is the "No text" stand-in, which has nothing to drag.
struct EditorTimelineBar: Identifiable {
  var id: String
  var number: Int
  var label: String
  /// The text has words, so it shows on the video.
  var on: Bool
  var draggable: Bool
  /// Seconds from the trim start.
  var span: TextTimeline.Span
  var lane: Int
}

private struct EditorTextBar: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  var bar: EditorTimelineBar
  var others: [EditorTimelineBar]
  var width: CGFloat
  var markSelected: Bool
  /// The span when a drag started.
  @State private var origin: TextTimeline.Span?
  private let h = EditorTimeline.textH
  /// Past this many points a press is a move, not a click.
  private static let clickSlop: CGFloat = 3

  private var math: EditorTrackMath {
    EditorTrackMath(duration: model.duration, width: width, markers: [model.video?.markerIn, model.video?.markerOut])
  }

  /// Seconds from the trim start that an edge snaps to: the trim's ends, markers, the playhead and other texts' ends.
  private func targets(_ tr: TrimRange) -> [Double] {
    [0, tr.duration, playback.time - tr.start] + [model.video?.markerIn, model.video?.markerOut].compactMap { $0.map { $0 - tr.start } }
      + others.filter(\.draggable).flatMap { [$0.span.start, $0.span.end] }
  }

  private var tolerance: Double { Double(8 / max(width, 1)) * model.duration }

  var body: some View {
    let tr = model.trim, m = math
    let a = m.x(tr.start + bar.span.start), b = m.x(tr.start + bar.span.end)
    let selected = bar.draggable && bar.id == model.selectedText
    ZStack(alignment: .leading) {
      fill(selected: selected)
        .frame(width: max(14, b - a), height: h)
        .overlay { moveSurface(tr) }
        .dsTooltip(bar.draggable ? "Click to edit this text, drag to move it" : "Edit the overlay text")
        .probeFrame("text-bar-\(bar.number)")
        .offset(x: a)
      if bar.draggable {
        grip(selected: selected, leading: true, tr)
          .probeFrame("text-start-\(bar.number)")
          .offset(x: a)
        grip(selected: selected, leading: false, tr)
          .probeFrame("text-end-\(bar.number)")
          .offset(x: b - 6)
      }
    }
    .frame(width: width, height: h, alignment: .leading)
  }

  private func moveSurface(_ tr: TrimRange) -> some View {
    EditorDragSurface(cursor: bar.draggable ? .openHand : .arrow, slop: Self.clickSlop, onPress: {
      model.selectText(bar.id)
      if bar.draggable { origin = bar.span }
    }, onDrag: { d in
      guard let o = origin else { return }
      let by = Double(d.width / max(width, 1)) * model.duration
      let start = TextTimeline.snappedStart(o, proposed: o.start + by, targets: targets(tr), tolerance: tolerance)
      let s = TextTimeline.moved(o, toStart: start, trimDuration: tr.duration)
      model.setTextWindow(bar.id, start: s.start, end: s.end)
    }, onRelease: { moved in
      origin = nil
      // A press that never moved is a click: it opens the text in the inspector.
      if !moved { model.scrollTarget = .text }
    })
  }

  private func gripSurface(leading: Bool, _ tr: TrimRange) -> some View {
    EditorDragSurface(cursor: .resizeLeftRight, onPress: {
      origin = bar.span
      model.selectText(bar.id)
    }, onDrag: { d in
      guard let o = origin else { return }
      let edge = math.x(tr.start + (leading ? o.start : o.end)) + d.width
      let t = math.snapped(edge, extra: targets(tr).map { $0 + tr.start }) - tr.start
      if leading {
        model.setTextWindow(bar.id, start: TextTimeline.clampedStart(t, end: o.end, trimDuration: tr.duration), end: o.end)
      } else {
        model.setTextWindow(bar.id, start: o.start, end: TextTimeline.clampedEnd(t, start: o.start, trimDuration: tr.duration))
      }
    }, onRelease: { _ in origin = nil })
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

  private func grip(selected: Bool, leading: Bool, _ tr: TrimRange) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(DS.color.text.opacity(selected || !markSelected ? 0.7 : 0.3)).frame(width: 6, height: h)
      .overlay { gripSurface(leading: leading, tr) }
      .dsTooltip("Drag to set when the text shows")
  }
}

// MARK: - Per-platform trim lane

struct EditorTrimLane: View {
  @ObservedObject var model: EditorModel
  var platform: Platform
  var width: CGFloat
  private let h = EditorTimeline.laneH

  var body: some View {
    let m = EditorTrackMath(duration: model.duration, width: width, markers: [model.video?.markerIn, model.video?.markerOut])
    let r = model.edit.platformTrims[platform] ?? model.trim
    let a = m.x(r.start), b = m.x(r.end)
    let lim = model.settings.limits[platform]?.maxDuration ?? .infinity
    let over = r.duration > lim + 0.05
    let tint = over ? DS.color.warning : DS.color.textSecondary
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 4).fill(DS.color.surfaceSunken).frame(width: width, height: h)
      RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .leading) {
          Text("\(platform.displayName) · \(Validation.fmt(r.duration)) / \(Validation.fmt(lim))")
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DS.color.text).lineLimit(1).padding(.horizontal, 8)
        }
        .frame(width: max(10, b - a), height: h).offset(x: a)
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: h).offset(x: a)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let t = min(m.snapped(v.location.x), r.end - 0.5)
          model.updateEdit { $0.platformTrims[platform]?.start = t }
        })
        .dsTooltip("Drag to set where \(platform.displayName)'s cut starts")
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: h).offset(x: b - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let t = max(m.snapped(v.location.x, extra: [r.start + lim]), r.start + 0.5)
          model.updateEdit { $0.platformTrims[platform]?.end = t }
        })
        .dsTooltip("Drag to set where \(platform.displayName)'s cut ends (snaps to \(Validation.fmt(lim)))")
    }
    .frame(width: width, height: h, alignment: .leading)
  }
}

private struct EditorFilmstripImages: View {
  @ObservedObject var strip: EditorFrameStrip
  var width: CGFloat
  var height: CGFloat
  var body: some View {
    HStack(spacing: 0) {
      if strip.frames.isEmpty {
        Rectangle().fill(DS.color.surfaceSunken)
          .overlay { if strip.loading { DSSpinner(size: 14) } }
      } else {
        ForEach(Array(strip.frames.enumerated()), id: \.offset) { _, f in
          Image(decorative: f.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            .frame(width: width / CGFloat(strip.frames.count), height: height).clipped()
        }
      }
    }
    .frame(width: width, height: height)
  }
}

private struct EditorPlayhead: View {
  @ObservedObject var playback: EditorPlayback
  var duration: Double
  var width: CGFloat
  var height: CGFloat
  var body: some View {
    let x = duration > 0 ? CGFloat(playback.time / duration) * width : 0
    VStack(spacing: 0) {
      Circle().fill(DS.color.text).frame(width: 8, height: 8)
      Rectangle().fill(DS.color.text).frame(width: 1.5)
    }
    .frame(width: 10, height: height + 8)
    .offset(x: x - 5, y: -8)
  }
}
