import AppKit
import DJQCore
import SwiftUI

/// `DJQ_EDITOR_KEYS_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): round 19. Drives the REAL editor's
/// keys on a throwaway copy of the dev database: Space after typing (the bug), a click on the picture and Esc taking the
/// cursor out of a field, ← / → by the arrow step (⇧ one frame), the step chip beside Play, ↑ / ↓ between clips, then
/// Settings → Playback's try-it strip. Keys and clicks are events handed to `NSApp.sendEvent` for this window only (the
/// path a real key takes, key monitors included); the window sits off every display and never takes focus. Every check
/// reads the player, the window's first responder or the model, never the view's intent. Saves
/// `keys-NN-<step>-<appearance>.png` and `checks-<appearance>.txt`.
@MainActor
enum EditorKeysScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("keys-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    let app = AppModel(store: store)
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: video)
    model.appHooks = EditorAppHooks(isCovered: { false }, arrowStep: { app.playback.arrowStep },
                                    setArrowStep: { s in app.setPlayback { $0.arrowStep = s } })
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    try? await Task.sleep(for: .seconds(3))

    var step = 0
    func shot(_ name: String, in view: NSView? = nil) async {
      let v = view ?? host
      await wait(300)
      window.displayIfNeeded()
      v.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "keys-%02d-%@-%@.png", step, name, appearance))
      if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func press(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code) else { return }
      NSApp.sendEvent(e)
      await wait()
    }
    func space() async { await press(" ", code: EditorKeys.space) }
    /// A click on a view's centre (an anchor or the picture), through the app's event path.
    func click(_ v: NSView, dx: CGFloat = 0, dy: CGFloat = 0) async {
      let f = v.convert(v.bounds, to: nil)
      let p = NSPoint(x: f.midX + dx, y: f.midY + dy)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          NSApp.sendEvent(e)
        }
      }
      await wait()
    }
    func typing() -> Bool { window.firstResponder is NSTextView }
    func titleField() -> NSTextField? {
      fields(in: host).first { $0.placeholderString == "Title" || $0.placeholderString == "Type a title" }
    }
    func focusTitle() async -> Bool {
      guard let f = titleField() else { return false }
      window.makeFirstResponder(f)
      await wait(200)
      return typing()
    }
    func pause() async { model.playback.pause(); await wait(200) }
    let pb = model.playback

    check("player loaded", pb.player != nil)
    check("arrow step defaults to 2 seconds", model.arrowStep == .twoSeconds)

    // 1. Space plays and pauses with nothing focused.
    await space()
    check("Space plays", pb.isPlaying)
    await shot("space-plays")
    await space()
    check("Space pauses", !pb.isPlaying)

    // 2. The bug: typing in Title, then a click on the picture. Before round 19 the field kept the cursor, so Space
    //    typed a space into the Title instead of playing.
    check("Title field takes the cursor", await focusTitle())
    await space()
    check("Space types while the Title has the cursor", !pb.isPlaying && typing())
    await shot("typing-title")
    // The picture: the tallest click-away zone (the other one is the timeline).
    if let canvas = zones(in: host).max(by: { $0.bounds.height < $1.bounds.height }) {
      await click(canvas)
    } else {
      check("picture found", false)
    }
    check("a click on the picture takes the cursor out of the Title", !typing())
    await space()
    check("Space plays right after the click", pb.isPlaying)
    await shot("click-away-then-space")
    await pause()

    // 3. Esc leaves a field too.
    _ = await focusTitle()
    model.titleDraft = nil
    await press("\u{1b}", code: EditorKeys.escape)
    check("Esc takes the cursor out of the Title", !typing())
    await space()
    check("Space plays after Esc", pb.isPlaying)
    await pause()

    // 4. ← / → jump by the step (2 s by default), ⇧ one frame.
    let start = min(model.trim.start + 6, max(0, model.duration - 4))
    pb.seek(start, exact: true)
    await wait(300)
    await press("\u{F703}", code: EditorKeys.right)
    check("→ jumps 2 s (\(String(format: "%.2f", pb.time - start)))", abs(pb.time - start - 2) < 0.05)
    await press("\u{F702}", code: EditorKeys.left)
    check("← jumps back 2 s", abs(pb.time - start) < 0.05)
    await press("\u{F703}", code: EditorKeys.right, flags: .shift)
    check("⇧→ moves one frame", abs(pb.time - start - 1 / model.fps) < 0.01)
    await shot("arrow-2s")

    // 5. The chip beside Play: 5 s (the menu itself is a system menu that can't run hidden; this sets the same binding
    //    the menu item sets — stand-in).
    note("stand-in: the step chip's menu is an NSMenu; choosing 5 s goes through EditorModel.setArrowStep, as the menu does")
    model.setArrowStep(.fiveSeconds)
    await wait(300)
    check("the choice is Eric's app-wide setting", app.playback.arrowStep == .fiveSeconds)
    pb.seek(start, exact: true)
    await wait(300)
    await press("\u{F703}", code: EditorKeys.right)
    check("→ now jumps 5 s", abs(pb.time - start - 5) < 0.05)
    await shot("arrow-5s")

    // 6. ↑ / ↓ move between clips; not while typing.
    let i = ids.firstIndex(of: model.videoId) ?? 0
    if ids.indices.contains(i + 1) {
      _ = await focusTitle()
      await press("\u{F701}", code: EditorKeys.down)
      check("↓ while typing stays on the clip", model.videoId == ids[i])
      await press("\u{1b}", code: EditorKeys.escape)
      await press("\u{F701}", code: EditorKeys.down)
      try? await Task.sleep(for: .seconds(2))
      check("↓ opens the next clip", model.videoId == ids[i + 1])
      await shot("down-next-clip")
      await space()
      check("Space plays the new clip", pb.isPlaying)
      await pause()
      await press("\u{F700}", code: EditorKeys.up)
      try? await Task.sleep(for: .seconds(2))
      check("↑ opens the previous clip", model.videoId == ids[i])
      // Another clip opened while typing (⌘] or the header arrow) starts with nothing focused, and the Title typed so
      // far stays with the clip it was typed on.
      let titleBefore = model.title
      _ = await focusTitle()
      EditorView.open(1, model: model, in: ids)
      try? await Task.sleep(for: .seconds(2))
      check("another clip opened while typing lets go of the field", !typing() && model.videoId == ids[i + 1])
      await space()
      check("…so Space plays it", pb.isPlaying)
      await pause()
      EditorView.open(-1, model: model, in: ids)
      try? await Task.sleep(for: .seconds(2))
      check("the first clip's Title is unchanged", model.title == titleBefore)
    } else {
      note("skip ↑ / ↓: only one clip")
    }

    // 7. Settings → Playback: the row and its try-it strip (5 s from step 5).
    let settings = NSHostingView(rootView: AnyView(VStack(alignment: .leading, spacing: 0) { PlaybackSettings(model: app); Spacer(minLength: 0) }
      .padding(DS.space.xl).frame(width: 760, height: 760).background(DS.color.background)))
    let sw = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 760, height: 760), [.titled, .fullSizeContentView])
    sw.appearance = window.appearance
    sw.contentView = settings
    sw.isReleasedWhenClosed = false
    Backstage.show(sw)
    defer { sw.orderOut(nil); sw.close() }
    await wait(800)
    await shot("settings-row", in: settings)
    if let strip = anchors(in: settings, named: "Arrow step try").first {
      let f = strip.convert(strip.bounds, to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: f.minX + f.width / 10, y: f.midY), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sw.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          NSApp.sendEvent(e)
        }
        await wait(150)
      }
      await wait(300)
      for _ in 0..<2 {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: sw.windowNumber, context: nil, characters: "\u{F703}",
                                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: EditorKeys.right) {
          NSApp.sendEvent(e)
        }
        await wait(300)
      }
      await shot("settings-try-it", in: settings)
      let t = TryItState.latest?.time ?? -1
      check("try-it: a click at 0:03 then → → at 5 s lands at 0:13 (\(String(format: "%.1f", t)))", abs(t - 13) < 0.05)
    } else {
      check("try-it strip found", false)
    }

    note("\(failed == 0 ? "all passed" : "\(failed) failed")")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }

  static func fields(in v: NSView) -> [NSTextField] {
    var out: [NSTextField] = []
    if let t = v as? NSTextField { out.append(t) }
    for s in v.subviews { out += fields(in: s) }
    return out
  }

  static func zones(in v: NSView) -> [NSView] {
    var out: [NSView] = v is EditorClickAway.ZoneView ? [v] : []
    for s in v.subviews { out += zones(in: s) }
    return out
  }

  static func anchors(in v: NSView, named name: String) -> [NSView] {
    var out: [NSView] = v.identifier?.rawValue == ScriptAnchor.prefix + name ? [v] : []
    for s in v.subviews { out += anchors(in: s, named: name) }
    return out
  }
}
