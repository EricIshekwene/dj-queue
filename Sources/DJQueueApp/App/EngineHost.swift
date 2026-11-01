import AppKit
import DJQCore
import UserNotifications

/// Runs the engine in this process, guarded by a file lock so only one process per database ticks.
@MainActor
final class EngineHost {
  let engine: Engine
  let renderer: Renderer
  let publisher: ManualPublisher
  private var lockFD: Int32 = -1
  private let store: Store

  init(model: AppModel) {
    store = model.store
    renderer = model.renderer
    publisher = model.publisher
    engine = Engine(store: model.store, renderer: renderer, publisher: publisher, notifier: UserNotifier.shared)
  }

  /// Returns false when another process already holds the engine lock (its heartbeats still drive the UI).
  @discardableResult
  func start() -> Bool {
    let path = store.paths.appSupport.appendingPathComponent("engine.lock").path
    lockFD = open(path, O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      Log.shared.warn("engine lock held by another process; this process only shows the UI")
      return false
    }
    engine.start()
    return true
  }

  func stop() {
    guard lockFD >= 0 else { return }
    engine.stop()
    flock(lockFD, LOCK_UN)
    close(lockFD)
    lockFD = -1
  }
}

/// `Notifier` backed by UNUserNotificationCenter (APP.N). Copyright/critical notifications are time-sensitive
/// and carry a red badge image so they read as loud.
final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
  static let shared = UserNotifier()

  /// UNUserNotificationCenter needs an app bundle; a bare `swift run` binary only logs.
  /// `DJQ_NOTIFY=0` turns delivery off for dev runs (no permission prompt).
  private let enabled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    && ProcessInfo.processInfo.environment["DJQ_NOTIFY"] != "0"
  private var registered = Set<String>()
  private let lock = NSLock()

  func setUp() {
    guard enabled else { return }
    let c = UNUserNotificationCenter.current()
    c.delegate = self
    c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
      if let err { Log.shared.warn("notifications not authorised: \(err)") } else if !ok { Log.shared.warn("notifications declined") }
    }
    register([.postNow, .shiftPlan, .skip])
    register([.markPosted, .skip])
    register([.open])
  }

  func deliver(_ n: AppNotification) {
    Log.shared.info("notify: \(n.title) — \(n.body)")
    guard enabled else { return }
    let content = UNMutableNotificationContent()
    content.title = n.critical ? "⛔︎ " + n.title : n.title
    content.body = n.body
    content.sound = .default
    content.interruptionLevel = n.critical ? .timeSensitive : .active
    content.threadIdentifier = n.critical ? "djq.critical" : "djq"
    content.categoryIdentifier = register(n.actions)
    var info: [String: String] = [:]
    if let p = n.postId { info["postId"] = p }
    if let v = n.videoId { info["videoId"] = v }
    content.userInfo = info
    if n.critical, let a = Self.criticalAttachment() { content.attachments = [a] }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.key, content: content, trigger: nil)) { err in
      if let err { Log.shared.error("notify failed: \(err)") }
    }
  }

  @discardableResult
  private func register(_ actions: [NotificationAction]) -> String {
    let id = actions.isEmpty ? "djq.none" : "djq." + actions.map(\.rawValue).joined(separator: "+")
    let isNew: Bool = lock.withLock { registered.insert(id).inserted }
    guard enabled, isNew else { return id }
    let un: [UNNotificationAction] = actions.map { a in
      switch a {
      case .postNow: UNNotificationAction(identifier: a.rawValue, title: "Post now", options: [.foreground])
      case .shiftPlan: UNNotificationAction(identifier: a.rawValue, title: "Shift plan", options: [])
      case .skip: UNNotificationAction(identifier: a.rawValue, title: "Skip", options: [.destructive])
      case .open: UNNotificationAction(identifier: a.rawValue, title: "Open", options: [.foreground])
      case .markPosted:
        UNTextInputNotificationAction(identifier: a.rawValue, title: "Mark posted", options: [],
                                      textInputButtonTitle: "Save", textInputPlaceholder: "Paste the post URL")
      }
    }
    let cat = UNNotificationCategory(identifier: id, actions: un, intentIdentifiers: [], options: [])
    let c = UNUserNotificationCenter.current()
    c.getNotificationCategories { existing in
      c.setNotificationCategories(existing.filter { $0.identifier != id }.union([cat]))
    }
    return id
  }

  private static func criticalAttachment() -> UNNotificationAttachment? {
    let img = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
      NSColor.systemRed.setFill()
      NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill()
      let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
      if let s = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: s.size, flipped: false) { rr in
          s.draw(in: rr)
          NSColor.white.set()
          rr.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(in: NSRect(x: (r.width - s.size.width) / 2, y: (r.height - s.size.height) / 2, width: s.size.width, height: s.size.height))
      }
      return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("djq-critical-\(UUID().uuidString).png")
    guard (try? png.write(to: url)) != nil else { return nil }
    return try? UNNotificationAttachment(identifier: "critical", url: url)
  }

  // MARK: UNUserNotificationCenterDelegate

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? NotificationAction.open.rawValue : response.actionIdentifier
    let text = (response as? UNTextInputNotificationResponse)?.userText
    let postId = info["postId"] as? String, videoId = info["videoId"] as? String
    DispatchQueue.main.async {
      AppHost.shared.handleNotification(action: action, postId: postId, videoId: videoId, text: text)
      completionHandler()
    }
  }
}
