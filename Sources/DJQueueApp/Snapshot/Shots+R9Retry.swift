import DJQCore
import SwiftUI

/// Round 9 (prefix r9-): a failed post with its automatic retry coming, on every screen that shows it: Today, Posts,
/// Week, the inspector and the menu bar. Nothing here is a Problem, so none of them shows a red badge for it.
extension SnapshotShots {
  static func r9retry(_ c: SnapshotContext) -> [Shot] {
    let pm = c.postiz
    func show(_ m: AppModel) {
      if var st = try? m.store.settings(), st.publishing.testMode {
        st.publishing.testMode = false
        try? m.store.save(st)
      }
      m.postiz.hasKey = true
      m.postiz.checkedAt = m.now.addingTimeInterval(-240)
      m.refreshNow()
    }
    func scheduled(_ m: AppModel, select: (PlatformPost) -> Bool) {
      show(m)
      BrowseUI.shared.reset()
      ListPrefs.shared.setStatus(.posts, PostsTab.scheduled.rawValue)
      let retrying = m.posts.filter { m.postizState($0)?.isRetrying == true }
      PostsCardState.shared.expanded = Set(PostGrouping.group(retrying, day: { m.dm.key($0) }).map(\.id))
      m.postsSelection = m.posts.first(where: select)?.id
      m.screen = .posts
    }
    return [
      c.main("r9-today", pm) { m in
        show(m)
        m.screen = .today
      },
      c.main("r9-posts-scheduled", pm) { m in
        scheduled(m) { _ in false }
      },
      c.main("r9-posts-inspector-attempt", pm) { m in
        scheduled(m) { $0.kind == .retry && $0.platform == .tiktok }
      },
      c.main("r9-posts-inspector-waiting", pm) { m in
        scheduled(m) { $0.state == .failed && $0.platform == .threads && $0.resolution == nil }
      },
      c.main("r9-posts-problems", pm) { m in
        show(m)
        BrowseUI.shared.reset()
        PostsCardState.shared.expanded = []
        ListPrefs.shared.setStatus(.posts, PostsTab.problems.rawValue)
        m.postsSelection = nil
        m.screen = .posts
      },
      c.main("r9-week", pm) { m in
        show(m)
        m.screen = .week
      },
      c.view("r9-menubar", width: 320) {
        show(pm)
        return AnyView(MenuBarContent(model: pm, state: MenuBarState(model: pm)))
      },
    ]
  }
}
