import DJQCore
import Foundation

/// `djq overlay list|add|set|remove` (round 16): the texts on a clip. Number 1 is the first text, which lives in the
/// fields `djq text` writes; the rest are `Version.moreText`. The edits themselves are `TextLayers`, shared with the
/// editor, so the two can't drift.
enum OverlayCommand {
  /// The options that shape a text, read before the positional arguments are.
  struct Options {
    var start: Double??, end: Double??
    var x: Double?, y: Double?
    var style: TextStyle?, align: TextAlign?
    var size: Double?
    var color: String??, background: String??
    var font: TextFont??
    var opacity: Double??, tracking: Double??

    /// nil = not given, .some(nil) = "default".
    private static func cleared<T>(_ raw: String?, _ parse: (String) throws -> T) rethrows -> T?? {
      guard let raw else { return nil }
      return raw == "default" ? .some(nil) : .some(try parse(raw))
    }

    private static func number(_ raw: String, _ name: String, _ range: ClosedRange<Double>) throws -> Double {
      guard let d = Double(raw), range.contains(d) else {
        throw CLIError("\(name) must be a number \(range.lowerBound)–\(range.upperBound) (got \(raw))")
      }
      return d
    }

    private static func colour(_ raw: String, _ name: String) throws -> String {
      guard let h = TextLook.hex(raw) else { throw CLIError("\(name) must be a colour like #FF3B30 (got \(raw))") }
      return h
    }

    static func parse() throws -> Options {
      var o = Options()
      let seconds = 0...Double(86_400)
      o.start = try cleared(option("--start")) { try number($0, "--start", seconds) }
      o.end = try cleared(option("--end")) { try number($0, "--end", seconds) }
      o.x = try option("--x").map { try number($0, "--x", 0...1) }
      o.y = try option("--y").map { try number($0, "--y", 0...1) }
      o.size = try option("--size").map { try number($0, "--size", 8...400) }
      o.style = try option("--style").map { raw in
        guard let s = TextStyle(rawValue: raw) else {
          throw CLIError("--style must be \(TextStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got \(raw))")
        }
        return s
      }
      o.align = try option("--align").map { raw in
        guard let a = TextAlign(rawValue: raw) else {
          throw CLIError("--align must be \(TextAlign.allCases.map(\.rawValue).joined(separator: ", ")) (got \(raw))")
        }
        return a
      }
      o.color = try cleared(option("--color")) { try colour($0, "--color") }
      o.background = try cleared(option("--background")) { try colour($0, "--background") }
      o.font = try cleared(option("--font")) { raw in
        guard let f = TextFont(rawValue: raw) else {
          throw CLIError("--font must be \(TextFont.allCases.map(\.rawValue).joined(separator: ", ")) (got \(raw))")
        }
        return f
      }
      o.opacity = try cleared(option("--opacity")) { try number($0, "--opacity", TextLook.opacityRange) }
      o.tracking = try cleared(option("--tracking")) { try number($0, "--tracking", TextLook.trackingRange) }
      return o
    }

    func apply(to l: inout TextLayer) throws {
      if let start { l.start = start }
      if let end { l.end = end }
      if let s = l.start, let e = l.end, e <= s {
        throw CLIError(String(format: "the text would end (%.2f s) before it starts (%.2f s)", e, s))
      }
      if let x { l.posX = x }
      if let y { l.posY = y }
      if let size { l.size = size }
      if let style { l.style = style }
      if let align { l.align = align }
      var look = l.look ?? TextLook()
      if let color { look.color = color }
      if let background { look.accent = background }
      if let font { look.font = font }
      if let opacity { look.opacity = opacity }
      if let tracking { look.tracking = tracking }
      l.look = look.normalized
    }
  }

