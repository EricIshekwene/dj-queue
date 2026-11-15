import DJQCore
import SwiftUI

/// Round 37 (DECISIONS-R37.md): Mark repostable / not repostable, the clip-wide repost action. One place for every
/// surface (Queue, Edit, Library, Calendar, ⌘K); each asks first and has Undo, like the other bulk actions.
extension AppModel {
  func isRepostable(_ id: String) -> Bool { repostable.contains(id) }

  /// Asks, then marks the short clips in `ids` repostable (each version posts `postsPerVersion` times) or not (once).
  func markRepostable(_ ids: [String], _ on: Bool) {
    let shorts = ids.filter { video($0)?.type == .short }
    guard !shorts.isEmpty else { show("Long-form is never reposted", error: true); return }
    if on, settings.postsPerVersion <= 1 {
      show("Posts per version is 1 (Settings › Schedule): set it to 2 or more, or set a version's Posts", error: true)
      return
    }
    let n = AppModel.pipelineClips(shorts.count)
    let times = EditorPostCountRow.times(max(1, settings.postsPerVersion)).lowercased()
    pipelineBulk(on ? "Mark \(n) repostable?" : "Mark \(n) not repostable?", verb: on ? "Mark repostable" : "Not repostable",
                 ids: shorts,
                 changes: [.init(field: "Posts", value: on ? "Each version \(times), spaced out. A version's own Posts stays."
                                                     : "Each version once. Reposts already planned come off.")],
                 done: on ? "Marked repostable" : "Marked not repostable") { b, dry in
      try b.setRepostable(shorts, on, dryRun: dry)
    }
  }
}

/// "Mark repostable" / "Mark not repostable" for a menu (native items: no tooltip, so the title says it). One clip shows
/// the one that changes it; several show both.
struct RepostMenuItems: View {
  @Bindable var model: AppModel
  let targets: [String]

  var body: some View {
    let shorts = targets.filter { model.video($0)?.type == .short }
    if !shorts.isEmpty {
      let n = shorts.count == 1 ? "" : " \(shorts.count)"
      let all = shorts.allSatisfy(model.isRepostable), none = !shorts.contains(where: model.isRepostable)
      if !all {
        // Native items show no tooltip: a disabled one says why in its title.
        let why = model.settings.postsPerVersion <= 1 ? " — Posts per version is 1 in Settings" : ""
        Button("Mark\(n) repostable" + why, systemImage: "arrow.2.squarepath") { model.markRepostable(shorts, true) }
          .disabled(!why.isEmpty)
      }
      if !none { Button("Mark\(n) not repostable", systemImage: "1.circle") { model.markRepostable(shorts, false) } }
    }
  }
}
