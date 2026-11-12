import AppKit
import DJQCore
import SwiftUI

/// Timeline card (DESIGN-v2 §7, #5): playback controls centred on top, a time ruler with Eric's markers (round 24), one
/// bar per text (overlapping texts take extra lanes, S3-R5), then the filmstrip of the clip file with yellow trim handles
/// that start on Eric's markers (the default trim). The grace seconds beyond the markers are a striped, dimmed zone the
/// handles can be dragged into. Per-platform trim lanes appear only when used.
///
/// Round 24: the timeline zooms (−/+, = / -, a pinch, Fit), a long file opens on its trim, and an overview bar under a
/// zoomed timeline pans it. The trim handles sit inside the trim with a wide grab area, follow the pointer from where
/// they were pressed, go a tenth as fast with ⌥ held, and take ← / → once clicked. Everything dragged here snaps to
/// Eric's markers (M).
struct EditorTimeline: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @StateObject private var strip = EditorFrameStrip()
  @State private var stripTask: Task<Void, Never>?

  static let gutter: CGFloat = 34
  static let textH: CGFloat = 20, filmH: CGFloat = 48, laneH: CGFloat = 18, gap: CGFloat = 8
  static let rulerH: CGFloat = 18, overviewH: CGFloat = 8

  private var lanes: [Platform] { EditorPlatforms.order.filter { model.edit.platformTrims[$0] != nil } }
  /// Height of the text lanes.
  private var textBlock: CGFloat { EditorTextTrack.height(lanes: model.textBars.laneCount) }
  private var textY: CGFloat { Self.rulerH + 4 }
  private var filmY: CGFloat { textY + textBlock + Self.gap }
  private var tracksHeight: CGFloat {
    filmY + Self.filmH + (lanes.isEmpty ? 0 : Self.gap + CGFloat(lanes.count) * (Self.laneH + 4) - 4)
  }
  private var zoomed: Bool { model.timelineZoomed }

  var body: some View {
    // Round 21: a photo post has photos where a clip has film, and nothing to play.
    if model.isPhoto {
      EditorPhotoTimeline(model: model, playback: playback, images: model.photoImages)
    } else {
      clipTimeline
    }
  }

  private var clipTimeline: some View {
    VStack(spacing: DS.space.xs) {
      EditorTransport(model: model, playback: playback)
      GeometryReader { g in
        let w = max(g.size.width - Self.gutter, 1)
        HStack(spacing: 0) {
          gutterLabels
          VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
              EditorRuler(model: model, playback: playback, width: w)
              EditorMarkLines(model: model, width: w, top: Self.rulerH, height: tracksHeight - Self.rulerH)
              EditorFilmTrack(model: model, playback: playback, strip: strip, width: w)
                .offset(y: filmY)
              // Text after the film: in the full window something of the film track took the mouse over the text row.
              EditorTextTrack(model: model, playback: playback, width: w)
                .offset(y: textY)
              ForEach(Array(lanes.enumerated()), id: \.element) { i, p in
                EditorTrimLane(model: model, platform: p, width: w)
                  .offset(y: filmY + Self.filmH + Self.gap + CGFloat(i) * (Self.laneH + 4))
              }
              EditorPlayhead(playback: playback, view: model.viewport, width: w, height: tracksHeight)
                .allowsHitTesting(false)
            }
            .frame(width: w, height: tracksHeight, alignment: .topLeading)
            .clipShape(Rectangle())
            .background(EditorTimelineWheel(model: model, width: w))
            .coordinateSpace(name: "track")
            if zoomed {
              EditorOverview(model: model, playback: playback, width: w)
            }
          }
          .frame(width: w, alignment: .topLeading)
        }
        .onAppear { reloadStrip(width: w) }
        .onChange(of: model.viewport) { _, _ in reloadStrip(width: w, debounce: true) }
        .onChange(of: w) { _, nw in reloadStrip(width: nw, debounce: true) }
      }
      .frame(height: tracksHeight + (zoomed ? Self.overviewH + 4 : 0))
      .dsAnimation(DS.motion.layout, value: textBlock)
    }
    .padding(.horizontal, DS.space.sm).padding(.top, DS.space.xs).padding(.bottom, DS.space.sm)
    .onChange(of: model.videoId) { _, _ in reloadStrip() }
    .onChange(of: model.fileURL) { _, _ in reloadStrip() }
    // A zoomed timeline follows the playhead while it plays.
    // A zoomed timeline follows the playhead a page at a time while it plays (not a sliver every frame).
    .onReceive(playback.$time) { t in if playback.isPlaying { model.pageTimeline(to: t) } }
  }

  @State private var lastWidth: CGFloat = 0

  /// The filmstrip shows the part of the file in view: one frame per ~48 points.
  private func reloadStrip(width: CGFloat? = nil, debounce: Bool = false) {
    guard !model.isPhoto else { return }
    if let width { lastWidth = width }
    let v = model.viewport
    let count = max(12, min(48, Int((lastWidth > 0 ? lastWidth : 860) / 48)))
    let url = model.fileMissing ? nil : model.fileURL
    stripTask?.cancel()
    if !debounce || model.snapshotMode {
      strip.load(url: url, from: v.start, to: v.end, count: count, sync: model.snapshotMode)
      return
    }
    stripTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      strip.load(url: url, from: v.start, to: v.end, count: count)
    }
  }

  private var gutterLabels: some View {
    VStack(alignment: .leading, spacing: 0) {
      Image(systemName: "flag").frame(height: Self.rulerH).contentShape(Rectangle())
        .dsTooltip("Time and your markers: press M to add one at the playhead", side: .leading)
      Spacer().frame(height: 4)
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

/// Shared x ↔ time mapping and snapping for the tracks, through the zoomed view (round 24).
struct EditorTrackMath {
  var duration: Double
  var width: CGFloat
  var markers: [Double?]
  var view: TimelineViewport
  /// Eric's own markers (round 24): everything dragged on the timeline snaps to them.
  var marks: [Double] = []

  /// Snap distance on screen.
  static let snapPoints: CGFloat = 8

  func x(_ t: Double) -> CGFloat { CGFloat(view.x(t, width: Double(width))) }
  func t(_ x: CGFloat) -> Double { view.t(Double(x), width: Double(width), duration: duration) }
  var secondsPerPoint: Double { view.secondsPerPoint(width: Double(width)) }
  var tolerance: Double { Double(Self.snapPoints) * secondsPerPoint }

  /// Snap to markers (CapCut's and Eric's) and clip ends (plus `extra`) within 8 pt.
  func snapped(_ x: CGFloat, extra: [Double] = []) -> Double { snap(t(x), extra: extra).value }

  func snap(_ t: Double, extra: [Double] = []) -> (value: Double, snapped: Bool) {
    let c = extra + TrimRules.snapTargets(duration: duration, markers: markers, marks: marks)
    return EditorGeometry.snap(t, to: c, tolerance: tolerance)
  }
}

extension EditorModel {
  func trackMath(width: CGFloat) -> EditorTrackMath {
    EditorTrackMath(duration: duration, width: width, markers: [video?.markerIn, video?.markerOut], view: viewport, marks: marks)
  }
}

/// "0:12.40": the time with hundredths, for the readout while a trim handle moves (a frame is ~0.03 s).
enum EditorPreciseTime {
  static func string(_ t: Double) -> String {
    let c = max(0, (t * 100).rounded()) / 100
    let m = Int(c / 60)
    return String(format: "%d:%05.2f", m, c - Double(m) * 60)
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
        if let e = model.trimEdge {
          DSBadge("\(e.title) selected · ← → move it · Esc", style: .soft(.neutral), size: .sm)
            .background(ScriptAnchor("Trim edge selected"))
            .dsTooltip("← / → move the \(e == .start ? "start" : "end") by your arrow step, ⇧ by one frame. Esc or a click on an empty spot lets it go")
        } else if !model.trimIsDefault {
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
        timelineTools
      }
      HStack(spacing: 4) {
        let step = model.arrowStep
        DSIconButton(step.backSymbol, tooltip: "Jump back \(step.title)", size: .sm, shortcut: "←") { jump(-1) }
        DSIconButton(playback.isPlaying ? "pause.fill" : "play.fill", tooltip: playback.isPlaying ? "Pause" : "Play the trim",
                     variant: .secondary, size: .md, shortcut: "Space",
                     disabledReason: playback.player == nil ? "The clip isn't loaded" : nil) { playback.toggle() }
        DSIconButton(step.forwardSymbol, tooltip: "Jump forward \(step.title)", size: .sm, shortcut: "→") { jump(1) }
        EditorTimeLabel(playback: playback, duration: model.duration).padding(.leading, 6)
        EditorArrowStepPicker(model: model).padding(.leading, 2)
      }
    }
    .frame(height: 34)
  }

  /// Round 24: add a marker, and the zoom (out, in, fit / zoom to the trim). Mobbin: Vimeo, VEED and Magnific put the
  /// zoom at the right of the transport row with a Fit beside it.
  private var timelineTools: some View {
    let onMark = TimelineMarks.index(near: playback.time, in: model.marks, tolerance: TimelineMarks.hitTolerance(fps: model.fps)) != nil
    let v = model.viewport
    let atMin = v.span <= min(TimelineViewport.minSpan, model.duration) + 0.001
    let off = model.video == nil || model.fileMissing ? "The clip isn't loaded" : nil
    return HStack(spacing: 2) {
      DSIconButton(onMark ? "flag.slash" : "flag", tooltip: onMark ? "Remove the marker at the playhead" : "Add a marker at the playhead",
                   size: .sm, shortcut: "M", disabledReason: off ?? (model.readOnly ? EditorView.readOnlyReason : nil)) {
        model.toggleMarker()
      }
      .background(ScriptAnchor("Add marker"))
      Rectangle().fill(DS.color.border).frame(width: 1, height: 16).padding(.horizontal, 4)
      DSIconButton("minus.magnifyingglass", tooltip: "Zoom out", size: .sm, shortcut: "-",
                   disabledReason: off ?? (model.timelineZoomed ? nil : "The whole file is showing")) { model.zoomTimeline(-1) }
        .background(ScriptAnchor("Zoom out"))
      DSIconButton("plus.magnifyingglass", tooltip: "Zoom in around the playhead", size: .sm, shortcut: "=",
                   disabledReason: off ?? (atMin ? "Zoomed in all the way" : nil)) { model.zoomTimeline(1) }
        .background(ScriptAnchor("Zoom in"))
      DSIconButton(model.timelineZoomed ? "arrow.left.and.right.square" : "scope",
                   tooltip: model.timelineZoomed ? "Show the whole file" : "Zoom to the trim", size: .sm,
                   disabledReason: off) {
        if model.timelineZoomed { model.fitTimeline() } else { model.zoomToTrim() }
      }
      .background(ScriptAnchor("Fit timeline"))
    }
  }
}

extension EditorTransport {
  private func jump(_ d: Int) {
    playback.jump(d, step: model.arrowStep, fine: false, fps: model.fps, duration: model.duration)
  }
}

/// "↔ 2 s" beside the time: how far ← / → and the jump buttons move (round 19). Changing it here works at once on
/// the clip that's open, so Eric can try a step with the arrows straight away; Settings → Playback holds the same choice.
struct EditorArrowStepPicker: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    DSSelect(selection: Binding(get: { model.arrowStep }, set: { model.setArrowStep($0) }),
             options: ArrowStep.allCases.map { DSSelectOption(value: $0, title: $0.short) },
             size: .sm, variant: .ghost, fullWidth: false)
      .background(ScriptAnchor("Arrow step"))
      .dsTooltip("How far ← → jump (⇧ ← → one frame). Try it with the arrows; Settings → Playback has it too")
      .accessibilityLabel("Arrow keys jump")
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

// MARK: - Ruler + markers (round 24)

/// Time ticks over the tracks, and Eric's markers as blue pins: click a pin to put the playhead on it, drag it to move
/// it. A click or drag anywhere else on the ruler moves the playhead (snapping to markers; ⌥ doesn't snap).
struct EditorRuler: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  var width: CGFloat
  @State private var pinDrag: (from: Double, now: Double)?

  var body: some View {
    let m = model.trackMath(width: width)
    let ticks = model.viewport.ticks(width: Double(width))
    ZStack(alignment: .topLeading) {
      Rectangle().fill(Color.clear).frame(width: width, height: EditorTimeline.rulerH)
        .overlay { EditorScrub(model: model, playback: playback, math: m, originX: 0) }
        .dsTooltip("Click or drag to move the playhead")
        .probeFrame("ruler")
      ForEach(ticks.times, id: \.self) { t in
        let x = m.x(t)
        ZStack(alignment: .bottomLeading) {
          Rectangle().fill(DS.color.borderStrong).frame(width: 1, height: 5)
          Text(Self.label(t, step: ticks.step)).font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(DS.color.textTertiary).fixedSize().offset(x: 3, y: -5)
        }
        .frame(height: EditorTimeline.rulerH, alignment: .bottomLeading)
        .offset(x: x)
        .allowsHitTesting(false)
      }
      ForEach(model.marks.filter { pinDrag?.from == $0 || (m.x($0) > -8 && m.x($0) < width + 8) }, id: \.self) { t in
        pin(t, m)
      }
    }
    .frame(width: width, height: EditorTimeline.rulerH, alignment: .topLeading)
  }

  private func pin(_ t: Double, _ m: EditorTrackMath) -> some View {
    let shown = pinDrag?.from == t ? pinDrag!.now : t
    return EditorMarkerPin()
      .frame(width: 14, height: EditorTimeline.rulerH)
      .overlay {
        EditorDragSurface(cursor: .pointingHand, slop: 2, onPress: {
          pinDrag = (t, t)
          playback.pause()
        }, onDrag: { d in
          guard let p = pinDrag else { return }
          let nt = min(max(p.from + Double(d.width) * m.secondsPerPoint, 0), model.duration)
          pinDrag = (p.from, nt)
        }, onRelease: { moved in
          guard let p = pinDrag else { return }
          pinDrag = nil
          if moved { model.moveMarker(from: p.from, to: p.now); playback.seek(p.now, exact: true) }
          else { playback.seek(p.from, exact: true) }
        })
      }
      .dsTooltip("Your marker at \(EditorPreciseTime.string(t)). Click to go there, drag to move it. M at the playhead removes it")
      .probeFrame("marker-\(model.marks.firstIndex(of: t) ?? 0)")
      .offset(x: m.x(shown) - 7)
  }

  static func label(_ t: Double, step: Double) -> String {
    let m = Int(t) / 60, s = t - Double(m * 60)
    return step < 1 ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s.rounded()))
  }
}

