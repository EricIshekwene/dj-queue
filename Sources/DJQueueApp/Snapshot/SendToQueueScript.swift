import AppKit
import DJQCore
import SwiftUI

/// `DJQ_SEND_TO_QUEUE_SCRIPT=1 DJQueueApp --snapshot <dir>` (B16): the promise that only Send to Queue moves a clip, in
/// the real main window on the throwaway sample. It opens the real editor on a clip whose one issue is "No text", types
/// the text through the live editor model, closes it, and checks the clip stayed in Edit with nothing to fix. Then it
/// runs the Send to Queue the stage control runs, and checks the clip moved. The window sits behind every other window
/// and nothing goes through the system event queue, so Eric's pointer and apps are never touched. Exits 1 on a failed
/// check and saves a capture of each step.
@MainActor
enum SendToQueueScript {
  static func run(model: AppModel, store: Store, out: URL) async -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      print("send-script: \(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    model.refreshNow()
    guard let clip = model.editList.first(where: { v in
      let kinds = (model.issuesByVideo[v.id] ?? []).map(\.kind)
      return kinds == [.noText] && !v.heldInEdit && !v.sentToQueue
    }) else {
      print("send-script: FAIL no unsent Edit clip whose only issue is No text")
      return 1
    }
    let name = model.displayName(clip)
    print("send-script: clip “\(name)”")

    SnapshotContext.resetUI(model)
    model.setViewMode(.wide, for: .edit)
    model.screen = .edit
    ListPrefs.shared.setSearch(.edit, name)
    let window = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
    window.setContentSize(Shot.standard.nsSize)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }

    func shot(_ file: String) async {
      try? await Task.sleep(for: .milliseconds(900))
      window.displayIfNeeded()
      guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(file).png"))
    }
    func state() -> VideoState? { (try? store.video(id: clip.id))?.state }

    await shot("send-1-edit-before")
    check("starts in Edit", model.editList.contains { $0.id == clip.id } && state() == .needsEdit)

    // Fix the last issue in the real editor, through the same model call the text field makes, then Done.
    model.openEditor(clip.id, in: [clip.id])
    try? await Task.sleep(for: .seconds(2))
    await shot("send-2-editor-open")
    let live = EditorModel.live.flatMap { $0.videoId == clip.id ? $0 : nil }
    check("the real editor is open on the clip", live != nil)
    live?.setText("Fixed in the script")
    EditorModel.flushLiveAndWait()
    try? await Task.sleep(for: .seconds(1))
    check("the editor says nothing to fix", live?.liveIssues.isEmpty == true)
    await shot("send-3-editor-nothing-to-fix")
    model.closeEditor()
    try? await Task.sleep(for: .seconds(1))
    model.refreshNow()
    await shot("send-4-edit-after-save")
    check("saved, and still in Edit", state() == .needsEdit && model.editList.contains { $0.id == clip.id })
    check("nothing left to fix", (model.issuesByVideo[clip.id] ?? []).isEmpty)
    check("not in the Queue", !model.queueClips.contains { $0.id == clip.id })
    check("the flag stayed off", (try? store.video(id: clip.id))?.sentToQueue == false)

    // Send to Queue: the stage control's action.
    guard let fresh = model.video(clip.id) else { return 1 }
    check("the stage control offers Send to Queue", model.stageForwardTitle(fresh) == "Send to Queue" && model.stageBlocker(fresh, .forward) == nil)
    model.stageForward([clip.id])
    for _ in 0..<40 where state() == .needsEdit { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .seconds(1))
    model.refreshNow()
    ListPrefs.shared.setSearch(.edit, "")
    ListPrefs.shared.setSearch(.queue, name)
    model.setViewMode(.wide, for: .queue)
    model.screen = .queue
    await shot("send-5-queue-after-send")
    check("sent, and in the Queue", state() == .ready && model.queueClips.contains { $0.id == clip.id })
    check("gone from Edit", !model.editList.contains { $0.id == clip.id })
    check("the flag is on", (try? store.video(id: clip.id))?.sentToQueue == true)
    print("send-script: \(failures == 0 ? "all passed" : "\(failures) failed")")
    return failures == 0 ? 0 : 1
  }
}

private extension CGSize {
  var nsSize: NSSize { NSSize(width: width, height: height) }
}
