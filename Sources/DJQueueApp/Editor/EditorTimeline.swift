import DJQCore
import SwiftUI

/// Timeline card (DESIGN-v2 §7, #5): playback controls centred on top, the text-timing bar, then the filmstrip of
/// the whole clip file with yellow trim handles that start on Eric's markers (the default trim). The grace seconds
/// beyond the markers are a striped, dimmed zone the handles can be dragged into. Per-platform trim lanes appear
/// only when used.
struct EditorTimeline: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @StateObject private var strip = EditorFrameStrip()

  static let gutter: CGFloat = 34
  static let textH: CGFloat = 20, filmH: CGFloat = 48, laneH: CGFloat = 18, gap: CGFloat = 8

  private var lanes: [Platform] { EditorPlatforms.order.filter { model.edit.platformTrims[$0] != nil } }
  private var tracksHeight: CGFloat {
    Self.textH + Self.gap + Self.filmH + (lanes.isEmpty ? 0 : Self.gap + CGFloat(lanes.count) * (Self.laneH + 4) - 4)
  }

  var body: some View {
    VStack(spacing: DS.space.xs) {
      EditorTransport(model: model, playback: playback)
      GeometryReader { g in
        let w = max(g.size.width - Self.gutter, 1)
        HStack(spacing: 0) {
          gutterLabels
          ZStack(alignment: .topLeading) {
            EditorTextBar(model: model, playback: playback, width: w)
            EditorFilmTrack(model: model, playback: playback, strip: strip, width: w)
              .offset(y: Self.textH + Self.gap)
            ForEach(Array(lanes.enumerated()), id: \.element) { i, p in
              EditorTrimLane(model: model, platform: p, width: w)
                .offset(y: Self.textH + Self.gap + Self.filmH + Self.gap + CGFloat(i) * (Self.laneH + 4))
            }
            EditorPlayhead(playback: playback, duration: model.duration, width: w, height: tracksHeight)
              .allowsHitTesting(false)
          }
          .frame(width: w, alignment: .topLeading)
          .coordinateSpace(name: "track")
        }
      }
      .frame(height: tracksHeight)
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
      Image(systemName: "textformat").frame(height: Self.textH).help("Text: when the overlay text shows")
      Spacer().frame(height: Self.gap)
      Image(systemName: "film").frame(height: Self.filmH).help("The clip file — trim handles, markers, grace zones")
      if !lanes.isEmpty { Spacer().frame(height: Self.gap) }
      ForEach(lanes, id: \.self) { p in
        DSPlatformIcon(platform: p, size: Self.laneH).frame(height: Self.laneH).padding(.bottom, 4)
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
          DSBadge("Custom", style: .soft(.neutral), size: .sm).help("Trim changed from your markers")
        } else if model.video?.markerIn != nil {
          Text("· markers").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        }
        Spacer()
        if !model.trimIsDefault {
          DSButton(model.video?.markerIn != nil ? "Trim to markers" : "Whole file", icon: "arrow.uturn.backward", variant: .ghost,
                   size: .sm, tooltip: "Reset the trim to the default (your in/out markers)") {
            model.resetEdit(.trimIn, .trimOut); model.commitTrim()
          }
        }
      }
      HStack(spacing: 4) {
        DSIconButton("gobackward.5", tooltip: "Back 5 seconds", size: .sm) { playback.skip(-5) }
        DSIconButton(playback.isPlaying ? "pause.fill" : "play.fill", tooltip: playback.isPlaying ? "Pause" : "Play the trim",
                     variant: .secondary, size: .md, shortcut: "Space",
                     disabledReason: playback.player == nil ? "The clip isn't loaded" : nil) { playback.toggle() }
        DSIconButton("goforward.5", tooltip: "Forward 5 seconds", size: .sm) { playback.skip(5) }
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
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
          .onChanged { v in playback.pause(); playback.seek(m.t(v.location.x)) }
          .onEnded { v in playback.seek(m.t(v.location.x), exact: true) })
        .help("Click or drag to move the playhead")
      // Grace zones: the seconds the file keeps beyond the markers (striped; extendable).
      ForEach(grace, id: \.start) { z in
        EditorGraceZone(width: max(1, m.x(z.end) - m.x(z.start)), height: h, leading: z.start < 0.01)
          .offset(x: m.x(z.start)).allowsHitTesting(false)
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
        .help("Trim in (I) — snaps to your markers; drag left into the grace zone to start earlier")
      handleView(leading: false).offset(x: b)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let nt = max(m.snapped(v.location.x), model.trim.start + 0.5)
          model.setTrimOut(nt, live: true)
          playback.pause(); playback.seek(nt)
        }.onEnded { _ in model.commitTrim() })
        .help("Trim out (O) — snaps to your markers; drag right into the grace zone to end later")
    }
    .frame(width: width, height: h, alignment: .topLeading)
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

  @ViewBuilder private func markerTicks(_ m: EditorTrackMath) -> some View {
    let marks = [model.video?.markerIn, model.video?.markerOut].compactMap { $0 }.filter { $0 >= 0 && $0 <= model.duration }
    ForEach(marks, id: \.self) { t in
      VStack(spacing: 0) {
        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.white)
        Rectangle().fill(Color.white).frame(width: 1.5)
      }
      .shadow(color: .black.opacity(0.6), radius: 1)
      .frame(width: 10, height: h)
      .offset(x: m.x(t) - 5)
      .allowsHitTesting(false)
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

// MARK: - Text timing bar

struct EditorTextBar: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  var width: CGFloat
  private let h = EditorTimeline.textH

  var body: some View {
    let m = EditorTrackMath(duration: model.duration, width: width, markers: [model.video?.markerIn, model.video?.markerOut])
    let r = model.resolved, tr = model.trim
    let s = tr.start + (r.textStart ?? 0)
    let e = r.textEnd.map { tr.start + $0 } ?? tr.end
    let a = m.x(min(max(s, tr.start), tr.end)), b = m.x(min(max(e, tr.start), tr.end))
    let on = r.hasText
    ZStack(alignment: .leading) {
      bar(on: on, text: on ? Captions.oneLine(r.text) : (r.noText ? "No text" : "No text yet"))
        .frame(width: max(14, b - a), height: h)
        .offset(x: a)
        .onTapGesture { model.scrollTarget = .text }
        .help("Overlay text — click to edit it")
      if on {
        grip.offset(x: a)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
            let t = min(max(m.snapped(v.location.x, extra: [tr.start, playback.time]), tr.start), e - 0.3)
            model.updateVersion { $0.textStart = t - tr.start < 0.02 ? 0 : t - tr.start }
          })
        grip.offset(x: b - 6)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
            let t = max(min(m.snapped(v.location.x, extra: [tr.end, playback.time]), tr.end), s + 0.3)
            model.updateVersion { $0.textEnd = t - tr.start }
          })
      }
    }
    .frame(width: width, height: h, alignment: .leading)
  }

  private func bar(on: Bool, text: String) -> some View {
    RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
      .fill(on ? DS.color.selected : DS.color.surfaceSunken)
      .overlay(RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
        .strokeBorder(on ? DS.color.borderStrong : DS.color.border, lineWidth: 1))
      .overlay(alignment: .leading) {
        Text(text).font(DS.type.micro).lineLimit(1)
          .foregroundStyle(on ? DS.color.text : DS.color.textTertiary)
          .padding(.leading, 10).padding(.trailing, 8)
      }
  }

  private var grip: some View {
    RoundedRectangle(cornerRadius: 2).fill(DS.color.text.opacity(0.7)).frame(width: 6, height: h)
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .help("Drag to set when the text shows")
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
        .help("\(platform.displayName) trim in")
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: h).offset(x: b - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let t = max(m.snapped(v.location.x, extra: [r.start + lim]), r.start + 0.5)
          model.updateEdit { $0.platformTrims[platform]?.end = t }
        })
        .help("\(platform.displayName) trim out — snaps to the \(Validation.fmt(lim)) limit")
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
