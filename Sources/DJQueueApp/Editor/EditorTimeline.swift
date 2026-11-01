import DJQCore
import SwiftUI

/// E.S2: transport, text-timing bar, filmstrip with trim handles + marker ticks, per-platform trim lanes.
struct EditorTimeline: View {
  @ObservedObject var model: EditorModel
  let playback: EditorPlayback
  @StateObject private var strip = EditorFrameStrip()

  static let gutter: CGFloat = 40
  private let textH: CGFloat = 20, filmH: CGFloat = 46, laneH: CGFloat = 18, gap: CGFloat = 8

  private var lanes: [Platform] { Platform.allCases.sorted().filter { model.edit.platformTrims[$0] != nil } }

  var body: some View {
    VStack(spacing: 6) {
      transport
      GeometryReader { g in
        let w = max(g.size.width - Self.gutter, 1)
        HStack(spacing: 0) {
          gutterLabels
          ZStack(alignment: .topLeading) {
            textBar(width: w)
            filmstrip(width: w).offset(y: textH + gap)
            ForEach(Array(lanes.enumerated()), id: \.element) { i, p in
              lane(p, width: w).offset(y: textH + gap + filmH + gap + CGFloat(i) * (laneH + 4))
            }
            EditorPlayhead(playback: playback, duration: model.duration, width: w,
                           height: textH + gap + filmH + (lanes.isEmpty ? 0 : gap + CGFloat(lanes.count) * (laneH + 4)))
              .allowsHitTesting(false)
          }
          .frame(width: w, alignment: .topLeading)
          .coordinateSpace(name: "track")
        }
      }
      .frame(height: textH + gap + filmH + (lanes.isEmpty ? 0 : gap + CGFloat(lanes.count) * (laneH + 4) - 4))
    }
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    .onAppear { reloadStrip() }
    .onChange(of: model.videoId) { _, _ in reloadStrip() }
    .onChange(of: model.fileURL) { _, _ in reloadStrip() }
  }

  private func reloadStrip() {
    strip.load(url: model.fileMissing ? nil : model.fileURL, from: 0, to: model.duration, count: 16, sync: model.snapshotMode)
  }

  // MARK: Transport

  private var transport: some View {
    HStack(spacing: 10) {
      Button { playback.toggle() } label: { EditorPlayIcon(playback: playback) }
        .buttonStyle(.borderless).help("Play / pause (space)").accessibilityLabel("Play or pause")
      EditorTimeLabel(playback: playback, duration: model.duration)
      Divider().frame(height: 14)
      let t = model.trim
      HStack(spacing: 6) {
        Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(.secondary)
        Text("\(EditorGeometry.time(t.start, tenths: true)) – \(EditorGeometry.time(t.end, tenths: true))")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        Text(String(format: "%.1f s", t.duration)).font(.system(size: 11, weight: .semibold, design: .monospaced))
      }
      Spacer()
      if let a = model.video?.markerIn, let b = model.video?.markerOut, abs(t.start - a) > 0.05 || abs(t.end - b) > 0.05 {
        Button("Trim to markers") { model.updateEdit { $0.trimIn = max(0, a); $0.trimOut = min(model.duration, b) } }
          .controlSize(.small).help("Use your in/out markers")
      }
      if model.edit.trimIn != nil || model.edit.trimOut != nil {
        Button("Whole clip") { model.updateEdit { $0.trimIn = nil; $0.trimOut = nil } }.controlSize(.small)
      }
    }
    .frame(height: 24)
  }

