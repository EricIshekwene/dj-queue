import DJQCore
import SwiftUI

// MARK: - Frame (aspect, crop, zoom, trim)

struct EditorFrameSection: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    EditorCollapsibleSection(.frame, disclosure: .frame, summary: summary, model: model) {
      if model.isPhoto {
        // Round 21: one shape for the post and a crop per photo; nothing to trim.
        EditorPhotoFrameFields(model: model)
      } else {
        VStack(alignment: .leading, spacing: DS.space.md) {
          EditorField(label: "Aspect", help: "Output shape of the video", isCustom: !model.isDefault(.aspect),
                      resetHelp: "Back to the default aspect (\(model.defaults.aspect.rawValue))",
                      onReset: { model.setAspect(model.defaults.aspect) }) {
            DSSegmented(selection: Binding(get: { model.aspect }, set: { model.setAspect($0) }),
                        segments: Aspect.allCases.map { DSSegment(value: $0, title: $0.rawValue) }, size: .sm, fullWidth: true)
          }
          crop
          trim
        }
      }
    }
  }

  /// Round 23: a video made from a photo isn't a "wide recording", and its framing never follows the anchor in Settings.
  private var cropHelp: String {
    guard model.video?.isStill == true else { return "Which part of the wide recording is shown" }
    return model.isWholePhoto ? "The whole photo is shown. Zoom in to show part of the frame" : "Which part of the photo is shown"
  }
  private var cropResetHelp: String {
    guard model.video?.isStill == true else { return "Back to the \(model.defaults.cropAnchor.displayName) framing (confirm again)" }
    return model.isWholePhoto ? Self.wholeResetHelp : "Back to the centred framing (confirm again)"
  }
  /// Also the name scripted runs find the Reset by.
  static let wholeResetHelp = "Back to the whole photo"

  private var summary: String {
    if model.isPhoto { return model.aspect.rawValue + (model.cropIsSet ? " · Your crop" : " · Centred crop") }
    return model.aspect.rawValue + (model.cropIsSet ? " · Crop confirmed" : " · Default crop")
  }

  private var crop: some View {
    EditorField(label: "Crop", help: cropHelp, isCustom: model.cropIsCustom, resetHelp: cropResetHelp,
                customHelp: model.isWholePhoto ? "Zoomed in or moved: part of the frame is shown" : "Changed from your New clip defaults",
                onReset: { model.resetEdit(.crop) }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        if !model.cropIsSet {
          HStack(alignment: .center, spacing: DS.space.xs) {
            EditorHint("Not confirmed yet — check the framing, then confirm", icon: "exclamationmark.circle.fill", tone: .warning)
            Spacer(minLength: 0)
            DSButton("Use this crop", variant: .outline, size: .sm,
                     disabledReason: model.fileMissing ? "The clip file is missing" : nil,
                     tooltip: "Confirm the framing shown on the canvas") { model.confirmCrop() }
              .background(ScriptAnchor("Use this crop"))
          }
        }
        // Zoom and Place are part of Crop, so they get small secondary labels, not field headers.
        HStack(spacing: DS.space.xs) {
          Text("Zoom").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).frame(width: 34, alignment: .leading)
            .accessibilityHidden(true)
          DSSlider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                   range: 1...EditorGeometry.maxZoom, step: 0.05, format: Self.zoomText, showsValue: false, accessibilityName: "Zoom")
            .dsTooltip("Zoom in; or scroll/pinch on the Frame view")
          Text(Self.zoomText(model.zoom)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
            .frame(width: 38, alignment: .trailing)
            .accessibilityHidden(true)
        }
        HStack(spacing: 6) {
          Text("Place").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).frame(width: 34, alignment: .leading)
          DSButton("Left", variant: .outline, size: .sm, tooltip: "Centre the crop on the left third") { model.placeCrop(atX: 1.0 / 3) }
          DSButton("Centre", variant: .outline, size: .sm, tooltip: "Centre the crop") { model.placeCrop(atX: 0.5) }
          DSButton("Right", variant: .outline, size: .sm, tooltip: "Centre the crop on the right third") { model.placeCrop(atX: 2.0 / 3) }
          Spacer(minLength: 0)
        }
        HStack(spacing: 6) {
          if model.upscale > 1.01 {
            DSBadge(String(format: "Upscaled %.1f×", model.upscale), style: .soft(.warning), icon: "exclamationmark.triangle.fill")
              .dsTooltip("The crop is under 1080 px wide, so it looks softer")
          }
          Text("\(Int(model.crop.w)) × \(Int(model.crop.h)) px").font(DS.type.mono).foregroundStyle(DS.color.textTertiary)
          Spacer(minLength: 0)
          if model.canvasMode != .frame {
            DSButton("Edit on canvas", variant: .ghost, size: .sm, tooltip: model.video?.isStill == true ? "Show the whole picture to drag the crop" : "Show the whole recording to drag the crop") {
              model.canvasMode = .frame
            }
          }
        }
      }
    }
  }

  private static func zoomText(_ z: Double) -> String { String(format: "%.2f×", z) }

  private var trim: some View {
    let t = model.trim
    let hasMarkers = model.video?.markerIn != nil && model.video?.markerOut != nil
    return EditorField(label: "Trim", help: "Which seconds of the clip file are posted", isCustom: !model.trimIsDefault,
                       resetHelp: hasMarkers ? "Reset the trim to your in/out markers" : "Reset the trim to the whole file",
                       onReset: { model.resetEdit(.trimIn, .trimOut); model.commitTrim() }) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("\(EditorGeometry.time(t.start, tenths: true)) – \(EditorGeometry.time(t.end, tenths: true))")
            .font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.text)
          Text(String(format: "%.1f s", t.duration)).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          Spacer(minLength: 0)
          if !model.trimIsDefault && hasMarkers {
            DSButton("Trim to markers", variant: .ghost, size: .sm, tooltip: "Back to your in/out markers") {
              model.resetEdit(.trimIn, .trimOut); model.commitTrim()
            }
          }
        }
        EditorHint(hasMarkers ? (model.trimIsDefault ? "Your markers. Drag a handle into the striped grace zone to extend."
                                                     : "Changed from your markers.")
                              : "No markers on this clip — the whole file is used.")
      }
    }
  }
}

