import DJQCore
import Foundation
import SwiftUI

/// View modes (#12), playback preferences and preview proxies.
extension AppModel {
  // MARK: View modes

  /// The remembered view mode of a screen (UserDefaults `djq.viewMode.<screen>`), else `Screen.defaultViewMode`.
  func viewMode(_ s: Screen) -> DSViewMode { viewModes[s] ?? s.defaultViewMode }

  func setViewMode(_ m: DSViewMode, for s: Screen) {
    viewModes[s] = m
    if !Self.isSnapshotRun { UserDefaults.standard.set(m.rawValue, forKey: "djq.viewMode.\(s.rawValue)") }
  }

  /// For `DSViewModeSwitcher(mode: model.viewModeBinding(.edit), modes: […])`.
  func viewModeBinding(_ s: Screen) -> Binding<DSViewMode> {
    Binding(get: { self.viewMode(s) }, set: { self.setViewMode($0, for: s) })
  }

  // MARK: Playback

  /// Changes and persists the playback preferences (UserDefaults `djq.playback`). A new loop range drops the
  /// known proxy URLs so tiles re-request the matching proxy.
  func setPlayback(_ change: (inout PlaybackPrefs) -> Void) {
    var p = playback
    change(&p)
    guard p != playback else { return }
    let rangeChanged = p.loop != playback.loop
    playback = p
    if rangeChanged {
      proxyURLs = [:]
      proxyPending = []
    }
    if !Self.isSnapshotRun, let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "djq.playback") }
  }

  /// `playback` as a binding for a setting control, e.g. `model.playbackBinding(\.autoplay)`.
  func playbackBinding<T>(_ kp: WritableKeyPath<PlaybackPrefs, T>) -> Binding<T> {
    Binding(get: { self.playback[keyPath: kp] }, set: { v in self.setPlayback { $0[keyPath: kp] = v } })
  }

  func loadPersistedPrefs() {
    for s in Screen.allCases {
      if let raw = UserDefaults.standard.string(forKey: "djq.viewMode.\(s.rawValue)"), let m = DSViewMode(rawValue: raw) { viewModes[s] = m }
    }
    if let d = UserDefaults.standard.data(forKey: "djq.playback"), let p = try? JSONDecoder().decode(PlaybackPrefs.self, from: d) {
      playback = p
    }
  }

  // MARK: Proxies

  /// Asks for preview proxies of the clips now on screen (most important first). Cached proxies land in
  /// `proxyURLs` at once; missing ones are generated in the background by `proxies` (visible first) and land when
  /// done. Snapshot mode only looks up cached files and never generates. Cheap to call repeatedly.
  func requestProxies(_ visibleIds: [String], prefetch: [String] = []) {
    let range = playback.loop
    func eligible(_ ids: [String]) -> [String] { ids.filter { id in videoById[id].map { $0.type == .short && !$0.missing } ?? false } }
    let now = eligible(visibleIds), later = eligible(prefetch).filter { !now.contains($0) }
    let wanted = (now + later).filter { proxyURLs[$0] == nil }
    if frozen {
      for id in wanted { if let u = proxies.cachedProxy(videoId: id, range: range) { proxyURLs[id] = u } }
      return
    }
    let fresh = wanted.filter { !proxyPending.contains($0) }
    proxyPending.formUnion(fresh)
    let svc = proxies
    let all = now + later
    let background = Set(later)
    Task.detached(priority: .utility) {
      svc.setVisible(all, range: range)
      for id in fresh {
        svc.request(id, priority: background.contains(id) ? .background : .visible, range: range) { result in
          Task { @MainActor in
            self.proxyPending.remove(id)
            if case .success(let url) = result, self.playback.loop == range { self.proxyURLs[id] = url }
          }
        }
      }
    }
  }

}
