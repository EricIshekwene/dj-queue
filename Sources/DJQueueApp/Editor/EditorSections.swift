import DJQCore
import SwiftUI

// MARK: - Frame (aspect, crop, zoom, trim)

struct EditorFrameSection: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    EditorSectionView(.frame) {
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

  private var crop: some View {
    EditorField(label: "Crop", help: "Which part of the wide recording is shown", isCustom: model.cropIsSet,
                resetHelp: "Back to the \(model.defaults.cropAnchor.displayName) framing (confirm again)",
                onReset: { model.resetEdit(.crop) }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        if !model.cropIsSet {
          HStack(alignment: .center, spacing: DS.space.xs) {
            EditorHint("Not confirmed yet — check the framing, then confirm", icon: "exclamationmark.circle.fill", tone: .warning)
            Spacer(minLength: 0)
            DSButton("Use this crop", variant: .outline, size: .sm,
                     disabledReason: model.fileMissing ? "The clip file is missing" : nil,
                     tooltip: "Confirm the framing shown on the canvas") { model.confirmCrop() }
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
            DSButton("Edit on canvas", variant: .ghost, size: .sm, tooltip: "Show the whole recording to drag the crop") {
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

// MARK: - Text (overlay text, style, size, alignment, position, timing)

struct EditorTextSection: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let r = model.resolved
    EditorSectionView(.text) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        EditorField(label: "Text on the video", isCustom: !r.isDefault("text"), inheritedFrom: model.source(of: "text"),
                    resetHelp: textResetHelp, onReset: resetter(["text"])) {
          VStack(alignment: .leading, spacing: DS.space.xs) {
            DSTextArea(placeholder: r.noText ? "No text on this clip" : "Text on the video",
                       text: Binding(get: { r.noText ? "" : r.text },
                                     set: { t in model.setText(t) }),
                       minHeight: Self.textAreaHeight(r.noText ? "" : r.text), maxHeight: 120)
              .disabled(r.noText)
              .opacity(r.noText ? 0.55 : 1)
            textSuggestions
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              EditorHint(textHint(r))
              Spacer(minLength: 0)
              if !r.isDefault("text") && model.ownsField(["text"]) && model.defaults.textSource == .title && !r.noText {
                DSButton("Follow the Title", variant: .ghost, size: .sm,
                         tooltip: "Drop the typed text and use the Title again") { model.resetVersion(["text"]) }
              }
            }
            DSToggle("No text", description: nil, isOn: Binding(get: { r.noText }, set: { v in model.setNoText(v) }),
                     size: .sm)
              .dsTooltip("Post this clip without any text on the video")
          }
        }
        EditorField(label: "Style", isCustom: !r.isDefault("style"), inheritedFrom: model.source(of: "style"),
                    resetHelp: "Back to the default style (\(model.defaults.textStyle.displayName))",
                    onReset: resetter(["style"])) {
          HStack(spacing: DS.space.xs) {
            ForEach(TextStyle.allCases, id: \.self) { s in styleTile(s, selected: r.style == s, noText: r.noText) }
          }
        }
        EditorField(label: "Size", value: "\(Self.sizeName(r.size)) · \(Int(r.size))", isCustom: !r.isDefault("size"), inheritedFrom: model.source(of: "size"),
                    resetHelp: "Back to the default size (\(Int(model.defaults.textSize)))", onReset: resetter(["size"])) {
          DSSlider(value: Binding(get: { r.size }, set: { v in model.setVersionField(\.size, \.size, v.rounded()) }),
                   range: 40...110, step: 1, format: { "\(Self.sizeName($0)) · \(Int($0))" }, showsValue: false,
                   disabledReason: r.noText ? noTextReason : nil, accessibilityName: "Text size")
        }
        EditorField(label: "Alignment", isCustom: !r.isDefault("align"), inheritedFrom: model.source(of: "align"),
                    resetHelp: "Back to the default alignment (\(Self.alignName(model.defaults.textAlign)))",
                    onReset: resetter(["align"])) {
          DSSegmented(selection: Binding(get: { r.align }, set: { a in model.setVersionField(\.align, \.align, a) }),
                      segments: [DSSegment(value: TextAlign.left, title: "Left", icon: "text.alignleft"),
                                 DSSegment(value: TextAlign.center, title: "Centre", icon: "text.aligncenter"),
                                 DSSegment(value: TextAlign.right, title: "Right", icon: "text.alignright")],
                      size: .sm, fullWidth: true)
            .disabled(r.noText)
            .opacity(r.noText ? 0.55 : 1)
            // On the wrapper (outside .disabled) so the reason still shows on hover.
            .dsTooltip(nil, disabledReason: r.noText ? noTextReason : nil)
        }
        EditorField(label: "Position", isCustom: !r.isDefault("posX") || !r.isDefault("posY"),
                    inheritedFrom: model.source(of: "posY"), resetHelp: "Back to the default position",
                    onReset: resetter(["posX", "posY"])) {
          VStack(alignment: .leading, spacing: 4) {
            Text(abs(r.posX - 0.5) < 0.001 && abs(r.posY - 0.5) < 0.001 ? "Centre"
                 : String(format: "%.0f %% across · %.0f %% down", r.posX * 100, r.posY * 100))
              .font(DS.type.callout).foregroundStyle(DS.color.text)
            EditorHint("Drag the text on the preview (Zones view).")
          }
        }
        EditorField(label: "Timing", isCustom: !r.isDefault("textStart") || !r.isDefault("textEnd"),
                    inheritedFrom: model.source(of: "textStart"), resetHelp: "Back to the default timing",
                    onReset: resetter(["textStart", "textEnd"])) {
          VStack(alignment: .leading, spacing: 4) {
            Text(r.textStart == nil && r.textEnd == nil ? "Whole clip"
                 : "\(EditorGeometry.time(r.textStart ?? 0, tenths: true)) – \(EditorGeometry.time(r.textEnd ?? model.trim.duration, tenths: true)) after the start")
              .font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.text)
            EditorHint("Drag the ends of the text bar on the timeline.")
          }
        }
      }
    }
  }