// MARK: - Cover

struct EditorCoverSection: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    EditorCollapsibleSection(.cover, disclosure: .cover, summary: summary, model: model) {
      EditorCoverFields(model: model)
    }
  }

  private var summary: String {
    EditorGeometry.time(model.coverTime, tenths: true) + (model.coverHasText ? " · With text" : " · No text")
  }
}

/// What's inside the Cover row: only there while it's open, so a closed row loads no frames.
private struct EditorCoverFields: View {
  @ObservedObject var model: EditorModel
  @StateObject private var strip = EditorFrameStrip()
  @State private var cover: CGImage?

  var body: some View {
    Group {
      VStack(alignment: .leading, spacing: DS.space.md) {
        EditorField(label: "Cover frame", isCustom: !model.isDefault(.coverTime),
                    resetHelp: "Back to the default cover frame (\(model.defaults.coverFrame.displayName))",
                    onReset: { model.resetEdit(.coverTime) }) {
          VStack(alignment: .leading, spacing: DS.space.sm) {
            HStack(alignment: .bottom, spacing: DS.space.sm) {
              ZStack {
                EditorCroppedImage(image: cover, crop: model.crop, source: model.sourceSize)
                ForEach(model.coverTextImages) { Image(decorative: $0.image, scale: 1).resizable() }
              }
              .aspectRatio(model.aspect.ratio, contentMode: .fit)
              .frame(height: 176)
              .clipShape(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
              .dsBorder(radius: DS.radius.sm)
              VStack(alignment: .leading, spacing: 4) {
                Text(EditorGeometry.time(model.coverTime, tenths: true)).font(DS.type.callout.monospacedDigit())
                  .foregroundStyle(DS.color.text)
                Text(model.isDefault(.coverTime) ? model.defaults.coverFrame.displayName : "Picked frame")
                  .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
                DSButton("Use playhead", icon: "scope", variant: .ghost, size: .sm,
                         tooltip: "Use the frame under the timeline playhead") { set(model.playback.time) }
                  .padding(.leading, -8)
              }
            }
            filmstrip
          }
        }
        EditorField(label: "Cover text", isCustom: !model.isDefault(.coverIncludesText),
                    resetHelp: "Back to the default (\(model.defaults.coverIncludesText ? "with" : "without") text)",
                    onReset: { model.resetEdit(.coverIncludesText) }) {
          DSToggle("Include text on the cover", isOn: Binding(get: { model.resolvedEdit.coverIncludesText },
                                                               set: { model.setCoverIncludesText($0) }), size: .sm)
            .dsTooltip("Draw the overlay text on the cover image too")
        }
        EditorCoverMeaning(platforms: model.postingPlatforms)
      }
    }
    .onAppear { reload() }
    .onChange(of: model.trim) { _, _ in if !model.trimDragging { reload() } }  // regenerate once the drag ends
    .onChange(of: model.trimDragging) { _, dragging in if !dragging { reload() } }
    .onChange(of: model.videoId) { _, _ in reload() }
    .onChange(of: model.coverTime) { _, _ in loadCover() }
  }

  private var filmstrip: some View {
    HStack(spacing: 3) {
      let nearest = strip.frames.indices.min { abs(strip.frames[$0].time - model.coverTime) < abs(strip.frames[$1].time - model.coverTime) }
      ForEach(Array(strip.frames.enumerated()), id: \.offset) { i, f in
        let sel = i == nearest
        EditorCroppedImage(image: f.image, crop: model.crop, source: model.sourceSize)
          .aspectRatio(model.aspect.ratio, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: DS.radius.xs - 2, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: DS.radius.xs - 2, style: .continuous)
            .strokeBorder(sel ? DS.color.text : .clear, lineWidth: 2))
          .contentShape(Rectangle())
          .onTapGesture { set(f.time) }
          .dsTooltip("Use the frame at \(EditorGeometry.time(f.time, tenths: true)) as the cover")
      }
      if strip.frames.isEmpty {
        RoundedRectangle(cornerRadius: DS.radius.xs).fill(DS.color.surfaceSunken).frame(height: 54)
      }
    }
  }

