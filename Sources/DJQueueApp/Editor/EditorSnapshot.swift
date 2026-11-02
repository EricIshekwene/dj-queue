import AppKit
import DJQCore
import SwiftUI

/// Editor-only snapshots and a live run, from a throwaway copy of the dev database (never the source DB).
///
/// - `DJQ_SNAPSHOT_EDITOR=1 DJQueueApp --snapshot <dir>` renders `editor-NN-<name>-{light,dark}.png` at 1440×900
///   (stills stand in for the player). Needs the one-line hook in `SnapshotRunner.run`.
///   `DJQ_EDITOR_VIDEO=<id prefix>` picks the clip (default: the first short clip with suggestions, else with markers);
///   `DJQ_SNAPSHOT_ONLY=<substring>` filters shots.
/// - `DJQ_EDITOR_LIVE=<seconds>` instead opens the real editor (live player) in a window for that long and prints
///   `editor-live: window <number>` so it can be captured with `screencapture -l <number>`.
@MainActor
enum EditorSnapshot {
  static func run(outputDir: String) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    do {
      let out = URL(fileURLWithPath: outputDir)
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let src = Paths.standard
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-editor-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: tmp) }
      let paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: src.database.path) {
        try Store(paths: src).db.backup(to: paths.database.path)
      }
      let store = try Store(paths: paths)
      if try store.videos().isEmpty { try Intake(store: store).run() }
      // View preferences go to a throwaway defaults suite, never the app's.
      let suite = "djq-editor-snapshot-\(UUID().uuidString)"
      EditorModel.defaults = UserDefaults(suiteName: suite) ?? .standard
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

      let shorts = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0").sorted { $0.name < $1.name }
      guard !shorts.isEmpty else { throw EngineError("no short clips in the dev database") }
      let pick: Video = try {
        if let p = env["DJQ_EDITOR_VIDEO"], let v = shorts.first(where: { $0.id.hasPrefix(p) }) { return v }
        if let v = try shorts.first(where: { !(try store.titleSuggestions(videoId: $0.id)).isEmpty }) { return v }
        return shorts.first { $0.markerIn != nil } ?? shorts[0]
      }()
      let ids = shorts.map(\.id)

      if env["DJQ_EDITOR_SELFTEST"] != nil { return selfTest(store: store, ids: ids, start: pick.id) }
      if let secs = env["DJQ_EDITOR_LIVE"].flatMap(Double.init) { return await live(store: store, video: pick.id, ids: ids, seconds: secs) }

      let model = EditorModel(store: store, videoId: pick.id, snapshotMode: true)
      // A clip with no title and no suggestions for the "Ask an agent" state.
      let helpless = shorts.first { $0.id != pick.id && $0.titleText == nil && ((try? store.titleSuggestions(videoId: $0.id)) ?? []).isEmpty }
      print("editor-snapshot: clip \(pick.id.prefix(8)) “\(pick.displayName)”, \(model.suggestions.count) suggestions")

      var shots: [(String, () -> Void)] = []
      func shot(_ name: String, _ setup: @escaping () -> Void) { shots.append((name, setup)) }
      let reset = {
        model.compare = false
        model.openPlatformCaption = nil
        model.toast = nil
      }
      shot("01-title-suggestions") { reset(); model.canvasMode = .zones; model.zonePlatforms = [.tiktok, .instagram]; model.scrollTarget = .title }
      shot("02-frame") { reset(); model.canvasMode = .frame; model.scrollTarget = .frame }
      shot("03-text") { reset(); model.canvasMode = .zones; model.scrollTarget = .text }
      shot("04-caption") { reset(); model.canvasMode = .zones; model.scrollTarget = .caption }
      shot("05-cover") { reset(); model.canvasMode = .zones; model.scrollTarget = .cover }
      shot("06-platforms") { reset(); model.canvasMode = .zones; model.scrollTarget = .platforms }
      shot("07-zones-3-platforms") {
        reset(); model.canvasMode = .zones; model.zonePlatforms = [.tiktok, .instagram, .youtube]; model.scrollTarget = .frame
      }
      shot("08-zones-cards") { reset(); model.canvasMode = .zones; model.zonePlatforms = [.facebook, .threads, .x]; model.scrollTarget = .title }
      for (i, p) in EditorPlatforms.order.enumerated() {
        shot(String(format: "%02d-preview-%@", 10 + i, p.rawValue)) {
          reset(); model.canvasMode = .preview; model.previewPlatform = p; model.scrollTarget = .caption
        }
      }
      shot("16-preview-compare") { reset(); model.canvasMode = .preview; model.previewPlatform = .tiktok; model.compare = true }
      shot("17-caption-over-limit") {
        reset()
        model.canvasMode = .preview
        model.previewPlatform = .x
        // A long typed caption (throwaway DB) so X (280) and Threads (500) go over.
        let long = (model.title ?? model.rawTag) + " — live at the Afroween Jazz Piano set. "
          + "That log drum switch into the second track still gets me every time. "
          + "Full set on YouTube, link in bio. Which blend should I post next? Tell me in the comments.\n{hashtags}"
        model.updateVersion { $0.caption = long }
        model.scrollTarget = .caption
      }
      shot("18-caption-x-own") {
        reset()
        model.canvasMode = .preview
        model.previewPlatform = .x
        model.dropHashtags(.x)
        model.toast = nil
        model.writePlatformCaption(.x)
      }
      if let h = helpless {
        shot("19-title-ask-agent") {
          reset(); model.resetVersion(["caption", "platformCaptions"]); model.load(h.id)
          model.canvasMode = .zones; model.scrollTarget = .title
        }
      }
      if let only = env["DJQ_SNAPSHOT_ONLY"] { shots = shots.filter { $0.0.contains(only) } }

      for (name, setup) in shots {
        setup()
        model.flushAndWait()
        try await DSGallerySnapshot.render(AnyView(EditorView(model: model, videoIds: ids, onDone: {})),
                                           size: CGSize(width: 1440, height: 900), name: "editor-\(name)", to: out)
        print("editor-snapshot: \(name)")
      }
      print("editor-snapshot: wrote \(shots.count * 2) PNGs to \(out.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("editor snapshot failed: \(error)\n".utf8))
      return 1
    }
  }

  /// `DJQ_EDITOR_SELFTEST=1`: exercises the model paths the header/keyboard use (⌘] = `load(next)`, Done/⌘↩ =
  /// `flushAndWait()`) and the "no-op click stores nothing" rules against the throwaway DB. Prints PASS/FAIL.
  private static func selfTest(store: Store, ids: [String], start: String) -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      print("editor-selftest: \(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    guard let i = ids.firstIndex(of: start), ids.count > 2 else { print("editor-selftest: need 3 clips"); return 1 }
    let next = ids[(i + 1) % ids.count], third = ids[(i + 2) % ids.count]
    let m = EditorModel(store: store, videoId: start, snapshotMode: true)
    // Typed title, then ⌘] (no blur): the header calls load(next).
    m.titleDraft = "Typed then next clip"
    m.load(next)
    m.flushAndWait()
    check("typed Title survives ⌘] / ‹ › (load)", (try? store.video(id: start))??.title == "Typed then next clip")
    check("next clip starts without the draft", m.titleDraft == nil && m.videoId == next)
    // Typed title, then Done / ⌘↩: EditorView.done() = flushAndWait().
    m.titleDraft = "Typed then Done"
    m.flushAndWait()
    check("typed Title survives Done / ⌘↩ (flushAndWait)", (try? store.video(id: next))??.title == "Typed then Done")
    m.load(third)
    // No-op clicks store nothing.
    m.setVersionField(\.style, \.style, m.resolved.style)
    check("clicking the default style stays Default", m.resolved.isDefault("style"))
    m.setVersionField(\.align, \.align, m.resolved.align)
    check("clicking the default alignment stays Default", m.resolved.isDefault("align"))
    m.setVersionField(\.size, \.size, m.resolved.size)
    check("dragging size back to the default stays Default", m.resolved.isDefault("size"))
    let sets = m.resolved.hashtagSetIds
    if let extra = m.sets.first(where: { !sets.contains($0.id) }) {
      m.setHashtagSets(sets + [extra.id])
      check("adding a hashtag set is Custom", !m.resolved.isDefault("hashtagSetIds"))
      m.setHashtagSets(sets)
      check("removing it again is Default", m.resolved.isDefault("hashtagSetIds"))
    }
    m.setCaptionTemplate(m.defaults.captionTemplateId)
    check("choosing the default template stays Default", m.resolved.isDefault("captionTemplateId"))
    m.setExtraHashtags(["#a"]); m.resetVersion(["hashtagSetIds", "extraHashtags"])
    check("hashtag reset clears extra hashtags", m.resolved.extraHashtags == m.defaults.extraHashtags)
    // Clearing the text field is an explicit empty, not the Title again; "Follow the Title" resets.
    m.setTitle("Some title")
    m.setText("typed")
    m.setText("")
    check("cleared text stays empty (no Title refill)", m.resolved.text.isEmpty && !m.resolved.isDefault("text"))
    m.resetVersion(["text"])
    check("Follow the Title restores the default", m.resolved.isDefault("text") && m.resolved.text == "Some title")
    m.setNoText(true); m.setNoText(false)
    check("No text on → off follows the Title again", m.resolved.isDefault("text") && m.resolved.text == "Some title")
    m.flushAndWait()
    print("editor-selftest: \(failures == 0 ? "all passed" : "\(failures) failed")")
    return failures == 0 ? 0 : 1
  }

  /// Opens the real editor (live AVPlayer) in a normal window for `seconds`, printing its window number.
  private static func live(store: Store, video: String, ids: [String], seconds: Double) async -> Int32 {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.title = "DJ Queue — Editor (dev)"
    window.contentView = NSHostingView(rootView: EditorView(store: store, videoId: video, videoIds: ids, onDone: {}))
    window.isReleasedWhenClosed = false
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    print("editor-live: window \(window.windowNumber)")
    fflush(stdout)
    // Optional in-process capture of our own window (window-server image: shows the live player frame; needs no
    // Screen Recording permission) — `DJQ_EDITOR_LIVE_PNG=<file>`, taken after 8 s.
    if let png = ProcessInfo.processInfo.environment["DJQ_EDITOR_LIVE_PNG"] {
      try? await Task.sleep(for: .seconds(8))
      let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
      print("editor-live: first responder \(fr) (text field focused: \(window.firstResponder is NSTextView))")
      if let data = WindowCapture.png(window) {
        try? data.write(to: URL(fileURLWithPath: png))
        print("editor-live: captured \(png)")
      } else {
        print("editor-live: window capture unavailable")
      }
      // The window server returns a blank image while the display sleeps, so also let AppKit draw the live view tree
      // (the live player layer doesn't draw this way; everything else is the real, non-snapshot editor).
      if let view = window.contentView {
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: rep)
          let viewPNG = png.replacingOccurrences(of: ".png", with: "-view.png")
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: viewPNG))
          print("editor-live: drew \(viewPNG)")
        }
      }
      fflush(stdout)
    }
    try? await Task.sleep(for: .seconds(seconds))
    window.close()
    return 0
  }
}