/// A marker pin: a small blue flag shape in the ruler.
struct EditorMarkerPin: View {
  var body: some View {
    VStack(spacing: 0) {
      UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 2)
        .fill(DS.color.accent).frame(width: 10, height: 8)
      Triangle().fill(DS.color.accent).frame(width: 10, height: 5)
      Rectangle().fill(DS.color.accent).frame(width: 1.5)
    }
    .shadow(color: .black.opacity(0.25), radius: 0.5)
  }

  private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
      var p = Path()
      p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
      p.closeSubpath()
      return p
    }
  }
}

/// Thin lines from each marker down through every track, so a text bar or a handle can be lined up by eye.
struct EditorMarkLines: View {
  @ObservedObject var model: EditorModel
  var width: CGFloat
  var top: CGFloat
  var height: CGFloat

  var body: some View {
    let m = model.trackMath(width: width)
    ZStack(alignment: .topLeading) {
      ForEach(model.marks.filter { m.x($0) > -2 && m.x($0) < width + 2 }, id: \.self) { t in
        Rectangle().fill(DS.color.accent.opacity(0.55)).frame(width: 1, height: height).offset(x: m.x(t) - 0.5, y: top)
      }
    }
    .frame(width: width, height: top + height, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

/// Click or drag to move the playhead (the ruler, the filmstrip, grace zones and marker ticks all scrub). Snaps to
/// markers and the trim's ends; ⌥ doesn't snap. A click here also lets go of a selected trim handle.
struct EditorScrub: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  var math: EditorTrackMath
  /// Where this surface starts on the track, so its own press point maps to a time.
  var originX: CGFloat
  @State private var pressX: CGFloat?
  /// The time the pointer (or the snap) last asked for: the release lands exactly there, never on where the player's
  /// loose seek happened to stop.
  @State private var target: Double?

  var body: some View {
    EditorDragSurface(cursor: .arrow, slop: 0, onPress: {
      model.selectTrimEdge(nil)
      playback.pause()
    }, onDrag: { _ in }, onRelease: { _ in
      pressX = nil
      if let t = target { playback.seek(t, exact: true) }
      target = nil
    }, onPressAt: { p in
      pressX = originX + p.x
      seek(originX + p.x, fine: NSEvent.modifierFlags.contains(.option))
    }, onDragMods: { d, mods in
      guard let x0 = pressX else { return }
      seek(x0 + d.width, fine: mods.contains(.option))
    })
  }

  private func seek(_ x: CGFloat, fine: Bool) {
    let tr = model.trim
    let t = fine ? math.t(x) : math.snap(math.t(x), extra: [tr.start, tr.end]).value
    target = t
    playback.seek(t)
  }
}

// MARK: - Filmstrip + trim + markers + grace zones

struct EditorFilmTrack: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @ObservedObject var strip: EditorFrameStrip
  var width: CGFloat
  /// The handle being dragged: the edge, its pointer-following state, whether it's snapped and whether ⌥ is held.
  @State private var drag: (edge: TrimEdge, state: TrimDrag, snapped: Bool, fine: Bool)?

  private let h = EditorTimeline.filmH
  static let handle = Color(light: 0xF5C400, dark: 0xFFD60A)
  /// Visible handle width, inside the trim (Mobbin: Whatnot, Posh, Retro, Facebook).
  static let handleW: CGFloat = 14
  /// The grab area reaches this far outside the trim, and `handleW + inner` inside it.
  static let reachOut: CGFloat = 10, reachIn: CGFloat = 8

  var body: some View {
    let m = model.trackMath(width: width)
    let tr = model.trim
    let a = m.x(tr.start), b = m.x(tr.end)
    let grace = EditorGeometry.graceZones(duration: model.duration, markerIn: model.video?.markerIn, markerOut: model.video?.markerOut)
    ZStack(alignment: .topLeading) {
      EditorFilmstripImages(strip: strip, width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
        .overlay { EditorScrub(model: model, playback: playback, math: m, originX: 0) }
        .dsTooltip("Click or drag to move the playhead")
        .probeFrame("film-track")
      // Grace zones: the seconds the file keeps beyond the markers (striped; extendable). Hoverable for the tooltip;
      // they carry the same scrub, so clicking/dragging on them still moves the playhead.
      // Zoomed in, only the part in view is drawn and takes the mouse.
      ForEach(grace, id: \.start) { z in
        let zx = max(m.x(z.start), -4), ze = min(m.x(z.end), width + 4)
        if ze - zx > 0.5 {
          EditorGraceZone(width: ze - zx, height: h, leading: z.start < 0.01)
            .overlay { EditorScrub(model: model, playback: playback, math: m, originX: zx) }
            .dsTooltip(z.start < 0.01 ? "Grace: drag the trim start into these seconds"
                                      : "Grace: drag the trim end into these seconds")
            .offset(x: zx)
        }
      }
      // Dim outside the trim.
      Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, min(a, width)), height: h).allowsHitTesting(false)
      Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, width - max(b, 0)), height: h).offset(x: max(b, 0))
        .allowsHitTesting(false)
      let oa = max(a, -6), ob = min(b, width + 6)
      if ob > oa {
        RoundedRectangle(cornerRadius: 4).stroke(Self.handle, lineWidth: 2.5)
          .frame(width: ob - oa, height: h - 2).offset(x: oa, y: 1).allowsHitTesting(false)
      }
      markerTicks(m)
      // A handle is only there while its edge is in view (a zoomed timeline can leave it off either side).
      if (a > -Self.handleW && a < width) || drag?.edge == .start { handle(.start, m, a: a, b: b) }
      if (b > 0 && b < width + Self.handleW) || drag?.edge == .end { handle(.end, m, a: a, b: b) }
      if let d = drag { readout(d, m) }
    }
    .frame(width: width, height: h, alignment: .topLeading)
  }

  /// A handle: drawn inside the trim, grabbed from `reachOut` outside to `reachIn` past it inside (shrinking on a short
  /// trim so the two never cover each other).
  @ViewBuilder private func handle(_ edge: TrimEdge, _ m: EditorTrackMath, a: CGFloat, b: CGFloat) -> some View {
    let g = Self.handleGeometry(edge, a: a, b: b)
    let selected = model.trimEdge == edge
    ZStack(alignment: .topLeading) {
      Color.clear
      handleView(edge, selected: selected).frame(width: Self.handleW).offset(x: g.visible - g.grab)
    }
    .frame(width: g.grabW, height: h, alignment: .topLeading)
    .overlay { surface(edge, m) }
    .dsTooltip(edge == .start ? "Drag to set the start (⌥ for fine control). Click it, then ← → to nudge"
                              : "Drag to set the end (⌥ for fine control). Click it, then ← → to nudge",
               shortcut: edge == .start ? "I" : "O")
    .probeFrame(edge == .start ? "trim-start" : "trim-end")
    .offset(x: g.grab)
  }

  /// Where a handle is drawn (`visible`) and grabbed (`grab` … `grab + grabW`). Inside the trim normally; a trim too
  /// narrow for two handles has them outside it, start to the left and end to the right, each grabbable up to the
  /// middle, so neither covers the other.
  static func handleGeometry(_ edge: TrimEdge, a: CGFloat, b: CGFloat) -> (visible: CGFloat, grab: CGFloat, grabW: CGFloat) {
    let l = TrimRules.handleLayout(edge, a: Double(a), b: Double(b), handleW: Double(handleW), reachOut: Double(reachOut),
                                   reachIn: Double(reachIn))
    return (CGFloat(l.visible), CGFloat(l.grab), CGFloat(l.grabWidth))
  }

  private func handleView(_ edge: TrimEdge, selected: Bool) -> some View {
    let leading = edge == .start
    return UnevenRoundedRectangle(topLeadingRadius: leading ? 4 : 0, bottomLeadingRadius: leading ? 4 : 0,
                                  bottomTrailingRadius: leading ? 0 : 4, topTrailingRadius: leading ? 0 : 4)
      .fill(Self.handle)
      .overlay {
        Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
          .font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.black.opacity(0.65))
      }
      .overlay {
        if selected {
          UnevenRoundedRectangle(topLeadingRadius: leading ? 4 : 0, bottomLeadingRadius: leading ? 4 : 0,
                                 bottomTrailingRadius: leading ? 0 : 4, topTrailingRadius: leading ? 0 : 4)
            .strokeBorder(Color.white, lineWidth: 2)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
        }
      }
      .frame(height: h)
  }

  /// The handle follows the pointer's movement from the press (it never jumps to the pointer); ⌥ = a tenth as fast and
  /// no snapping. The playhead shows the frame the edge is on.
  private func surface(_ edge: TrimEdge, _ m: EditorTrackMath) -> some View {
    EditorDragSurface(cursor: .resizeLeftRight, slop: 0, onPress: {
      model.selectTrimEdge(edge)
      playback.pause()
      let now = edge == .start ? model.trim.start : model.trim.end
      drag = (edge, TrimDrag(edgeTime: now), false, false)
      playback.seek(now, exact: true)
    }, onDrag: { _ in }, onRelease: { moved in
      let had = drag
      drag = nil
      guard had != nil, moved else { return }
      model.commitTrim()
      playback.seek(edge == .start ? model.trim.start : model.trim.end, exact: true)
    }, onDragMods: { d, mods in
      guard var g = drag else { return }
      let fine = mods.contains(.option)
      let raw = g.state.move(dx: Double(d.width), secondsPerPoint: m.secondsPerPoint, fine: fine)
      var t = raw, snapped = false
      if !fine { (t, snapped) = EditorGeometry.snap(raw, to: model.trimSnapTargets, tolerance: m.tolerance) }
      g.snapped = snapped
      g.fine = fine
      drag = g
      model.setTrimEdge(edge, t, live: true)
      let now = edge == .start ? model.trim.start : model.trim.end
      playback.seek(now)
      model.revealOnTimeline(now)
    })
  }

  /// The time pill over the handle being dragged (Mobbin: Loom's trim readout).
  private func readout(_ d: (edge: TrimEdge, state: TrimDrag, snapped: Bool, fine: Bool), _ m: EditorTrackMath) -> some View {
    let t = d.edge == .start ? model.trim.start : model.trim.end
    let note = d.fine ? " · fine" : d.snapped ? " · snapped" : ""
    let text = "\(EditorPreciseTime.string(t))\(note)"
    let x = min(max(m.x(t) + (d.edge == .start ? 4 : -4), 40), width - 40)
    return Text(text).font(DS.type.micro.monospacedDigit().weight(.semibold)).foregroundStyle(DS.color.inverseText)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(DS.color.inverseSurface.opacity(0.9), in: Capsule())
      .fixedSize()
      .frame(width: 120)
      .offset(x: x - 60, y: h - 20)
      .allowsHitTesting(false)
      .background(ScriptAnchor("Trim readout"))
  }

  /// In/out marker ticks: hoverable for the tooltip, and they scrub like the filmstrip under them.
  @ViewBuilder private func markerTicks(_ m: EditorTrackMath) -> some View {
    let marks = [(model.video?.markerIn, "in"), (model.video?.markerOut, "out")]
      .compactMap { t, k in t.map { ($0, k) } }.filter { $0.0 >= 0 && $0.0 <= model.duration }
      .filter { m.x($0.0) > -6 && m.x($0.0) < width + 6 }
    ForEach(marks, id: \.1) { t, kind in
      VStack(spacing: 0) {
        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.white)
        Rectangle().fill(Color.white).frame(width: 1.5)
      }
      .shadow(color: .black.opacity(0.6), radius: 1)
      .frame(width: 10, height: h)
      .overlay { EditorScrub(model: model, playback: playback, math: m, originX: m.x(t) - 5) }
      .dsTooltip("Your \(kind) marker at \(EditorGeometry.time(t, tenths: true)); the trim snaps here")
      .offset(x: m.x(t) - 5)
    }
  }
}

