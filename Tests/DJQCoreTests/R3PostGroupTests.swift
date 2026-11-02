import Foundation
import Testing
@testable import DJQCore

/// Posts → one card per (clip, scheduled day): grouping, order and the one-line summary.
@Suite struct R3PostGroupTests {
  func post(_ id: String, _ video: String, _ p: Platform, day: Int, hour: Int = 19, state: PostState = .rendered,
            kind: PostKind = .regular, attempt: Int = 1) -> PlatformPost {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    let d = c.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    return PlatformPost(id: id, videoId: video, platform: p, versionNo: 1, attemptNo: attempt, kind: kind, planSlotId: nil,
                        scheduledAt: d, renderId: nil, state: state, publisher: "manual", externalId: nil, url: nil, postedAt: nil,
                        errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: d, updatedAt: d)
  }

  func dayKey(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  @Test func groupsByClipAndDayKeepingOrder() {
    let list = [
      post("1", "a", .x, day: 2, hour: 20), post("2", "a", .tiktok, day: 2, hour: 12),
      post("3", "b", .tiktok, day: 3), post("4", "a", .instagram, day: 2),
      post("5", "a", .tiktok, day: 4, kind: .retry, attempt: 2),  // retry on another day → own card
      post("6", "a", .x, day: 2, hour: 21, kind: .repost, attempt: 2),  // same day → folds in
    ]
    let g = PostGrouping.group(list, day: dayKey)
    #expect(g.map(\.id) == ["a|2026-11-02", "b|2026-11-03", "a|2026-11-04"])
    #expect(g[0].posts.map(\.id) == ["2", "4", "1", "6"])  // time order
    #expect(g[0].extras.map(\.id) == ["6"])
    #expect(dayKey(g[0].first) == "2026-11-02" && g[0].first < g[0].last)
  }

  @Test func summaries() {
    let same = Platform.allCases.enumerated().map { post("\($0.offset)", "a", $0.element, day: 2) }
    #expect(PostGrouping.summary(same) == "6 platforms · all rendered")
    #expect(PostGrouping.summary([post("1", "a", .x, day: 2, state: .planned)]) == "1 platform · planned")
    let mixed = [post("1", "a", .x, day: 2, state: .posted), post("2", "a", .tiktok, day: 2, state: .posted),
                 post("3", "a", .instagram, day: 2, state: .failed), post("4", "a", .youtube, day: 2, state: .due),
                 post("5", "a", .x, day: 2, state: .planned, kind: .retry, attempt: 2)]
    #expect(PostGrouping.summary(mixed) == "2 posted · 1 failed · 1 due now · 1 planned · 1 retry")
  }
}
