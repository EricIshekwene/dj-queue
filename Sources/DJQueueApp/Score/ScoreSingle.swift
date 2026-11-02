import DJQCore
import SwiftUI

/// Score → Single (DESIGN-v2 §6.1, refs R2.SCORE Google Photos review card + Midjourney progress/key hints):
///
/// ```
///   17 of 29 scored  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///        ┌──────────┐        Title or raw tag
///    ‹   │  player  │   ›    Session · 0:42
///        │ 349×620  │        Kind  [DJ vid | Talking]
///        └──────────┘        Notes [            ]
///   ( [ 72 ] [Save & next ↩] Skip )                     Exclude ⌘⌫
///   Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next · ⌘⌫ exclude
/// ```
/// The score field is a key-driven box (focused on appear) so ↩/⇥/←/→/⌘⌫ always reach the screen — a native text
/// field would swallow the arrows and Tab. Save & next: the clip slides left 24 pt and fades, the next fades in.
struct ScoreSingleView: View {
  @Bindable var model: AppModel
  let videos: [Video]
  @Binding var index: Int
  let progress: (done: Int, total: Int)
  let onSave: (Video, Int) -> Void
  let onExclude: (Video) -> Void

  @State private var text = ""
  @State private var notes = ""
  @State private var notesFor: String?
  @FocusState private var fieldFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var i: Int { min(max(0, index), max(0, videos.count - 1)) }
  private var video: Video? { videos.indices.contains(i) ? videos[i] : nil }
  private var value: Int? { PipelineUIState.score(text) }

  var body: some View {
    GeometryReader { geo in
      // strip 26 · gaps · pill 56 · hint 16 · padding — the player takes the rest (≈ 620 at 900 without cards).
      let h = max(280, min(640, geo.size.height - 26 - 56 - 16 - 3 * DS.space.md - DS.space.sm - DS.space.xl))
      let w = (h * 9 / 16).rounded()
      let groupWidth = w + 2 * (DS.size.controlLg + DS.space.md) + DS.space.xxl + 280
      VStack(spacing: DS.space.md) {
        strip.frame(width: groupWidth)
        if let v = video {
          HStack(alignment: .top, spacing: DS.space.xxl) {
            VStack(spacing: DS.space.md) {
              HStack(spacing: DS.space.md) {
                DSIconButton("chevron.left", tooltip: "Previous clip", variant: .ghost, size: .lg, shortcut: "←",
                             disabledReason: i == 0 ? "This is the first clip" : nil) { move(-1) }
                player(v).frame(width: w, height: h)
                  .id(v.id)
                  .transition(.asymmetric(insertion: .opacity,
                                          removal: reduceMotion ? .opacity : .offset(x: -24).combined(with: .opacity)))
                DSIconButton("chevron.right", tooltip: "Next clip", variant: .ghost, size: .lg, shortcut: "→",
                             disabledReason: i >= videos.count - 1 ? "This is the last clip" : nil) { move(1) }
              }
              pill(v)
              Text("Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next · ⌘⌫ exclude")
                .font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
                .frame(height: 16)
            }
            panel(v).frame(width: 280, alignment: .leading)
          }
        }
      }
      .padding(.top, DS.space.sm)
      .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
    }
    .pipelineClipFeed(model, .score, ids: videos.map(\.id), play: playIds)
    .onAppear {
      fieldFocused = true
      loadNotes()
    }
    .onChange(of: video?.id) { _, _ in
      text = ""
      loadNotes()
      fieldFocused = true
    }
    .task(id: notes) {
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      saveNotes()
    }
    .onDisappear { saveNotes() }
    .dsAnimation(DS.motion.fade, value: video?.id)
  }

  private var playIds: [String] {
    [i, i + 1, i - 1].filter { videos.indices.contains($0) }.map { videos[$0].id }
  }

  // MARK: Pieces