  /// Agent suggestions for the text on the video (`text_suggestions`): a tap puts one on this version.
  @ViewBuilder private var textSuggestions: some View {
    if model.textSuggestions.isEmpty {
      HStack(spacing: 6) {
        EditorHint("No text suggestions yet", icon: "text.badge.plus")
        Spacer(minLength: 0)
        DSButton("Ask an agent", icon: "doc.on.clipboard", variant: .ghost, size: .sm,
                 tooltip: "Copy a prompt for your agent: song names, the title and the text on the video") {
          model.copyAgentPrompt()
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text("Text suggestions").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        DSFlowLayout(spacing: 6) {
          ForEach(model.textSuggestions) { s in
            let chosen = model.isCurrentText(s)
            EditorSuggestionChip(text: s.text, detail: s.confidence.map { "\(Int(($0 * 100).rounded())) %" },
                                 chosen: chosen, lineLimit: 4, tooltip: textTooltip(s, chosen: chosen)) {
              model.acceptText(s)
            }
          }
        }
      }
    }
  }

  /// Same shape as the Title chips: the full text first (line breaks as " / "), then what a click does.
  private func textTooltip(_ s: TitleSuggestion, chosen: Bool) -> String {
    let one = s.text.replacingOccurrences(of: "\n", with: " / ")
    var t = "“\(one)” · " + (chosen ? "the text on the video" : "click to put on the video")
    if let v = versionLabel { t += " (\(v))" }
    if !s.source.isEmpty { t += "\nFrom \(s.source)" }
    return t
  }

  /// "v2" when the editor is on a later version, so the tooltip says which one the tap changes.
  private var versionLabel: String? { model.versionNo > 1 ? "v\(model.versionNo)" : nil }

  private func resetter(_ f: [String]) -> (() -> Void)? {
    model.ownsField(f) ? { model.resetVersion(f) } : nil
  }

  private var textResetHelp: String {
    switch model.defaults.textSource {
    case .title: "Back to the Title"
    case .rawTag: "Back to the raw tag"
    case .empty: "Back to no text"
    }
  }

  private func textHint(_ r: ResolvedVersion) -> String {
    if !r.isDefault("text") { return r.noText ? "No text on this clip." : "Typed for this clip." }
    if r.noText { return "Talking clips have no text by default." }
    switch model.defaults.textSource {
    case .title: return model.title == nil ? "Follows the Title — no Title yet. Set one above, or type text here." : "Follows the Title."
    case .rawTag: return "Follows the raw tag (Settings → New clip defaults)."
    case .empty: return "Empty by default (Settings → New clip defaults)."
    }
  }

  /// Tall enough to show every line of a laid-out text (2–5 lines; longer ones scroll).
  static func textAreaHeight(_ text: String) -> CGFloat {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return CGFloat(min(5, max(2, lines))) * 18 + 24
  }

  static func sizeName(_ s: Double) -> String { s < 54 ? "Small" : s <= 76 ? "Medium" : "Large" }
  static func alignName(_ a: TextAlign) -> String { a == .left ? "Left" : a == .right ? "Right" : "Centre" }

  private let noTextReason = "No text is on; turn off No text to style it"

  /// Soft-disabled while No text is on (dimmed, ignores clicks, the tooltip says why).
  private func styleTile(_ s: TextStyle, selected: Bool, noText: Bool) -> some View {
    Button { if !noText { model.setVersionField(\.style, \.style, s) } } label: {
      VStack(spacing: 5) {
        ZStack {
          RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
          sample(s)
        }
        .frame(height: 50)
        .overlay(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
          .strokeBorder(selected ? DS.color.text : Color.clear, lineWidth: 2).padding(-3))
        Text(s.displayName).font(selected ? DS.type.captionMedium : DS.type.caption)
          .foregroundStyle(selected ? DS.color.text : DS.color.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(EditorPressStyle())
    .opacity(noText ? 0.55 : 1)
    .dsTooltip(selected ? "This is the text style" : "Use the \(s.displayName) text style", disabledReason: noText ? noTextReason : nil)
  }

  @ViewBuilder private func sample(_ s: TextStyle) -> some View {
    switch s {
    case .box:
      Text("Aa").font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
        .padding(.horizontal, 8).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(.white))
    case .outline:
      ZStack {
        ForEach(0..<8, id: \.self) { i in
          let a = Double(i) * .pi / 4
          Text("Aa").font(.system(size: 17, weight: .heavy)).foregroundStyle(.black).offset(x: cos(a) * 1.5, y: sin(a) * 1.5)
        }
        Text("Aa").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
      }
    case .shadow:
      Text("Aa").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.9), radius: 3, y: 1)
    }
  }
}

// MARK: - Cover

struct EditorCoverSection: View {
  @ObservedObject var model: EditorModel
  @StateObject private var strip = EditorFrameStrip()
  @State private var cover: CGImage?

