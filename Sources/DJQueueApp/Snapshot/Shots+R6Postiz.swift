import DJQCore
import SwiftUI

/// Round 6 (prefix r6-): Settings → Publishing in every connection state, the Test run badge, Postiz post status on
/// Today / Posts / Week / the menu bar, and the editor items (cover meaning, YouTube title, long clips).
extension SnapshotShots {
  static func r6postiz(_ c: SnapshotContext) -> [Shot] {
    let pm = c.postiz
    /// Full Postiz state for one shot (shots don't depend on order): DB flags, then a reload.
    func state(_ m: AppModel, hasKey: Bool = true, invalid: String? = nil, pausedFor: TimeInterval? = nil, testRun: Bool = false,
               checked: Bool = true, checkError: String? = nil) {
      let s = m.store
      try? s.clearPostizKeyInvalid()
      if let invalid { _ = try? s.setPostizKeyInvalid(invalid) }
      try? s.setKV(PostizBudget.kvKey, PostizBudget())
      if let pausedFor { try? s.pausePostiz(for: pausedFor) }
      if var st = try? s.settings(), st.publishing.testMode != testRun {
        st.publishing.testMode = testRun
        try? s.save(st)
      }
      m.postiz.hasKey = hasKey
      m.postiz.checkedAt = checked ? m.now.addingTimeInterval(-4 * 60) : nil
      m.postiz.checkError = checkError
      m.postiz.checking = false
      m.refreshNow()
    }
    func open(_ m: AppModel, expanded: Set<Platform> = [], replacing: Bool = false) {
      SettingsUIState.shared.reset()
      SettingsUIState.shared.publishingExpanded = expanded
      SettingsUIState.shared.publishingReplacingKey = replacing
      m.screen = .today
      m.settingsSection = .publishing
      m.showSettings = true
    }
    /// The whole pane, unscrolled (the modal only shows its top).
    func pane(_ name: String, _ m: AppModel, expanded: Set<Platform> = [], setup: @escaping () -> Void) -> Shot {
      c.view(name, width: 600) {
        setup()
        SettingsUIState.shared.reset()
        SettingsUIState.shared.publishingExpanded = expanded
        return AnyView(VStack(alignment: .leading, spacing: 0) { PublishingSection(model: m) }
          .padding(.horizontal, DS.space.xl).padding(.bottom, DS.space.xl))
      }
    }
    return [
      // U1: Settings → Publishing
      c.main("r6-publishing-not-set-up") { m in
        state(m, hasKey: false, checked: false)
        open(m)
      },
      c.main("r6-publishing-connected", pm) { m in
        state(m)
        open(m)
      },
      c.main("r6-publishing-key-invalid", pm) { m in
        state(m, invalid: "Postiz refused the API key")
        open(m)
      },
      c.main("r6-publishing-rate-limited", pm) { m in
        state(m, pausedFor: 4 * 3600 + 30 * 60)
        open(m)
      },
      c.main("r6-publishing-replace-key", pm) { m in
        state(m, checkError: "Can't reach Postiz: The Internet connection appears to be offline.")
        open(m, replacing: true)
      },
      pane("r6-publishing-pane-connected", pm, expanded: [.tiktok, .youtube]) { state(pm) },
      pane("r6-publishing-pane-test-run", pm, expanded: [.instagram, .x, .threads]) { state(pm, testRun: true) },
      pane("r6-publishing-pane-not-set-up", c.model) { state(c.model, hasKey: false, checked: false) },
      c.view("r6-platforms-pane-limits", width: 600) {
        state(pm)
        return AnyView(VStack(alignment: .leading, spacing: 0) { PlatformsSettings(model: pm) }
          .padding(.horizontal, DS.space.xl).padding(.bottom, DS.space.xl))
      },
      c.main("r6-sidebar-test-run", pm) { m in
        state(m, testRun: true)
        m.screen = .queue
      },
      c.main("r6-sidebar-test-run-compact", pm) { m in
        state(m, testRun: true)
        m.screen = .queue
        m.sidebarCollapsed = true
      },
    ]
  }
}
