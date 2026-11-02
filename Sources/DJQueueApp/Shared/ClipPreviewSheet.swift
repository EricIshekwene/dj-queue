import AVFoundation
import DJQCore
import SwiftUI

extension AppModel {
  /// The clip's source file (16:9 DJ footage).
  func clipURL(_ v: Video) -> URL? { try? store.fileURL(for: v) }
  /// Eric's markers inside the clip file (the default trim).
  func markerRange(_ v: Video) -> ClosedRange<Double>? {
    guard let a = v.markerIn, let b = v.markerOut, b > a else { return nil }
    return a...b
  }
}

/// Which picture a quick look shows: the clip as it will post (default) or Eric's 16:9 source.
enum ClipPreviewSource: Hashable { case edited, original }

/// The clip as it will post, at its aspect (S6): the current render when one exists (`renderURL`), else the 540-px
/// proxy with the text drawn live in its window; while the proxy is being made, the edited cover with "Updating
/// preview" — never the raw source. `.original` plays the 16:9 source looping Eric's markers. Long-form and missing
/// clips always show the source frame (no toggle).
struct EditedClipPlayer: View {
  @Bindable var model: AppModel
  let video: Video
  @Binding var source: ClipPreviewSource
  var maxHeight: CGFloat = 560
  @State private var renderURL: URL?

  static func hasToggle(_ v: Video) -> Bool { v.type == .short && !v.missing }

  var body: some View {
    let v = model.video(video.id) ?? video
    let edited = Self.hasToggle(v) && source == .edited
    let p = model.clipPreview(v)
    VStack(spacing: DS.space.sm) {
      if Self.hasToggle(v) {
        DSSegmented(selection: $source, segments: [
          DSSegment(value: ClipPreviewSource.edited, title: "Edited", icon: "crop",
                    tooltip: "The clip as it will post: crop, trim, text and cover"),
          DSSegment(value: .original, title: "Original", icon: "rectangle",
                    tooltip: "The 16:9 source between your markers, before any edit"),
        ], size: .sm)
      }
      Group {
        if edited {
          let url = renderURL ?? p.proxyURL
          DSVideoPreview(url: url, poster: p.cover, isActive: !model.frozen, isPriority: true, showsScrubber: true,
                         cornerRadius: DS.radius.md, overlay: renderURL == nil ? p.overlay : nil, textWindow: p.textWindow,
                         isUpdating: url == nil, gravity: .resizeAspect)
            .aspectRatio(p.aspectRatio, contentMode: .fit)
        } else {
          DSVideoPreview(url: v.missing ? nil : model.clipURL(v), poster: v.type == .long ? model.poster(v) : model.originalPoster(v),
                         isActive: !v.missing && !model.frozen, isPriority: true,
                         loopRange: v.type == .short ? model.markerRange(v) : nil, showsScrubber: true,
                         cornerRadius: DS.radius.md, gravity: .resizeAspect)
            .aspectRatio(16 / 9, contentMode: .fit)
        }
      }
      .frame(maxHeight: maxHeight)
      .background(Color.black, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    }
    .onChange(of: source, initial: true) { _, s in if s == .original { model.requestOriginalPoster(v) } }
    .task(id: p.stamp) {
      renderURL = nil  // an older render (older crop/text) never keeps playing while the new one is looked up
      guard Self.hasToggle(v) else { model.requestPoster(v); return }
      model.requestPoster(v)
      model.requestProxies([v.id], keepOthersVisible: true)
      renderURL = model.frozen ? nil : await model.currentRenderFile(v)
    }
  }
}

/// Quick look (⌘K "Preview", context menu, Space in some lists): the clip as it will post, 9:16 — the current render
/// when there is one, else the proxy + live text — with an "Original" toggle for the 16:9 source (S6). In-window
/// dialog, presented by MainWindowView while `model.previewVideo` is set.
struct ClipPreviewSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var source = ClipPreviewSource.edited

  var body: some View {
    let edited = EditedClipPlayer.hasToggle(video) && source == .edited
    DSDialog(model.displayName(video), description: [model.sessionName(video), Fmt.duration(model.clipDuration(video))]
      .filter { !$0.isEmpty }.joined(separator: " · "), width: edited ? 420 : 760, onClose: close) {
      EditedClipPlayer(model: model, video: video, source: $source)
    } footer: {
      DSButton("Close", variant: .ghost, shortcut: "esc", action: close).keyboardShortcut(.cancelAction)
      DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .primary, tooltip: "Edit crop, text, caption and cover") {
        close()
        model.openEditor(video.id)
      }
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func close() { model.previewVideo = nil }
}
