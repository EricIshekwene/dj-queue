import AppKit
import DJQCore
import SwiftUI

/// A bulk action as a screen describes it. `run(true)` must be a dry run (`BulkActions` `dryRun: true`),
/// `run(false)` applies it. Both run OFF the main thread, so capture `model.bulk` (Sendable) and plain values,
/// never views:
///
/// ```swift
/// let bulk = model.bulk, ids = model.selectedIds(.edit)
/// model.requestBulk(BulkRequest(title: "Send \(ids.count) clips to the Queue?", verb: "Send to Queue", ids: ids,
///                               changes: [.init(field: "Crop", value: "Default anchor"), …]) { dry in
///   try bulk.makeReadyWithDefaults(ids, dryRun: dry)
/// })
/// ```
struct BulkRequest {
  /// Sheet title, e.g. "Send 9 clips to the Queue?".
  var title: String
  /// Primary button label, e.g. "Send to Queue".
  var verb: String
  var ids: [String]
  /// "What will change" rows (DSChangeList), e.g. Caption → Template "DJ set".
  var changes: [DSChangeList.Change] = []
  /// Toast after applying; nil = "Updated N clips" (make-ready: its outlook, "3 sent to the Queue · 58 still need a title").
  var doneMessage: String? = nil
  /// Clear the screen's selection once the batch changed something (the bulk bar hides, the toast is unobstructed).
  var clearsSelection = true
  /// Ask first even for one clip (e.g. Remove from queue when it would remove scheduled days, Back to Score).
  var alwaysConfirm = false
  /// Sheet: a titled list built from the dry run (e.g. "Scheduled days removed" → "Thu 5 Nov · 6 platforms").
  var previewTitle: String? = nil
  var previewLines: ((BulkResult) -> [String])? = nil
  var previewIcon = "calendar"
  /// Toast from the applied result (message, detail); nil falls back to `doneMessage`.
  var doneText: ((BulkResult) -> (String, String?))? = nil
  var run: @Sendable (_ dryRun: Bool) throws -> BulkResult
}

/// The confirmation sheet's state: the request plus its dry-run preview once it lands.
struct PendingBulk: Identifiable {
  let id = UUID()
  var request: BulkRequest
  var preview: BulkResult?
  var error: String?
  var applying = false
}

/// Bulk flow (#11): >1 clip → confirmation sheet (dry run → change list → apply); 1 clip → apply at once.
/// Every applied batch ends with the toast "Updated N clips · Undo" (BulkActions.undo). ⌘Z → `undoLast()`.
extension AppModel {
  func requestBulk(_ r: BulkRequest) {
    guard !r.ids.isEmpty else { return }
    if r.ids.count == 1 && !r.alwaysConfirm {
      apply(r)
      return
    }
    pendingBulk = PendingBulk(request: r)
    recheckPendingBulk()
  }

  /// Confirmation sheet → primary button.
  func confirmPendingBulk() {
    guard let p = pendingBulk, !p.applying else { return }
    pendingBulk?.applying = true
    apply(p.request) { [weak self] in self?.pendingBulk = nil }
  }

  func cancelPendingBulk() { pendingBulk = nil }

  func apply(_ r: BulkRequest, then: (() -> Void)? = nil) {
    splitEditorSession()
    let run = r.run
    let screen = self.screen
    Task.detached(priority: .userInitiated) {
      let out: Result<BulkResult, Error> = Result { try run(false) }
      await MainActor.run {
        then?()
        self.refresh()
        switch out {
        case .failure(let e):
          self.show(e.localizedDescription, error: true)
        case .success(let res):
          let n = res.changed.count
          // One clip refused: the reason is the message (a post removed from Postiz, a day too soon).
          if n == 0, r.ids.count == 1, res.outlook == nil, let why = res.skipped.values.first {
            self.show(why, error: true)
            return
          }
          if n == 0 {
            self.show(DSToastModel(message: "Nothing changed",
                                   detail: res.outlook.map { "\($0.summary)" } ?? res.skipped.values.sorted().first, duration: 4))
            return
          }
          if r.clearsSelection { self.clearSelection(screen) }
          let custom = r.doneText?(res)
          let msg = custom?.0 ?? r.doneMessage ?? res.outlook.map { Self.outlookMessage($0, changed: n) } ?? "Updated \(n) clip\(n == 1 ? "" : "s")"
          if let b = res.batchId { self.undoHistory.push(b, label: msg) }
          let skipped = res.skipped.count
          let allReady = res.outlook.map { $0.needTitle.isEmpty && $0.other.isEmpty && $0.needScore.isEmpty } ?? true
          let detail = [custom?.1, skipped > 0 ? "\(skipped) skipped" : nil].compactMap { $0 }.joined(separator: " · ")
          self.show(DSToastModel(message: msg, detail: detail.isEmpty ? nil : detail, tone: allReady ? .success : .neutral,
                                 actionTitle: res.batchId == nil ? nil : "Undo",
                                 action: res.batchId.map { b in { self.undo(batch: b) } }, duration: 6))
        }
      }
    }
  }

  /// Make-ready's true result: "3 sent to the Queue · 58 still need a title" (none: "Crop confirmed for 3 · …").
  static func outlookMessage(_ o: ReadyOutlook, changed: Int) -> String {
    var parts = [o.ready.isEmpty ? "Crop confirmed for \(pipelineClips(changed))" : "\(o.ready.count) sent to the Queue"]
    if !o.needTitle.isEmpty { parts.append("\(o.needTitle.count) still need\(o.needTitle.count == 1 ? "s" : "") a title") }
    if !o.other.isEmpty { parts.append("\(o.other.count) with other issues") }
    if !o.needScore.isEmpty { parts.append("\(o.needScore.count) still need\(o.needScore.count == 1 ? "s" : "") a score") }
    return parts.joined(separator: " · ")
  }

