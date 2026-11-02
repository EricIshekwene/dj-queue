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
/// Esc clears. Selection survives screen switches; ids that disappear from a list are dropped on refresh by the
/// screens' own filtering (`selectedIds` only returns ids the screen still shows when it registered them).
extension AppModel {
  func selected(_ s: Screen) -> Set<String> { selection[s] ?? [] }
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
  }

  /// ⌘A / "Select all": every id the screen shows (or the given ids).
  func selectAll(_ s: Screen, ids: [String]? = nil) {
    selection[s] = Set(ids ?? visibleIds[s] ?? [])
  }

  func clearSelection(_ s: Screen) {
    selection[s] = []
    selectionAnchor[s] = nil
  }

  /// The one selected clip on the current screen (⌘E, ⌘K clip commands).
  var focusedVideo: Video? {
    let ids = selectedVideoIds
    return ids.count == 1 ? video(ids[0]) : nil
  }
}
