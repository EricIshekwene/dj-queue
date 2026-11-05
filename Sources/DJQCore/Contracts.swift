import Foundation

// Shared interfaces between the render engine, the background engine and the UI.
// Implementations: Renderer (Render/), Engine/Planner/PostActions/ManualPublisher/Doctor (Engine/).

// MARK: Rendering

public protocol RenderService: AnyObject, Sendable {
  /// Hash of everything that changes the output file (edit, resolved version, scope, render settings).
  func editHash(videoId: String, versionNo: Int, platform: Platform?) throws -> String
  /// "all", or the platform's rawValue when the edit has a per-platform trim for it.
  func scope(videoId: String, platform: Platform?) throws -> String
  /// A finished render matching the current hash, or nil.
  func currentRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render?
  /// Returns a matching finished render, rendering now if needed (blocking; call off the main thread).
  @discardableResult
  func ensureRender(videoId: String, versionNo: Int, platform: Platform?) throws -> Render
  /// Marks renders not in `keep` deleted and removes their files from Ready to Post (spec §7).
  func deleteRenders(except keep: Set<String>) throws
}

// MARK: Publishing (spec §2: queue, editor and tracking must not change when Postiz arrives)

public struct PreparedPost: Sendable, Hashable {
  public var postId: String
  public var platform: Platform
  public var fileURL: URL
  public var coverURL: URL?
  public var caption: String
  public var title: String?  // YouTube
  public var uploadURL: URL
  public init(postId: String, platform: Platform, fileURL: URL, coverURL: URL?, caption: String, title: String?, uploadURL: URL) {
    self.postId = postId; self.platform = platform; self.fileURL = fileURL; self.coverURL = coverURL
    self.caption = caption; self.title = title; self.uploadURL = uploadURL
  }
}

public enum PublishStatus: Sendable, Hashable {
  case waitingForUser  // manual: Eric posts and marks done
  case scheduled(externalId: String)
  case posted(url: String, at: Date)
  case failed(ErrorType, String)
}

public protocol Publisher: AnyObject, Sendable {
  var name: String { get }  // "manual" | "postiz"
  func prepare(postId: String) throws -> PreparedPost
  func submit(_ post: PreparedPost) throws -> PublishStatus
  func status(postId: String) throws -> PublishStatus
}

// MARK: Notifications (the app implements this with UNUserNotificationCenter; the CLI logs)

public enum NotificationAction: String, Sendable, CaseIterable {
  case postNow = "post_now", shiftPlan = "shift_plan", skip, open, markPosted = "mark_posted"
}

public struct AppNotification: Sendable, Hashable {
  public var key: String  // dedupe key; each key is delivered once
  public var title: String
  public var body: String
  public var critical: Bool
  public var actions: [NotificationAction]
  public var postId: String?
  public var videoId: String?
  public init(key: String, title: String, body: String, critical: Bool = false, actions: [NotificationAction] = [],
              postId: String? = nil, videoId: String? = nil) {
    self.key = key; self.title = title; self.body = body; self.critical = critical; self.actions = actions
    self.postId = postId; self.videoId = videoId
  }
}

public protocol Notifier: AnyObject, Sendable {
  func deliver(_ n: AppNotification)
}

public final class LogNotifier: Notifier, @unchecked Sendable {
  public private(set) var delivered: [AppNotification] = []
  private let lock = NSLock()
  public init() {}
  public func deliver(_ n: AppNotification) {
    lock.withLock { delivered.append(n) }
    Log.shared.info("notify: \(n.title) — \(n.body)")
  }
}

// MARK: Shared value types for the UI

public struct Runway: Sendable, Hashable, Codable {
  public var approvedDays: Int  // days covered by the approved plan from today
  public var readyDays: Int  // ready-but-unplanned videos ÷ posts per day
  public var totalDays: Int  // approved + ready + needs-edit (scored) ÷ posts per day
  public init(approvedDays: Int, readyDays: Int, totalDays: Int) {
    self.approvedDays = approvedDays; self.readyDays = readyDays; self.totalDays = totalDays
  }
}

public enum Severity: String, Sendable, Codable, Comparable {
  case info, warning, error
  public static func < (a: Severity, b: Severity) -> Bool {
    let o: [Severity] = [.info, .warning, .error]
    return o.firstIndex(of: a)! < o.firstIndex(of: b)!
  }
}

public struct DoctorFinding: Sendable, Codable, Hashable, Identifiable {
  public var id: String  // stable check id, e.g. "files.missing"
  public var severity: Severity
  public var title: String
  public var detail: String
  public var where_: [String]  // ids / paths
  public var fix: String
  public init(id: String, severity: Severity, title: String, detail: String, where_: [String], fix: String) {
    self.id = id; self.severity = severity; self.title = title; self.detail = detail; self.where_ = where_; self.fix = fix
  }
  enum CodingKeys: String, CodingKey { case id, severity, title, detail, where_ = "where", fix }
}

public struct DoctorReport: Sendable, Codable, Hashable {
  public var generatedAt: Date
  public var findings: [DoctorFinding]
  public var passed: [String]  // check ids that passed
  public init(generatedAt: Date, findings: [DoctorFinding], passed: [String]) {
    self.generatedAt = generatedAt; self.findings = findings; self.passed = passed
  }
}

public enum CopyrightResolution: Sendable, Hashable {
  case reuploadAnyway(versionNo: Int?)  // new attempt, optionally a new version
  case skipPlatform
  case accept
}

/// Posted by any process after it changes the database, so the app/engine refresh promptly.
public enum ChangeSignal {
  public static let name = "com.djlovd.queue.changed"
  /// `DJQ_NO_SIGNAL=1` (tests, snapshots and scripted runs): `post` and `observe` stay inside this process, so a dev run can
  /// never make the installed DJ Queue reload or tick. The app's and engine's own observers aren't part of those runs.
  public static var isLocal: Bool { ProcessInfo.processInfo.environment["DJQ_NO_SIGNAL"] == "1" }

  public static func post() {
    if isLocal {
      // Never from the main queue: an observer on `.main` makes the poster wait for it, which deadlocks on the main actor.
      DispatchQueue.global(qos: .userInitiated).async { NotificationCenter.default.post(name: .init(name), object: nil) }
    } else {
      DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
  }

  /// Calls `block` on the main queue after each signal; remove the token from `center`.
  public static func observe(_ block: @escaping @Sendable () -> Void) -> (center: NotificationCenter, token: NSObjectProtocol) {
    let center: NotificationCenter = isLocal ? .default : DistributedNotificationCenter.default()
    return (center, center.addObserver(forName: .init(name), object: nil, queue: .main) { _ in block() })
  }
}
