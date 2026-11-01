import AVFoundation
import AppKit
import DJQCore
import SwiftUI

/// AVPlayerLayer that loops a clip between Eric's marker in/out (falls back to the whole file).
struct LoopingPlayer: NSViewRepresentable {
  let url: URL?
  let range: ClosedRange<Double>?
  var muted = false

  final class PlayerNSView: NSView {
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?
    var current: URL?
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer = CALayer()
      playerLayer.player = player
      playerLayer.videoGravity = .resizeAspect
      layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
      super.layout()
      playerLayer.frame = bounds
    }
  }

  func makeNSView(context: Context) -> PlayerNSView { PlayerNSView() }

  func updateNSView(_ v: PlayerNSView, context: Context) {
    v.player.isMuted = muted
    guard v.current != url else { return }
    v.current = url
    v.looper?.disableLooping()
    v.player.removeAllItems()
    guard let url else { return }
    let item = AVPlayerItem(url: url)
    if let r = range, r.upperBound > r.lowerBound {
      let tr = CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                           end: CMTime(seconds: r.upperBound, preferredTimescale: 600))
      v.looper = AVPlayerLooper(player: v.player, templateItem: item, timeRange: tr)
    } else {
      v.looper = AVPlayerLooper(player: v.player, templateItem: item)
    }
    v.player.play()
  }

  static func dismantleNSView(_ v: PlayerNSView, coordinator: ()) {
    v.player.pause()
    v.looper?.disableLooping()
  }
}

extension AppModel {
  func clipURL(_ v: Video) -> URL? { try? store.fileURL(for: v) }
  func markerRange(_ v: Video) -> ClosedRange<Double>? {
    guard let a = v.markerIn, let b = v.markerOut, b > a else { return nil }
    return a...b
  }
}

/// Q.S6 Score mode: full-window player, big number field, Enter saves and jumps to the next unscored, Esc exits.
struct ScoreModeView: View {
  @Bindable var model: AppModel
  @State private var queue: [String] = []
  @State private var index = 0
  @State private var text = ""
  @State private var scoredThisRun = 0
  @FocusState private var focused: Bool

  private var current: Video? { index < queue.count ? model.video(queue[index]) : nil }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let v = current {
        VStack(spacing: 0) {
          topBar
          ZStack {
            LoopingPlayer(url: model.clipURL(v), range: model.markerRange(v))
              .background { posterFallback(v) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          bottomBar(v)
        }
      } else {
        VStack(spacing: 14) {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
          Text("Everything is scored").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
          Text("\(scoredThisRun) scored this time").foregroundStyle(.white.opacity(0.6))
          Button("Back to Queue") { model.scoreMode = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      }
    }
    .environment(\.colorScheme, .dark)
    .onAppear {
      queue = model.toScore.map(\.id)
      if queue.isEmpty, let sel = model.focusedVideo { queue = [sel.id] }
      index = 0
      load()
    }
    .onExitCommand { model.scoreMode = false }
  }

  private func posterFallback(_ v: Video) -> some View {
    GeometryReader { g in
      CoverThumb(video: v, width: g.size.height * 9 / 16, height: g.size.height, radius: 0)
        .frame(maxWidth: .infinity)
        .opacity(0.9)
    }
  }

  private var topBar: some View {
    HStack {
      Button { model.scoreMode = false } label: { Label("Exit", systemImage: "xmark") }
        .buttonStyle(.bordered)
        .help("Esc")
      Spacer()
      Text("\(max(0, queue.count - index)) left").font(DS.Font.bodyStrong.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
      ProgressView(value: Double(index), total: Double(max(queue.count, 1))).frame(width: 160).tint(.white)
      Spacer()
      Text("Score mode").font(DS.Font.bodyStrong).foregroundStyle(.white.opacity(0.75))
    }
    .padding(.horizontal, 20)
    .frame(height: 52)
  }

  private func bottomBar(_ v: Video) -> some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.title(v)).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        Text("\(model.setName(v)) · \(Fmt.duration(v.duration)) · \(v.kind.displayName)").foregroundStyle(.white.opacity(0.6))
      }
      Spacer()
      HStack(spacing: 6) {
        hint("0–100 ↩", "save & next")
        hint("← →", "skip")
        hint("Esc", "exit")
      }
      TextField("–", text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .frame(width: 130, height: 76)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))
        .focused($focused)
        .onSubmit(save)
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { p in
          let step = p.modifiers.contains(.shift) ? 10 : 1
          text = "\(min(100, max(0, (Int(text) ?? 50) + (p.key == .upArrow ? step : -step))))"
          return .handled
        }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 18)
    .background(Color.white.opacity(0.06))
  }

  private func hint(_ k: String, _ t: String) -> some View {
    HStack(spacing: 4) {
      Text(k).font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
      Text(t).font(DS.Font.secondary)
    }
    .foregroundStyle(.white.opacity(0.7))
  }

  private func load() {
    text = current?.score.map(String.init) ?? ""
    focused = true
  }

  private func go(_ d: Int) {
    index = min(max(0, index + d), max(queue.count - 1, 0))
    load()
  }

  private func save() {
    guard let v = current, let n = Int(text.trimmingCharacters(in: .whitespaces)), (0...100).contains(n) else { NSSound.beep(); return }
    model.setScore([v.id], n)
    scoredThisRun += 1
    // Next unscored after this one (skips anything scored meanwhile).
    var i = index + 1
    while i < queue.count, model.video(queue[i])?.score != nil { i += 1 }
    index = i
    load()
  }
}

/// Space-bar preview of a clip (looping marker range).
struct PreviewSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      LoopingPlayer(url: model.clipURL(video), range: model.markerRange(video))
        .frame(width: 800, height: 450)
        .background(Color.black)
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title(video)).font(DS.Font.title)
          Text("\(model.setName(video)) · \(Fmt.duration(video.duration))").font(DS.Font.secondary).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Edit") { dismiss(); model.openEditor(video.id) }
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(14)
    }
    .onKeyPress(.space) { dismiss(); return .handled }
  }
}
