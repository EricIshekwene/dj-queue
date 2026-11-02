import AppKit
import DJQCore
import SwiftUI

/// A bulk action as a screen describes it. `run(true)` must be a dry run (`BulkActions` `dryRun: true`),
/// `run(false)` applies it. Both run OFF the main thread, so capture `model.bulk` (Sendable) and plain values,
/// never views:
///
/// ```swift
/// let bulk = model.bulk, ids = model.selectedIds(.edit)
/// model.requestBulk(BulkRequest(title: "Make \(ids.count) clips ready?", verb: "Make ready", ids: ids,
///                               changes: [.init(field: "Crop", value: "Default anchor"), …]) { dry in
///   try bulk.makeReadyWithDefaults(ids, dryRun: dry)
/// })
/// ```
struct BulkRequest {
  /// Sheet title, e.g. "Make 9 clips ready?".
  var title: String
  /// Primary button label, e.g. "Make ready".
  var verb: String
  var ids: [String]
  /// "What will change" rows (DSChangeList), e.g. Caption → Template "DJ set".
  var changes: [DSChangeList.Change] = []
  /// Toast after applying; nil = "Updated N clips" (make-ready: its outlook, "Made 3 ready · 58 still need a title").
  var doneMessage: String? = nil
  /// Clear the screen's selection once the batch changed something (the bulk bar hides, the toast is unobstructed).
  var clearsSelection = true
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
    if r.ids.count == 1 {
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
          if let b = res.batchId { self.lastBatchId = b }
          let n = res.changed.count
          if n == 0 {
            self.show(DSToastModel(message: "Nothing changed",
                                   detail: res.outlook.map { "\($0.summary)" } ?? res.skipped.values.sorted().first, duration: 4))
            return
          }
          if r.clearsSelection { self.clearSelection(screen) }
          let msg = r.doneMessage ?? res.outlook.map { Self.outlookMessage($0, changed: n) } ?? "Updated \(n) clip\(n == 1 ? "" : "s")"
          let skipped = res.skipped.count
          let allReady = res.outlook.map { $0.needTitle.isEmpty && $0.other.isEmpty } ?? true
          self.show(DSToastModel(message: msg, detail: skipped > 0 ? "\(skipped) skipped" : nil, tone: allReady ? .success : .neutral,
                                 actionTitle: res.batchId == nil ? nil : "Undo",
                                 action: res.batchId.map { b in { self.undo(batch: b) } }, duration: 6))
        }
      }
    }
  }

  /// Make-ready's true result: "Made 3 ready · 58 still need a title" (none ready: "Crop confirmed for 3 · …").
  static func outlookMessage(_ o: ReadyOutlook, changed: Int) -> String {
    var parts = [o.ready.isEmpty ? "Crop confirmed for \(pipelineClips(changed))" : "Made \(o.ready.count) ready"]
    if !o.needTitle.isEmpty { parts.append("\(o.needTitle.count) still need\(o.needTitle.count == 1 ? "s" : "") a title") }
    if !o.other.isEmpty { parts.append("\(o.other.count) with other issues") }
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

  /// Undoes one batch (toast "Undone", or why not). Clips changed again since are skipped by BulkActions.
  func undo(batch id: String) {
    let b = bulk
    Task.detached(priority: .userInitiated) {
      let out: Result<BulkResult, Error> = Result { try b.undo(id) }
      await MainActor.run {
        if self.lastBatchId == id { self.lastBatchId = nil }
        self.refresh()
        switch out {
        case .success(let r):
          self.show(DSToastModel(message: "Undone", detail: r.skipped.isEmpty ? nil : "\(r.skipped.count) skipped · changed since",
                                 tone: .neutral, duration: 4))
        case .failure(let e):
          self.show("Couldn't undo: \(e.localizedDescription)", error: true)
        }
      }
    }
  }

  /// ⌘Z (when no text field is focused): undo the last batch applied in this session.
  func undoLast() {
    guard let id = lastBatchId else { show("Nothing to undo"); return }
    undo(batch: id)
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
