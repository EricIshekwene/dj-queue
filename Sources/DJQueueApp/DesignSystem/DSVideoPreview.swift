import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Caps how many previews decode at once (DESIGN-v2 §4: ≤4 concurrent players, focused card first) and keeps
/// at most one audible. Views request a slot while visible + active; the top `maxPlayers` by (priority, request
/// order) play, the rest show their poster and take over automatically when a slot frees up.
@MainActor
@Observable
final class DSPlaybackBudget {
  static let shared = DSPlaybackBudget()
  var maxPlayers = 4
  private struct Request: Equatable { let id: UUID; var priority: Int }
  private var requests: [Request] = []
  /// The preview Eric unmuted with its button (sticky until muted or released).
  var audible: UUID?
  /// The preview under the pointer while "Unmute on hover" is on. It wins over `audible`, so exactly one clip
  /// is ever heard; it goes back to muted as soon as the pointer leaves.
  private(set) var hoverAudible: UUID?
  /// Muted with its button while hovered: stays muted until the pointer leaves.
  private(set) var hoverMuted: UUID?

  /// The single preview that plays sound right now.
  var effectiveAudible: UUID? {
    if let h = hoverAudible, h != hoverMuted { return h }
    return audible
  }

  func setHover(_ id: UUID, _ on: Bool) {
    if on {
      hoverAudible = id
    } else {
      if hoverAudible == id { hoverAudible = nil }
      if hoverMuted == id { hoverMuted = nil }
    }
  }

  /// The mute button: mutes whatever of this preview is audible, or unmutes it (sticky).
  func toggleSound(_ id: UUID) {
    if effectiveAudible == id {
      if hoverAudible == id { hoverMuted = id }
      if audible == id { audible = nil }
    } else {
      if hoverMuted == id { hoverMuted = nil }
      if hoverAudible != id { audible = id }
    }
  }

  func request(_ id: UUID, priority: Int = 0) {
    if let i = requests.firstIndex(where: { $0.id == id }) {
      if requests[i].priority != priority { requests[i].priority = priority }
    } else {
      requests.append(Request(id: id, priority: priority))
    }
  }

  func release(_ id: UUID) {
    requests.removeAll { $0.id == id }
    if audible == id { audible = nil }
    setHover(id, false)
  }

  func isGranted(_ id: UUID) -> Bool {
    let ranked = requests.enumerated().sorted { a, b in
      a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
    }
    return ranked.prefix(maxPlayers).contains { $0.element.id == id }
  }

  var activeCount: Int { min(maxPlayers, requests.count) }
}

/// Playback position shared between the player view and the scrubber.
@MainActor
@Observable
final class DSPlaybackProgress {
  var fraction: Double = 0
  @ObservationIgnored weak var view: DSPlayerNSView?
  func seek(_ f: Double) { view?.seek(fraction: f) }
}

/// How a preview says "Updating preview" (S6): a labelled capsule (tiles, Single, dialogs), a small icon (cards),
/// or nothing (tiny list thumbnails).
enum DSPreviewUpdatingStyle: Sendable { case label, icon, none }

/// Evidence runs only (snapshots): draw the text overlay over the poster too, since a still can't show the playing
/// preview's text window. `.environment(\.dsPreviewOverlayOnPoster, true)`.
private struct DSPreviewOverlayOnPosterKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var dsPreviewOverlayOnPoster: Bool {
    get { self[DSPreviewOverlayOnPosterKey.self] }
    set { self[DSPreviewOverlayOnPosterKey.self] = newValue }
  }
}

/// One text over a playing preview: transparent, at the video's aspect, shown while the player time is inside `window`
/// (seconds of the proxy's timeline; nil = the whole time). `key` says it's the same image, so a redraw is never needed.
struct DSTimedOverlay: Equatable {
  var key: String
  var image: CGImage
  var window: ClosedRange<Double>?

  func shows(at t: Double) -> Bool { window.map { t >= $0.lowerBound - 0.01 && t <= $0.upperBound + 0.01 } ?? true }
  static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.window == b.window }
}