  private func set(_ t: Double) {
    model.setCover(t)
    model.playback.pause()
    model.playback.seek(model.coverTime, exact: true)
  }

  private func reload() {
    strip.load(url: model.fileMissing ? nil : model.fileURL, from: model.trim.start, to: model.trim.end, count: 8,
               sync: model.snapshotMode)
    loadCover()
  }

  private func loadCover() {
    guard let url = model.fileURL, !model.fileMissing else { cover = nil; return }
    let t = model.coverTime
    if model.snapshotMode { cover = Media.frame(url, at: t, maxSize: CGSize(width: 1280, height: 720)); return }
    Task.detached(priority: .userInitiated) {
      let img = Media.frame(url, at: t, maxSize: CGSize(width: 1280, height: 720))
      await MainActor.run { if abs(t - model.coverTime) < 0.001 { cover = img } }
    }
  }
}

// MARK: - Platforms (post to, per-platform length)

struct EditorPlatformsSection: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    EditorSectionView(.platforms) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        EditorField(label: "Post to", help: "Platforms this \(model.isPhoto ? "post goes out" : "clip is posted") on", isCustom: !model.isDefault(.platforms),
                    resetHelp: "Back to the default platforms", onReset: { model.resetEdit(.platforms) }) {
          DSFlowLayout(spacing: 6) {
            ForEach(EditorPlatforms.order) { p in
              let enabled = model.settings.enabledPlatforms.contains(p)
              let ownTrim = model.posting(p) && model.edit.platformTrims[p] != nil
              // Round 21 (D8): a platform that takes no photos is off for a photo post and says why.
              let never = model.isPhoto && !p.supportsPhotos
              let what = model.isPhoto ? "post" : "clip"
              DSChip(p.displayName, icon: ownTrim ? "scissors" : nil, isSelected: model.posting(p),
                     disabledReason: never ? PhotoRules.youtubeReason : enabled ? nil : "\(p.displayName) is turned off in Settings → Platforms", size: .sm,
                     tooltip: enabled ? (model.posting(p) ? "Skip \(p.displayName) for this \(what)\(ownTrim ? " (it has its own trim)" : "")"
                                                          : "Post this \(what) on \(p.displayName) too") : nil) {
                model.setPosting(p, !model.posting(p))
              }
              .background(ScriptAnchor("Post to \(p.displayName)"))
            }
          }
        }
        if model.isPhoto { EditorPhotoPlatformNotes(model: model) } else { lengths }
        EditorHint("Safe zones are a view setting: pick platforms under the preview in the Zones view.", icon: "rectangle.dashed")
      }
    }
  }

  /// F6: every platform the clip is too long for (posting or skipped because of it) and every platform with its own
  /// trim. Too long → two clear choices, "Trim for X" (adds X's trim lane cut at X's limit) and "Skip X"; the row
  /// then says what happened ("X posts its own 1:30 trim" / "X skipped for this clip") with the way back.
  @ViewBuilder private var lengths: some View {
    let rows = EditorPlatforms.order.compactMap { p -> (Platform, Double, Double)? in
      guard model.settings.enabledPlatforms.contains(p), let lim = model.settings.limits[p]?.maxDuration else { return nil }
      let d = model.resolvedEdit.trim(platform: p).duration
      let mainTooLong = model.trim.duration > lim + 0.05
      if model.posting(p) { return d > lim + 0.05 || model.edit.platformTrims[p] != nil ? (p, d, lim) : nil }
      return mainTooLong ? (p, d, lim) : nil  // skipped: shown while the main trim is still too long for it
    }
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        ForEach(rows, id: \.0) { p, d, lim in lengthRow(p, d, lim) }
      }
    }
  }

  @ViewBuilder private func lengthRow(_ p: Platform, _ d: Double, _ lim: Double) -> some View {
    let name = p.displayName
    let over = d > lim + 0.05
    VStack(alignment: .leading, spacing: 6) {
      if !model.posting(p) {
        EditorHint("\(name) skipped for this clip · \(Validation.fmt(model.trim.duration)) is over its \(Validation.fmt(lim))",
                   icon: "forward", tone: nil)
        DSButton("Post on \(name) again", variant: .ghost, size: .sm,
                 tooltip: "Post this clip on \(name) too (it still needs a \(name) trim)") { model.setPosting(p, true) }
          .padding(.leading, -8)
      } else if over {
        EditorHint("Too long for \(name) · \(Validation.fmt(d)) / \(Validation.fmt(lim)) — trim it for \(name) or skip \(name)",
                   icon: "exclamationmark.triangle.fill", tone: .warning)
        HStack(spacing: 6) {
          if model.edit.platformTrims[p] == nil {
            DSButton("Trim for \(name)", icon: "scissors", variant: .outline, size: .sm,
                     tooltip: "Add a \(name)-only trim lane cut at \(Validation.fmt(lim))") { model.addPlatformTrim(p) }
          }
          DSButton("Skip \(name)", icon: "forward", variant: .ghost, size: .sm,
                   tooltip: "Don't post this clip on \(name); the other platforms keep the full length") { model.setPosting(p, false) }
        }
      } else {
        EditorHint("\(name) posts its own \(Validation.fmt(d)) trim · the timeline's \(name) lane", icon: "scissors", tone: .success)
        DSButton("Remove \(name) trim", variant: .ghost, size: .sm, tooltip: "Delete the \(name)-only trim; use the main one") {
          model.updateEdit { $0.platformTrims[p] = nil }
        }
        .padding(.leading, -8)
      }
    }
  }
}

