import Foundation

/// Every location the app reads or writes. Tests point these at a temp dir with
/// `DJQ_ROOT` (the "DJ Video" folder) and `DJQ_HOME` (app support, logs).
public struct Paths: Sendable {
  public var root: URL  // ~/Movies/DJ Video
  public var appSupport: URL  // ~/Library/Application Support/DJ Queue
  public var logs: URL  // ~/Library/Logs/DJ Queue
  public var launchAgents: URL  // ~/Library/LaunchAgents

  public init(root: URL, appSupport: URL, logs: URL, launchAgents: URL) {
    self.root = root; self.appSupport = appSupport; self.logs = logs; self.launchAgents = launchAgents
  }

  /// Why a run must not start: dev binaries only run on dev data, because opening the Store migrates it. `nil` means go.
  public static func devRunRefusal(executable: String, environment: [String: String]) -> String? {
    guard executable.contains("/.build/"), !hasDevEnvironment(environment) else { return nil }
    return "refused: a dev build needs DJQ_HOME and DJQ_ROOT, so it never opens the real database"
  }

  /// Both dev variables set: DJQ_HOME keeps the real database out, DJQ_ROOT keeps the real footage out.
  public static func hasDevEnvironment(_ environment: [String: String]) -> Bool {
    ["DJQ_HOME", "DJQ_ROOT"].allSatisfy { environment[$0]?.isEmpty == false }
  }

  public static var standard: Paths {
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    let root = env["DJQ_ROOT"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent("Movies/DJ Video")
    if let h = env["DJQ_HOME"] {
      let base = URL(fileURLWithPath: h)
      return Paths(root: root, appSupport: base.appendingPathComponent("support"),
                   logs: base.appendingPathComponent("logs"), launchAgents: base.appendingPathComponent("LaunchAgents"))
    }
    return Paths(root: root,
                 appSupport: home.appendingPathComponent("Library/Application Support/DJ Queue"),
                 logs: home.appendingPathComponent("Library/Logs/DJ Queue"),
                 launchAgents: home.appendingPathComponent("Library/LaunchAgents"))
  }

  public var sessions: URL { root.appendingPathComponent("Sessions") }
  /// Round 21: the Photos session folder. The app's copies of imported photos live in `Originals/<post id>/`, and photo
  /// renders in `Ready to Post/Shortform/` and `Posted/Shortform/` below it, like any session.
  public var photos: URL { root.appendingPathComponent("Photos") }
  public var appFolder: URL { root.appendingPathComponent("_app") }
  public var backups: URL { appFolder.appendingPathComponent("backups") }
  public var database: URL { appSupport.appendingPathComponent("queue.sqlite") }
  public var work: URL { appSupport.appendingPathComponent("work") }
  public var thumbs: URL { appSupport.appendingPathComponent("thumbs") }
  public var proxies: URL { appSupport.appendingPathComponent("proxies") }
  public var overlays: URL { appSupport.appendingPathComponent("overlays") }
  public var engineLog: URL { logs.appendingPathComponent("engine.log") }
  public var agentPlist: URL { launchAgents.appendingPathComponent("com.djlovd.queue.engine.plist") }

  public func ensure() throws {
    for d in [appSupport, logs, work, thumbs, proxies, overlays] {
      try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
  }
}

/// Injectable clock so the engine can be tested across days, sleeps and missed slots.
public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}
  public var now: Date { Date() }
}

public final class FixedClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  public init(_ d: Date) { value = d }
  public var now: Date { lock.withLock { value } }
  public func set(_ d: Date) { lock.withLock { value = d } }
  public func advance(_ s: TimeInterval) { lock.withLock { value = value.addingTimeInterval(s) } }
}

public enum Tools {
  public static func find(_ name: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
      let p = "\(dir)/\(name)"
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }
  public static var ffmpeg: String? { find("ffmpeg") }
  public static var ffprobe: String? { find("ffprobe") }
}

/// Local-calendar day keys ("YYYY-MM-DD") in the configured time zone.
public struct DayMath: Sendable {
  public let calendar: Calendar

  public init(tz: TimeZone, weekStartsOn: Int = 2) {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    c.firstWeekday = weekStartsOn
    calendar = c
  }

  public init(settings: Settings) { self.init(tz: settings.tz, weekStartsOn: settings.weekStartsOn) }

  public func key(_ d: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  public func date(_ key: String) -> Date {
    let p = key.split(separator: "-").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
  }

  /// Wall-clock time on a local day (DST-safe: 19:00 is 19:00 even on the day the clocks change).
  public func at(_ key: String, minutes: Int) -> Date {
    let day = minutes >= 0 ? addDays(key, minutes / 1440) : key
    let m = minutes >= 0 ? minutes % 1440 : 0
    let p = day.split(separator: "-").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: m / 60, minute: m % 60))!
  }

  public func addDays(_ key: String, _ n: Int) -> String {
    self.key(calendar.date(byAdding: .day, value: n, to: date(key))!)
  }

  public func weekStart(of d: Date) -> String {
    let start = calendar.dateInterval(of: .weekOfYear, for: d)!.start
    return key(start)
  }

  public func weekDays(_ weekStart: String) -> [String] { (0..<7).map { addDays(weekStart, $0) } }

  public func days(from a: String, to b: String) -> Int {
    calendar.dateComponents([.day], from: date(a), to: date(b)).day ?? 0
  }
}
