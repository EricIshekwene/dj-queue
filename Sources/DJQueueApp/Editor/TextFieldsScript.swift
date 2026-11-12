import AppKit
import DJQCore
import SwiftUI

/// `DJQ_TEXT_FIELDS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 25. Eric: the text boxes
/// "tweak out" when clicking to place the cursor or adding a new line. Drives every kind of multi-line box through real
/// events on a throwaway copy of the dev database: the editor's Text on the video, its caption and a platform's own
/// caption, and a bare `DSTextArea` (the one component every other multi-line box uses: templates, notes, post sheets).
///
/// Clicks are a mouse-down / mouse-up pair handed to the view under the point (the up waits in the app's own queue for
/// the text view's tracking loop); Return is a key event handed to the field's window, and letters go in through
/// `insertText`, where a key press ends. Both skip the app-level key monitor (`EditorKeyMonitor`, which leaves Return
/// and letters to a focused field anyway), because routing through `NSApp` would need the window to be key, which a
/// check must never make it. Nothing reaches the system event queue, the window sits off every display and never takes
/// focus. Each step samples the field every few milliseconds for a while and checks
/// what Eric would see: the caret where it was put and staying there, Return adding exactly one line where the caret is,
/// the same text view keeping the cursor, the box growing once (never bouncing) and the text never scrolling away.
/// Saves `fields-NN-<step>-<appearance>.png` and `checks-<appearance>.txt`.
@MainActor
enum TextFieldsScript {
  struct Sample: Equatable {
    var caret: Int
    var text: String
    var height: CGFloat
    var scrollY: CGFloat
    var fieldY: CGFloat
    var hasCursor: Bool
  }

  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("fields-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }

    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: video)
    model.appHooks = EditorAppHooks(isCovered: { false }, arrowStep: { .twoSeconds }, setArrowStep: { _ in })
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    try? await Task.sleep(for: .seconds(3))

