import Foundation

/// When a published post's numbers are pulled again (round 39). Postiz only gives "as of now" totals, so the shape of
/// a post's curve comes from asking at set ages. Early ages are close together (short-form grows in its first days),
/// later ones far apart, and nothing is asked after a year. The engine asks for at most `perHour` posts in any rolling
/// hour, inside Postiz's shared budget and below creates, deletes and sync (`PostizCallKind.analytics`), so analytics
/// can never hold up a post.
public enum AnalyticsSchedule {
  /// Ages in days after posting.
  public static let milestones: [Double] = [0.5, 1, 3, 7, 14, 30, 60, 90, 180, 365]
  /// After an empty answer (Postiz has nothing for the post: X today, or a post whose platform id is missing), only
  /// these ages are asked again, so a platform that starts answering later is picked up without wasting calls.
  public static let afterEmpty: [Double] = [30, 90, 180, 365]
  /// Post analytics calls in any rolling hour (the shared Postiz budget is 25; creates keep priority).
  public static let perHour = 8
  /// Channel (account) analytics: once a day per channel; the first pull reaches back further for history.
  public static let channelDays = 30
  public static let channelFirstDays = 90
  public static let channelInterval: TimeInterval = 20 * 3600

  /// The milestone a post has reached and not been asked at yet (nil: nothing due). `lastWasEmpty`: the last answer
  /// had no numbers.
  public static func due(postedAt: Date, last: Date?, lastWasEmpty: Bool = false, now: Date) -> Double? {
    let age = now.timeIntervalSince(postedAt) / 86400
    let list = lastWasEmpty ? afterEmpty : milestones
    guard let m = list.last(where: { $0 <= age }) else { return nil }
    guard let last else { return m }
    let lastAge = last.timeIntervalSince(postedAt) / 86400
    return m > lastAge + 1e-6 ? m : nil
  }

  /// The next age a post will be asked at (for `djq analytics post` and the inspector's "next pull").
  public static func next(postedAt: Date, last: Date?, lastWasEmpty: Bool = false, now: Date) -> Date? {
    let lastAge = last.map { $0.timeIntervalSince(postedAt) / 86400 } ?? -1
    let age = now.timeIntervalSince(postedAt) / 86400
    let list = lastWasEmpty ? afterEmpty : milestones
    if due(postedAt: postedAt, last: last, lastWasEmpty: lastWasEmpty, now: now) != nil { return now }
    guard let m = list.first(where: { $0 > max(lastAge, age) }) else { return nil }
    return postedAt.addingTimeInterval(m * 86400)
  }
}
