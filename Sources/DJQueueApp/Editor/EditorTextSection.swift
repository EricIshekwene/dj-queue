import DJQCore
import SwiftUI

// MARK: - Text (S3, S4-R3): switcher · text · suggestions · No text · Style · Size and position · Advanced

/// Every field edits the selected text. The first text keeps its Default / Custom markers and Title-follow; the others
/// have no default to go back to, so they show neither.
struct EditorTextSection: View {
  @ObservedObject var model: EditorModel
  @ObservedObject private var open = EditorDisclosures.shared

  var body: some View {
    let r = model.resolved
    let l = model.selectedLayer
    let first = model.selectedIsFirst
    let photo = model.isPhoto
    let what = photo ? (model.isCarousel ? "the photos" : "the photo") : "the video"
    EditorSectionView(.text) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        // Round 21 (D7): a photo post starts with no text, and says so with the one thing to do about it.
        if model.photoHasNoTextYet {
          EditorPhotoNoText(model: model).disabled(model.fieldsOff)
        } else {
        if model.texts.count > 1 { switcher.disabled(model.fieldsOff) }
        EditorField(label: "Text on \(what)", isCustom: first && !r.isDefault("text"), inheritedFrom: first ? model.source(of: "text") : nil,
                    resetHelp: textResetHelp, customHelp: photo ? "Typed for this post" : "Changed from your New clip defaults",
                    onReset: resetter(["text"])) {
          VStack(alignment: .leading, spacing: DS.space.xs) {
            DSTextArea(placeholder: r.noText ? "No text on this \(photo ? "post" : "clip")" : first ? "Text on \(what)"
                         : l.countdown != nil ? "Just the number, or words with {n} where it goes" : "Type the new text",
                       text: Binding(get: { r.noText ? "" : l.text }, set: { t in model.setSelectedWords(t) }),
                       minHeight: Self.textAreaHeight(r.noText ? "" : l.text), maxHeight: 120, focusToken: model.focusTextField)
              .disabled(r.noText)
              .opacity(r.noText ? 0.55 : 1)
              .background(ScriptAnchor("Text field"))
            textSuggestions
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              EditorHint(first ? textHint(r) : windowHint(l))
              Spacer(minLength: 0)
              // (A video made from a photo doesn't follow the Title: with nothing typed it has no text.)
              if !photo && !model.namedByFile && first && !r.isDefault("text") && model.ownsField(["text"]) && model.defaults.textSource == .title && !r.noText {
                DSButton("Follow the Title", variant: .ghost, size: .sm,
                         tooltip: "Drop the typed text and use the Title again") { model.resetVersion(["text"]) }
              }
            }
            DSToggle("No text", description: nil, isOn: Binding(get: { r.noText }, set: { v in model.setNoText(v) }),
                     size: .sm)
              .dsTooltip(model.texts.count > 1 ? "Post this \(photo ? "post" : "clip") without any of its texts; they stay saved"
                                               : "Post this \(photo ? "post" : "clip") without any text on \(what)")
              .background(ScriptAnchor("No text"))
          }
        }
        .disabled(model.fieldsOff)
        // Round 26: any text after the first on a clip can count down, in one slot.
        if !first && !photo { countdownField(r, l).disabled(model.fieldsOff) }
        // Which photos the selected text shows on. A single photo has nothing to choose.
        if photo && model.isCarousel { EditorPhotoShowsOn(model: model).disabled(model.fieldsOff) }
        EditorField(label: "Style", isCustom: first && !r.isDefault("style"), inheritedFrom: first ? model.source(of: "style") : nil,
                    resetHelp: "Back to the default style (\(model.defaults.textStyle.displayName))",
                    onReset: resetter(["style"])) {
          HStack(spacing: DS.space.xs) {
            ForEach(TextStyle.allCases, id: \.self) { s in styleTile(s, selected: l.style == s, noText: r.noText) }
          }
        }
        .disabled(model.fieldsOff)
        VStack(alignment: .leading, spacing: 0) {
          DSSeparator()
          DSDisclosure("Size and position", summary: placement(l), isOpen: open.binding(.sizeAndPosition)) {
            VStack(alignment: .leading, spacing: DS.space.md) { sizeField(r, l, first); alignField(r, l, first); positionField(r, l, first) }
              .disabled(model.fieldsOff)
          }
          DSSeparator()
          DSDisclosure("Advanced", summary: advancedSummary(r), isOpen: open.binding(.advanced)) {
            EditorTextAdvanced(model: model).disabled(model.fieldsOff)
          }
        }
        }
      }
    }
  }

  /// Which text the section edits, when there's more than one (S3-R4).
  private var switcher: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
      Text("Editing").font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
      DSFlowLayout(spacing: 4) {
        ForEach(Array(model.texts.enumerated()), id: \.element.id) { i, t in
          DSChip("\(i + 1)", isSelected: t.id == model.selectedText, showsCheck: false, size: .sm, tooltip: Self.textTip(t, number: i + 1)) {
            // On a photo post the canvas goes to a photo the text is on (it draws only what posts).
            if model.isPhoto { model.focusText(t.id) } else { model.selectText(t.id) }
          }
          .background(ScriptAnchor("Text \(i + 1)"))
        }
      }
    }
  }

  private static func textTip(_ t: TextLayer, number: Int) -> String {
    if let n = t.countdown { return "Edit text \(number): countdown \(TextLayers.countdownLabel(t, from: n))" }
    return t.isBlank ? "Edit text \(number) (empty)" : "Edit text \(number): “\(Captions.oneLine(t.text))”"
  }

  /// Round 26: Off · 3 · 5 · 10, like a camera's self-timer (Mobbin: Future Pro's Timer Off · 5s · 10s). A count set
  /// through `djq` that isn't one of them gets its own segment, so the control always shows what's stored.
  private func countdownField(_ r: ResolvedVersion, _ l: TextLayer) -> some View {
    var counts = [3, 5, 10]
    if let n = l.countdown, !counts.contains(n) { counts = (counts + [n]).sorted() }
    let off = r.noText ? noTextReason : nil
    let span = TextTimeline.span(l, trimDuration: model.trim.duration)
    return EditorField(label: "Countdown", help: "Show a count down to 1 in this one text, a number at a time") {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        DSSegmented(selection: Binding(get: { l.countdown ?? 0 }, set: { n in model.setSelectedCountdown(n == 0 ? nil : n) }),
                    segments: [DSSegment(value: 0, title: "Off", tooltip: "A plain text", disabledReason: off)]
                      + counts.map { n in
                        DSSegment(value: n, title: "\(n)", tooltip: l.countdown == nil ? "Count \(TextLayers.countdownLabel(TextLayer(text: ""), from: n)), one number a second, ending where this text ends"
                                                            : "Count \(TextLayers.countdownLabel(TextLayer(text: ""), from: n)) across this text's time",
                                  disabledReason: off)
                      },
                    size: .sm, fullWidth: true)
          .background(ScriptAnchor("Countdown"))
        if let n = l.countdown {
          let each = (span.end - span.start) / Double(n)
          EditorHint("Shows \(TextLayers.countdownLabel(TextLayer(text: ""), from: n)), \(String(format: "%.1f", each)) s each across its time. Type {n} in the text to put words around the number.")
        }
      }
    }
  }

  private func placement(_ l: TextLayer) -> String {
    let row = l.posY < 0.34 ? "Top" : l.posY < 0.67 ? "Middle" : "Bottom"
    return "\(Self.sizeName(l.size)) · \(Self.alignName(l.align)) · \(row)"
  }

  private func advancedSummary(_ r: ResolvedVersion) -> String? {
    let n = r.moreText.count
    if n > 0 { return n == 1 ? "1 more text" : "\(n) more texts" }
    return r.textLook == nil ? nil : "Custom look"
  }

  private func windowHint(_ l: TextLayer) -> String {
    if model.isPhoto { return "Text \(model.selectedNumber) · \(model.textRangeLabel(l.id).lowercased())" }
    let s = TextTimeline.span(l, trimDuration: model.trim.duration)
    return "Text \(model.selectedNumber) · shows \(EditorGeometry.time(s.start, tenths: true)) – \(EditorGeometry.time(s.end, tenths: true))"
  }

  private func sizeField(_ r: ResolvedVersion, _ l: TextLayer, _ first: Bool) -> some View {
    EditorField(label: "Size", value: "\(Self.sizeName(l.size)) · \(Int(l.size))", isCustom: first && !r.isDefault("size"),
                inheritedFrom: first ? model.source(of: "size") : nil,
                resetHelp: "Back to the default size (\(Int(model.defaults.textSize)))", onReset: resetter(["size"])) {
      DSSlider(value: Binding(get: { l.size }, set: { v in model.setSelectedSize(v.rounded()) }),
               range: 40...110, step: 1, format: { "\(Self.sizeName($0)) · \(Int($0))" }, showsValue: false,
               disabledReason: r.noText ? noTextReason : nil, accessibilityName: "Text size")
    }
  }

  private func alignField(_ r: ResolvedVersion, _ l: TextLayer, _ first: Bool) -> some View {
    EditorField(label: "Alignment", isCustom: first && !r.isDefault("align"), inheritedFrom: first ? model.source(of: "align") : nil,
                resetHelp: "Back to the default alignment (\(Self.alignName(model.defaults.textAlign)))",
                onReset: resetter(["align"])) {
      DSSegmented(selection: Binding(get: { l.align }, set: { a in model.setSelectedAlign(a) }),
                  segments: [DSSegment(value: TextAlign.left, title: "Left", icon: "text.alignleft"),
                             DSSegment(value: TextAlign.center, title: "Centre", icon: "text.aligncenter"),
                             DSSegment(value: TextAlign.right, title: "Right", icon: "text.alignright")],
                  size: .sm, fullWidth: true)
        .disabled(r.noText)
        .opacity(r.noText ? 0.55 : 1)
        // On the wrapper (outside .disabled) so the reason still shows on hover.
        .dsTooltip(nil, disabledReason: r.noText ? noTextReason : nil)
    }
  }

  private func positionField(_ r: ResolvedVersion, _ l: TextLayer, _ first: Bool) -> some View {
    EditorField(label: "Position", isCustom: first && (!r.isDefault("posX") || !r.isDefault("posY")),
                inheritedFrom: first ? model.source(of: "posY") : nil, resetHelp: "Back to the default position",
                onReset: resetter(["posX", "posY"])) {
      VStack(alignment: .leading, spacing: 4) {
        Text(abs(l.posX - 0.5) < 0.001 && abs(l.posY - 0.5) < 0.001 ? "Centre"
             : String(format: "%.0f %% across · %.0f %% down", l.posX * 100, l.posY * 100))
          .font(DS.type.callout).foregroundStyle(DS.color.text)
        EditorHint("Drag the text on the preview (Zones view).")
      }
    }
  }

  /// Agent suggestions for the text on the video (`text_suggestions`): a tap puts one on the selected text.
  @ViewBuilder private var textSuggestions: some View {
    if model.textSuggestions.isEmpty {
      // Round 21: the agent prompt asks for song names, which a photo doesn't have (nor a video made from one, round 23).
      if !model.namedByFile { HStack(spacing: 6) {
        EditorHint("No text suggestions yet", icon: "text.badge.plus")
        Spacer(minLength: 0)
        DSButton("Ask an agent", icon: "doc.on.clipboard", variant: .ghost, size: .sm,
                 tooltip: "Copy a prompt for your agent: song names, the title and the text on the video") {
          model.copyAgentPrompt()
        }
      } }
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

  /// Reset applies to the first text only: the others have no default to go back to.
  private func resetter(_ f: [String]) -> (() -> Void)? {
    model.selectedIsFirst && model.ownsField(f) ? { model.resetVersion(f) } : nil
  }

  private var textResetHelp: String {
    if model.namedByFile { return "Take this text off (back to no text)" }
    switch model.defaults.textSource {
    case .title: return "Back to the Title"
    case .rawTag: return "Back to the raw tag"
    case .empty: return "Back to no text"
    }
  }

  private func textHint(_ r: ResolvedVersion) -> String {
    if model.isPhoto { return r.noText ? "No text on this post." : model.isCarousel ? "Shows on \(model.textRangeLabel(TextLayer.firstId).lowercased())." : "Typed for this post." }
    if !r.isDefault("text") { return r.noText ? "No text on this clip." : "Typed for this clip." }
    if r.noText { return model.video?.isStill == true ? "A photo with audio starts with no text." : "Talking clips have no text by default." }
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
    Button { if !noText { model.setSelectedStyle(s) } } label: {
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
    .background(ScriptAnchor("Style \(s.displayName)"))
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

// MARK: - Advanced (S3-R3): add, duplicate and delete; when it shows; font, colours, opacity, spacing

private struct EditorTextAdvanced: View {
  @ObservedObject var model: EditorModel

  /// The names of `TextLook.swatches`, in their order.
  private static let swatches: [DSColorSwatches.Swatch] =
    zip(TextLook.swatches, ["White", "Black", "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"])
      .map { DSColorSwatches.Swatch(hex: $0, name: $1) }

  var body: some View {
    let r = model.resolved
    let l = model.selectedLayer
    let look = l.look ?? TextLook()
    let off: String? = r.noText ? "No text is on; turn off No text to style it" : nil
    VStack(alignment: .leading, spacing: DS.space.md) {
      actions
      // Round 21: a photo post has no seconds. Which photos a text shows on is the "Shows on" row above.
      if !model.isPhoto { timing(r, l) }
      EditorField(label: "Font", isCustom: look.font != nil, resetHelp: "Back to the default font",
                  onReset: look.font == nil ? nil : { model.setLook { $0.font = nil } }) {
        DSSelect(selection: Binding(get: { look.font ?? .standard }, set: { f in model.setLook { $0.font = f } }),
                 options: fonts(including: look.font).map { DSSelectOption(value: $0, title: $0.displayName) },
                 size: .sm, disabledReason: off)
          .background(ScriptAnchor("Font"))
      }
      colour("Text colour", hex: look.color, fallback: TextLook.defaultColor(l.style), off: off) { h, coalesce in
        model.setLook(coalesce: coalesce) { $0.color = h }
      }
      colour(Self.accentLabel(l.style), hex: look.accent, fallback: TextLook.defaultAccent(l.style), off: off) { h, coalesce in
        model.setLook(coalesce: coalesce) { $0.accent = h }
      }
      EditorField(label: "Opacity", value: "\(Int(((look.opacity ?? 1) * 100).rounded())) %", isCustom: look.opacity != nil,
                  resetHelp: "Back to fully opaque", onReset: look.opacity == nil ? nil : { model.setLook { $0.opacity = nil } }) {
        DSSlider(value: Binding(get: { look.opacity ?? 1 }, set: { v in model.setLook(coalesce: true) { $0.opacity = v } }),
                 range: TextLook.opacityRange, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" }, showsValue: false,
                 disabledReason: off, accessibilityName: "Opacity")
      }
      EditorField(label: "Letter spacing", value: Self.spacingText(look.tracking ?? 0), isCustom: look.tracking != nil,
                  resetHelp: "Back to normal spacing", onReset: look.tracking == nil ? nil : { model.setLook { $0.tracking = nil } }) {
        DSSlider(value: Binding(get: { look.tracking ?? 0 }, set: { v in model.setLook(coalesce: true) { $0.tracking = v } }),
                 range: TextLook.trackingRange, step: 0.01, format: Self.spacingText, showsValue: false,
                 disabledReason: off, accessibilityName: "Letter spacing")
      }
      DSButton("Back to default look", icon: "arrow.uturn.backward", variant: .ghost, size: .sm,
               disabledReason: look.isDefault ? "This text has the default look" : nil,
               tooltip: "Default font, colours, opacity and spacing for this text") { model.resetLook() }
        .padding(.leading, -8)
        .background(ScriptAnchor("Back to default look"))
    }
  }

  private static func spacingText(_ t: Double) -> String { String(format: abs(t) < 0.005 ? "%.0f %%" : "%+.0f %%", abs(t) < 0.005 ? 0 : t * 100) }

  /// The second colour is the box, the outline or the shadow, by style.
  private static func accentLabel(_ s: TextStyle) -> String {
    switch s {
    case .box: "Box colour"
    case .outline: "Outline colour"
    case .shadow: "Shadow colour"
    }
  }

  private var actions: some View {
    HStack(spacing: 6) {
      DSButton("Add text", icon: "plus", variant: .outline, size: .sm, disabledReason: model.addTextOffReason,
               tooltip: !model.isPhoto ? "Add a text at the playhead, looking like this one"
                 : model.isCarousel ? "Add a text on photo \(model.photoIndex + 1), looking like this one" : "Add another text, looking like this one") { model.addText() }
        .background(ScriptAnchor("Add text"))
      DSButton("Duplicate", variant: .ghost, size: .sm, disabledReason: model.addTextOffReason,
               tooltip: model.isPhoto ? "Copy this text" : "Copy this text, right after it on the timeline") { model.duplicateText() }
        .background(ScriptAnchor("Duplicate"))
      DSButton("Delete", variant: .ghost, size: .sm, disabledReason: model.deleteTextOffReason,
               tooltip: model.selectedIsFirst ? "Delete this text; the next one takes its place" : "Delete this text") { model.deleteText() }
        .background(ScriptAnchor("Delete"))
      Spacer(minLength: 0)
    }
  }

  /// When the selected text shows. The first text keeps its Custom tag and ↺, which go back to the default timing and so
  /// follow the trim again; the others have no default.
  private func timing(_ r: ResolvedVersion, _ l: TextLayer) -> some View {
    let s = TextTimeline.span(l, trimDuration: model.trim.duration)
    let first = model.selectedIsFirst
    let off: String? = r.noText ? "No text is on; turn it off to change when this shows" : nil
    let fields = ["textStart", "textEnd"]
    return EditorField(label: "Timing", isCustom: first && (!r.isDefault("textStart") || !r.isDefault("textEnd")),
                       inheritedFrom: first ? model.source(of: "textStart") : nil, resetHelp: "Back to the default timing",
                       onReset: first && model.ownsField(fields) ? { model.resetVersion(fields) } : nil) {
      VStack(alignment: .leading, spacing: 6) {
        EditorTimeRow(model: model, id: l.id, token: model.timeDraftToken, isStart: true, label: "Show from", seconds: s.start, off: off, tooltip: "Start this text at the playhead")
        EditorTimeRow(model: model, id: l.id, token: model.timeDraftToken, isStart: false, label: "Show to", seconds: s.end, off: off, tooltip: "End this text at the playhead")
        EditorHint("Seconds from the start of the clip as posted.")
      }
    }
    .id("\(model.videoId)|\(model.versionNo)|\(l.id)|\(model.timeDraftToken)")
  }

  private func colour(_ label: String, hex: String?, fallback: String, off: String?, set: @escaping (String?, Bool) -> Void) -> some View {
    let shown = hex ?? fallback
    return EditorField(label: label, value: shown, isCustom: hex != nil, resetHelp: "Back to the default \(label.lowercased())",
                       onReset: hex == nil ? nil : { set(nil, false) }) {
      // The default colour is no colour: picking it never writes a custom look.
      DSColorSwatches(name: label.lowercased(), swatches: Self.swatches, selection: shown, disabledReason: off,
                      onPick: { set($0 == fallback ? nil : $0, false) }, onCustom: { set($0 == fallback ? nil : $0, true) })
    }
  }

  /// The curated fonts this Mac has, plus the chosen one even if it doesn't (it draws in the fallback font).
  private func fonts(including chosen: TextFont?) -> [TextFont] {
    TextFont.allCases.filter { f in f == chosen || f.postScriptName.map { NSFont(name: $0, size: 12) != nil } ?? true }
  }
}

/// A typed time with a Use playhead button. It commits on ↩ or when the keyboard leaves, so typing "1.5" doesn't land "1"
/// first; a time that isn't one says so and changes nothing. The model holds what's typed, so a clip or version change
/// commits it to this text first (`EditorModel.commitTimeDraft`).
private struct EditorTimeRow: View {
  @ObservedObject var model: EditorModel
  let id: String
  /// `EditorModel.timeDraftToken` when this row was made. A newer one means it's on its way out, so it passes nothing on.
  let token: Int
  let isStart: Bool
  let label: String
  let seconds: Double
  let off: String?
  let tooltip: String
  @State private var draft: String?
  @State private var invalid = false

  private var shown: String { EditorGeometry.time(seconds, tenths: true) }

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Text(label).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).frame(width: 66, height: DSButtonSize.sm.height, alignment: .leading)
      DSTextField(placeholder: "0:00.0", text: Binding(get: { draft ?? shown }, set: { t in
        guard token == model.timeDraftToken else { return }
        draft = t
        invalid = false
        model.timeDraft = t == shown ? nil : (id, isStart, t)
      }), error: invalid ? "Use a time like 0:03.5" : nil, size: .sm, onSubmit: finish)
        .whenBlurred(finish)
        .disabled(off != nil)
        .opacity(off == nil ? 1 : 0.55)
        // Outside .disabled, so the reason still shows on hover.
        .dsTooltip(nil, disabledReason: off)
        .background(ScriptAnchor(label))
      DSButton("Use playhead", icon: "scope", variant: .ghost, size: .sm, disabledReason: off, tooltip: tooltip) {
        draft = nil
        invalid = false
        model.timeDraft = nil
        let t = model.playback.time - model.trim.start
        if isStart { model.setTextTime(id, start: t) } else { model.setTextTime(id, end: t) }
      }
      .fixedSize()
      .background(ScriptAnchor("\(label) playhead"))
    }
    .onDisappear(perform: finish)
  }

  /// A draft the model has already applied, or dropped, just clears here.
  private func finish() {
    guard let d = draft else { return }
    guard token == model.timeDraftToken else { draft = nil; return }
    if d != shown, TextTimeline.parse(d) == nil, model.timeDraft != nil {
      invalid = true
      return
    }
    draft = nil
    model.commitTimeDraft()
  }
}
