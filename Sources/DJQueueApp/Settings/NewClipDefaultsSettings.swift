import DJQCore
import SwiftUI

/// New clip defaults (north star #10, DESIGN-v2 §6.9): every `NewClipDefaults` field, edited as a set (draft in
/// `SettingsUIState`) and committed with the sticky Save. Clips store only their own changes, so a saved default
/// changes every clip that still follows it.
struct NewClipDefaultsSettings: View {
  @Bindable var model: AppModel
  let ui: SettingsUIState
  @State private var templates: [CaptionTemplate] = []
  @State private var sets: [HashtagSet] = []
  @State private var extraTags = ""

  static let captionAnchor = "caption"
  static let postingAnchor = "posting"

  private var saved: NewClipDefaults { model.settings.defaults }
  private var d: NewClipDefaults { ui.draft ?? saved }
  private var dirty: Bool { ui.isDirty(saved) }

  private func b<T>(_ kp: WritableKeyPath<NewClipDefaults, T>) -> Binding<T> {
    Binding(get: { d[keyPath: kp] }, set: { v in
      var x = d
      x[keyPath: kp] = v
      ui.draft = x
    })
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            SettingsNote("Clips store only their own changes. Changing a default updates every clip that still follows it — previews, renders and captions. The editor marks each field Default or Custom.")
            frameGroup
            trimGroup
            textGroup
            coverGroup
            captionGroup.id(Self.captionAnchor)
            postingGroup.id(Self.postingAnchor)
            kindGroup
          }
          .padding(.bottom, DS.space.xl)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
          guard let t = ui.scrollTarget else { return }
          ui.scrollTarget = nil
          DispatchQueue.main.async { proxy.scrollTo(t, anchor: .top) }
        }
      }
      footer
    }
    .onAppear(perform: load)
    .onChange(of: d.extraHashtags) { _, tags in if parse(extraTags) != tags { extraTags = tags.joined(separator: " ") } }
  }

  // MARK: Groups

  @ViewBuilder private var frameGroup: some View {
    SettingsGroupHeader("Frame", description: "Default framing for clips you haven't cropped. Each crop is still confirmed per clip.")
    SettingsRow("Aspect", description: "Shape of the posted video.") {
      SettingsSelect(label: "Default aspect", selection: b(\.aspect), options: Aspect.allCases.map { DSSelectOption(value: $0, title: aspectTitle($0)) })
    }
    SettingsRow("Crop position", description: "Where the default crop sits on a wide picture.") {
      SettingsSelect(label: "Default crop position", selection: b(\.cropAnchor),
                     options: NewClipDefaults.CropAnchor.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
  }

  @ViewBuilder private var trimGroup: some View {
    let whole = d.trimMode == .wholeFile ? "Only used when the trim follows the markers." : nil
    SettingsGroupHeader("Trim", description: "Default start and end of a clip.")
    SettingsRow("Start and end", description: "Clips without markers always use the whole file.") {
      SettingsSelect(label: "Default trim", selection: b(\.trimMode), options: [
        DSSelectOption(value: NewClipDefaults.TrimMode.markers, title: "Marker in and out"),
        DSSelectOption(value: NewClipDefaults.TrimMode.wholeFile, title: "Whole file"),
      ])
    }
    SettingsRow("Extra seconds before", description: "Starts this much before the in-marker.", disabledReason: whole) {
      DSXStepper(label: "Extra seconds before", value: b(\.extraSecondsBefore), range: 0...10, step: 0.5, format: SettingsFmt.seconds)
    }
    SettingsRow("Extra seconds after", description: "Ends this much after the out-marker.", disabledReason: whole) {
      DSXStepper(label: "Extra seconds after", value: b(\.extraSecondsAfter), range: 0...10, step: 0.5, format: SettingsFmt.seconds)
    }
  }

  @ViewBuilder private var textGroup: some View {
    SettingsGroupHeader("Text", description: "Default overlay text on the video.")
    SettingsRow("Style") {
      SettingsSelect(label: "Default text style", selection: b(\.textStyle), options: TextStyle.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
    SettingsRow("Size", description: "Points on a 1080-wide frame.") {
      SettingsSelect(label: "Default text size", selection: b(\.textSize), options: presetOptions(
        [(52, "Small"), (64, "Medium"), (80, "Large")], current: d.textSize) { "\(Int($0)) pt" })
    }
    SettingsRow("Vertical position", description: "Each clip can still be dragged in the editor.") {
      SettingsSelect(label: "Default vertical position", selection: b(\.textPosY), options: presetOptions(
        [(0.18, "Top"), (0.32, "Upper"), (0.5, "Centre"), (0.68, "Lower"), (0.82, "Bottom")], current: d.textPosY, format: percent))
    }
    SettingsRow("Horizontal position") {
      SettingsSelect(label: "Default horizontal position", selection: b(\.textPosX), options: presetOptions(
        [(0.25, "Left"), (0.5, "Centre"), (0.75, "Right")], current: d.textPosX, format: percent))
    }
    SettingsRow("Alignment") {
      DSSegmented(selection: b(\.textAlign), segments: [
        DSSegment(value: TextAlign.left, icon: "text.alignleft", tooltip: "Align left"),
        DSSegment(value: TextAlign.center, icon: "text.aligncenter", tooltip: "Align centre"),
        DSSegment(value: TextAlign.right, icon: "text.alignright", tooltip: "Align right"),
      ], size: .sm)
    }
    SettingsRow("Show text", description: "For the whole clip or only at the start.") {
      SettingsSelect(label: "Default text timing", selection: b(\.textTiming),
                     options: NewClipDefaults.TextTiming.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
    SettingsRow("First seconds", description: "How long the text shows at the start.",
                disabledReason: d.textTiming == .whole ? "Only used when text shows for the first seconds." : nil) {
      DSXStepper(label: "First seconds", value: b(\.textFirstSeconds), range: 0.5...15, step: 0.5, format: SettingsFmt.seconds)
    }
    SettingsRow("Text comes from", description: "Used until you type text for a clip. Never rewritten.") {
      SettingsSelect(label: "Default text source", selection: b(\.textSource),
                     options: NewClipDefaults.TextSource.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
    SettingsRow("No text for Talking clips", description: "Talking clips start without overlay text.") {
      DSSwitch(isOn: b(\.noTextForTalking)).accessibilityLabel("No text for Talking clips")
    }
  }

  @ViewBuilder private var coverGroup: some View {
    SettingsGroupHeader("Cover", description: "Default cover image for each post.")
    SettingsRow("Include text on cover", description: "The overlay text is drawn on the cover too.") {
      DSSwitch(isOn: b(\.coverIncludesText)).accessibilityLabel("Include text on cover")
    }
    SettingsRow("Cover frame") {
      SettingsSelect(label: "Default cover frame", selection: b(\.coverFrame),
                     options: NewClipDefaults.CoverFrame.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
    SettingsRow("Seconds into the trim", description: "Where the cover frame is taken.",
                disabledReason: d.coverFrame == .offsetSeconds ? nil : "Only used when the cover is a set number of seconds in.") {
      DSXStepper(label: "Seconds into the trim", value: b(\.coverOffsetSeconds), range: 0...30, step: 0.5, format: SettingsFmt.seconds)
    }
  }

  @ViewBuilder private var captionGroup: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroupHeader("Caption", description: "Default caption and YouTube title. Templates, hashtag groups and title templates live in Captions & titles.")
      SettingsRow("Caption template") {
        SettingsSelect(label: "Default caption template", selection: b(\.captionTemplateId), options: templateOptions(current: d.captionTemplateId))
      }
      SettingsRow("Hashtag groups", description: "Groups every new clip starts with (none = no hashtags). Filled into {hashtags}.", stacked: true) {
        let groups = HashtagGroups.pickable(sets)
        if groups.isEmpty {
          Text("No hashtag groups yet — make your own in Captions & titles.").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        } else {
          // One chip per set (DSChip, not DSChipGroup) so each says which tags it adds.
          DSFlowLayout(spacing: 6) {
            ForEach(groups) { s in
              let on = d.hashtagSetIds.contains(s.id)
              DSChip(HashtagGroups.label(s), icon: "number", isSelected: on, size: .sm) {
                var ids = Set(d.hashtagSetIds)
                if on { ids.remove(s.id) } else { ids.insert(s.id) }
                hashtagBinding.wrappedValue = ids
              }
              .dsTooltip(s.tags.isEmpty ? "This group has no hashtags yet"
                         : "\(on ? "Stop adding" : "Add") \(s.tags.joined(separator: " ")) to new clips")
            }
          }
        }
      }
      SettingsRow("Extra hashtags", description: "Added after the groups, separated by spaces.", stacked: true) {
        DSTextField(placeholder: "#tag #another", text: Binding(get: { extraTags }, set: { t in
          extraTags = t
          let tags = parse(t)
          if tags != d.extraHashtags { b(\.extraHashtags).wrappedValue = tags }
        }), size: .sm)
      }
      SettingsRow("YouTube title template", description: "The title template new clips use. Edit the templates in Captions & titles.") {
        SettingsSelect(label: "Default YouTube title template", selection: b(\.youtubeTitleTemplateId), options: titleOptions)
      }
      SettingsGroupHeader("Caption template per platform", description: "Default template for one platform when the clip didn't choose one.")
      ForEach(Platform.allCases.sorted()) { p in
        SettingsRow(p.displayName, platform: p) {
          SettingsSelect(label: "\(p.displayName) caption template", selection: platformTemplateBinding(p),
                         options: [DSSelectOption(value: String?.none, title: "Same as caption template")]
                           + templateOptions(current: d.platformCaptionTemplates[p]).map { DSSelectOption(value: String?.some($0.value), title: $0.title) })
        }
      }
    }
  }

  @ViewBuilder private var postingGroup: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroupHeader("Posting", description: "Default platforms for a new clip. A clip can still turn one on or off in the editor.")
      SettingsRow("Post to", description: "Only platforms that are on in Platforms get posts.", stacked: true) {
        DSChipGroup(options: platformChips, selection: b(\.platforms), size: .sm)
      }
      SettingsRow("Safe zones shown", description: "Platform overlays the editor shows on the preview.", stacked: true) {
        DSChipGroup(options: platformChips, selection: b(\.safeZonePlatforms), noneTitle: "None", size: .sm)
      }
    }
  }

  @ViewBuilder private var kindGroup: some View {
    SettingsGroupHeader("Kind")
    SettingsRow("Kind", description: "videos.json content-type: talking still wins.") {
      SettingsSelect(label: "Default kind", selection: b(\.kind), options: Kind.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
  }

  // MARK: Footer (sticky)

  private var footer: some View {
    VStack(spacing: 0) {
      DSSeparator()
      HStack(spacing: DS.space.xs) {
        DSButton("Reset to built-in defaults", icon: "arrow.counterclockwise", variant: .ghost, size: .sm,
                 disabledReason: saved == NewClipDefaults() && !dirty ? "Already the built-in defaults" : nil,
                 tooltip: "Put every default back to the built-in value…") { confirmReset() }
        Spacer(minLength: DS.space.xs)
        if dirty {
          Text(changeCount == 1 ? "1 unsaved change" : "\(changeCount) unsaved changes")
            .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        }
        DSButton("Discard changes", variant: .outline, disabledReason: dirty ? nil : "No unsaved changes",
                 tooltip: "Throw away the unsaved default changes") { ui.draft = nil }
        DSButton("Save", variant: .primary, disabledReason: dirty ? nil : "No unsaved changes",
                 tooltip: "Save defaults (clips that follow them change; clips with scheduled or posted posts keep their captions)", shortcut: "⌘S") { save() }
          .keyboardShortcut("s", modifiers: .command)
      }
      .padding(.vertical, DS.space.sm)
    }
    .background(DS.color.surfaceRaised)
  }

  private var changeCount: Int {
    guard let draft = ui.draft else { return 0 }
    let a = Mirror(reflecting: draft).children.map { String(describing: $0.value) }
    let s = Mirror(reflecting: saved).children.map { String(describing: $0.value) }
    return zip(a, s).filter { $0 != $1 }.count
  }

  private func save() {
    guard let draft = ui.draft else { return }
    // Undoable (toast · Undo, ⌘Z): every clip that follows a default changes with it, except clips with posts.
    if model.saveDefaults(draft, label: "New clip defaults saved") {
      ui.draft = nil
      model.revalidateStages()
    }
  }

  private func confirmReset() {
    ui.confirm = SettingsConfirm(
      title: "Reset new clip defaults?",
      message: "Every default goes back to the built-in value and is saved now. Clips that follow a default change with it; their own changes stay, and clips with scheduled or posted posts keep their captions. Undo (⌘Z) puts your defaults back.",
      confirmTitle: "Reset defaults", destructive: true, icon: "arrow.counterclockwise") {
        if model.saveDefaults(NewClipDefaults(), label: "New clip defaults reset") {
          ui.draft = nil
          model.revalidateStages()
        }
      }
  }

  // MARK: Helpers

  private func load() {
    templates = (try? model.store.captionTemplates()) ?? []
    sets = (try? model.store.hashtagSets()) ?? []
    extraTags = d.extraHashtags.joined(separator: " ")
  }

  private func parse(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

  private var platformChips: [DSChipOption<Platform>] {
    Platform.allCases.sorted().map { DSChipOption(value: $0, title: $0.displayName, icon: $0.dsSymbol) }
  }

  private var hashtagBinding: Binding<Set<String>> {
    Binding(get: { Set(d.hashtagSetIds) }, set: { ids in
      let known = sets.map(\.id)
      // Keep the sets' order; ids that no longer exist are dropped once Eric edits the selection.
      b(\.hashtagSetIds).wrappedValue = known.filter { ids.contains($0) }
    })
  }

  private func platformTemplateBinding(_ p: Platform) -> Binding<String?> {
    Binding(get: { d.platformCaptionTemplates[p] }, set: { v in
      var m = d.platformCaptionTemplates
      m[p] = v
      b(\.platformCaptionTemplates).wrappedValue = m
    })
  }

  private var titleOptions: [DSSelectOption<String>] {
    var o = model.settings.youtubeTitleTemplates.map { DSSelectOption(value: $0.id, title: $0.name, detail: $0.template) }
    if !model.settings.youtubeTitleTemplates.contains(where: { $0.id == d.youtubeTitleTemplateId }) {
      o.append(DSSelectOption(value: d.youtubeTitleTemplateId, title: "Missing template"))
    }
    return o
  }

  private func templateOptions(current: String?) -> [DSSelectOption<String>] {
    var o = templates.map { DSSelectOption(value: $0.id, title: $0.name) }
    if let current, !templates.contains(where: { $0.id == current }) {
      o.append(DSSelectOption(value: current, title: "Missing template"))
    }
    return o
  }

  private func aspectTitle(_ a: Aspect) -> String {
    switch a {
    case .r9x16: "9:16 vertical"
    case .r4x5: "4:5 portrait"
    case .r1x1: "1:1 square"
    case .r16x9: "16:9 wide"
    }
  }

  private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

  /// Named presets ("Medium · 64 pt") plus the current value when it's custom (set by dragging, CLI…).
  private func presetOptions(_ presets: [(Double, String)], current: Double, format: (Double) -> String) -> [DSSelectOption<Double>] {
    var o = presets.map { DSSelectOption(value: $0.0, title: "\($0.1) · \(format($0.0))") }
    if !presets.contains(where: { abs($0.0 - current) < 0.0001 }) {
      o.append(DSSelectOption(value: current, title: "Custom · \(format(current))"))
    }
    return o
  }
}
