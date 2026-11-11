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

  /// A photo post has one look, as it will post: no "Original" side, and nothing to play.
  static func hasToggle(_ v: Video) -> Bool { v.type == .short && !v.missing && !v.isPhoto }

  var body: some View {
    let v = model.video(video.id) ?? video
    if v.isPhoto { PhotoPostPreview(model: model, video: v, maxHeight: maxHeight) } else { player(v) }
  }

  @ViewBuilder private func player(_ v: Video) -> some View {
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
                         cornerRadius: DS.radius.md, overlays: renderURL == nil ? p.overlays : [],
                         isUpdating: url == nil, needsOverlay: renderURL == nil && p.overlayMissing,
                         onNeedsOverlay: { model.reloadOverlay(v.id) }, gravity: .resizeAspect)
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

/// A photo post in a quick look (round 21): each photo exactly as it will post, at its own shape. A carousel steps
/// with ‹ › and dots. No player is ever made for it.
struct PhotoPostPreview: View {
  @Bindable var model: AppModel
  let video: Video
  var maxHeight: CGFloat = 560

  var body: some View {
    let p = model.clipPreview(video)
    DSPhotoPreview(count: video.photoCount, aspectRatio: p.aspectRatio, poster: p.cover,
                   image: { model.photoImage(video, index: $0) }, load: { model.requestPhoto(video, index: $0) },
                   stamp: p.stamp, steps: true, cornerRadius: DS.radius.md, anchor: "Quick look photo")
      .aspectRatio(p.aspectRatio, contentMode: .fit)
      .frame(maxHeight: maxHeight)
      .frame(maxWidth: .infinity)
      .onAppear { model.requestPoster(video) }
      .task(id: p.stamp) { model.requestPoster(video) }
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
    let v = model.video(video.id) ?? video
    // A photo post says "Photo" / "Carousel · 5" where a clip names its night and length (D18).
    let about = v.photoLabel ?? [model.sessionName(video), Fmt.duration(model.clipDuration(video))].filter { !$0.isEmpty }.joined(separator: " · ")
    DSDialog(model.displayName(video), description: about, width: v.isPhoto ? 480 : edited ? 420 : 760, onClose: close) {
      EditedClipPlayer(model: model, video: video, source: $source)
    } footer: {
      DSButton("Close", variant: .ghost, shortcut: "esc", action: close).keyboardShortcut(.cancelAction)
      DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .primary,
               tooltip: v.isPhoto ? "Edit photos, crop, text and caption" : "Edit crop, text, caption and cover") {
        close()
        model.openEditor(video.id)
      }
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
  }

  private func close() { model.previewVideo = nil }
}
