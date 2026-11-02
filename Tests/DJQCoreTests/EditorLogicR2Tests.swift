import Foundation
import Testing
@testable import DJQCore

/// Round-2 editor rules: overrides on top of New clip defaults, posting toggles, caption warnings, grace zones.
@Suite struct EditorLogicR2Tests {
  func clip(_ d: Double) -> Video {
    Video(id: "v", sessionId: "s", name: "s – yayo x johnny", tags: ["yayo x johnny"], type: .short, contentType: "dj vid",
          kind: .djVid, file: "f.mp4", fingerprint: nil, fileSize: nil, duration: d, markedStart: nil, markedEnd: nil,
          start: nil, end: nil, grace: nil, audio: nil, part: nil, score: nil, state: .needsEdit, excluded: false,
          missing: false, inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil, createdAt: Date(), updatedAt: Date())
  }

  @Test func valueEqualToDefaultFollowsTheDefault() {
    #expect(EditorLogic.override(3.0, default: 3.0) == nil)
    #expect(EditorLogic.override(3.004, default: 3.0) == nil)
    #expect(EditorLogic.override(2.5, default: 3.0) == 2.5)
  }

  @Test func postingTogglesAreOverridesOnTopOfDefaults() {
    var d = NewClipDefaults()
    d.platforms = [.tiktok, .instagram]
    var e = Edit()
    EditorLogic.setPosting(&e, .tiktok, false, defaults: d)
    #expect(e.skippedPlatforms == [.tiktok] && e.includedPlatforms.isEmpty)
    #expect(e.isSkipped(.tiktok, defaults: d))
    EditorLogic.setPosting(&e, .tiktok, true, defaults: d)
    #expect(e.isEmpty)  // back to the default: nothing stored
    EditorLogic.setPosting(&e, .x, true, defaults: d)  // the defaults leave X out
    #expect(e.includedPlatforms == [.x] && !e.isSkipped(.x, defaults: d))
    EditorLogic.setPosting(&e, .x, false, defaults: d)
    #expect(e.isEmpty)
  }

  @Test func resolvedPlatformsFollowTheToggles() {
    let v = clip(30)
    var e = Edit()
    let d = NewClipDefaults()
    EditorLogic.setPosting(&e, .threads, false, defaults: d)
    let r = EditResolver.resolve(e, video: v, defaults: d)
    #expect(r.isSkipped(.threads) && !r.isDefault(.platforms))
    EditResolver.reset(&e, .platforms)
    #expect(EditResolver.resolve(e, video: v, defaults: d).isDefault(.platforms))
  }

  @Test func captionWarningsOnlyNearOrOver() {
    #expect(EditorLogic.lengthLevel(count: 200, limit: 280) == .ok)
    #expect(EditorLogic.lengthLevel(count: 252, limit: 280) == .near)
    #expect(EditorLogic.lengthLevel(count: 280, limit: 280) == .near)
    #expect(EditorLogic.lengthLevel(count: 312, limit: 280) == .over)
  }

  @Test func graceZonesAreTheSecondsBeyondTheMarkers() {
    let z = EditorLogic.graceZones(duration: 27, markerIn: 3, markerOut: 24)
    #expect(z == [TrimRange(start: 0, end: 3), TrimRange(start: 24, end: 27)])
    #expect(EditorLogic.graceZones(duration: 27, markerIn: nil, markerOut: nil).isEmpty)
    #expect(EditorLogic.graceZones(duration: 27, markerIn: 0, markerOut: 27).isEmpty)
  }

  @Test func defaultTrimIsTheMarkersSoHandlesStartThere() {
    var v = clip(27)
    v.start = 100; v.markedStart = 103; v.markedEnd = 124
    let r = EditResolver.resolve(Edit(), video: v, defaults: NewClipDefaults())
    #expect(r.trimIn == 3 && r.trimOut == 24 && r.isDefault(.trimIn) && r.isDefault(.trimOut))
    #expect(EditorLogic.override(r.trimIn, default: NewClipDefaults().trim(for: v).start) == nil)
  }
}
