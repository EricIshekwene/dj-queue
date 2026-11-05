import AppKit
import DJQCore
import SwiftUI

/// `DJQ_SETTINGS_GROUP_SCRIPT=<dir>` (with `DJQ_SNAPSHOT_EDITOR=1 … --snapshot <dir>`): v0.8.3. Drives the real Settings →
/// Captions & titles rows on a throwaway copy of the dev database, the way `EditorGroupScript` does: text through the real
/// field editors, the click handed to this window only. Every check reads the store. Saves `settings-NN-<step>-<appearance>.png`
/// and `settings-checks-<appearance>.txt`.
@MainActor
enum SettingsGroupScript {
  static func run(store: Store, dir: String, appearance: String) async -> Int32 {
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var log: [String] = []
    var failed = 0
    func note(_ s: String) { print("settings-script: \(s)"); log.append(s) }
    func check(_ name: String, _ ok: Bool) {
      if !ok { failed += 1 }
      note("\(ok ? "PASS" : "FAIL") \(name)")
    }
    func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func groups() -> [HashtagSet] { (try? store.hashtagSets()) ?? [] }
    func group(_ id: String) -> HashtagSet? { groups().first { $0.id == id } }

    for g in groups() { try? store.deleteHashtagSet(g.id) }
    for g in [HashtagSet(id: "s-blank", name: "", category: "Dj", tags: [], sort: 0),
              HashtagSet(id: "s-untitled", name: "  ", category: "My groups", tags: ["#amapiano"], sort: 1),
              HashtagSet(id: "s-piano", name: "Piano", category: "My groups", tags: ["#piano"], sort: 2)] {
      try? store.save(g)
    }

    let app = AppModel(store: store)
    app.refreshNow()
    SettingsUIState.shared.reset()
    SettingsUIState.shared.scrollTarget = NewClipDefaultsSettings.captionAnchor
    let defaults = AnyView(NewClipDefaultsSettings(model: app, ui: SettingsUIState.shared).padding(DS.space.xl).background(DS.color.background))
    try? await DSGallerySnapshot.render(defaults, size: CGSize(width: 760, height: 900), name: "settings-new-clip-defaults", to: out)
    SettingsUIState.shared.reset()

    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 760, height: 620), [.titled, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    func open() async -> NSView {
      let host = NSHostingView(rootView: CaptionsSettings(model: app).frame(width: 760, height: 620).background(DS.color.background))
      window.contentView = host
      await wait(800)
      return host
    }
    var host = await open()
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }

    var step = 0
    func shot(_ name: String) async {
      await wait(300)
      host.layoutSubtreeIfNeeded()
      step += 1
      let file = out.appendingPathComponent(String(format: "settings-%02d-%@-%@.png", step, name, appearance))
      if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
      }
      note("shot \(file.lastPathComponent)")
    }
    func named() -> [NSTextField] { EditorGroupScript.fields(in: host).filter { $0.placeholderString == "Group name" } }
    func tagged() -> [NSTextField] { EditorGroupScript.fields(in: host).filter { $0.placeholderString == "#amapiano #piano" } }
    /// Waits out the row's 600 ms save pause.
    func replace(_ f: NSTextField?, with text: String) async {
      guard let f else { note("no field"); return }
      window.makeFirstResponder(f)
      await wait(100)
      guard let e = f.currentEditor() as? NSTextView else { note("no field editor"); return }
      e.selectAll(nil)
      e.deleteBackward(nil)
      for ch in text { e.insertText(String(ch), replacementRange: e.selectedRange()) }
      await wait(1000)
    }
    /// Add hashtag group sits just under the last row.
    func clickAdd() async {
      guard let last = named().last else { return }
      let f = last.convert(last.bounds, to: nil)
      let p = NSPoint(x: f.minX + 40, y: f.minY - 28)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      await wait(500)
    }

    check("blank rows stay visible in Settings", named().count == 3)
    await shot("blank-rows")

    await replace(named().last, with: "")
    check("a cleared name stays editable", named().last?.stringValue == "")
    check("a cleared name isn't stored", group("s-piano")?.name == "Piano")
    check("clearing a name saves nothing", app.undoHistory.top == nil)
    await shot("name-cleared")
    await replace(tagged().last, with: "#piano #keys")
    check("a tag edit under a cleared name keeps the name", group("s-piano")?.name == "Piano" && group("s-piano")?.tags == ["#piano", "#keys"])
    await replace(named().last, with: "Keys")
    check("a new name saves", group("s-piano")?.name == "Keys")

    await replace(named().first, with: "Fixed")
    check("a blank row can be fixed", group("s-blank")?.name == "Fixed")
    await replace(named().first, with: "")
    check("a fixed row can't go blank again", group("s-blank")?.name == "Fixed")

    host = await open()
    await clickAdd()
    check("Add hashtag group adds a row", named().count == 4)
    check("an untouched new group isn't saved", groups().count == 3)
    await shot("new-group-untouched")
    host = await open()
    check("it's gone when Settings opens again", named().count == 3 && groups().count == 3)

    await clickAdd()
    await replace(named().last, with: "")
    await replace(tagged().last, with: "#new")
    check("a new group with no name waits for one", groups().count == 3)
    await replace(named().last, with: "Filled in")
    check("a filled-in group saves once", groups().filter { $0.name == "Filled in" && $0.tags == ["#new"] }.count == 1)
    await replace(tagged().last, with: "#new #two")
    check("then saves as an edit", groups().count == 4 && groups().last?.tags == ["#new", "#two"])
    await shot("new-group-saved")

    note(failed == 0 ? "all passed" : "\(failed) failed")
    try? log.joined(separator: "\n").write(to: out.appendingPathComponent("settings-checks-\(appearance).txt"), atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
  }
}
