import DJQCore
import SwiftUI

/// Round 3 fixes (prefix posts-/sidebar-/grid-): Posts grouped into one card per clip and day (collapsed, one open,
/// Problems), the paused card on Posts only and the sidebar posting status as the control, grid hover playback.
extension SnapshotShots {
  static func r3posts(_ c: SnapshotContext) -> [Shot] {
    let ui = BrowseUI.shared
    let cards = PostsCardState.shared
    func posts(_ m: AppModel, _ tab: PostsTab) {
      ui.reset()
      cards.expanded = []
      cards.fineShown = []
      m.postsSelection = nil
      m.update { $0.paused = false }; m.toast = nil  // setup, not an action shown in the shot
      ListPrefs.shared.setStatus(.posts, tab == .all ? nil : tab.rawValue)
      m.screen = .posts
    }
    /// The first scheduled card with several platforms (the one shown open).
    func firstGroup(_ m: AppModel) -> String? {
      let list = m.posts.filter { !$0.state.isTerminal && $0.state != .overdue }.sorted { $0.scheduledAt < $1.scheduledAt }
      return PostGrouping.group(list, day: { m.dm.key($0) }).first { $0.posts.count > 1 }?.id
    }
    return [
      c.main("posts-scheduled-collapsed") { m in posts(m, .scheduled) },
      c.main("posts-scheduled-expanded") { m in
        posts(m, .scheduled)
        if let id = firstGroup(m) { cards.expanded = [id] }
      },
      c.main("posts-all") { m in posts(m, .all) },
      c.main("posts-paused-banner") { m in
        posts(m, .scheduled)
        m.update { $0.paused = true }; m.toast = nil  // setup, not an action shown in the shot
      },
      c.main("sidebar-paused-edit-no-banner") { m in
        m.update { $0.paused = true }; m.toast = nil  // setup, not an action shown in the shot
        m.screen = .edit
      },
      c.view("sidebar-status-menu-paused", width: 300) {
        c.model.update { $0.paused = true }
        return AnyView(VStack(alignment: .leading, spacing: DS.space.sm) {
          EngineLine(model: c.model)
          EngineMenu(model: c.model) {}
            .padding(DS.space.xxs)
            .dsFloatingSurface(radius: DS.radius.md)
          EngineLine(model: c.model)
            .environment(\.dsForcedState, .hover)
        }
        .padding(DS.space.md))
      },
      c.view("grid-edit-hover", width: 760) {
        let m = c.model
        m.update { $0.paused = false }; m.toast = nil  // setup, not an action shown in the shot
        let vids = Array((m.editList.isEmpty ? m.queueClips : m.editList).prefix(4))
        m.requestProxies(vids.map(\.id))
        return AnyView(HStack(alignment: .top, spacing: DS.space.md) {
          ForEach(Array(vids.enumerated()), id: \.element.id) { i, v in
            DSClipCard(m.dsClip(v, for: .edit), mode: .grid, config: gridConfig(m, hovered: i == 1), onToggleSelect: {},
                       onTap: { _ in })
              .frame(width: 170)
              .environment(\.dsForcedState, i == 1 ? .hover : nil)
          }
        }
        .padding(DS.space.lg))
      },
      // Last: it adds two problems to the throwaway snapshot copy (a failed upload + a copyright block on one card).
      c.main("posts-problems") { m in
        if m.problems.isEmpty, let g = firstGroup(m).flatMap({ id in
          PostGrouping.group(m.posts.filter { !$0.state.isTerminal }, day: { m.dm.key($0) }).first { $0.id == id }
        }), g.posts.count >= 3 {
          let a = PostActions(store: c.store)
          try? a.reportProblem(postId: g.posts[0].id, type: .uploadFailed, message: "Upload stalled at 80% — the app timed out.")
          try? a.reportProblem(postId: g.posts[1].id, type: .copyrightBlocked, message: "Blocked: matched third-party audio.")
          m.refreshNow()
        }
        posts(m, .problems)
      },
    ]
  }

  @MainActor static func gridConfig(_ m: AppModel, hovered: Bool) -> DSClipCardConfig {
    var cfg = DSClipCardConfig()
    cfg.autoplay = PreviewPlayback.plays(m.playback, layout: .grid, hovered: hovered, focused: false)
    cfg.unmuteOnHover = m.playback.hoverSound
    return cfg
  }
}
