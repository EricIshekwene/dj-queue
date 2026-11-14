import Foundation
import Testing
@testable import DJQCore

/// Round 32: the Queue screen's score order and "Move one place later" are the engine's own (`Queue.scoreOrder`,
/// `Queue.applySkips`), so what Eric sees is the order clips get their days.
struct R32QueueOrderTests {
  private func clip(_ id: String, score: Int?, session: String = "s1", part: Int? = 1, start: Double? = 0,
                    created: TimeInterval = 0, photo: Bool = false) -> Video {
    var v = Video(id: id, sessionId: session, name: id, tags: [id], type: .short, contentType: "dj vid", kind: .djVid,
                  file: "\(id).mp4", fingerprint: nil, fileSize: nil, duration: 10, markedStart: nil, markedEnd: nil,
                  start: start, end: nil, grace: nil, audio: nil, part: part, score: score, state: .ready, excluded: false,
                  missing: false, inManifest: true, notes: "", alreadyPostedOn: [], longformURL: nil,
                  createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(), title: nil)
    if photo { v.photos = [PhotoItem(file: "\(id).jpg", width: 1080, height: 1920)] }
    return v
  }

  private let dates = ["s1": "2026-10-01", "s2": "2026-10-23"]

  @Test func scoresGoTheChosenWayWithUnscoredPhotosFirst() {
    let vs = [clip("a", score: 44), clip("b", score: 20), clip("p2", score: nil, created: 2, photo: true),
              clip("c", score: 67), clip("p1", score: nil, created: 1, photo: true), clip("d", score: 17)]
    #expect(Queue.scoreOrder(vs, direction: .worstFirst, sessionDates: dates).map(\.id) == ["p1", "p2", "d", "b", "a", "c"])
    #expect(Queue.scoreOrder(vs, direction: .bestFirst, sessionDates: dates).map(\.id) == ["p1", "p2", "c", "a", "b", "d"])
  }

  @Test func tiesGoOlderSetThenPartThenStartThenId() {
    let vs = [clip("y", score: 50, session: "s2", part: 1, start: 0), clip("x", score: 50, session: "s1", part: 2, start: 0),
              clip("w", score: 50, session: "s1", part: 1, start: 30), clip("v", score: 50, session: "s1", part: 1, start: 10),
              clip("u", score: 50, session: "s1", part: 1, start: 10)]
    #expect(Queue.scoreOrder(vs, direction: .worstFirst, sessionDates: dates).map(\.id) == ["u", "v", "w", "x", "y"])
  }

  @Test func aSkippedClipWithNoSlotMovesOnePlaceLater() {
    let vs = ["a", "b", "c", "d"].map { clip($0, score: 10) }
    #expect(Queue.applySkips(vs, skipIds: ["b"], slotted: []).map(\.id) == ["a", "c", "b", "d"])
    #expect(Queue.applySkips(vs, skipIds: ["b"], slotted: ["b"]).map(\.id) == ["a", "b", "c", "d"])
    #expect(Queue.applySkips(vs, skipIds: ["d"], slotted: []).map(\.id) == ["a", "b", "c", "d"])
  }
}
