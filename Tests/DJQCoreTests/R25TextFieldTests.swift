import Foundation
import Testing
@testable import DJQCore

/// Round 25: a box that was emptied keeps what Eric types next, even only spaces or empty lines. Before, a Return in
/// an emptied Text box resolved back to the Title, and the box swapped its text out from under the caret.
@Suite struct R25TextFieldTests {
  func video() -> Video {
    Video(id: "v", sessionId: "s", name: "2026-10-23 – Afroween Jazz Piano – yayo x johnny", tags: ["yayo x johnny"],
          type: .short, contentType: "dj vid", kind: .djVid, file: "f.mp4", fingerprint: nil, fileSize: nil, duration: 27,
          markedStart: nil, markedEnd: nil, start: nil, end: nil, grace: nil, audio: nil, part: nil, score: nil,
          state: .needsEdit, excluded: false, missing: false, inManifest: true, notes: "", alreadyPostedOn: [],
          longformURL: nil, createdAt: Date(), updatedAt: Date())
  }

  func resolve(_ versions: [Version], _ n: Int = 1) -> ResolvedVersion {
    var v = video()
    v.title = "Yayo x Johnny"
    return VersionResolver.resolve(versions, number: n, settings: Settings(), video: v)
  }

  @Test func blankTypedTextStaysAsTyped() {
    for typed in ["", "\n", " ", "  \n "] {
      var v = Version(number: 1)
      v.text = typed
      v.noText = false  // what the editor stores for a blank box
      let r = resolve([v])
      #expect(r.text == typed, "typed \(typed.debugDescription)")
      #expect(!r.noText && !r.hasText && r.layers.isEmpty)
    }
  }

  @Test func untouchedTextStillFollowsTheTitle() {
    #expect(resolve([Version(number: 1)]).text == "Yayo x Johnny")
  }

  @Test func blankOnALaterVersionDoesNotReachBack() {
    var v1 = Version(number: 1)
    v1.text = "Afroween live"
    var v2 = Version(number: 2)
    v2.text = "\n"
    v2.noText = false
    #expect(resolve([v1, v2], 2).text == "\n")
    #expect(resolve([v1, v2], 1).text == "Afroween live")
  }

  @Test func typedTextIsKeptExactly() {
    var v = Version(number: 1)
    v.text = "Afro\nween live\n"
    #expect(resolve([v]).text == "Afro\nween live\n")
  }
}
