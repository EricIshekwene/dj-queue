import Foundation
import Testing
@testable import DJQCore

/// v0.8.3: part chips change the caption text in place.
@Suite struct R11PartsTests {
  let values = CaptionParts.Values(text: "Amarider blend", set: "Afroween Jazz Piano", link: "Full set on YouTube (link in bio)", title: "Song A")
  let tags = "#djlovd #afrobeats #amapiano"

  func toggle(_ c: String, _ parts: CaptionPart...) -> String {
    parts.reduce(c) { CaptionParts.toggled($1, in: $0, values) }
  }

  @Test func onAndOffRestoresTheExactText() {
    let captions = ["", tags, "Words", "Words\n\n\(tags)", "Words\n\(tags)", "One\n\nTwo\n\n\n\(tags)", "  spaced  \n\(tags)",
                    "Amarider blend\n\n\(tags)", "Own line\n\nFull set on YouTube (link in bio)\n\(tags)"]
    for c in captions {
      for p in CaptionPart.allCases where !CaptionParts.isOn(p, in: c, values) {
        #expect(toggle(c, p, p) == c, "\(p) on \(c)")
      }
      let all = CaptionPart.allCases.filter { !CaptionParts.isOn($0, in: c, values) }
      #expect(all.reduce(all.reduce(c) { CaptionParts.toggled($1, in: $0, values) }) { CaptionParts.toggled($1, in: $0, values) } == c, "all on \(c)")
    }
  }

  @Test func theOrderIsFixedWhateverTheClickOrder() {
    let want = "Amarider blend\nAfroween Jazz Piano\nFull set on YouTube (link in bio)\nSong A\n\n\(tags)"
    #expect(toggle(tags, .text, .set, .link, .title) == want)
    #expect(toggle(tags, .title, .link, .set, .text) == want)
    #expect(toggle(tags, .link, .title, .text, .set) == want)
  }

  @Test func hashtagsAreUntouched() {
    for p in CaptionPart.allCases {
      #expect(Captions.tags(in: toggle(tags, p)) == Captions.tags(in: tags))
      #expect(toggle(tags, p).hasSuffix(tags))
    }
    #expect(toggle("Words\n\n#a\n#b", .link).hasSuffix("\n\n#a\n#b"))
  }

  @Test func noDuplicates() {
    let once = toggle(tags, .text)
    #expect(CaptionParts.isOn(.text, in: once, values))
    #expect(toggle(once, .text) == tags)
    #expect(once.components(separatedBy: "Amarider blend").count == 2)
  }

  @Test func aChipFollowsTheTextNotAClick() {
    #expect(CaptionParts.isOn(.link, in: "watch: full set on youtube (LINK IN BIO) now", values))
    #expect(!CaptionParts.isOn(.title, in: "Songs A plenty", values))
    #expect(!CaptionParts.isOn(.text, in: "#Amarider", .init(text: "Amarider", set: "S", link: "L", title: nil)))
  }

  @Test func textEqualToTitleIsOneLine() {
    let same = CaptionParts.Values(text: "Song A", set: "Set", link: "Link", title: "Song A")
    let on = CaptionParts.toggled(.text, in: tags, same)
    #expect(CaptionParts.isOn(.text, in: on, same) && CaptionParts.isOn(.title, in: on, same))
    #expect(CaptionParts.toggled(.title, in: on, same) == on.replacingOccurrences(of: "Song A\n\n", with: ""))
    #expect(on.components(separatedBy: "Song A").count == 2)
    let other = CaptionParts.toggled(.title, in: tags, same)
    #expect(other == on)
  }

  @Test func aTitleInsideTheTextDoesntCountAsTheTitle() {
    let v = CaptionParts.Values(text: "Song A into Song B", set: "S", link: "L", title: "Song A")
    let c = CaptionParts.toggled(.text, in: "", v)
    #expect(CaptionParts.isOn(.text, in: c, v) && !CaptionParts.isOn(.title, in: c, v))
    #expect(CaptionParts.toggled(.title, in: c, v) == "Song A into Song B\nSong A")
  }

  @Test func aPartInsideALineComesOutCleanly() {
    let line = "🎧 Afroween Jazz Piano — full set on YouTube (link in bio)"
    let c = "Amarider blend\n\n\(line)\n\(tags)"
    #expect(toggle(c, .link) == "Amarider blend\n\n🎧 Afroween Jazz Piano\n\(tags)")
    #expect(toggle(c, .set) == "Amarider blend\n\n🎧 full set on YouTube (link in bio)\n\(tags)")
    #expect(toggle(c, .link, .set) == "Amarider blend\n\n\(tags)")
  }

  @Test func nothingToResolveIsOffWithAReason() {
    let v = CaptionParts.Values(text: "T", set: "S", link: "  ", title: nil)
    #expect(CaptionParts.offReason(.title, v) == "No title yet")
    #expect(CaptionParts.offReason(.link, v)?.contains("Settings") == true)
    #expect(CaptionParts.offReason(.text, v) == nil)
    #expect(CaptionParts.toggled(.title, in: tags, v) == tags)
    #expect(!CaptionParts.isOn(.title, in: tags, v))
  }

  @Test func theLinkLineHoldsScheduledClips() throws {
    let f = try Fixture.planned()
    let t = CaptionTemplates.make(name: "Link", template: "{text} {link}", existing: try f.store.captionTemplates())
    try CaptionTemplates.create(t, store: f.store, bulk: f.bulk)
    for id in ["clip-0", "clip-1"] {
      var v = try #require(try f.store.versions(videoId: id).first)
      v.captionTemplateId = t.id
      try f.store.save(v, videoId: id)
    }
    let before = try f.captions("clip-0"), hashes = try f.hashes()
    let c = try CaptionTemplates.setLink("New link", store: f.store, bulk: f.bulk)
    #expect(c.kept == ["clip-0"])
    #expect(try f.captions("clip-0") == before)
    #expect(try f.hashes() == hashes)
    #expect(try f.captions("clip-1")[1]?[.x]?.hasSuffix("New link") == true)
    let session = try f.bulk.begin("editor", ids: ["clip-0"])
    try CaptionTemplates.setLink("Newer", store: f.store, bulk: f.bulk)
    #expect(try f.bulk.commit(session).batchId == nil)
    let b = try #require(try f.bulk.batches().first { $0.action == CaptionTemplates.linkAction })
    try f.bulk.undo(b.id)
    #expect(try f.store.settings().captionLink == "New link")
  }
}
