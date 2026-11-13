import DJQCore
import Foundation

/// `djq trim` (round 30): which seconds of the clip file each version posts. With `--version N` it sets that version's
/// own trim (only that version changes; its texts count from its own start); without, the clip's trim, which every
/// version without its own uses. Each change is one `djq bulk undo` step.
enum TrimCommand {
  static let usage = """
      trim <video> [--json]                                      each version's trim (its own, or the clip's)
      trim <video> --in S --out S [--version N] [--json]         set the clip's trim, or version N's own (either side alone keeps the other)
      trim <video> --default [--version N] [--json]              the clip's trim back to the default (markers ± extra seconds) and its
                                                                 per-platform trims cleared; with --version, v N follows the clip's trim again
    """

  struct Out: Encodable {
    var video_id: String
    var changed: Bool
    var batch_id: String?
    var trims: [AgentAPI.VersionTrimOut]
  }

  static func run(_ store: Store, _ settings: Settings, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json"), toDefault = flag("--default")
    let number = try option("--version").map { try intArg($0, "--version", 1...99) }
    func seconds(_ name: String) throws -> Double? {
      try option(name).map { raw in
        guard let d = Double(raw), d.isFinite else { throw CLIError("\(name) must be seconds, e.g. 23.16 (got \(raw))") }
        return d
      }
    }
    let start = try seconds("--in"), end = try seconds("--out")
    guard let first = args.first else { throw CLIError("usage:\n\(usage)") }
    if args.count > 1 { throw CLIError("unexpected \(args[1])\n\nusage:\n\(usage)") }
    let v = try resolveVideo(store, first)
    if v.isPhoto { throw CLIError("\(v.tag) is a photo post: it has no trim") }
    if toDefault && (start != nil || end != nil) { throw CLIError("--default takes no --in or --out") }

    var batch: String?
    var changed = false
    if toDefault || start != nil || end != nil {
      let r = try BulkActions(store: store).record("trim", ids: [v.id], params: [
        "version": number.map(String.init) ?? "clip", "in": start.map { String($0) } ?? "", "out": end.map { String($0) } ?? "",
        "default": toDefault ? "1" : "",
      ]) {
        do {
          switch (number, toDefault) {
          case (let n?, true): try VersionTrims.clearOwn(store: store, videoId: v.id, version: n)
          case (nil, true): try VersionTrims.resetClip(store: store, videoId: v.id)
          case (let n?, false): try VersionTrims.setOwn(store: store, videoId: v.id, version: n, start: start, end: end)
          case (nil, false): try VersionTrims.setClip(store: store, videoId: v.id, start: start, end: end)
          }
        } catch let e as VersionTrims.TrimProblem {
          throw CLIError(e.description)
        }
      }
      batch = r.batchId
      changed = !r.changed.isEmpty
      wrote = changed
    }

    let trims = try AgentAPI.versionTrims(v.id, store: store, settings: try store.settings())
    if json {
      try printJSON(Out(video_id: v.id, changed: changed, batch_id: batch, trims: trims))
      return 0
    }
    if toDefault || start != nil || end != nil {
      print(changed ? "\(v.tag): \(number.map { "v\($0)" } ?? "the clip's trim") changed" : "\(v.tag): nothing changed")
    } else {
      print("\(v.tag) [\(short(v.id))]")
    }
    let edit = try store.edit(videoId: v.id)
    for t in trims { print("  " + describe(t)) }
    if !edit.platformTrims.isEmpty, trims.contains(where: { !$0.own }) {
      let list = edit.platformTrims.sorted { $0.key.rawValue < $1.key.rawValue }
        .map { "\($0.key.displayName) \(time($0.value.start))–\(time($0.value.end))" }.joined(separator: ", ")
      print("  clip's per-platform trims: \(list)")
    }
    if let batch { print("  undo: djq bulk undo \(short(batch))") }
    return 0
  }

  static func time(_ s: Double) -> String { EditorLogic.time(s, tenths: true) }

  /// "v3  0:23.2–0:46.9  23.7 s  own trim"
  static func describe(_ t: AgentAPI.VersionTrimOut) -> String {
    let whose = t.own ? "own trim" : t.clip_default ? "clip's trim (default)" : "clip's trim"
    let platforms = t.own && !t.platform_trims.isEmpty
      ? " · " + t.platform_trims.sorted { $0.key < $1.key }.map { "\($0.key) \(time($0.value.start))–\(time($0.value.end))" }.joined(separator: ", ")
      : ""
    return "v\(t.version)  \(time(t.trim_in))–\(time(t.trim_out))  \(String(format: "%.1f s", t.duration))  \(whose)\(platforms)"
  }

  /// The trim line `djq overlay list` prints for one version.
  static func describe(_ re: ResolvedEdit, version: Int) -> String {
    let whose = re.hasVersionTrim ? "its own trim" : re.isDefault(.trimIn) && re.isDefault(.trimOut) ? "the clip's trim (default)" : "the clip's trim"
    return "trim \(time(re.trimIn))–\(time(re.trimOut)) (\(String(format: "%.1f s", re.trimOut - re.trimIn)), \(whose)); times count from its start"
  }
}