/// Muted looping preview of a proxy file with poster fallback (DESIGN-v2 §2.6/§4). Plays only while visible,
/// `isActive` and granted a slot; releases the decoder when scrolled away. The proxy fades in over the poster in
/// 200 ms. Mute toggle on hover. `unmuteOnHover`: while the pointer is over the preview or its card (`isHovered`) it
/// plays with sound — starting playback (with a priority slot) when it wasn't playing — and mutes again on exit;
/// `DSPlaybackBudget` keeps one clip audible at a time. Hover here and in cards comes from `dsPlaybackHover`, so an
/// exit SwiftUI doesn't report still stops the clip. When it stops, the player is released at once.
///
/// S6 (the clip as it will post): `overlays` — the on-video texts — are drawn over the playing proxy, each only while the
/// player time is inside its window (like the editor and the renderer); never over the poster (the cover already has
/// the text when "cover includes text" is on). `isUpdating`: the edit changed and the new proxy isn't ready,
/// so the (new) poster shows with a quiet "Updating preview".
struct DSVideoPreview: View {
  let url: URL?
  var poster: NSImage? = nil
  /// Parent's say: `PreviewPlayback.plays`, file present, etc.
  var isActive = true
  /// Focused card: gets a slot before others.
  var isPriority = false
  /// Loop only this range (trim) instead of the whole file.
  var loopRange: ClosedRange<Double>? = nil
  var unmuteOnHover = false
  /// The parent card is hovered (counts as hovering the preview for sound and playback).
  var isHovered = false
  var showsMuteButton = true
  var muteAlignment: Alignment = .bottomTrailing
  /// Thin scrub bar on hover (Single view).
  var showsScrubber = false
  var cornerRadius: CGFloat = 0
  /// The on-video texts, in stacking order.
  var overlays: [DSTimedOverlay] = []
  var isUpdating = false
  var updatingStyle: DSPreviewUpdatingStyle = .label
  /// The clip has text whose overlay isn't loaded: `onNeedsOverlay` runs when this preview starts playing (so only
  /// the ≤4 playing previews ever re-draw an evicted overlay).
  var needsOverlay = false
  var onNeedsOverlay: (() -> Void)? = nil
  var gravity: AVLayerVideoGravity = .resizeAspectFill

  @State private var id = UUID()
  @State private var visible = false
  @State private var hovering = false
  @State private var ready = false
  @State private var progress = DSPlaybackProgress()
  /// The scrubber is being dragged. A held mouse can leave the preview: the drag keeps the scrubber and the sound
  /// until it ends (a gesture state, so it also clears if the drag is cancelled).
  @GestureState private var scrubbing = false
  /// A new player view after each release, so one that's still fading out never comes back (`released`).
  @State private var playerGeneration = 0
  @Environment(\.dsPreviewOverlayOnPoster) private var overlayOnPoster
  private var budget: DSPlaybackBudget { .shared }

  var body: some View {
    let hoverSound = unmuteOnHover && (hovering || isHovered || scrubbing)
    let wantsPlay = url != nil && visible && (isActive || hoverSound)
    let priority = hoverSound ? 2 : isPriority ? 1 : 0
    let playing = wantsPlay && budget.isGranted(id)
    let audible = playing && budget.effectiveAudible == id
    ZStack {
      posterView
      if playing, let url {
        DSPlayerLayerView(url: url, loopRange: loopRange, muted: !audible, gravity: gravity, overlays: overlays,
                          progress: progress) { r in ready = r }
          .id(playerGeneration)
          .opacity(ready ? 1 : 0)
          .dsAnimation(DS.motion.fade, value: ready)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    // Bottom-leading, above a tile's duration badge and the scrubber: never under the selection circle (top-leading)
    // or the score (top-trailing).
    .overlay(alignment: .bottomLeading) {
      if isUpdating && url == nil && updatingStyle != .none {
        updatingBadge
          .padding(.leading, updatingStyle == .icon ? 4 : 8)
          .padding(.bottom, updatingStyle == .icon ? 4 : 32)
          .transition(.opacity)
      }
    }
    .overlay(alignment: muteAlignment) {
      if showsMuteButton && playing && (hovering || audible) {
        Button {
          budget.toggleSound(id)
        } label: {
          Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.black.opacity(0.63), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .dsTooltip(audible ? "Mute this preview" : "Play this preview's sound", side: .bottom)
        .transition(.opacity)
      }
    }
    .overlay(alignment: .bottom) {
      if showsScrubber && playing && (hovering || scrubbing) { scrubber.padding(.horizontal, 14).padding(.bottom, 12).transition(.opacity) }
    }
    .dsPlaybackHover { hovering = $0 }
    .onAppear { visible = true }
    .onDisappear { visible = false; budget.release(id) }
    .onScrollVisibilityChange(threshold: 0.3) { visible = $0 }
    .onChange(of: wantsPlay, initial: true) { _, w in
      if w {
        budget.request(id, priority: priority)
      } else {
        budget.release(id)
        ready = false
        // At once: a removal inside a hover animation would keep the player (and its sound) until the fade ends.
        progress.view?.release()
        playerGeneration += 1
      }
    }
    .onChange(of: priority) { _, p in if wantsPlay { budget.request(id, priority: p) } }
    .onChange(of: playing && needsOverlay, initial: true) { _, need in if need { onNeedsOverlay?() } }
    .onChange(of: hoverSound, initial: true) { _, h in budget.setHover(id, h) }
    .accessibilityLabel(playing ? (audible ? "Video preview, playing with sound" : "Video preview, playing muted")
                        : isUpdating ? "Video cover, preview updating" : "Video cover")
  }

  /// Quiet, white-on-dark like the duration badge; explains itself on hover.
  private var updatingBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: updatingStyle == .icon ? 8.5 : 9.5, weight: .semibold))
      if updatingStyle == .label { Text("Updating preview").font(DS.type.micro) }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, updatingStyle == .icon ? 0 : 7)
    .frame(width: updatingStyle == .icon ? 18 : nil, height: 18)
    .background(Color.black.opacity(0.63), in: Capsule())
    .fixedSize()
    .dsTooltip("The edit changed — its new preview is being made. The cover already shows the edit.")
    .accessibilityLabel("Updating preview")
  }

  @ViewBuilder private var posterView: some View {
    if let poster {
      Image(nsImage: poster).resizable().aspectRatio(contentMode: gravity == .resizeAspect ? .fit : .fill)
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .overlay {
          if overlayOnPoster {
            ForEach(Array(overlays.enumerated()), id: \.offset) { _, o in
              Image(decorative: o.image, scale: 1).resizable().aspectRatio(contentMode: gravity == .resizeAspect ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
          }
        }
    } else {
      DSPosterPlaceholder()
    }
  }

  private var scrubber: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.3))
        Capsule().fill(Color.white).frame(width: max(4, g.size.width * progress.fraction))
      }
      .frame(height: 4)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .updating($scrubbing) { _, on, _ in on = true }
        .onChanged { v in progress.seek(min(1, max(0, v.location.x / max(1, g.size.width)))) })
    }
    .frame(height: 16)
    .dsTooltip("Drag to scrub through the preview")
    .accessibilityLabel("Playback position")
  }
}

