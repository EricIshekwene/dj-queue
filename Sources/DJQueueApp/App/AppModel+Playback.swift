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
  ///
  /// S6: a proxy that lands after the clip's preview changed (`previewChanged` bumped its generation) is dropped
  /// and asked for again, so an older crop/trim never plays. `keepOthersVisible`: re-requests (from
  /// `previewChanged`) don't demote the screen's other visible clips.
  func requestProxies(_ visibleIds: [String], prefetch: [String] = [], keepOthersVisible: Bool = false) {
    let range = playback.loop
    func eligible(_ ids: [String]) -> [String] { ids.filter { id in videoById[id].map { $0.type == .short && !$0.missing } ?? false } }
    let now = eligible(visibleIds), later = eligible(prefetch).filter { !now.contains($0) }
    for id in now {
      if let i = recentProxyIds.firstIndex(of: id) { recentProxyIds.remove(at: i) }
      recentProxyIds.append(id)
    }
    if recentProxyIds.count > 48 { recentProxyIds.removeFirst(recentProxyIds.count - 48) }
    let wanted = (now + later).filter { proxyURLs[$0] == nil }
    if frozen {
      for id in wanted { if let u = proxies.cachedProxy(videoId: id, range: range) { proxyURLs[id] = u } }
      return
    }
    let fresh = wanted.filter { !proxyPending.contains($0) }
    proxyPending.formUnion(fresh)
    let gens = Dictionary(uniqueKeysWithValues: fresh.map { ($0, ThumbStamps.shared.gen($0)) })
    let svc = proxies
    let all = now + later
    let background = Set(later)
    let land: @Sendable (String, Result<URL, Error>) -> Void = { id, result in
      Task { @MainActor in
        guard ThumbStamps.shared.gen(id) == gens[id] else { return }  // the preview changed meanwhile: a newer request owns it
        self.proxyPending.remove(id)
        guard self.playback.loop == range else { return }
        if case .success(let url) = result { self.proxyURLs[id] = url }
        self.previewUpdating.remove(id)
      }
    }
    Task.detached(priority: .utility) {
      if !keepOthersVisible { svc.setVisible(all, range: range) }
      for id in fresh {
        // Already made (e.g. a text-only change keeps the crop/trim): no wait behind other encodes.
        if let u = svc.cachedProxy(videoId: id, range: range) { land(id, .success(u)); continue }
        svc.request(id, priority: background.contains(id) ? .background : .visible, range: range) { result in land(id, result) }
      }
    }
  }
}
