import Foundation
import Testing
@testable import DJQCore

/// "Unmute on hover" defaults on; saved prefs from before round 3 (never chosen) migrate to on once, and Eric's
/// own choice is respected from then on.
@Suite struct R3PlaybackPrefsTests {
  func decode(_ json: String) throws -> PlaybackPrefs { try JSONDecoder().decode(PlaybackPrefs.self, from: Data(json.utf8)) }
  func roundTrip(_ p: PlaybackPrefs) throws -> PlaybackPrefs { try JSONDecoder().decode(PlaybackPrefs.self, from: JSONEncoder().encode(p)) }

  @Test func defaultIsOn() {
    #expect(PlaybackPrefs().unmuteOnHover && !PlaybackPrefs().unmuteOnHoverChosen)
  }

  @Test func oldSavedPrefsMigrateToOnAndKeepTheRest() throws {
    let old = try decode(#"{"autoplay":false,"unmuteOnHover":false,"focusOnly":true,"loop":"wholeFile"}"#)
    #expect(old.unmuteOnHover && !old.unmuteOnHoverChosen)
    #expect(!old.autoplay && old.focusOnly && old.loop == .wholeFile)
    #expect(try decode("{}") == PlaybackPrefs())
  }

  @Test func ericsChoiceSticks() throws {
    var p = try decode(#"{"unmuteOnHover":false}"#)
    p.chooseUnmuteOnHover(false)
    let saved = try roundTrip(p)
    #expect(!saved.unmuteOnHover && saved.unmuteOnHoverChosen)
    var q = saved
    q.chooseUnmuteOnHover(true)
    #expect(try roundTrip(q).unmuteOnHover)
  }

  @Test func gridHoverOnlyDefaultsOnAndMigratesOnce() throws {
    #expect(PlaybackPrefs().gridHoverOnly)
    #expect(try decode(#"{"autoplay":true}"#).gridHoverOnly)
    var p = PlaybackPrefs()
    p.chooseGridHoverOnly(false)
    #expect(try !roundTrip(p).gridHoverOnly)
  }

  /// Round 14: size decides. Every small preview is a cover until the pointer (or keyboard focus) is on it.
  @Test func smallPreviewsPlayOnlyWhileHovered() {
    let p = PlaybackPrefs()
    for layout in [PreviewPlayback.Layout.cards, .grid, .list] {
      #expect(!PreviewPlayback.plays(p, layout: layout, hovered: false, focused: false))
      #expect(PreviewPlayback.plays(p, layout: layout, hovered: true, focused: false))
      #expect(PreviewPlayback.plays(p, layout: layout, hovered: false, focused: true))
    }
  }

  @Test func singlePlaysByItself() {
    var p = PlaybackPrefs()
    #expect(PreviewPlayback.plays(p, layout: .single, hovered: false, focused: false))
    #expect(PreviewPlayback.plays(p, layout: .single, hovered: false, focused: true))
    p.focusOnly = true
    #expect(PreviewPlayback.plays(p, layout: .single, hovered: false, focused: true))
    #expect(!PreviewPlayback.plays(p, layout: .single, hovered: false, focused: false))
  }

  /// "Small previews: play on hover only" off: the old behaviour for every small layout.
  @Test func hoverOnlyOffPlaysEveryVisibleClip() {
    var p = PlaybackPrefs()
    p.chooseGridHoverOnly(false)
    for layout in [PreviewPlayback.Layout.cards, .grid, .list] {
      #expect(PreviewPlayback.plays(p, layout: layout, hovered: false, focused: false))
    }
    p.focusOnly = true
    for layout in [PreviewPlayback.Layout.cards, .grid, .list] {
      #expect(!PreviewPlayback.plays(p, layout: layout, hovered: false, focused: false))
      #expect(PreviewPlayback.plays(p, layout: layout, hovered: true, focused: false))
    }
  }

  @Test func autoplayOffPlaysNothing() {
    for hoverOnly in [true, false] {
      var p = PlaybackPrefs()
      p.chooseGridHoverOnly(hoverOnly)
      p.autoplay = false
      for layout in [PreviewPlayback.Layout.cards, .grid, .list, .single] {
        #expect(!PreviewPlayback.plays(p, layout: layout, hovered: true, focused: true))
      }
    }
  }

  @Test func proxyTargets() {
    let p = PlaybackPrefs()
    let vis = ["a", "b", "c", "d", "e"]
    let h = PreviewPlayback.proxyTargets(p, layout: .grid, visible: vis, hovered: "c")
    #expect(h.now == ["c"] && h.prefetch == ["d", "b"])
    let none = PreviewPlayback.proxyTargets(p, layout: .grid, visible: vis, hovered: nil)
    #expect(none.now.isEmpty && none.prefetch == ["c", "b"])
    #expect(PreviewPlayback.proxyTargets(p, layout: .cards, visible: vis, hovered: "c").now == vis)
    var off = p
    off.autoplay = false
    #expect(PreviewPlayback.proxyTargets(off, layout: .cards, visible: vis, hovered: nil).now.isEmpty)
  }
}
