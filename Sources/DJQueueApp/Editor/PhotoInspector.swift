import DJQCore
import SwiftUI

// Round 21: what the inspector shows for a photo post where a clip's fields don't apply (DECISIONS-R21.md D5, D7, D8,
// D9, D20). Every section is the clip's own; these are the parts inside them that differ.

// MARK: - Frame: one shape for the post, a crop per photo

struct EditorPhotoFrameFields: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.md) {
      shape
      crop
    }
  }

  /// The shape picker (D5): the four shapes with their marks, and what a platform that refuses one says (D20) with the
  /// two ways out, one click each.
  private var shape: some View {
    let posting = model.postingPlatforms
    let refusing = PhotoRules.refusing(model.aspect, posting: posting)
    return EditorField(label: "Shape", help: "Every photo of this post is cropped to this shape", isCustom: !model.isDefault(.aspect),
                       resetHelp: "Back to the default shape (\(model.defaults.photoAspect.rawValue))",
                       onReset: { model.setAspect(model.defaults.photoAspect) }) {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        DSSegmented(selection: Binding(get: { model.aspect }, set: { model.setAspect($0) }),
                    segments: PhotoRules.aspects.map { a in
                      DSSegment(value: a, title: a.rawValue, icon: Self.mark(a), tooltip: Self.tip(a, posting: posting))
                    }, size: .sm, fullWidth: true)
          .background(ScriptAnchor("Shape"))
        ForEach(refusing) { p in
          EditorHint(PhotoRules.shapeProblem(model.aspect, platform: p) ?? "", icon: "exclamationmark.triangle.fill", tone: .warning)
          DSFlowLayout(spacing: 6) {
            if let fix = Self.fix(posting: posting, defaults: model.defaults) {
              DSButton("Use \(fix.rawValue)", variant: .outline, size: .sm,
                       tooltip: "Change this post's shape to \(fix.rawValue), which every platform it posts on takes") { model.setAspect(fix) }
                .background(ScriptAnchor("Use \(fix.rawValue)"))
            }
            DSButton("Turn \(p.displayName) off for this post", variant: .ghost, size: .sm,
                     tooltip: "Keep \(model.aspect.rawValue) and skip \(p.displayName) for this post") { model.setPosting(p, false) }
              .background(ScriptAnchor("Turn \(p.displayName) off"))
          }
        }
      }
    }
  }

  /// The shape a refused post can change to: the default when every posting platform takes it, else the first that fits.
  static func fix(posting: [Platform], defaults: NewClipDefaults) -> Aspect? {
    ([defaults.photoAspect] + PhotoRules.aspects).first { PhotoRules.refusing($0, posting: posting).isEmpty }
  }

  private static func mark(_ a: Aspect) -> String {
    switch a {
    case .r4x5: "rectangle.ratio.3.to.4"
    case .r1x1: "square"
    case .r9x16: "rectangle.ratio.9.to.16"
    case .r16x9: "rectangle.ratio.16.to.9"
    }
  }

  private static func tip(_ a: Aspect, posting: [Platform]) -> String {
    let out = a.outputSize
    let name = switch a {
    case .r4x5: "Portrait"
    case .r1x1: "Square"
    case .r9x16: "Full screen"
    case .r16x9: "Landscape"
    }
    let base = "\(name), \(out.w) × \(out.h)"
    return PhotoRules.aspectNote(a, posting: posting).map { "\(base) · \($0)" } ?? base
  }

  /// The current photo's crop: zoom, its size in pixels, and the canvas for dragging it.
  private var crop: some View {
    let n = model.photoCount, i = model.photoIndex
    return EditorField(label: n > 1 ? "Crop of photo \(i + 1)" : "Crop", help: "Which part of this photo is shown", isCustom: model.cropIsSet,
                       resetHelp: "Back to the centred crop for this photo", customHelp: "You set this photo's crop",
                       onReset: { model.resetPhotoCrop() }) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        HStack(spacing: DS.space.xs) {
          Text("Zoom").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).frame(width: 34, alignment: .leading)
            .accessibilityHidden(true)
          DSSlider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                   range: 1...EditorGeometry.maxZoom, step: 0.05, format: Self.zoomText, showsValue: false, accessibilityName: "Zoom")
            .dsTooltip("Zoom in; or scroll or pinch on the Frame view")
          Text(Self.zoomText(model.zoom)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
            .frame(width: 38, alignment: .trailing)
            .accessibilityHidden(true)
        }
        HStack(spacing: 6) {
          if model.upscale > 1.01 {
            DSBadge(String(format: "Upscaled %.1f×", model.upscale), style: .soft(.warning), icon: "exclamationmark.triangle.fill")
              .dsTooltip("The crop is under 1080 px wide, so it looks softer")
          }
          Text("\(Int(model.crop.w)) × \(Int(model.crop.h)) px").font(DS.type.mono).foregroundStyle(DS.color.textTertiary)
          Spacer(minLength: 0)
          if model.canvasMode != .frame {
            DSButton("Edit on canvas", variant: .ghost, size: .sm, tooltip: "Show the whole photo to drag the crop") {
              model.canvasMode = .frame
            }
            .background(ScriptAnchor("Edit on canvas"))
          }
        }
        if n > 1 {
          DSButton("Use this framing for every photo", variant: .ghost, size: .sm,
                   tooltip: "Give every photo this zoom and position. A photo of another size gets the nearest framing that fits it.") {
            model.useFramingForEveryPhoto()
          }
          .padding(.leading, -8)
          .background(ScriptAnchor("Framing for every photo"))
          EditorHint("Each photo has its own crop. ← → step through the photos.")
        }
      }
    }
  }

  private static func zoomText(_ z: Double) -> String { String(format: "%.2f×", z) }
}