  /// Confirmation sheet → "Use raw tag as title for these M": sets each clip's Title to its raw tag verbatim (one
  /// undoable batch), then re-checks the pending action so the sheet's counts are true again.
  func useRawTagAsTitle(_ ids: [String]) {
    let b = bulk
    apply(BulkRequest(title: "", verb: "", ids: ids, doneMessage: "Raw tag set as the title for \(AppModel.pipelineClips(ids.count))",
                      clearsSelection: false) { dry in try b.useRawTagAsTitle(ids, dryRun: dry) }) { [weak self] in
      self?.recheckPendingBulk()
    }
  }

  /// Runs the pending sheet's dry run again (after something changed underneath it).
  func recheckPendingBulk() {
    guard let p = pendingBulk else { return }
    pendingBulk?.preview = nil
    pendingBulk?.error = nil
    let run = p.request.run
    Task.detached(priority: .userInitiated) {
      let out: Result<BulkResult, Error> = Result { try run(true) }
      await MainActor.run {
        guard self.pendingBulk?.id == p.id else { return }
        switch out {
        case .success(let res): self.pendingBulk?.preview = res
        case .failure(let e): self.pendingBulk?.error = e.localizedDescription
        }
      }
    }
  }

  /// Undoes one batch (toast "Undone: <what>", or why not). Clips changed again since are skipped by BulkActions.
  func undo(batch id: String) {
    // An undo that would put Postiz back on live (e.g. undoing "Test run turned on", or "TikTok now posts manually")
    // asks first, like the switch itself did; core refuses it otherwise.
    let live = (try? bulk.undoWouldGoLive(id)) ?? []
    guard live.isEmpty else {
      let names = live.map(\.displayName)
      let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
      confirmHere(ConfirmRequest(
        title: "Undo and post publicly?",
        message: "Undoing this puts \(list) back on Postiz with Test run off: planned posts there go out publicly at their slots, and one whose time has passed within minutes.",
        verb: "Undo and go live", icon: "paperplane") { [weak self] in self?.runUndo(id, confirmGoLive: true) })
      return
    }
    runUndo(id, confirmGoLive: false)
  }

  /// Core's refusal in Eric's words: no action names, no force the app doesn't offer.
  static func undoFailure(_ message: String) -> String {
    if message.contains("its slot has passed") { return "That day's slot has passed, so this can't be undone" }
    guard let colon = message.range(of: ": "), message.hasPrefix("Can't undo the plan part of"),
          let end = message.range(of: ". Use force") else { return "Couldn't undo: \(message)" }
    return "Couldn't undo: \(message[colon.upperBound..<end.lowerBound])"
  }

  private func runUndo(_ id: String, confirmGoLive: Bool) {
    splitEditorSession()
    let label = undoHistory.entries.first { $0.batchId == id }?.label
    undoHistory.remove(id)
    let finish: @Sendable (Result<BulkResult, Error>) -> Void = { out in
      DispatchQueue.main.async {
        self.refresh()
        switch out {
        case .success(let r):
          // An undo from a toast while the editor is open: the session restarts after it (its edits so far were
          // journaled by the split above), so closing the editor never re-applies what was just undone.
          if let s = self.editorSession { self.editorSession = (try? self.bulk.begin(s.action, ids: s.ids)) ?? s }
          let left = r.summary.contains("plan left as it is") ? "plan left as it is" : "changed since"
          self.show(DSToastModel(message: label.map { "Undone: \($0)" } ?? "Undone",
                                 detail: r.skipped.isEmpty ? nil : "\(r.skipped.count) skipped · \(left)",
                                 tone: .neutral, duration: 4))
        case .failure(let e):
          self.show(Self.undoFailure(e.localizedDescription), error: true)
        }
      }
    }
    if confirmGoLive {
      // After every undo already submitted (the runner is serial), then this one with the go-live confirmation.
      let (runner, b) = (undoRunner, bulk)
      Task.detached { runner.wait(); finish(Result { try b.undo(id, confirmGoLive: true) }) }
    } else {
      // UndoRunner is serial: ⌘Z⌘Z restores newest-first even when pressed faster than an undo takes.
      undoRunner.undo(id, done: finish)
    }
  }

  /// ⌘Z (when no text field is focused and the editor is closed): undo the MOST RECENT undoable action of this
  /// session — bulk batch or single action alike (UndoHistory). Again for the one before.
  func undoLast() {
    guard let e = undoHistory.top else { show("Nothing to undo"); return }
    // ⌘Z over an overlay: edits to the clip open behind it stay in the editor's own history.
    if editor != nil, openEditorBatches.contains(e.batchId) { show("Close the editor to undo \(e.label.lowercased())"); return }
    undo(batch: e.batchId)
  }

  /// Sets a clip's Title from a suggestion chip (undoable like any batch).
  func acceptSuggestion(_ videoId: String, _ text: String) {
    let b = bulk
    requestBulk(BulkRequest(title: "Set title?", verb: "Set title", ids: [videoId], doneMessage: "Title set",
                            clearsSelection: false) { dry in
      try b.setTitle([videoId], text, dryRun: dry)
    })
  }

  /// "Ask an agent" / "Copy agent prompt for N clips": the deterministic AgentPrompts template to the pasteboard.
  func copyAgentPrompt(_ ids: [String]) {
    do {
      let md = try AgentPrompts.titles(for: ids, store: store)
      copy(md)
      show(DSToastModel(message: "Agent prompt copied for \(ids.count) clip\(ids.count == 1 ? "" : "s")",
                        detail: "Paste it to your agent; it answers with djq suggest", tone: .success, duration: 5))
    } catch {
      show(error.localizedDescription, error: true)
    }
  }
}