/// Neutral placeholder when there is no cover yet.
struct DSPosterPlaceholder: View {
  var body: some View {
    ZStack {
      DS.color.surfaceSunken
      Image(systemName: "film").font(.system(size: 18, weight: .light)).foregroundStyle(DS.color.textTertiary)
    }
  }
}

/// AVPlayerLayer host. Rebuilds the player only when the URL or loop range changes.
private struct DSPlayerLayerView: NSViewRepresentable {
  let url: URL
  let loopRange: ClosedRange<Double>?
  let muted: Bool
  let gravity: AVLayerVideoGravity
  let overlays: [DSTimedOverlay]
  let progress: DSPlaybackProgress
  let onReady: (Bool) -> Void

  func makeNSView(context: Context) -> DSPlayerNSView {
    let v = DSPlayerNSView()
    v.onReady = onReady
    progress.view = v
    return v
  }

  func updateNSView(_ v: DSPlayerNSView, context: Context) {
    v.onReady = onReady
    v.progress = progress
    progress.view = v
    v.configure(url: url, loopRange: loopRange, muted: muted, gravity: gravity)
    v.setOverlays(overlays, gravity: gravity)
  }

  static func dismantleNSView(_ v: DSPlayerNSView, coordinator: ()) { v.teardown() }
}