// MARK: - Platforms: what each one does with a photo post

/// Quiet lines under "Post to" (D8, D9, D20): why YouTube is off, a platform that gets only the first photos of a long
/// carousel, and a platform that refuses the shape (that one is a warning: it keeps the post in Edit).
struct EditorPhotoPlatformNotes: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let n = model.photoCount, a = model.aspect
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.postingPlatforms) { p in
        if let note = PhotoRules.platformNote(count: n, aspect: a, platform: p) {
          let refused = PhotoRules.shapeProblem(a, platform: p) != nil
          EditorHint(note, icon: refused ? "exclamationmark.triangle.fill" : "info.circle", tone: refused ? .warning : nil)
        }
      }
      EditorHint(PhotoRules.youtubeReason + ".", icon: "info.circle")
    }
  }
}

// MARK: - Text: none yet, and which photos a text shows on

/// A photo post with no text: what that means and the one way to add some.
struct EditorPhotoNoText: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      EditorHint("No text on this post. Most photos don't need any.")
      DSButton("Add text", icon: "plus", variant: .outline, size: .sm,
               tooltip: model.isCarousel ? "Add a text on photo \(model.photoIndex + 1). It can go on more photos after."
                                         : "Add a text on the photo") { model.addText() }
        .background(ScriptAnchor("Add text"))
    }
  }
}

/// "Shows on: Every photo / Photos 2–4" for the selected text of a carousel (D7), with the two usual answers as
/// buttons and a first and last photo to step, so the range can be set without dragging its bar.
struct EditorPhotoShowsOn: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let id = model.selectedText, n = model.photoCount, here = model.photoIndex + 1
    let range = model.textRange(id)
    let first = range?.lowerBound ?? n, last = range?.upperBound ?? n
    let every = range.map { $0.lowerBound <= 1 && $0.upperBound >= n } ?? false
    let off: String? = model.resolved.noText ? "No text is on; turn it off to change where this shows" : nil
    EditorField(label: "Shows on", help: "The photos this text is drawn on", value: model.textRangeLabel(id)) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          DSButton("Every photo", variant: .outline, size: .sm, disabledReason: off ?? (every ? "It already shows on every photo" : nil),
                   tooltip: "Show this text on every photo, also ones added later") { model.setTextRange(id, nil, step: true) }
            .background(ScriptAnchor("Every photo"))
          DSButton("This photo", variant: .outline, size: .sm,
                   disabledReason: off ?? (range == here...here ? "It already shows on photo \(here) only" : nil),
                   tooltip: "Show this text on photo \(here) only") { model.setTextRange(id, here...here, step: true) }
            .background(ScriptAnchor("This photo"))
          Spacer(minLength: 0)
        }
        HStack(spacing: DS.space.xs) {
          Text("From").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          stepper(first, name: "first", earlier: first > 1 ? first - 1 : nil, later: first < last ? first + 1 : nil, off: off) { v in
            model.setTextRange(id, v...last, step: true)
          }
          Text("to").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          stepper(last, name: "last", earlier: last > first ? last - 1 : nil, later: last < n ? last + 1 : nil, off: off) { v in
            model.setTextRange(id, first...v, step: true)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  /// One end of the range: the photo's number between a step down and a step up.
  private func stepper(_ value: Int, name: String, earlier: Int?, later: Int?, off: String?, set: @escaping (Int) -> Void) -> some View {
    HStack(spacing: 0) {
      DSIconButton("minus", tooltip: "Move the \(name) photo one earlier", size: .sm,
                   disabledReason: off ?? (earlier == nil ? "It can't go earlier" : nil)) { if let earlier { set(earlier) } }
        .background(ScriptAnchor("Shows \(name) earlier"))
      Text("\(value)").font(DS.type.calloutMedium.monospacedDigit()).foregroundStyle(DS.color.text).frame(minWidth: 20)
      DSIconButton("plus", tooltip: "Move the \(name) photo one later", size: .sm,
                   disabledReason: off ?? (later == nil ? "It can't go later" : nil)) { if let later { set(later) } }
        .background(ScriptAnchor("Shows \(name) later"))
    }
  }
}