  private var gutterLabels: some View {
    VStack(alignment: .leading, spacing: 0) {
      Image(systemName: "textformat").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: textH)
      Spacer().frame(height: gap)
      Image(systemName: "film").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: filmH)
      if !lanes.isEmpty { Spacer().frame(height: gap) }
      ForEach(lanes, id: \.self) { p in
        HStack(spacing: 2) {
          EditorPlatformBadge(platform: p)
          Button { model.updateEdit { $0.platformTrims[p] = nil } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove the \(p.displayName) trim")
            .accessibilityLabel("Remove the \(p.displayName) trim")
        }
        .frame(height: laneH).padding(.bottom, 4)
      }
    }
    .frame(width: Self.gutter, alignment: .topLeading)
  }

  // MARK: Helpers

  private func x(_ t: Double, _ w: CGFloat) -> CGFloat { model.duration > 0 ? CGFloat(t / model.duration) * w : 0 }
  private func t(_ x: CGFloat, _ w: CGFloat) -> Double { min(max(Double(x / w) * model.duration, 0), model.duration) }

  /// Snap to markers and clip ends (plus `extra`). The playhead is a target only when the drag doesn't move it
  /// (trim drags seek, so including it would pin the handle to its own last position).
  private func snapped(_ x: CGFloat, _ w: CGFloat, extra: [Double] = [], playhead: Bool = false) -> Double {
    let c = extra + EditorGeometry.trimSnapTargets(duration: model.duration, markers: [model.video?.markerIn, model.video?.markerOut])
      + (playhead ? [playback.time] : [])
    return EditorGeometry.snap(t(x, w), to: c, tolerance: Double(8 / w) * model.duration).value
  }

  // MARK: Filmstrip + trim (yellow handles, marker ticks)

  private func filmstrip(width w: CGFloat) -> some View {
    let tr = model.trim
    let a = x(tr.start, w), b = x(tr.end, w)
    return ZStack(alignment: .topLeading) {
      EditorFilmstripImages(strip: strip, width: w, height: filmH)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
          .onChanged { v in playback.pause(); playback.seek(t(v.location.x, w)) }
          .onEnded { v in playback.seek(t(v.location.x, w), exact: true) })
      // Dim outside the trim.
      Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, a), height: filmH).allowsHitTesting(false)
      Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, w - b), height: filmH).offset(x: b).allowsHitTesting(false)
      // Trim frame.
      Rectangle().stroke(Color.yellow, lineWidth: 2.5)
        .frame(width: max(0, b - a), height: filmH - 2).offset(x: a, y: 1).allowsHitTesting(false)
      markerTicks(width: w)
      trimHandle(at: a, leading: true)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let nt = min(snapped(v.location.x, w), model.trim.end - 0.5)
          model.updateEdit(live: true) { $0.trimIn = nt <= 0.01 ? nil : nt }
          playback.pause(); playback.seek(nt)
        }.onEnded { _ in model.commitTrim() })
      trimHandle(at: b, leading: false)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let nt = max(snapped(v.location.x, w), model.trim.start + 0.5)
          model.updateEdit(live: true) { $0.trimOut = nt >= model.duration - 0.01 ? nil : nt }
          playback.pause(); playback.seek(nt)
        }.onEnded { _ in model.commitTrim() })
    }
    .frame(width: w, height: filmH, alignment: .topLeading)
  }

  private func trimHandle(at x: CGFloat, leading: Bool) -> some View {
    UnevenRoundedRectangle(topLeadingRadius: leading ? 5 : 0, bottomLeadingRadius: leading ? 5 : 0,
                           bottomTrailingRadius: leading ? 0 : 5, topTrailingRadius: leading ? 0 : 5)
      .fill(Color.yellow)
      .overlay(Capsule().fill(Color.black.opacity(0.55)).frame(width: 2, height: 16))
      .frame(width: 11, height: filmH)
      .offset(x: leading ? x - 11 : x)
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .help(leading ? "Trim in (I)" : "Trim out (O)")
  }

  @ViewBuilder private func markerTicks(width w: CGFloat) -> some View {
    ForEach([model.video?.markerIn, model.video?.markerOut].compactMap { $0 }.filter { $0 >= 0 && $0 <= model.duration }, id: \.self) { m in
      VStack(spacing: 0) {
        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.white)
          .shadow(color: .black.opacity(0.6), radius: 1)
        Rectangle().fill(Color.white).frame(width: 1.5).shadow(color: .black.opacity(0.6), radius: 1)
      }
      .frame(width: 10, height: filmH)
      .offset(x: x(m, w) - 5)
      .allowsHitTesting(false)
      .help("Your marker")
    }
  }

  // MARK: Text timing bar

  private func textBar(width w: CGFloat) -> some View {
    let r = model.resolved, tr = model.trim
    let s = tr.start + (r.textStart ?? 0), e = r.textEnd.map { tr.start + $0 } ?? tr.end
    let a = x(min(max(s, tr.start), tr.end), w), b = x(min(max(e, tr.start), tr.end), w)
    let on = r.hasText
    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 5)
        .fill(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.3), lineWidth: 1))
        .overlay(alignment: .leading) {
          Label(on ? Captions.oneLine(r.text) : "No text", systemImage: "textformat")
            .font(.system(size: 10, weight: .medium)).lineLimit(1)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.leading, 10).padding(.trailing, 8)
        }
        .frame(width: max(12, b - a), height: textH)
        .offset(x: a)
        .contentShape(Rectangle())
        .onTapGesture { model.tab = .text }
      if on {
        barGrip().offset(x: a)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
            let t = min(max(snapped(v.location.x, w, extra: [tr.start], playhead: true), tr.start), e - 0.3)
            model.updateVersion { $0.textStart = t - tr.start < 0.02 ? 0 : t - tr.start }
          })
        barGrip().offset(x: b - 6)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
            let t = max(min(snapped(v.location.x, w, extra: [tr.end], playhead: true), tr.end), s + 0.3)
            model.updateVersion { $0.textEnd = t - tr.start }
          })
      }
    }
    .frame(width: w, height: textH, alignment: .leading)
  }

  private func barGrip() -> some View {
    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 6, height: textH)
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .help("Drag to set when the text shows")
  }

  // MARK: Per-platform trim lane

  private func lane(_ p: Platform, width w: CGFloat) -> some View {
    let r = model.edit.platformTrims[p] ?? model.trim
    let a = x(r.start, w), b = x(r.end, w)
    let lim = model.settings.limits[p]?.maxDuration ?? .infinity
    let over = r.duration > lim + 0.05
    let tint: Color = over ? .orange : .yellow
    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)).frame(width: w, height: laneH)
      RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.3))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 1))
        .overlay(Text("\(p.displayName) · \(Validation.fmt(r.duration)) / \(Validation.fmt(lim))")
          .font(.system(size: 9, weight: .semibold)).lineLimit(1).padding(.horizontal, 8), alignment: .leading)
        .frame(width: max(10, b - a), height: laneH).offset(x: a)
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: laneH).offset(x: a)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let t = min(snapped(v.location.x, w), r.end - 0.5)
          model.updateEdit { $0.platformTrims[p]?.start = t }
        })
      RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 6, height: laneH).offset(x: b - 6)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { v in
          let t = max(snapped(v.location.x, w, extra: [r.start + lim]), r.start + 0.5)
          model.updateEdit { $0.platformTrims[p]?.end = t }
        })
    }
    .frame(width: w, height: laneH, alignment: .leading)
  }
}

private struct EditorFilmstripImages: View {
  @ObservedObject var strip: EditorFrameStrip
  var width: CGFloat
  var height: CGFloat
  var body: some View {
    HStack(spacing: 0) {
      if strip.frames.isEmpty {
        Rectangle().fill(Color.secondary.opacity(0.15))
          .overlay { if strip.loading { ProgressView().controlSize(.small) } }
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
      Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(Color.primary)
      Rectangle().fill(Color.primary).frame(width: 1.5)
    }
    .frame(width: 10, height: height + 10)
    .offset(x: x - 5, y: -10)
  }
}

struct EditorPlayIcon: View {
  @ObservedObject var playback: EditorPlayback
  var body: some View {
    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14)).frame(width: 22)
  }
}

private struct EditorTimeLabel: View {
  @ObservedObject var playback: EditorPlayback
  var duration: Double
  var body: some View {
    Text("\(EditorGeometry.time(playback.time, tenths: true)) / \(EditorGeometry.time(duration, tenths: true))")
      .font(.system(size: 12, design: .monospaced)).monospacedDigit()
  }
}