  var body: some View {
    EditorSectionView(.cover) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        EditorField(label: "Cover frame", isCustom: !model.isDefault(.coverTime),
                    resetHelp: "Back to the default cover frame (\(model.defaults.coverFrame.displayName))",
                    onReset: { model.resetEdit(.coverTime) }) {
          VStack(alignment: .leading, spacing: DS.space.sm) {
            HStack(alignment: .bottom, spacing: DS.space.sm) {
              ZStack {
                EditorCroppedImage(image: cover, crop: model.crop, source: model.sourceSize)
                if model.resolvedEdit.coverIncludesText, let o = model.overlay { Image(decorative: o, scale: 1).resizable() }
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
        EditorField(label: "Post to", help: "Platforms this clip is posted on", isCustom: !model.isDefault(.platforms),
                    resetHelp: "Back to the default platforms", onReset: { model.resetEdit(.platforms) }) {
          DSFlowLayout(spacing: 6) {
            ForEach(EditorPlatforms.order) { p in
              let enabled = model.settings.enabledPlatforms.contains(p)
              let ownTrim = model.posting(p) && model.edit.platformTrims[p] != nil
              DSChip(p.displayName, icon: ownTrim ? "scissors" : nil, isSelected: model.posting(p),
                     disabledReason: enabled ? nil : "\(p.displayName) is turned off in Settings → Platforms", size: .sm,
                     tooltip: enabled ? (model.posting(p) ? "Skip \(p.displayName) for this clip\(ownTrim ? " (it has its own trim)" : "")"
                                                          : "Post this clip on \(p.displayName) too") : nil) {
                model.setPosting(p, !model.posting(p))
              }
            }
          }
        }
        lengths
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
      EditorField(label: "What the cover does", help: "Through Postiz: how each platform uses this cover") {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(groups, id: \.0) { m, ps in
            HStack(spacing: DS.space.xs) {
              DSBadge(m.label, style: m == .platformPicks ? .outline : .soft(.neutral),
                      icon: m == .thumbnail ? "photo" : m == .coverFrame ? "film" : "questionmark", size: .sm,
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
