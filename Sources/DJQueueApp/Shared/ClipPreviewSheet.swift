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

/// Quick look (⌘K "Preview", context menu, Space in some lists): the 9:16 proxy when there is one, else the
/// source file looping Eric's markers. In-window dialog, presented by MainWindowView while `model.previewVideo`
/// is set.
struct ClipPreviewSheet: View {
  @Bindable var model: AppModel
  let video: Video

  var body: some View {
    let proxy = model.proxyURLs[video.id]
    DSDialog(model.displayName(video), description: [model.sessionName(video), Fmt.duration(model.clipDuration(video))]
      .filter { !$0.isEmpty }.joined(separator: " · "), width: proxy == nil ? 760 : 420, onClose: close) {
      DSVideoPreview(url: proxy ?? model.clipURL(video), poster: model.poster(video), isActive: true, isPriority: true,
                     loopRange: proxy == nil ? model.markerRange(video) : nil, showsScrubber: true, cornerRadius: DS.radius.md,
                     gravity: .resizeAspect)
        .aspectRatio(proxy == nil ? 16 / 9 : 9 / 16, contentMode: .fit)
        .frame(maxHeight: 560)
        .background(Color.black, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
    } footer: {
      DSButton("Close", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .primary) {
        close()
        model.openEditor(video.id)
      }
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .onAppear { model.requestProxies([video.id]); model.requestPoster(video) }
  }

  private func close() { model.previewVideo = nil }
}