// MARK: - Overview (round 24)

/// Under a zoomed timeline: the whole file with the trim, markers, playhead and the part in view. Drag the window to pan,
/// or click anywhere to centre the view there.
struct EditorOverview: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var playback: EditorPlayback
  var width: CGFloat
  @State private var grab: TimelineViewport?

  var body: some View {
    let d = max(model.duration, 0.001), v = model.viewport, tr = model.trim
    let k = width / CGFloat(d)
    let vx = CGFloat(v.start) * k, vw = max(CGFloat(v.span) * k, 12)
    ZStack(alignment: .topLeading) {
      Capsule().fill(DS.color.surfaceSunken).frame(width: width, height: EditorTimeline.overviewH)
        .overlay {
          EditorDragSurface(cursor: .arrow, slop: 0, onDrag: { _ in }, onRelease: { _ in }, onPressAt: { p in
            let c = Double(p.x / k)
            model.setViewport(v.panned(by: c - (v.start + v.span / 2), duration: model.duration))
          })
        }
        .dsTooltip("The whole file: click to show that part")
      Rectangle().fill(EditorFilmTrack.handle.opacity(0.7))
        .frame(width: max(2, CGFloat(tr.duration) * k), height: 3).offset(x: CGFloat(tr.start) * k, y: 2.5)
        .allowsHitTesting(false)
      ForEach(model.marks, id: \.self) { t in
        Rectangle().fill(DS.color.accent).frame(width: 1.5, height: EditorTimeline.overviewH).offset(x: CGFloat(t) * k)
          .allowsHitTesting(false)
      }
      RoundedRectangle(cornerRadius: 3).fill(DS.color.text.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(DS.color.textSecondary, lineWidth: 1))
        .frame(width: vw, height: EditorTimeline.overviewH)
        .overlay {
          EditorDragSurface(cursor: .openHand, slop: 0, onPress: { grab = model.viewport }, onDrag: { d in
            guard let g = grab else { return }
            model.setViewport(g.panned(by: Double(d.width / k), duration: model.duration))
          }, onRelease: { _ in grab = nil })
        }
        .dsTooltip("Drag to see another part of the file")
        .probeFrame("overview-window")
        .offset(x: min(vx, width - vw))
      Rectangle().fill(DS.color.text).frame(width: 1.5, height: EditorTimeline.overviewH + 2)
        .offset(x: CGFloat(playback.time) * k, y: -1).allowsHitTesting(false)
    }
    .frame(width: width, height: EditorTimeline.overviewH, alignment: .topLeading)
  }
}

