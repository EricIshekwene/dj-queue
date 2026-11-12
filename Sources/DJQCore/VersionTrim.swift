import Foundation

/// Round 30 (Eric, 2026-11-12: "when I change a clip's trim while editing v3, only v3 changes; v1 and v2 keep their own
/// start and end"). Where a trim change goes: the version being edited (`Version.trimIn/Out`, its own trim) or the clip
/// (`Edit.trimIn/Out`, shared by every version without its own).
public enum TrimScope: String, Codable, Sendable, Hashable, CaseIterable {
  case version, clip
}

/// Round 30: reading and writing per-version trims outside the editor (`djq trim`, the data repair). A version with its
/// own trim renders, posts, gets its cover and has its length checked on that trim, and its texts count from its start
/// (`EditResolver.resolve(_:video:defaults:version:)`). Without one it follows the clip's trim.
public enum VersionTrims {
  /// The shortest trim (seconds), the same floor the resolver keeps.
  public static let minimum = 0.3

  public struct TrimProblem: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ d: String) { description = d }
  }

  /// Why `start…end` can't be a trim of `v` (nil = it can).
  public static func problem(start: Double, end: Double, video v: Video) -> String? {
    if v.isPhoto { return "a photo post has no trim" }
    if start < 0 { return "--in can't be before 0 s" }
    if v.duration > 0, end > v.duration + 0.001 {
      return String(format: "--out can't be past the end of the file (%.2f s)", v.duration)
    }
    if end - start < minimum { return String(format: "the trim must be at least %.1f s long (in %.2f, out %.2f)", minimum, start, end) }
    return nil
  }

  /// Gives version `number` its own trim. `start`/`end` nil keep that side as the version shows it now (its own trim,
  /// else the clip's). Its per-platform trims are kept only where they still fit inside. Returns the saved version.
  @discardableResult
  public static func setOwn(store: Store, videoId: String, version number: Int, start: Double?, end: Double?) throws -> Version {
    guard let v = try store.video(id: videoId) else { throw TrimProblem("no video \(videoId)") }
    var ver = try stored(store, v, number)
    let now = try store.resolvedEdit(videoId: videoId, version: number)
    let a = start ?? now.trimIn, b = end ?? now.trimOut
    if let why = problem(start: a, end: b, video: v) { throw TrimProblem(why) }
    ver.trimIn = a
    ver.trimOut = b
    if let p = ver.platformTrims {
      let kept = p.filter { $0.value.start >= a - 0.001 && $0.value.end <= b + 0.001 }
      ver.platformTrims = kept.isEmpty ? nil : kept
    }
    try store.save(ver, videoId: videoId)
    return ver
  }

  /// Version `number` follows the clip's trim again (its own trim and its per-platform trims are dropped).
  public static func clearOwn(store: Store, videoId: String, version number: Int) throws {
    guard let v = try store.video(id: videoId) else { throw TrimProblem("no video \(videoId)") }
    var ver = try stored(store, v, number)
    guard ver.hasOwnTrim || ver.platformTrims != nil else { return }
    ver.clearOwnTrim()
    try store.save(ver, videoId: videoId)
  }

  /// Sets the clip's trim (every version without its own uses it). nil keeps that side as it is. A side equal to the
  /// default is stored as the default, so it reads "default" again.
  public static func setClip(store: Store, videoId: String, start: Double?, end: Double?) throws {
    guard let v = try store.video(id: videoId) else { throw TrimProblem("no video \(videoId)") }
    var e = try store.edit(videoId: videoId)
    let now = try store.resolvedEdit(videoId: videoId, version: 0)  // no version 0: the clip's own trim
    let a = start ?? now.trimIn, b = end ?? now.trimOut
    if let why = problem(start: a, end: b, video: v) { throw TrimProblem(why) }
    let def = try store.settings().defaults.trim(for: v)
    e.trimIn = abs(a - def.start) < 0.001 ? nil : a
    e.trimOut = abs(b - def.end) < 0.001 ? nil : b
    try store.save(e, videoId: videoId)
  }

  /// The clip's trim back to the default (markers ± extra seconds, or the whole file), and its per-platform trims
  /// cleared. Versions with their own trim keep it.
  public static func resetClip(store: Store, videoId: String) throws {
    guard try store.video(id: videoId) != nil else { throw TrimProblem("no video \(videoId)") }
    var e = try store.edit(videoId: videoId)
    e.trimIn = nil
    e.trimOut = nil
    e.platformTrims = [:]
    try store.save(e, videoId: videoId)
  }

  /// Drops versions' own trims: every one (`inside` nil), or only those that don't fit in `0…inside` seconds (a made
  /// video whose audio got shorter). Returns how many versions changed.
  @discardableResult
  public static func dropOwn(store: Store, videoId: String, keepingInside inside: Double? = nil) throws -> Int {
    var n = 0
    for var ver in try store.versions(videoId: videoId) where ver.hasOwnTrim || ver.platformTrims != nil {
      if let inside, let a = ver.trimIn, let b = ver.trimOut, a < inside, b <= inside { continue }
      ver.clearOwnTrim()
      try store.save(ver, videoId: videoId)
      n += 1
    }
    return n
  }

  /// The stored version `number` (v1 when it has no row yet). A version that doesn't exist is an error.
  static func stored(_ store: Store, _ v: Video, _ number: Int) throws -> Version {
    let all = try store.versions(videoId: v.id)
    if let x = all.first(where: { $0.number == number }) { return x }
    if number == 1 { return Version(number: 1) }
    throw TrimProblem("\(v.tag) has no v\(number) (it has \(([1] + all.map(\.number)).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted().map { "v\($0)" }.joined(separator: ", ")))")
  }
}
