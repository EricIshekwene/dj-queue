import AppKit
import DJQCore
import SwiftUI

/// `DJQ_EDITOR_CAPTION_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): drives the REAL caption field of
/// the real (non-snapshot) editor through AppKit's text system — the same `NSTextView.insertText` / `deleteBackward`
/// calls a key press ends in — on a throwaway copy of the dev database. The window sits behind every other window and
/// never takes focus; nothing is posted to the system event queue, so Eric's pointer and apps are never touched.
///
/// It measures what each keystroke costs (main thread, insert → SwiftUI update → display) on a 2,000+ character
/// caption, and saves an AppKit drawing of the window after each step (`caption-NN-<step>.png`), plus `timing.txt`.
@MainActor
enum EditorCaptionScript {
  static func run(store: Store, video: String, ids: [String], dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    func note(_ s: String) { print("caption-script: \(s)"); log.append(s) }

    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    let model = EditorModel(store: store, videoId: video)
    let host = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.contentView = host
    window.isReleasedWhenClosed = false
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }
    try? await Task.sleep(for: .seconds(3))
    model.scrollTarget = .caption
    try? await Task.sleep(for: .seconds(1))

    var step = 0
    func shot(_ name: String) async {
      try? await Task.sleep(for: .milliseconds(500))
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "caption-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }

    /// The caption field: the text view tagged `editor.caption`, else the one showing the caption text.
    func captionView() -> NSTextView? {
      let all = textViews(in: host)
      if let t = all.first(where: { $0.enclosingScrollView?.identifier?.rawValue == "editor.caption"
        || $0.identifier?.rawValue == "editor.caption" || ($0.accessibilityIdentifier() == "editor.caption") }) { return t }
      let want = model.resolved.caption, shown = model.mainCaption
      return all.first { !shown.isEmpty && $0.string == shown } ?? all.first { !want.isEmpty && $0.string == want }
        ?? all.first { $0.string.contains("{hashtags}") || $0.string.count > 1500 }
    }

    // 0. Round 7: Eric's own groups; the field shows the real caption, and chips / templates / ⌘Z change the text IN the
    //    field (read back from the NSTextView, not the model).
    for g in [HashtagSet(id: "cs-piano", name: "Piano", category: "My groups", tags: ["#amapiano", "#piano"], sort: 0),
              HashtagSet(id: "cs-sa", name: "Piano · SA", category: "My groups", tags: ["#amapianosa"], sort: 1)] { try? store.save(g) }
    model.load(video)
    try? await Task.sleep(for: .seconds(2))
    model.resetVersion(["caption", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
    model.scrollTarget = .caption
    try? await Task.sleep(for: .seconds(1))
    var checks: [Bool] = []
    func check(_ name: String, _ ok: Bool) { checks.append(ok); note("\(ok ? "PASS" : "FAIL") \(name)") }
    if let f = captionView() {
      check("field holds the template's caption (\(f.string.count) chars)", f.string == model.mainCaption && !f.string.isEmpty)
      model.setHashtagSets(["cs-piano"])
      try? await Task.sleep(for: .milliseconds(600))
      check("Piano chip → #amapiano #piano appear in the field", f.string.hasSuffix("#amapiano #piano"))
      await shot("group-on")
      f.setSelectedRange(NSRange(location: 0, length: 0))
      for ch in "Hook: " { f.insertText(String(ch), replacementRange: f.selectedRange()); try? await Task.sleep(for: .milliseconds(40)) }
      try? await Task.sleep(for: .milliseconds(600))
      check("typing at the start → Custom with the typed text", model.captionIsWritten && model.resolved.caption.hasPrefix("Hook: "))
      model.setHashtagSets(["cs-piano", "cs-sa"])
      try? await Task.sleep(for: .milliseconds(600))
      check("second chip on a written caption → tags swapped in place, text kept",
            f.string.hasPrefix("Hook: ") && f.string.hasSuffix("#amapiano #piano #amapianosa")
              && f.string.components(separatedBy: "#amapiano ").count == 2)
      await shot("second-group-in-written-caption")
      let written = f.string
      model.setCaptionTemplate("short")
      try? await Task.sleep(for: .milliseconds(600))
      check("template switch rewrites the field", f.string == model.mainCaption && !f.string.hasPrefix("Hook: "))
      await shot("template-switch")
      model.undo()
      try? await Task.sleep(for: .milliseconds(600))
      check("⌘Z puts the written caption back in the field", f.string == written)
      await shot("undo")
    } else {
      check("caption field found", false)
    }

    // 1. A 2,000+ character caption.
    let para = "That log drum switch into the second track still gets me every time, live at the Afroween Jazz Piano set. "
    var long = ""
    while long.count < 2100 { long += para }
    long += "\n{hashtags}"
    model.updateVersion(coalesce: false) { $0.caption = long }
    model.toast = nil
    try? await Task.sleep(for: .seconds(4))
    await shot("long-caption")
    guard let tv = captionView() else {
      note("FAIL no caption text view found (\(textViews(in: host).count) text views)")
      try? log.joined(separator: "\n").write(to: out.appendingPathComponent("timing-\(appearance).txt"), atomically: true, encoding: .utf8)
      return 1
    }
    note("caption view: \(tv.string.count) chars, editable \(tv.isEditable), frame \(Int(tv.enclosingScrollView?.frame.height ?? tv.frame.height)) pt tall, document \(Int(tv.frame.height)) pt")

    // 2. Click mid-text and type 40 characters, one keystroke at a time, timing each.
    let mid = (tv.string as NSString).length / 2
    tv.setSelectedRange(NSRange(location: mid, length: 0))
    tv.scrollRangeToVisible(NSRange(location: mid, length: 0))
    var costs: [Double] = []
    for ch in "TYPED-MID-TEXT-0123456789-abcdefghijklmn" {
      let t0 = CFAbsoluteTimeGetCurrent()
      tv.insertText(String(ch), replacementRange: tv.selectedRange())
      await Task.yield()
      window.displayIfNeeded()
      costs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
      try? await Task.sleep(for: .milliseconds(40))  // 25 keys a second, past anyone's typing
    }
    try? await Task.sleep(for: .milliseconds(800))
    let sorted = costs.sorted()
    note(String(format: "typing 40 chars mid-caption: median %.1f ms, p90 %.1f ms, max %.1f ms per keystroke",
                sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0))
    let typedOK = model.resolved.caption.contains("TYPED-MID-TEXT-0123456789-abcdefghijklmn")
    note("\(typedOK ? "PASS" : "FAIL") typed text reached the clip's caption (\(model.resolved.caption.count) chars)")
    await shot("typed-mid-text")

    // 3. Delete 10 characters (backspace).
    for _ in 0..<10 { tv.deleteBackward(nil); try? await Task.sleep(for: .milliseconds(40)) }
    try? await Task.sleep(for: .milliseconds(800))
    let delOK = model.resolved.caption.contains("TYPED-MID-TEXT-0123456789-abcd") && !model.resolved.caption.contains("abcde")
    note("\(delOK ? "PASS" : "FAIL") backspace ×10 reached the caption")
    await shot("deleted")

    // 4. Select all (the field shows the whole caption selected).
    tv.selectAll(nil)
    let selOK = tv.selectedRange().length == (tv.string as NSString).length && tv.selectedRange().length > 2000
    note("\(selOK ? "PASS" : "FAIL") select-all selects all \(tv.selectedRange().length) characters")
    await shot("select-all")

    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("timing-\(appearance).txt"), atomically: true, encoding: .utf8)
    model.flushAndWait()
    return typedOK && delOK && selOK && !checks.contains(false) ? 0 : 1
  }

  static func textViews(in v: NSView) -> [NSTextView] {
    var out: [NSTextView] = []
    if let t = v as? NSTextView { out.append(t) }
    for s in v.subviews { out += textViews(in: s) }
    return out
  }
}
