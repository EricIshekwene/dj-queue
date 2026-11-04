import Foundation

/// What a Postiz call is for. Priority (highest first): delete > create (soonest slot first) > sync > analytics.
/// Lower priorities leave some of the hour's budget for higher ones.
public enum PostizCallKind: String, Codable, Sendable, CaseIterable {
  case delete, create, sync, analytics, check

  /// Calls this kind leaves unused in the rolling hour for higher priorities.
  var reserve: Int {
    switch self {
    case .delete: 0
    case .create: 1  // one call an hour always stays for sync
    case .sync, .check: 0
    case .analytics: 8
    }
  }
}

/// The request budget every DJ Queue process shares (the app's engine and `djq`), persisted in kv
/// `postiz.budget`: `hourlyBudget` calls per rolling hour (25 by default, docs/postiz.md §1), a 15-minute pause after
/// a 429, and the "key invalid" flag after a 401 (no calls until a later call succeeds or the key is saved again).
public struct PostizBudget: Codable, Sendable, Equatable {
  public var calls: [Date] = []
  public var pausedUntil: Date?

  public init() {}

  public static let kvKey = "postiz.budget"
  public static let keyInvalidKey = "postiz.keyInvalid"
  public static let pauseAfter429: TimeInterval = 15 * 60

  public func used(now: Date) -> Int { calls.filter { now.timeIntervalSince($0) < 3600 }.count }

  public func remaining(now: Date, limit: Int) -> Int { max(0, limit - used(now: now)) }

  public func isPaused(now: Date) -> Bool { (pausedUntil ?? .distantPast) > now }
}

public struct PostizKeyInvalid: Codable, Sendable, Equatable {
  public var at: Date
  public var message: String
}

extension Store {
  public func postizBudget() throws -> PostizBudget { try kv(PostizBudget.kvKey) ?? PostizBudget() }

  /// Takes one call from the shared budget (atomically across processes). False = don't call now.
  public func takePostizCall(_ kind: PostizCallKind, limit: Int) throws -> Bool {
    try db.transaction {
      var b = try postizBudget()
      let now = self.now
      b.calls = b.calls.filter { now.timeIntervalSince($0) < 3600 }
      if b.isPaused(now: now) { return false }
      guard limit - b.calls.count > kind.reserve else { return false }
      b.calls.append(now)
      try setKV(PostizBudget.kvKey, b)
      return true
    }
  }

  /// After a 429: no calls for 15 minutes.
  public func pausePostiz(for seconds: TimeInterval = PostizBudget.pauseAfter429) throws {
    try db.transaction {
      var b = try postizBudget()
      b.pausedUntil = now.addingTimeInterval(seconds)
      try setKV(PostizBudget.kvKey, b)
    }
  }

  public func postizKeyInvalid() throws -> PostizKeyInvalid? { try kv(PostizBudget.keyInvalidKey) }

  /// Returns true when the flag was newly set (the caller notifies once).
  @discardableResult
  public func setPostizKeyInvalid(_ message: String) throws -> Bool {
    try db.transaction {
      let was = try postizKeyInvalid() != nil
      try setKV(PostizBudget.keyInvalidKey, PostizKeyInvalid(at: now, message: message))
      return !was
    }
  }

  public func clearPostizKeyInvalid() throws {
    try db.run("DELETE FROM kv WHERE key=?", [PostizBudget.keyInvalidKey])
  }
}