final class DSPlayerNSView: NSView {
  private let playerLayer = AVPlayerLayer()
  /// One layer per text, each shown only while the time is inside its window (toggled by `textObs`, no SwiftUI redraws).
  private var overlayLayers: [CALayer] = []
  private var overlays: [DSTimedOverlay] = []
  private var textObs: Any?
  private var player: AVQueuePlayer?
  private var looper: AVPlayerLooper?
  private var key: String?
  private var range: ClosedRange<Double>?
  private var readyObs: NSKeyValueObservation?
  private var timeObs: Any?
  /// Told to stop for good: SwiftUI's last update on a fading view must not build a new player.
  private var released = false
  var onReady: ((Bool) -> Void)?
  weak var progress: DSPlaybackProgress?
  /// A video frame is on screen (evidence runs: the tooltip probe waits for it).
  var isShowingVideo: Bool { playerLayer.isReadyForDisplay }
  /// Evidence runs (DSHoverProbe): what the player is really doing, and how many exist anywhere.
  var isPlayingWithSound: Bool { (player?.rate ?? 0) > 0 && player?.isMuted == false }
  var isPlaying: Bool { (player?.rate ?? 0) > 0 }
  /// Evidence runs: which of this preview's texts are showing right now, and the player time.
  var debugShownTexts: [Bool] { overlayLayers.map { !$0.isHidden } }
  var debugTime: Double { player?.currentTime().seconds ?? .nan }
  @MainActor static var debugLivePlayers = 0
  @MainActor static var debugPlayersBuilt = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer = CALayer()
    layer?.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    for l in overlayLayers { l.frame = bounds }
    CATransaction.commit()
  }

  func configure(url: URL, loopRange: ClosedRange<Double>?, muted: Bool, gravity: AVLayerVideoGravity) {
    guard !released else { return }
    playerLayer.videoGravity = gravity
    let k = "\(url.path)|\(loopRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "")"
    if k != key {
      teardown()
      key = k
      range = loopRange
      let item = AVPlayerItem(url: url)
      let p = AVQueuePlayer()
      p.isMuted = true
      Backstage.silenceForChecks(p)
      p.preventsDisplaySleepDuringVideoPlayback = false
      p.automaticallyWaitsToMinimizeStalling = false
      if let r = loopRange, r.upperBound > r.lowerBound {
        looper = AVPlayerLooper(player: p, templateItem: item,
                                timeRange: CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                                                       end: CMTime(seconds: r.upperBound, preferredTimescale: 600)))
      } else {
        looper = AVPlayerLooper(player: p, templateItem: item)
      }
      player = p
      Self.debugLivePlayers += 1
      Self.debugPlayersBuilt += 1
      playerLayer.player = p
      readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
        let r = l.isReadyForDisplay
        DispatchQueue.main.async { self?.onReady?(r) }
      }
      timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
        MainActor.assumeIsolated { self?.report(t) }
      }
      p.play()
    }
    player?.isMuted = muted
  }

  /// Sets the texts and their windows. Same gravity as the video, so they land on the same pixels. Called on every SwiftUI
  /// update of the preview, so an unchanged list costs a comparison and nothing else.
  func setOverlays(_ list: [DSTimedOverlay], gravity: AVLayerVideoGravity) {
    let contentsGravity: CALayerContentsGravity = gravity == .resizeAspect ? .resizeAspect : gravity == .resize ? .resize : .resizeAspectFill
    if list != overlays || overlayLayers.first?.contentsGravity != contentsGravity {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      while overlayLayers.count > list.count { overlayLayers.removeLast().removeFromSuperlayer() }
      while overlayLayers.count < list.count {
        let l = CALayer()
        l.isHidden = true
        l.frame = bounds
        l.actions = ["hidden": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(l)
        overlayLayers.append(l)
      }
      for (l, o) in zip(overlayLayers, list) {
        l.contents = o.image
        l.contentsGravity = contentsGravity
      }
      overlays = list
      CATransaction.commit()
    }
    if list.isEmpty {
      if let textObs { player?.removeTimeObserver(textObs) }
      textObs = nil
    } else if textObs == nil, let p = player {
      textObs = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
        MainActor.assumeIsolated { self?.updateText(t.seconds) }
      }
      updateText(p.currentTime().seconds)
    }
  }

  @MainActor private func updateText(_ t: Double) {
    guard t.isFinite else {
      for l in overlayLayers where !l.isHidden { l.isHidden = true }
      return
    }
    for (l, o) in zip(overlayLayers, overlays) {
      let on = o.shows(at: t)
      if l.isHidden == on { l.isHidden = !on }
    }
  }

  @MainActor private func report(_ t: CMTime) {
    guard let item = player?.currentItem else { return }
    let start = range?.lowerBound ?? 0
    let end = range?.upperBound ?? item.duration.seconds
    guard end.isFinite, end > start else { return }
    progress?.fraction = min(1, max(0, (t.seconds - start) / (end - start)))
  }

  func seek(fraction: Double) {
    guard let item = player?.currentItem else { return }
    let start = range?.lowerBound ?? 0
    let end = range?.upperBound ?? item.duration.seconds
    guard end.isFinite, end > start else { return }
    player?.seek(to: CMTime(seconds: start + fraction * (end - start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func release() {
    released = true
    teardown()
  }

  func teardown() {
    if let timeObs { player?.removeTimeObserver(timeObs) }
    timeObs = nil
    if let textObs { player?.removeTimeObserver(textObs) }
    textObs = nil
    for l in overlayLayers { l.isHidden = true }
    readyObs = nil
    player?.pause()
    looper?.disableLooping()
    looper = nil
    player?.removeAllItems()
    if player != nil { Self.debugLivePlayers -= 1 }
    player = nil
    playerLayer.player = nil
    key = nil
  }
}
