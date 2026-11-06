import DJQCore
import SwiftUI

/// What a click did (see `AppModel.select`).
enum SelectResult {
  /// ⇧ / ⌘ click: the selection changed.
  case handled
  /// Plain click: nothing changed; the caller decides (open the clip, or toggle it while something is selected).
  case plainClick
}

/// Per-screen multi-select (#11): checkbox toggles, ⇧-click range from the anchor, ⌘-click toggle, ⌘A selects
/// every item the screen shows (`visibleIds[screen]`, registered by ClipCollection or by the screen itself),
/// Esc clears. Selection survives screen switches. Ids a list stops showing are dropped when it registers them, and ids that
/// left the screen's stage are dropped on every refresh (`pruneSelection`), even when no list is left on screen to do it. A bulk
/// edit that takes clips out of a filter keeps them selected; a search or filter changed afterwards drops hidden clips as usual.
extension AppModel {
  func selected(_ s: Screen) -> Set<String> { selection[s] ?? [] }

  /// Every clip a screen holds, filters aside. Nil = the screen has no clip stage.
  func stageIds(_ s: Screen) -> Set<String>? {
    switch s {
    case .score: Set(scoreList.map(\.id))
    case .edit: Set(editList.map(\.id))
    case .queue: Set(queueClips.map(\.id))
    case .library: Set(libraryAll.map(\.id))
    default: nil
    }
  }

  /// Drops selected clips that left their screen. The lists can't do this once they've gone from the screen (an empty state).
  func pruneSelection() {
    for s in Array(selection.keys) {
      guard let sel = selection[s], !sel.isEmpty, let all = stageIds(s), !sel.isSubset(of: all) else { continue }
      selection[s] = sel.intersection(all)
    }
  }

  /// What a list keeps selected when it shows `shown`: those, and the clips a bulk edit just touched.
  func keptSelection(_ s: Screen, shown: [String]) -> Set<String> {
    guard let edited = bulkEdited[s], edited.until > Date() else { return Set(shown) }
    return Set(shown).union(edited.ids).intersection(stageIds(s) ?? Set(shown))
  }

  /// Selected clips no list shows right now (a bulk edit took them out of a filter).
  func hiddenSelected(_ s: Screen) -> Int {
    guard let shown = visibleIds[s], !shown.isEmpty else { return 0 }
    return selected(s).subtracting(shown).count
  }
  func isSelected(_ id: String, in s: Screen) -> Bool { selection[s]?.contains(id) ?? false }
  /// Selected ids in display order (`visibleIds[s]` order; unknown ids last).
  func selectedIds(_ s: Screen) -> [String] {
    let sel = selected(s)
    guard !sel.isEmpty else { return [] }
    let order = visibleIds[s] ?? []
    let known = order.filter { sel.contains($0) }
    return known + sel.subtracting(known).sorted()
  }

  /// Handles a card click with its modifiers. `ordered` = the ids as displayed (for ⇧ ranges).
  /// ⌘ toggles the id; ⇧ selects the range anchor…id (adds to the selection); plain → `.plainClick`, unchanged.
  @discardableResult
  func select(_ id: String, modifiers: EventModifiers, ordered: [String], screen s: Screen) -> SelectResult {
    if modifiers.contains(.shift), let anchor = selectionAnchor[s], let a = ordered.firstIndex(of: anchor),
       let b = ordered.firstIndex(of: id) {
      selection[s, default: []].formUnion(ordered[min(a, b)...max(a, b)])
      return .handled
    }
    if modifiers.contains(.shift) || modifiers.contains(.command) {
      toggleSelection(id, screen: s)
      return .handled
    }
    return .plainClick
  }

  /// Checkbox / ⌘-click: add or remove one id and make it the range anchor.
  func toggleSelection(_ id: String, screen s: Screen) {
    if selection[s, default: []].contains(id) { selection[s]?.remove(id) } else { selection[s, default: []].insert(id) }
    selectionAnchor[s] = id
  }

  /// Replace the selection with exactly these ids.
  func setSelection(_ ids: some Sequence<String>, screen s: Screen) {
    selection[s] = Set(ids)
    selectionAnchor[s] = nil
    bulkEdited[s] = nil
  }

  /// ⌘A / "Select all": every id the screen shows (or the given ids).
  func selectAll(_ s: Screen, ids: [String]? = nil) {
    selection[s] = Set(ids ?? visibleIds[s] ?? [])
    bulkEdited[s] = nil
  }

  func clearSelection(_ s: Screen) {
    selection[s] = []
    selectionAnchor[s] = nil
    bulkEdited[s] = nil
  }

  /// The one selected clip on the current screen (⌘E, ⌘K clip commands).
  var focusedVideo: Video? {
    let ids = selectedVideoIds
    return ids.count == 1 ? video(ids[0]) : nil
  }
}
