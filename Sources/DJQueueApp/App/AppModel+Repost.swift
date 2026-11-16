import DJQCore
import SwiftUI

/// Round 37/38 (DECISIONS-R37.md, R38): Mark repostable ×N / not repostable, the clip-wide repost setting. One place for
/// every surface (Queue, Edit, Library, Calendar, ⌘K); each asks first and has Undo, like the other bulk actions. A
/// version's own Posts is its override and stays either way.
extension AppModel {
  func isRepostable(_ id: String) -> Bool { repostable.contains(id) }

  /// Asks, then marks the short clips in `ids` repostable ×`count` (every version posts that many times) or not (nil).
  func markRepostable(_ ids: [String], count: Int?) {
    let shorts = ids.filter { video($0)?.type == .short }
    guard !shorts.isEmpty else { show("Long-form is never reposted", error: true); return }
    let n = AppModel.pipelineClips(shorts.count)
    pipelineBulk(count.map { "Mark \(n) repostable ×\($0)?" } ?? "Mark \(n) not repostable?",
                 verb: count.map { "Repostable ×\($0)" } ?? "Not repostable", ids: shorts,
                 changes: [.init(field: "Posts", value: count.map { "Every version \($0) times, spaced out. A version's own Posts stays." }
                                                     ?? "Every version once. A version's own Posts stays; reposts already planned come off.")],
                 done: count.map { "Marked repostable ×\($0)" } ?? "Marked not repostable") { b, dry in
      try b.setRepostable(shorts, count: count, dryRun: dry)
    }
  }
}

/// "Mark repostable ▸ ×2 ×3 ×4 ×5" and "Mark not repostable" for a menu (native items: no tooltip, so titles say it). The
/// count a single clip has is checked.
struct RepostMenuItems: View {
  @Bindable var model: AppModel
  let targets: [String]

  var body: some View {
    let shorts = targets.filter { model.video($0)?.type == .short }
    if !shorts.isEmpty {
      let n = shorts.count == 1 ? "" : " \(shorts.count)"
      let counts = Set(shorts.map { model.repostCounts[$0] })
      let current = counts.count == 1 ? counts.first! : nil
      Menu("Mark\(n) repostable") {
        ForEach(RepostSwitch.menuCounts, id: \.self) { c in
          Button { model.markRepostable(shorts, count: c) } label: {
            if current == c { Label("×\(c): every version posts \(c) times", systemImage: "checkmark") }
            else { Text("×\(c): every version posts \(c) times") }
          }
        }
      }
      if counts.contains(where: { $0 != nil }) {
        Button("Mark\(n) not repostable", systemImage: "1.circle") { model.markRepostable(shorts, count: nil) }
      }
    }
  }
}
