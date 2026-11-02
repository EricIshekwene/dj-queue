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
  /// The one preview allowed to play sound. Never auto-unmuted.
  var audible: UUID?

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

/// Muted looping preview of a proxy file with poster fallback (DESIGN-v2 §2.6/§4). Plays only while visible,
/// `isActive` and granted a slot; releases the decoder when scrolled away. The proxy fades in over the poster in
/// 200 ms. Mute toggle on hover; `unmuteOnHover` plays sound only while the pointer is over it.
struct DSVideoPreview: View {
  let url: URL?
  var poster: NSImage? = nil
  /// Parent's say: autoplay setting on, focus-only rules, file present, etc.
  var isActive = true
  /// Focused card: gets a slot before others.
  var isPriority = false
  /// Loop only this range (trim) instead of the whole file.
  var loopRange: ClosedRange<Double>? = nil
  var unmuteOnHover = false
  var showsMuteButton = true
  var muteAlignment: Alignment = .bottomTrailing
  /// Thin scrub bar on hover (Single view).
  var showsScrubber = false
  var cornerRadius: CGFloat = 0
  var gravity: AVLayerVideoGravity = .resizeAspectFill

  @State private var id = UUID()
  @State private var visible = false
  @State private var hovering = false
  @State private var ready = false
  @State private var progress = DSPlaybackProgress()
  private var budget: DSPlaybackBudget { .shared }

  var body: some View {
    let wantsPlay = url != nil && isActive && visible
    let playing = wantsPlay && budget.isGranted(id)
    let audible = budget.audible == id || (unmuteOnHover && hovering && playing)
    ZStack {
      posterView
      if playing, let url {
        DSPlayerLayerView(url: url, loopRange: loopRange, muted: !audible, gravity: gravity, progress: progress) { r in ready = r }
          .opacity(ready ? 1 : 0)
          .animation(DS.motion.fade, value: ready)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(alignment: muteAlignment) {
      if showsMuteButton && playing && (hovering || budget.audible == id) {
        Button {
          budget.audible = budget.audible == id ? nil : id
        } label: {
          Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.black.opacity(0.63), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .dsTooltip(audible ? "Mute" : "Unmute", edge: .bottom)
        .transition(.opacity)
      }
    }
    .overlay(alignment: .bottom) {
      if showsScrubber && playing && hovering { scrubber.padding(.horizontal, 14).padding(.bottom, 12).transition(.opacity) }
    }
    .onHover { hovering = $0 }
    .onAppear { visible = true }
    .onDisappear { visible = false; budget.release(id) }
    .onScrollVisibilityChange(threshold: 0.3) { visible = $0 }
    .onChange(of: wantsPlay, initial: true) { _, w in
      if w { budget.request(id, priority: isPriority ? 1 : 0) } else { budget.release(id); ready = false }
    }
    .onChange(of: isPriority) { _, p in if wantsPlay { budget.request(id, priority: p ? 1 : 0) } }
    .accessibilityLabel(playing ? "Video preview, playing muted" : "Video cover")
  }

  @ViewBuilder private var posterView: some View {
    if let poster {
      Image(nsImage: poster).resizable().aspectRatio(contentMode: gravity == .resizeAspect ? .fit : .fill)
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
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
      .gesture(DragGesture(minimumDistance: 0).onChanged { v in progress.seek(min(1, max(0, v.location.x / max(1, g.size.width)))) })
    }
    .frame(height: 16)
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
  }

  static func dismantleNSView(_ v: DSPlayerNSView, coordinator: ()) { v.teardown() }
}

final class DSPlayerNSView: NSView {
  private let playerLayer = AVPlayerLayer()
  private var player: AVQueuePlayer?
  private var looper: AVPlayerLooper?
  private var key: String?
  private var range: ClosedRange<Double>?
  private var readyObs: NSKeyValueObservation?
  private var timeObs: Any?
  var onReady: ((Bool) -> Void)?
  weak var progress: DSPlaybackProgress?

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
    CATransaction.commit()
  }

  func configure(url: URL, loopRange: ClosedRange<Double>?, muted: Bool, gravity: AVLayerVideoGravity) {
    playerLayer.videoGravity = gravity
    let k = "\(url.path)|\(loopRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "")"
    if k != key {
      teardown()
      key = k
      range = loopRange
      let item = AVPlayerItem(url: url)
      let p = AVQueuePlayer()
      p.isMuted = true
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

  func teardown() {
    if let timeObs { player?.removeTimeObserver(timeObs) }
    timeObs = nil
    readyObs = nil
    player?.pause()
    looper?.disableLooping()
    looper = nil
    player?.removeAllItems()
    player = nil
    playerLayer.player = nil
    key = nil
  }
}