  static func run(_ store: Store, _ settings: Settings, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json")
    let number = try option("--version").map { try intArg($0, "--version", 1...99) } ?? 1
    let options = try Options.parse()
    let sub = try arg(0, "overlay command (list, add, set or remove)")
    guard ["list", "add", "set", "remove"].contains(sub) else { throw CLIError("unknown overlay command \(sub)\n\n\(usage)") }
    let v = try resolveVideo(store, try arg(1, "video id"))

    let saved = try store.versions(videoId: v.id)
    let existing = Set(saved.map(\.number))
    if number > 1, !existing.contains(number), !existing.contains(number - 1) { throw CLIError("v\(number - 1) doesn't exist yet") }
    var chain = saved
    if !existing.contains(1) { chain.insert(Version(number: 1), at: 0) }
    if !chain.contains(where: { $0.number == number }) { chain.append(Version(number: number)) }
    let ver = chain.first { $0.number == number }!
    let r = VersionResolver.resolve(chain, number: number, settings: settings, video: v)
    let trim = try store.resolvedEdit(videoId: v.id, settings: settings).trim()

    func target(_ i: Int) throws -> TextLayer {
      let ref = try arg(i, "text number or id")
      guard let l = TextLayers.layer(ref, in: r) else {
        throw CLIError("no text \(ref) on \(v.tag) (it has \(r.allLayers.count); djq overlay list \(short(v.id)))")
      }
      return l
    }
    func finish(_ next: Version, _ message: String) throws -> Int32 {
      try store.save(next, videoId: v.id)
      wrote = true
      let after = try store.resolvedVersion(videoId: v.id, number: number, settings: settings) ?? r
      if json { try printJSON(AgentAPI.overlays(after, trimDuration: trim.duration)); return 0 }
      print(message)
      if after.noText { print("  No text is on, so nothing shows until it's off (djq text)") }
      return 0
    }

    switch sub {
    case "list":
      let list = AgentAPI.overlays(r, trimDuration: trim.duration)
      if json { try printJSON(list); return 0 }
      print("\(v.tag) v\(number): \(list.count) text\(list.count == 1 ? "" : "s")\(r.noText ? " (No text is on: none show)" : "")")
      for o in list { print("  " + line(o)) }

    case "add":
      let text = try arg(2, "text")
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError("write the text to add") }
      var l = TextLayers.new(text: text, like: r.firstLayer)
      try options.apply(to: &l)
      guard let next = TextLayers.adding(l, to: ver, resolved: r) else {
        throw CLIError("\(v.tag) already has \(TextLayers.maxCount) texts, the most a clip can have")
      }
      return try finish(next, "\(v.tag) v\(number): added text \(r.allLayers.count + 1) [\(l.id)] \"\(Captions.oneLine(text))\"")

    case "set":
      let l = try target(2)
      var thrown: Error?
      let next = TextLayers.updating(l.id, in: ver, resolved: r) { x in
        if args.count > 3 { x.text = args[3] }
        do { try options.apply(to: &x) } catch { thrown = error }
      }
      if let thrown { throw thrown }
      return try finish(next, "\(v.tag) v\(number): updated text \(l.id == TextLayer.firstId ? "1" : l.id)")

    default:  // remove
      let l = try target(2)
      guard let next = TextLayers.removing(l.id, from: ver, resolved: r) else {
        throw CLIError("that's the only text on \(v.tag): use djq text \(short(v.id)) --none for no text, or --default to follow the Title")
      }
      return try finish(next, l.id == TextLayer.firstId
        ? "\(v.tag) v\(number): removed the first text, the next one took its place"
        : "\(v.tag) v\(number): removed text \(l.id)")
    }
    return 0
  }

  private static func line(_ o: AgentAPI.OverlayOut) -> String {
    let when: String
    if let a = o.shows_from, let b = o.shows_to {
      when = String(format: "%.1f–%.1f s", a, b)
    } else {
      when = "not drawn"
    }
    var parts = [o.style, String(format: "%.0f", o.size), o.align, String(format: "at %.2f, %.2f", o.x, o.y)]
    if let c = o.color { parts.append("colour \(c)") }
    if let b = o.background { parts.append("background \(b)") }
    if let f = o.font { parts.append(f) }
    if let a = o.opacity { parts.append(String(format: "opacity %.2f", a)) }
    if let t = o.tracking { parts.append(String(format: "tracking %.2f", t)) }
    return "\(pad(String(o.number), 3))\(pad(o.id, 10))\(pad(when, 14))\"\(Captions.oneLine(o.text))\"  \(parts.joined(separator: " · "))"
  }
}
