import DJQCore
import SwiftUI

/// What one platform's phone mock shows. Everything is real clip data (no invented content): the caption is
/// `Captions.caption(for:)`, the YouTube title `Captions.youtubeTitle`, the handle `PlatformUI.handle`.
struct PhoneMockContent: Equatable {
  var platform: Platform
  /// The full caption for this platform (the mock truncates it with `PlatformUI.previewCaption`).
  var caption: String
  /// YouTube Shorts shows this under the handle instead of the caption.
  var youtubeTitle: String
  var handle: String
  /// Display name for card layouts (X shows name + @handle).
  var displayName: String = "DJ Lovd"
  /// Music / sound line ("Original audio", or the Title's tracks).
  var soundLine: String = "Original audio"
  /// "0:21" — X duration badge.
  var durationText: String = ""
  /// The clip's output aspect (the `media` view is drawn at exactly this aspect).
  var aspect: Aspect = .r9x16
}

/// Generic phone mock of a platform's feed (TikTok, Instagram Reels, Facebook Reels, YouTube Shorts) or post card
/// (Threads, X), drawn from `PlatformUI` geometry (DESIGN-v2 §8). No logos, no brand colours.
///
/// Fills the width it's given at the phone aspect (9:19.5). `media` is the clip's output frame (video + overlay
/// text) and fills whatever frame it gets, so the mock always frames it at `content.aspect` and clips it.
struct EditorPhoneMock<Media: View>: View {
  let content: PhoneMockContent
  let media: Media

  init(content: PhoneMockContent, @ViewBuilder media: () -> Media) {
    self.content = content
    self.media = media()
  }

  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = w * 19.5 / 9
      ZStack(alignment: .topLeading) {
        Color.black
        media
          .frame(width: w, height: w / content.aspect.ratio)
          .position(x: w / 2, y: h * 0.45)
      }
      .frame(width: w, height: h)
      .clipShape(RoundedRectangle(cornerRadius: 44 * w / 393, style: .continuous))
    }
    .aspectRatio(9 / 19.5, contentMode: .fit)
  }
}