    var step = 0
    func shot(_ name: String, in w: NSWindow? = nil) async {
      let w = w ?? window
      guard let v = w.contentView else { return }
      await wait(250)
      w.displayIfNeeded()
      v.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "fields-%02d-%@-%@.png", step, name, appearance))
      if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }

    // MARK: event helpers (all through this app only)

    func press(_ chars: String, code: UInt16, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code) else { return }
      // Straight to the field's window: `NSApp.sendEvent` hands keys to the key window, and a background app has none.
      w.sendEvent(e)
    }
    /// Letters go in the way a key press ends (`insertText` on the field: a background app has no input method to turn
    /// a key event into text); Return is the real key event.
    func type(_ s: String, in w: NSWindow) async {
      for ch in s {
        if ch == "\n" { press("\r", code: 36, in: w) } else if let tv = w.firstResponder as? NSTextView {
          tv.insertText(String(ch), replacementRange: tv.selectedRange())
        }
        await wait(30)
      }
    }
    func deleteAll(in w: NSWindow) {
      guard let tv = w.firstResponder as? NSTextView else { return }
      tv.selectAll(nil)
      tv.deleteBackward(nil)
    }
    /// From the moment the caret first reaches `want`, it never leaves.
    func holds(_ s: [Sample], _ want: Int) -> Bool {
      guard let i = s.firstIndex(where: { $0.caret == want }) else { return false }
      return s[i...].allSatisfy { $0.caret == want }
    }
    /// A click at character `index` of `tv` (just inside that character's left edge, half way down its line).
    func click(_ tv: NSTextView, at index: Int) {
      guard let w = tv.window else { return }
      // Eric clicks a box he can see: bring it into the inspector's view first (a box below the fold has no place
      // on the page to click).
      let box = tv.enclosingScrollView ?? tv
      box.scrollToVisible(box.bounds)
      w.displayIfNeeded()
      let len = (tv.string as NSString).length
      let i = min(index, len)
      var actual = NSRange()
      let screen = tv.firstRect(forCharacterRange: NSRange(location: i, length: 0), actualRange: &actual)
      let r = w.convertFromScreen(screen)
      let p = NSPoint(x: r.minX + 1, y: r.midY)
      let t = ProcessInfo.processInfo.systemUptime
      if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05,
                                     windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
        NSApp.postEvent(up, atStart: false)
      }
      if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        // The view under the point takes the click itself: a window in an app that never activates treats a routed
        // click as the one that would bring it forward, which a check must never do.
        let hit = w.contentView?.superview?.hitTest(p)
        (hit ?? tv).mouseDown(with: down)
        note("click \(index) at \(Int(p.x)),\(Int(p.y)) hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil") → caret \(tv.selectedRange().location)")
      }
    }

    // MARK: sampling

    func sample(_ tv: NSTextView) -> Sample {
      let sv = tv.enclosingScrollView
      let frame = (sv ?? tv).convert((sv ?? tv).bounds, to: nil)
      return Sample(caret: tv.selectedRange().location, text: tv.string, height: (sv?.frame.height ?? tv.frame.height).rounded(),
                    scrollY: (sv?.contentView.bounds.origin.y ?? 0).rounded(), fieldY: frame.maxY.rounded(),
                    hasCursor: tv.window?.firstResponder === tv)
    }
    /// Samples for `ms` milliseconds (every 8 ms), following the text view that holds the field's text.
    func watch(_ find: @escaping () -> NSTextView?, ms: Int = 700) async -> [Sample] {
      var s: [Sample] = []
      let end = Date().addingTimeInterval(Double(ms) / 1000)
      while Date() < end {
        if let tv = find() { s.append(sample(tv)) }
        try? await Task.sleep(for: .milliseconds(8))
      }
      return s
    }
    /// Values in order with repeats removed.
    func steps<T: Equatable>(_ xs: [T]) -> [T] { xs.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }

    /// The checks every field gets. `find` re-finds the field's text view each time (SwiftUI may replace it, which is a
    /// failure in itself: `same view` below).
    func exercise(_ name: String, _ find: @escaping () -> NSTextView?, in w: NSWindow, shotName: String) async {
      guard let tv0 = find() else { check("\(name): field found", false); return }
      // A known three-line text to start from, typed for real.
      w.makeFirstResponder(tv0)
      await wait(200)
      deleteAll(in: w)
      await wait(400)
      await type("Afroween live", in: w)
      await wait(400)
      guard let tv = find() else { check("\(name): field still there after typing", false); return }
      check("\(name): typing lands in the field (\(tv.string.debugDescription))", tv.string == "Afroween live")
      check("\(name): the same text view keeps the cursor while typing", tv === tv0 && w.firstResponder === tv)

      // 1. Return at the end adds a line and stays.
      var s = await watch(find)
      press("\r", code: 36, in: w)
      s = await watch(find)
      let afterEnd = s.last
      check("\(name): Return at the end adds one line (\(afterEnd?.text.debugDescription ?? "nil"))", afterEnd?.text == "Afroween live\n")
      check("\(name): caret on the new line (\(afterEnd?.caret ?? -1))", afterEnd?.caret == 14)
      check("\(name): caret never jumps after Return (\(steps(s.map(\.caret))))", holds(s, 14))
      check("\(name): the box grows without bouncing (\(steps(s.map(\.height))))", !bounces(s.map(\.height)))
      check("\(name): the text doesn't scroll away (\(steps(s.map(\.scrollY))))", steps(s.map(\.scrollY)).count <= 1 && (s.last?.scrollY ?? 0) == 0)
      check("\(name): the field stays put on the page (\(steps(s.map(\.fieldY))))", steps(s.map(\.fieldY)).count <= 1)
      check("\(name): the field keeps the cursor after Return", s.allSatisfy(\.hasCursor) && find() === tv)
      await type("Jazz piano", in: w)
      await wait(300)
      await type("\nlog drum", in: w)
      await wait(500)
      guard let tv2 = find() else { check("\(name): field still there", false); return }
      let three = "Afroween live\nJazz piano\nlog drum"
      check("\(name): three lines typed (\(tv2.string.debugDescription))", tv2.string == three)
      await shot("\(shotName)-typed", in: w)

      // 2. A click in the middle of the first line puts the caret there, and it stays.
      let target = 4  // "Afro|ween"
      click(tv2, at: target)
      s = await watch(find)
      check("\(name): a click puts the caret where clicked (\(s.first?.caret ?? -1) → \(s.last?.caret ?? -1), want \(target))",
            s.last?.caret == target)
      check("\(name): the caret stays where clicked (\(steps(s.map(\.caret))))", holds(s, target))
      check("\(name): a click doesn't scroll the text (\(steps(s.map(\.scrollY))))", steps(s.map(\.scrollY)).count <= 1)
      check("\(name): a click doesn't move the field (\(steps(s.map(\.fieldY))))", steps(s.map(\.fieldY)).count <= 1)

      // 3. Return in the middle splits the line at the caret.
      press("\r", code: 36, in: w)
      s = await watch(find)
      let split = "Afro\nween live\nJazz piano\nlog drum"
      check("\(name): Return mid-line splits at the caret (\(s.last?.text.debugDescription ?? "nil"))", s.last?.text == split)
      check("\(name): caret right after the new line (\(s.last?.caret ?? -1))", s.last?.caret == target + 1)
      check("\(name): caret never jumps after a mid-line Return (\(steps(s.map(\.caret))))", holds(s, target + 1))
      check("\(name): no bounce after a mid-line Return (\(steps(s.map(\.height))))", !bounces(s.map(\.height)))
      check("\(name): no scroll jump after a mid-line Return (\(steps(s.map(\.scrollY))))", steps(s.map(\.scrollY)).count <= 1)
      await shot("\(shotName)-split", in: w)

      // 4. A click on the last line, then typing there.
      if let tv3 = find(), case let lastLine = (tv3.string as NSString).range(of: "log").location, lastLine != NSNotFound {
        click(tv3, at: lastLine)
        await wait(250)
        await type("deep ", in: w)
        s = await watch(find, ms: 500)
        check("\(name): typing where clicked (\(s.last?.text.debugDescription ?? "nil"))", s.last?.text == "Afro\nween live\nJazz piano\ndeep log drum")
        check("\(name): caret follows the typing (\(s.last?.caret ?? -1))", s.last?.caret == lastLine + 5)
      }

      // 5. Emptied, then Return / a space first: the box keeps what was typed (it never brings other text back).
      if let tv4 = find() {
        w.makeFirstResponder(tv4)
        deleteAll(in: w)
        await wait(400)
        press("\r", code: 36, in: w)
        s = await watch(find)
        check("\(name): Return in an emptied box is one empty line (\(s.last?.text.debugDescription ?? "nil"))", s.last?.text == "\n")
        check("\(name): …with the caret on it (\(steps(s.map(\.caret))))", holds(s, 1))
        deleteAll(in: w)
        await wait(400)
        await type(" new", in: w)
        s = await watch(find, ms: 500)
        check("\(name): a space typed first stays (\(s.last?.text.debugDescription ?? "nil"))", s.last?.text == " new")
      }
      await shot("\(shotName)-end", in: w)
    }

    // MARK: the editor's Text on the video

    model.scrollTarget = .text
    await wait(1200)
    func textView(near anchor: String, in root: NSView) -> NSTextView? {
      guard let a = anchors(in: root, named: anchor).first else { return nil }
      let af = a.convert(a.bounds, to: nil)
      return textViews(in: root).first { $0.convert($0.bounds, to: nil).intersects(af) || ($0.enclosingScrollView.map { $0.convert($0.bounds, to: nil).intersects(af) } ?? false) }
    }
    await shot("text-start")
    await exercise("Text on the video", { textView(near: "Text field", in: host) }, in: window, shotName: "text")
    // What the field shows is what the model keeps.
    check("Text on the video: the model keeps what the box shows (\(model.selectedLayer.text.debugDescription))",
          model.selectedLayer.text == (textView(near: "Text field", in: host)?.string ?? "?"))
    EditorFocus.leaveText(in: window)

    // MARK: the caption

    model.scrollTarget = .caption
    await wait(1200)
    await exercise("Caption", { textView(near: "Caption field", in: host) }, in: window, shotName: "caption")
    EditorFocus.leaveText(in: window)
    await wait(600)
    check("Caption: the model keeps what the box shows (\(model.mainCaption.debugDescription))",
          model.mainCaption == (textView(near: "Caption field", in: host)?.string ?? "?"))

    // MARK: a platform's own caption (X)

    model.writePlatformCaption(.x)
    await wait(1200)
    await exercise("X caption", { textView(near: "Caption field x", in: host) }, in: window, shotName: "caption-x")
    EditorFocus.leaveText(in: window)
    await wait(600)
    check("X caption: the model keeps what the box shows (\((model.resolved.platformCaptions[.x] ?? "nil").debugDescription))",
          model.resolved.platformCaptions[.x] == (textView(near: "Caption field x", in: host)?.string ?? "?"))

    // MARK: a bare DSTextArea (templates, notes, post sheets all use it)

    let bare = NSHostingView(rootView: BareArea())
    let bw = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 520, height: 420), [.titled, .fullSizeContentView])
    bw.appearance = window.appearance
    bw.contentView = bare
    bw.isReleasedWhenClosed = false
    Backstage.show(bw)
    defer { bw.orderOut(nil); bw.close() }
    await wait(800)
    await exercise("Text area", { textViews(in: bare).first }, in: bw, shotName: "area")
    check("Text area: the binding holds what the box shows (\(BareArea.Box.shared.text.debugDescription))",
          BareArea.Box.shared.text == (textViews(in: bare).first?.string ?? "?"))

    note("\(failed == 0 ? "all passed" : "\(failed) failed")")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }

  /// True when a run of heights goes up then down (or down then up): the box jumped and came back.
  static func bounces(_ hs: [CGFloat]) -> Bool {
    var dir = 0
    var last: CGFloat?
    for h in hs {
      defer { last = h }
      guard let l = last, h != l else { continue }
      let d = h > l ? 1 : -1
      if dir != 0 && d != dir { return true }
      dir = d
    }
    return false
  }

  static func textViews(in v: NSView) -> [NSTextView] {
    var out: [NSTextView] = []
    if let t = v as? NSTextView, t.isEditable { out.append(t) }
    for s in v.subviews { out += textViews(in: s) }
    return out
  }

  static func anchors(in v: NSView, named name: String) -> [NSView] { EditorKeysScript.anchors(in: v, named: name) }

  /// A `DSTextArea` on a plain binding, as Settings and the sheets use it.
  struct BareArea: View {
    @MainActor final class Box: ObservableObject {
      static let shared = Box()
      @Published var text = ""
    }
    @ObservedObject var box = Box.shared
    var body: some View {
      VStack(alignment: .leading) {
        DSTextArea("Template", placeholder: "{text}\n\n{hashtags}", text: $box.text, hint: "A plain text area", minHeight: 88, maxHeight: 180)
        Spacer(minLength: 0)
      }
      .padding(DS.space.xl).frame(width: 520, height: 420).background(DS.color.background)
    }
  }
}
