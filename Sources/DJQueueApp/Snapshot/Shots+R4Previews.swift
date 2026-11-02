import DJQCore
import SwiftUI

/// Round 4 S6 shots (prefix r4-previews-): lists show the edited clip — covers with text, the text overlay a playing
/// preview shows in its text window, the quiet "Updating preview" state, and the Quick look / Library dialog with
/// the edited 9:16 picture by default and an "Original" toggle.
extension SnapshotShots {
  static func r4previews(_ c: SnapshotContext) -> [Shot] {
    /// Short clips with a file, given on-video text in the throwaway snapshot DB (one with the cover text off).
    func clips(_ m: AppModel) -> [Video] {
      let vids = Array(m.videos.filter { $0.type == .short && !$0.missing && !$0.excluded }.prefix(4))
      for (i, v) in vids.enumerated() {
        var ver = (try? m.store.versions(videoId: v.id))?.first { $0.number == 1 } ?? Version(number: 1)
        if (ver.text ?? "").isEmpty { ver.text = ["Wait for the drop 🔥", "Lagos rooftop at sunset", "Who knows this one?", "Part 2 next"][i % 4] }
        ver.noText = nil
        try? m.store.save(ver, videoId: v.id)
        if var e = try? m.store.edit(videoId: v.id) {
          e.coverIncludesTextOverride = i == 1 ? false : nil
          try? m.store.save(e, videoId: v.id)
        }
      }
      m.refreshNow()
      let fresh = vids.compactMap { m.video($0.id) }
      for v in fresh { m.requestPoster(v) }
      return fresh
    }
    return [
      // Grid tiles: cover with text · cover without text + the text a playing preview shows in its window ·
      // updating · plain.
      c.view("r4-previews-grid", width: 760) {
        let m = c.model
        let cards: [DSClip] = clips(m).enumerated().map { i, v in
          var clip = m.dsClip(v, for: .library)
          if i == 2 { clip.isUpdatingPreview = true; clip.proxyURL = nil }
          return clip
        }
        return AnyView(HStack(alignment: .top, spacing: DS.space.md) {
          ForEach(Array(cards.enumerated()), id: \.element.id) { i, clip in
            DSClipCard(clip, mode: .grid, config: gridConfig(m, hovered: false), onToggleSelect: {}, onTap: { _ in })
              .frame(width: 170)
              .environment(\.dsPreviewOverlayOnPoster, i == 1)
          }
        }
        .padding(DS.space.lg))
      },
      // Cards (Edit/Queue width): the updating state as an icon on the small preview.
      c.view("r4-previews-cards", width: 900) {
        let m = c.model
        let cards: [DSClip] = clips(m).prefix(2).enumerated().map { i, v in
          var clip = m.dsClip(v, for: .edit)
          if i == 0 { clip.isUpdatingPreview = true; clip.proxyURL = nil }
          return clip
        }
        return AnyView(VStack(spacing: DS.space.xs) {
          ForEach(cards) { clip in DSClipCard(clip, mode: .wide, onToggleSelect: {}, onTap: { _ in }) }
        }
        .padding(DS.space.lg))
      },
      // Quick look opens on the edited 9:16 picture (cover + text; "Updating preview" until its proxy exists).
      c.main("r4-previews-quicklook-edited") { m in
        if let v = clips(m).first { m.previewVideo = v }
      },
      // The same player with "Original" chosen: the 16:9 source between the markers.
      c.view("r4-previews-quicklook-original", width: 760) {
        let m = c.model
        guard let v = clips(m).first else { return AnyView(EmptyView()) }
        return AnyView(EditedClipPlayer(model: m, video: v, source: .constant(.original), maxHeight: 420).padding(DS.space.lg))
      },
      // Library's clip dialog: edited by default, with the toggle.
      c.main("r4-previews-library-dialog") { m in
        BrowseUI.shared.reset()
        m.screen = .library
        if let v = clips(m).first { BrowseUI.shared.quickLook = v }
      },
    ]
  }
}