// MARK: - Trackpad: scroll to pan, pinch to zoom (round 24)

/// Two-finger sideways scrolls (or ⇧ + scroll) pan a zoomed timeline; a pinch zooms around the pointer. Read with a
/// local monitor, only over the tracks, so the inspector and the page scroll as before.
struct EditorTimelineWheel: NSViewRepresentable {
  @ObservedObject var model: EditorModel
  var width: CGFloat

  func makeNSView(context: Context) -> Watcher { let v = Watcher(); v.parts = self; return v }
  func updateNSView(_ v: Watcher, context: Context) { v.parts = self }

  final class Watcher: NSView {
    var parts: EditorTimelineWheel?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
        guard let self else { return e }
        let used = MainActor.assumeIsolated { self.handle(e) }
        return used ? nil : e
      }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func handle(_ e: NSEvent) -> Bool {
      guard let parts, e.window === window, !isHiddenOrHasHiddenAncestor else { return false }
      let p = convert(e.locationInWindow, from: nil)
      guard bounds.contains(p) else { return false }
      let model = parts.model
      guard model.isCovered?() != true, !model.fileMissing, model.video != nil else { return false }
      let v = model.viewport, w = Double(max(parts.width, 1))
      let x = Double(p.x)
      if e.type == .magnify {
        model.zoomTimeline(by: 1 + Double(e.magnification), around: v.t(x, width: w, duration: model.duration))
        return true
      }
      let dx = e.modifierFlags.contains(.shift) && e.scrollingDeltaX == 0 ? e.scrollingDeltaY : e.scrollingDeltaX
      guard abs(dx) > abs(e.scrollingDeltaY) || e.modifierFlags.contains(.shift), model.timelineZoomed else { return false }
      let pts = e.hasPreciseScrollingDeltas ? Double(dx) : Double(dx) * 8
      model.panTimeline(by: -pts * v.secondsPerPoint(width: w))
      return true
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
          .zIndex(bar.id == model.selectedText ? 1 : 0)
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
  /// The span when a drag started, and whether it has written anything. Until it changes something it writes nothing: a
  /// sloppy press on a whole-clip bar mustn't pin the window to today's trim.
  @State private var origin: (span: TextTimeline.Span, wrote: Bool)?
  private let h = EditorTimeline.textH
  /// Past this many points a press is a move, not a click.
  private static let clickSlop: CGFloat = 3

  private var math: EditorTrackMath { model.trackMath(width: width) }

  /// Seconds from the trim start that an edge snaps to: the trim's ends, markers (CapCut's and Eric's), the playhead and
  /// other texts' ends.
  private func targets(_ tr: TrimRange) -> [Double] {
    [0, tr.duration, playback.time - tr.start]
      + ([model.video?.markerIn, model.video?.markerOut].compactMap { $0 } + model.marks).map { $0 - tr.start }
      + others.filter(\.draggable).flatMap { [$0.span.start, $0.span.end] }
  }

  private var tolerance: Double { math.tolerance }

  var body: some View {
    let tr = model.trim, m = math
    let a = m.x(tr.start + bar.span.start), b = m.x(tr.start + bar.span.end)
    // Zoomed in, a bar can run far past the track: draw (and take the mouse on) only its visible part.
    let ca = max(a, -16), cb = min(b, width + 16)
    let selected = bar.draggable && bar.id == model.shownText
    ZStack(alignment: .leading) {
      // A bar or grip being dragged stays, even past the edge, so the drag never drops.
      if (cb > -2 && ca < width + 2) || origin != nil {
        fill(selected: selected)
          .frame(width: max(14, cb - ca), height: h)
          .overlay { moveSurface(tr) }
          .dsTooltip(bar.draggable ? "Click to edit this text, drag to move it" : "Edit the overlay text")
          .probeFrame("text-bar-\(bar.number)")
          .offset(x: ca)
      }
      if bar.draggable {
        if (a > -6 && a < width) || origin != nil {
          grip(selected: selected, leading: true, tr)
            .probeFrame("text-start-\(bar.number)")
            .offset(x: a)
        }
        if (b > 0 && b < width + 6) || origin != nil {
          grip(selected: selected, leading: false, tr)
            .probeFrame("text-end-\(bar.number)")
            .offset(x: b - 6)
        }
      }
    }
    .frame(width: width, height: h, alignment: .leading)
  }

  private func moveSurface(_ tr: TrimRange) -> some View {
    EditorDragSurface(cursor: bar.draggable ? .openHand : .arrow, slop: Self.clickSlop, onPress: {
      model.selectText(bar.id)
      if bar.draggable { origin = (bar.span, false) }
    }, onDrag: { d in
      guard let o = origin?.span else { return }
      let by = Double(d.width) * math.secondsPerPoint
      let start = TextTimeline.snappedStart(o, proposed: o.start + by, targets: targets(tr), tolerance: tolerance)
      write(TextTimeline.moved(o, toStart: start, trimDuration: tr.duration))
    }, onRelease: { moved in
      origin = nil
      // A press that never moved is a click: it opens the text in the inspector.
      if !moved { model.scrollTarget = .text }
    })
  }

  private func write(_ s: TextTimeline.Span) {
    guard let o = origin, o.wrote || s.start != o.span.start || s.end != o.span.end else { return }
    origin?.wrote = true
    model.setTextWindow(bar.id, start: s.start, end: s.end)
  }

  private func gripSurface(leading: Bool, _ tr: TrimRange) -> some View {
    EditorDragSurface(cursor: .resizeLeftRight, onPress: {
      origin = (bar.span, false)
      model.selectText(bar.id)
    }, onDrag: { d in
      guard let o = origin?.span else { return }
      let edge = math.x(tr.start + (leading ? o.start : o.end)) + d.width
      let t = math.snapped(edge, extra: targets(tr).map { $0 + tr.start }) - tr.start
      if leading {
        write((TextTimeline.clampedStart(t, end: o.end, trimDuration: tr.duration), o.end))
      } else {
        write((o.start, TextTimeline.clampedEnd(t, start: o.start, trimDuration: tr.duration)))
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
  /// The grip being dragged stays drawn past the view edge so the drag never drops.
  @State private var dragging: TrimEdge?

  var body: some View {
    let m = model.trackMath(width: width)
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
        .frame(width: max(10, min(b, width + 8) - max(a, -8)), height: h).offset(x: max(a, -8))
        .opacity(b < 0 || a > width ? 0 : 1)
      if (a > -6 && a < width) || dragging == .start {
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: h).offset(x: a)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          dragging = .start
          let t = min(m.snapped(v.location.x), r.end - 0.5)
          model.updateEdit { $0.platformTrims[platform]?.start = t }
        }.onEnded { _ in dragging = nil })
        .dsTooltip("Drag to set where \(platform.displayName)'s cut starts")
      }
      if (b > 0 && b < width + 6) || dragging == .end {
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: h).offset(x: b - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          dragging = .end
          let t = max(m.snapped(v.location.x, extra: [r.start + lim]), r.start + 0.5)
          model.updateEdit { $0.platformTrims[platform]?.end = t }
        }.onEnded { _ in dragging = nil })
        .dsTooltip("Drag to set where \(platform.displayName)'s cut ends (snaps to \(Validation.fmt(lim)))")
      }
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
  var view: TimelineViewport
  var width: CGFloat
  var height: CGFloat
  var body: some View {
    let x = CGFloat(view.x(playback.time, width: Double(width)))
    VStack(spacing: 0) {
      Circle().fill(DS.color.text).frame(width: 8, height: 8)
      Rectangle().fill(DS.color.text).frame(width: 1.5)
    }
    .frame(width: 10, height: height)
    .offset(x: x - 5)
    .opacity(x < -5 || x > width + 5 ? 0 : 1)
  }
}