  private var strip: some View {
    let p = progress
    return DSProgress(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total), label: "\(p.done) of \(p.total) scored")
      .dsTooltip("Clips in the sets you're scoring now")
  }

  private func player(_ v: Video) -> some View {
    let pb = model.playback
    return DSVideoPreview(url: model.proxyURLs[v.id], poster: model.poster(v), isActive: pb.autoplay, isPriority: true,
                          unmuteOnHover: pb.hoverSound, showsMuteButton: true, muteAlignment: .topTrailing,
                          showsScrubber: true, cornerRadius: DS.radius.xl)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.xl, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: DS.radius.xl, style: .continuous).strokeBorder(DS.color.border) }
      .overlay(alignment: .bottomLeading) {
        Text(Fmt.duration(model.clipDuration(v))).font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
          .padding(.horizontal, 6).frame(height: 18)
          .background(Color.black.opacity(0.63), in: Capsule())
          .padding(12)
      }
      .onAppear { model.requestPoster(v) }
      .accessibilityLabel("Clip preview: \(model.displayName(v))")
  }

  private func pill(_ v: Video) -> some View {
    HStack(spacing: DS.space.xs) {
      ScoreKeyField(text: text, invalid: !text.isEmpty && value == nil, focused: $fieldFocused, onKey: handle)
      DSButton("Save & next", trailingIcon: "return", variant: .primary, size: .lg,
               disabledReason: value == nil ? "Type a score from 0 to 100 first" : nil, shortcut: "↩") { save() }
      DSButton("Skip", variant: .ghost, size: .lg, tooltip: "Leave this clip for later", shortcut: "⇥") { move(1, wrap: true) }
    }
    .padding(.horizontal, 6)
    .frame(height: 56)
    .background(DS.color.surfaceRaised, in: Capsule())
    .overlay(Capsule().strokeBorder(DS.color.border))
    .dsElevation(DS.elevation.e2)
    .dsToastAvoid()
  }

  private func panel(_ v: Video) -> some View {
    VStack(alignment: .leading, spacing: DS.space.lg) {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.displayName(v)).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
        Text([model.sessionName(v), Fmt.duration(model.clipDuration(v))].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Kind").font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        DSSegmented(selection: Binding(get: { v.kind }, set: { k in if k != v.kind { model.setKind([v.id], k) } }),
                    segments: Kind.allCases.map { DSSegment(value: $0, title: $0.displayName) }, size: .sm)
          .dsTooltip("Talking clips get no text by default")
      }
      DSTextArea("Notes", placeholder: "Anything to remember about this clip", text: $notes, minHeight: 72, maxHeight: 140)
      DSButton("Exclude", icon: "minus.circle", variant: .ghost, size: .sm,
               tooltip: "Leave this clip out — it never posts (find it in Library → Excluded)", shortcut: "⌘⌫") { onExclude(v) }
        .padding(.leading, -10)
      Spacer(minLength: 0)
    }
    .padding(.top, 4)
  }

  // MARK: Actions

  private func handle(_ k: KeyPress) -> KeyPress.Result {
    if k.modifiers.contains(.command) {
      if k.key == .delete, let v = video { onExclude(v); return .handled }
      return .ignored
    }
    switch k.key {
    case .return: save()
    case .tab: move(k.modifiers.contains(.shift) ? -1 : 1, wrap: true)
    case .leftArrow: move(-1)
    case .rightArrow: move(1)
    case .delete: if !text.isEmpty { text.removeLast() }
    case .escape:
      guard !text.isEmpty else { return .ignored }
      text = ""
    default:
      guard let c = k.characters.first, c.isASCII, c.isNumber else { return .ignored }
      let next = text == "0" ? String(c) : text + String(c)
      if let n = Int(next), n <= 100, next.count <= 3 { text = next }
    }
    return .handled
  }

  private func save() {
    guard let v = video, let n = value else { return }
    saveNotes()
    text = ""
    onSave(v, n)
    // The saved clip leaves the list; the same index now shows the next clip (or the last one).
    if index >= videos.count - 1 { index = max(0, videos.count - 2) }
  }

  private func move(_ d: Int, wrap: Bool = false) {
    guard !videos.isEmpty else { return }
    saveNotes()
    var n = i + d
    if wrap { n = (n + videos.count) % videos.count }
    index = min(max(0, n), videos.count - 1)
  }

  private func loadNotes() {
    notes = video?.notes ?? ""
    notesFor = video?.id
  }

  private func saveNotes() {
    guard let id = notesFor, let v = model.video(id), v.notes != notes else { return }
    model.setNotes(id, notes)
  }
}

/// The big score box (display 28, 96 wide) inside the control pill. Key-driven: the parent handles every key.
struct ScoreKeyField: View {
  let text: String
  var invalid = false
  var focused: FocusState<Bool>.Binding
  let onKey: (KeyPress) -> KeyPress.Result
  @State private var hovering = false

  var body: some View {
    let isFocused = focused.wrappedValue
    HStack(spacing: 1) {
      Text(text.isEmpty ? "0–100" : text)
        .font(text.isEmpty ? Font.system(size: 22, weight: .regular) : DS.type.display.monospacedDigit())
        .foregroundStyle(text.isEmpty ? DS.color.textTertiary : DS.color.text)
      if isFocused && !text.isEmpty {
        Capsule().fill(DS.color.accent).frame(width: 2, height: 26)
      }
    }
    .frame(width: 96, height: 44)
    .modifier(DSFieldBox(focused: isFocused, hovering: hovering, error: invalid, disabled: false, radius: 22))
    .contentShape(Capsule())
    .focusable()
    .focused(focused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down, action: onKey)
    .onTapGesture { focused.wrappedValue = true }
    .onHover { hovering = $0 }
    .dsTooltip("Score 0–100 — type digits, ↩ saves")
    .accessibilityElement()
    .accessibilityLabel("Score")
    .accessibilityValue(text.isEmpty ? "Empty" : text)
  }
}
