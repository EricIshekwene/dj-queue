import AppKit
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
///   Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next when empty · ⌘⌫ exclude
/// ```
/// The score box is a real text field (round 40: ⌫, ⌦, ⌘A, the caret and ⌘Z work as anywhere on the Mac), focused on
/// appear and on each new clip. It hands ↩ / ⇥ / ⌘⌫ / esc to the screen, and ← / → too while it's empty
/// (`ScoreFieldKeys`). Save & next: the clip slides left 24 pt and fades, the next fades in.
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
  /// Bumped to put the keyboard in the score box (on appear, on each new clip).
  @State private var focusToken = 0
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
              Text("Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next when empty · ⌘⌫ exclude")
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
      focusToken += 1
      loadNotes()
    }
    .onChange(of: video?.id) { _, _ in
      text = ""
      loadNotes()
      focusToken += 1
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
    // The clip as it will post (round 4 S6): edited cover, proxy (crop/aspect/trim) + live text in its window.
    let p = model.clipPreview(v)
    return DSVideoPreview(url: p.proxyURL, poster: p.cover, isActive: pb.autoplay, isPriority: true,
                          loopRange: p.loopRange, unmuteOnHover: pb.hoverSound, showsMuteButton: true, muteAlignment: .topTrailing,
                          showsScrubber: true, cornerRadius: DS.radius.xl, overlays: p.overlays,
                          isUpdating: p.isUpdating, needsOverlay: p.overlayMissing,
                          onNeedsOverlay: { model.reloadOverlay(v.id, version: p.version) })
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.xl, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: DS.radius.xl, style: .continuous).strokeBorder(DS.color.border) }
      .overlay(alignment: .bottomLeading) {
        Text(Fmt.duration(model.clipDuration(v))).font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
          .padding(.horizontal, 6).frame(height: 18)
          .background(Color.black.opacity(0.63), in: Capsule())
          .padding(12)
      }
      .onAppear { model.requestPoster(v) }
      .task(id: p.stamp) { model.requestPoster(v) }
      .accessibilityLabel("Clip preview: \(model.displayName(v))")
  }

  private func pill(_ v: Video) -> some View {
    HStack(spacing: DS.space.xs) {
      ScoreKeyField(text: $text, invalid: !text.isEmpty && value == nil, focusToken: focusToken, onCommand: handle)
      DSButton("Save & next", trailingIcon: "return", variant: .primary, size: .lg,
               disabledReason: value == nil ? "Type a score from 0 to 100 first" : nil,
               tooltip: "Save score and show the next clip", shortcut: "↩") { save() }
      DSButton("Skip", variant: .ghost, size: .lg, tooltip: "Leave unscored for now, show the next", shortcut: "⇥") { move(1, wrap: true) }
    }
    .padding(.horizontal, 6)
    .frame(height: 56)
    .background(DS.color.surfaceRaised, in: Capsule())
    .overlay(Capsule().strokeBorder(DS.color.border))
    .dsElevation(DS.elevation.e2)
    .dsToastAvoid()
    .background(ScriptAnchor("Score clip \(v.id)"))
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
          .dsTooltip("Talking clips get no text overlay (undoable)")
      }
      DSTextArea("Notes", placeholder: "Anything to remember about this clip", text: $notes, minHeight: 72, maxHeight: 140)
      DSButton("Exclude", icon: "minus.circle", variant: .ghost, size: .sm,
               tooltip: "Never post this clip (Library → Excluded)", shortcut: "⌘⌫") { onExclude(v) }
        .padding(.leading, -10)
      Spacer(minLength: 0)
    }
    .padding(.top, 4)
  }

  // MARK: Actions

  private func handle(_ c: ScoreFieldKeys.Command) {
    switch c {
    case .save: save()
    case .skip(let d): move(d, wrap: true)
    case .move(let d): move(d)
    case .exclude: if let v = video { onExclude(v) }
    case .clear: text = ""
    }
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

/// The big score box (display 28, 96 wide) inside the control pill: a real AppKit text field, so typing, ⌫ / ⌦,
/// ⌘A, clicking or arrowing the caret, ⌘Z and paste all behave as in any Mac field. It holds only 0–100
/// (`ScoreFieldKeys.accepts`) and hands the screen's keys to `onCommand` (`ScoreFieldKeys.command`).
struct ScoreKeyField: View {
  @Binding var text: String
  var invalid = false
  /// Changing it puts the keyboard here.
  var focusToken = 0
  let onCommand: (ScoreFieldKeys.Command) -> Void
  @State private var hovering = false
  @State private var focused = false

  var body: some View {
    ScoreTextField(text: $text, focusToken: focusToken, onCommand: onCommand, onFocus: { focused = $0 })
      .padding(.horizontal, 10)
      .frame(width: 96, height: 44)
      .modifier(DSFieldBox(focused: focused, hovering: hovering, error: invalid, disabled: false, radius: 22))
      .onHover { hovering = $0 }
      .dsTooltip("Type a score 0–100, then save & next", shortcut: "↩")
  }
}

/// The AppKit field under `ScoreKeyField`. Borderless and clear (the DS box draws the frame), centred tabular digits,
/// a 22 pt tertiary "0–100" placeholder, accent caret.
struct ScoreTextField: NSViewRepresentable {
  @Binding var text: String
  var focusToken: Int
  let onCommand: (ScoreFieldKeys.Command) -> Void
  let onFocus: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> Field {
    let f = Field()
    f.isBordered = false
    f.drawsBackground = false
    f.focusRingType = .none
    f.isBezeled = false
    f.alignment = .center
    f.usesSingleLineMode = true
    f.lineBreakMode = .byClipping
    f.cell?.isScrollable = true
    f.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .regular)
    f.textColor = NSColor(DS.color.text)
    f.placeholder = NSAttributedString(string: "0–100", attributes: [
      .font: NSFont.systemFont(ofSize: 22, weight: .regular),
      .foregroundColor: NSColor(DS.color.textTertiary),
      .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
    ])
    f.formatter = ScoreFormatter()
    f.delegate = context.coordinator
    f.onFocus = { context.coordinator.parent.onFocus($0) }
    f.setAccessibilityLabel("Score")
    f.stringValue = text
    return f
  }

  func updateNSView(_ f: Field, context: Context) {
    context.coordinator.parent = self
    if f.stringValue != text { f.stringValue = text }
    if context.coordinator.focusToken != focusToken {
      context.coordinator.focusToken = focusToken
      f.takeKeyboard()
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: ScoreTextField
    var focusToken = 0
    init(_ parent: ScoreTextField) { self.parent = parent }

    func controlTextDidChange(_ n: Notification) {
      guard let f = n.object as? NSTextField else { return }
      if parent.text != f.stringValue { parent.text = f.stringValue }
    }

    func controlTextDidEndEditing(_ n: Notification) {
      (n.object as? Field)?.showPlaceholder(true)
      parent.onFocus(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let c = ScoreFieldKeys.command(for: NSStringFromSelector(selector), text: textView.string) else { return false }
      if c == .clear { textView.string = "" ; parent.text = "" } else { parent.onCommand(c) }
      return true
    }
  }

  final class Field: NSTextField {
    var onFocus: ((Bool) -> Void)?
    /// "0–100" while the box doesn't have the cursor. With the cursor it's an empty box with a centred caret: a
    /// centred placeholder would sit under the caret (the hint line under the pill says what to type).
    var placeholder: NSAttributedString? { didSet { showPlaceholder(currentEditor() == nil) } }
    func showPlaceholder(_ on: Bool) {
      placeholderAttributedString = on ? placeholder : nil
      needsDisplay = true
      currentEditor()?.needsDisplay = true
    }
    /// A focus asked for before the field was in a window (the first clip), taken once it is.
    private var wantsKeyboard = false

    func takeKeyboard() {
      guard let w = window else { wantsKeyboard = true; return }
      wantsKeyboard = false
      if currentEditor() == nil { w.makeFirstResponder(self) }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if wantsKeyboard, window != nil { DispatchQueue.main.async { [weak self] in self?.takeKeyboard() } }
    }

    override func becomeFirstResponder() -> Bool {
      // Before the field editor starts: it takes the placeholder as it finds it.
      showPlaceholder(false)
      let ok = super.becomeFirstResponder()
      if !ok { showPlaceholder(true) }
      if ok {
        onFocus?(true)
        (currentEditor() as? NSTextView)?.insertionPointColor = NSColor(DS.color.accent)
      }
      return ok
    }
  }
}

/// Only 0–100 gets in the score box: a letter, a fourth digit or 101 is turned away and the box keeps what it had
/// (typed or pasted). The value stays the typed text.
final class ScoreFormatter: Formatter {
  override func string(for obj: Any?) -> String? { obj as? String ?? (obj as? NSNumber)?.stringValue }
  override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                               errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
    obj?.pointee = string as NSString
    return true
  }
  override func isPartialStringValid(_ partial: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                     errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
    ScoreFieldKeys.accepts(partial)
  }
}
