import CoreGraphics
import CryptoKit
import Foundation

// Round 4 S6 ("lists show the edited clip"): the preview identity of a clip, the overlay key and the
// cost-capped overlay cache. Pure and testable; the app keeps one `PreviewStampTable` per refresh.

/// Edit times per clip, read in two queries. `stamp(for:version:)` is the clip's preview identity: it changes when
/// anything that changes how the clip looks as posted changes — its edit (crop, aspect, trim, cover), a version
/// at or below the one shown (text, style, timing), New-clip defaults (`defaultsGeneration`), or the clip's own
/// row fields that defaults read (title for "text = Title", kind for "no text on talking clips", markers for the
/// default trim, the file itself).
public struct PreviewStampTable: Sendable, Equatable {
  /// `edits.updated_at` per video id.
  public var editAt: [String: Double]
  /// `versions.updated_at` per video id and version number.
  public var versionAt: [String: [Int: Double]]
  /// Changes whenever New-clip defaults change (and, with the "same as last crop" anchor, the last crop).
  public var defaultsGeneration: String

  public init(editAt: [String: Double] = [:], versionAt: [String: [Int: Double]] = [:], defaultsGeneration: String = "") {
    self.editAt = editAt
    self.versionAt = versionAt
    self.defaultsGeneration = defaultsGeneration
  }

  /// The preview stamp of `v` shown at text `version` (1 for every list; the post's version for Posts/Week).
  /// `Int.max` covers every version (change detection).
  public func stamp(for v: Video, version: Int = 1) -> String {
    let vs = (versionAt[v.id] ?? [:]).filter { $0.key <= version }.sorted { $0.key < $1.key }
    let versions = vs.map { "\($0.key)@\($0.value)" }.joined(separator: ",")
    let raw = "\(v.id)|e\(editAt[v.id] ?? 0)|\(versions)|\(defaultsGeneration)|\(Self.videoPart(v))"
    return PreviewKeys.short(raw)
  }

  /// The clip-row fields a preview depends on. (Not the cached source size: filling it in changes no pixels.)
  static func videoPart(_ v: Video) -> String {
    func d(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "-" }
    return [v.file, v.fingerprint ?? "", d(v.duration), d(v.markedStart), d(v.markedEnd), d(v.start), d(v.end), d(v.grace),
            v.titleText ?? "", v.tag, v.kind.rawValue, v.type.rawValue, v.missing ? "m" : ""].joined(separator: "|")
  }
}

extension Store {
  /// Reads the stamp table (two small queries plus settings). Cheap enough for every refresh.
  public func previewStampTable() throws -> PreviewStampTable {
    var t = PreviewStampTable()
    for r in try db.query("SELECT video_id, updated_at FROM edits") {
      if let id = r.string("video_id") { t.editAt[id] = r.double("updated_at") ?? 0 }
    }
    for r in try db.query("SELECT video_id, number, updated_at FROM versions") {
      if let id = r.string("video_id") { t.versionAt[id, default: [:]][r.int("number") ?? 1] = r.double("updated_at") ?? 0 }
    }
    let s = try settings()
    t.defaultsGeneration = PreviewKeys.defaultsGeneration(s.defaults,
                                                          lastCrop: s.defaults.cropAnchor == .lastUsed ? try lastCropCentre() : nil)
    return t
  }
}

public enum PreviewKeys {
  /// 16 hex characters of SHA-256.
  public static func short(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Identity of the New-clip defaults (deterministic: JSON with sorted keys and sorted sets).
  public static func defaultsGeneration(_ d: NewClipDefaults, lastCrop: CGPoint?) -> String {
    var obj = (try? JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(d))) as? [String: Any] ?? [:]
    for (k, v) in obj { if let a = v as? [String] { obj[k] = a.sorted() } }
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    let crop = lastCrop.map { String(format: "%.4f,%.4f", $0.x, $0.y) } ?? "-"
    return short(String(decoding: data, as: UTF8.self) + "|" + crop)
  }

  /// Identity of the on-video text as drawn (`TextOverlay.image`): text, style, size, position, alignment and the
  /// output aspect. "none" when there is no text. Timing is not part of it (it never changes the pixels).
  public static func textKey(_ v: ResolvedVersion?, aspect: Aspect) -> String {
    guard let v, v.hasText else { return "none" }
    let raw = [v.text, v.style.rawValue, String(format: "%.3f", v.size), String(format: "%.4f", v.posX),
               String(format: "%.4f", v.posY), v.align.rawValue, aspect.rawValue].joined(separator: "\u{1F}")
    return short(raw)
  }

  /// When the text shows, in seconds from the start of the posted clip (the trim) — the renderer's rule:
  /// an empty or inverted window means the whole clip. Nil when there is no text.
  public static func textWindow(_ v: ResolvedVersion?, trimDuration dur: Double) -> ClosedRange<Double>? {
    guard let v, v.hasText, dur > 0 else { return nil }
    var ts = max(0, v.textStart ?? 0)
    var te = min(dur + 1, v.textEnd ?? (dur + 1))
    if te <= ts || ts >= dur { ts = 0; te = dur + 1 }
    return ts...te
  }
}

/// A thread-safe least-recently-used cache with a total cost cap (bytes). Unlike `NSCache` it evicts at once and
/// deterministically, so "stays under the cap" holds at every moment (S6: the overlay cache, ~64 MB).
public final class CostCappedCache<Key: Hashable, Value>: @unchecked Sendable {
  public let costLimit: Int
  private let lock = NSLock()
  private var items: [Key: (value: Value, cost: Int, tick: UInt64)] = [:]
  private var tick: UInt64 = 0
  private var totalCost = 0

  public init(costLimit: Int) { self.costLimit = costLimit }

  public func value(_ key: Key) -> Value? {
    lock.withLock {
      guard var e = items[key] else { return nil }
      tick += 1
      e.tick = tick
      items[key] = e
      return e.value
    }
  }

  /// Stores `value`; evicts the least recently used items until the total is within the cap. An item larger than
  /// the cap is not stored.
  public func set(_ value: Value, for key: Key, cost: Int) {
    lock.withLock {
      if let old = items.removeValue(forKey: key) { totalCost -= old.cost }
      guard cost <= costLimit else { return }
      tick += 1
      items[key] = (value, cost, tick)
      totalCost += cost
      while totalCost > costLimit, let lru = items.min(by: { $0.value.tick < $1.value.tick }) {
        totalCost -= lru.value.cost
        items.removeValue(forKey: lru.key)
      }
    }
  }

  public func remove(where match: (Key) -> Bool) {
    lock.withLock {
      for k in items.keys where match(k) { totalCost -= items[k]!.cost; items.removeValue(forKey: k) }
    }
  }

  public var count: Int { lock.withLock { items.count } }
  public var totalCostNow: Int { lock.withLock { totalCost } }
}