/// F2: what the cover does on each platform it posts to through Postiz (core `CoverMeaning`), one line per meaning:
/// "Thumbnail · YouTube Shorts", "Cover frame · Instagram, TikTok", "Platform picks · Facebook, Threads, X".
struct EditorCoverMeaning: View {
  let platforms: [Platform]

  /// Core's sentence, naming every platform in the group ("Instagram and TikTok use the frame …").
  static func meaningText(_ m: CoverMeaning, _ ps: [Platform]) -> String {
    let first = m.detail(ps[0])
    guard ps.count > 1 else { return first }
    let names = ps.dropLast().map(\.displayName).joined(separator: ", ") + " and " + ps.last!.displayName
    return first.replacingOccurrences(of: ps[0].displayName + " uses", with: names + " use")
      .replacingOccurrences(of: ps[0].displayName + " picks its", with: names + " pick their")
      .replacingOccurrences(of: ps[0].displayName, with: names)
  }

  var body: some View {
    let groups = CoverMeaning.allCases.compactMap { m -> (CoverMeaning, [Platform])? in
      let ps = EditorPlatforms.order.filter { platforms.contains($0) && CoverMeaning.of($0) == m }
      return ps.isEmpty ? nil : (m, ps)
    }
    if !groups.isEmpty {
      EditorField(label: "What the cover does", help: "How each platform uses this cover when Postiz posts it") {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(groups, id: \.0) { m, ps in
            HStack(spacing: DS.space.xs) {
              DSBadge(m.label, style: m == .platformPicks ? .outline : .soft(.neutral),
                      icon: m == .thumbnail ? "photo" : m == .coverFrame ? "film" : "rectangle.dashed", size: .sm,
                      help: Self.meaningText(m, ps))
              Text(ps.map(\.displayName).joined(separator: ", ")).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }
}
