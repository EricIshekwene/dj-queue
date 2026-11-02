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
  /// Toast after applying; nil = "Updated N clips".
  var doneMessage: String? = nil
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
    let p = PendingBulk(request: r)
    pendingBulk = p
    let run = r.run
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

  /// Confirmation sheet → primary button.
  func confirmPendingBulk() {
    guard let p = pendingBulk, !p.applying else { return }
    pendingBulk?.applying = true
    apply(p.request) { [weak self] in self?.pendingBulk = nil }
  }

  func cancelPendingBulk() { pendingBulk = nil }

  private func apply(_ r: BulkRequest, then: (() -> Void)? = nil) {
    let run = r.run
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
            self.show(DSToastModel(message: "Nothing changed", detail: res.skipped.values.sorted().first, duration: 4))
            return
          }
          let msg = r.doneMessage ?? "Updated \(n) clip\(n == 1 ? "" : "s")"
          let skipped = res.skipped.count
          self.show(DSToastModel(message: msg, detail: skipped > 0 ? "\(skipped) skipped" : nil, tone: .success,
                                 actionTitle: res.batchId == nil ? nil : "Undo",
                                 action: res.batchId.map { b in { self.undo(batch: b) } }, duration: 6))
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
    requestBulk(BulkRequest(title: "Set title?", verb: "Set title", ids: [videoId], doneMessage: "Title set") { dry in
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
