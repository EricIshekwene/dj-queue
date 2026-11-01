import AppKit
import DJQCore
import SwiftUI

/// One process: engine loop + menu-bar item + (on demand) the main window (ARCHITECTURE.md → Process model).
///
/// - `DJQueueApp --agent`     launched by the LaunchAgent: menu bar only, engine running.
/// - `DJQueueApp`             plain launch: engine running and the main window open.
/// - `DJQueueApp --snapshot <dir>`  renders every screen (light + dark) to PNGs from a throwaway DB copy, then quits.
@main
struct DJQueueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var host = AppHost.shared

  var body: some Scene {
    MenuBarExtra(isInserted: $host.menuBarInserted) {
      MenuBarRoot(host: host)
    } label: {
      MenuBarLabel(host: host)
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { WindowManager.shared.showSettings() }.keyboardShortcut(",")
      }
      CommandGroup(replacing: .newItem) {
        Button("Open DJ Queue") { WindowManager.shared.showMain() }.keyboardShortcut("0")
      }
    }
  }
}

enum LaunchMode: Equatable {
  case normal, agent
  case snapshot(String)

  static var current: LaunchMode {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--snapshot") {
      return .snapshot(i + 1 < a.count ? a[i + 1] : FileManager.default.currentDirectoryPath + "/snapshots")
    }
    return a.contains("--agent") ? .agent : .normal
  }
}

/// Owns the store, the model and the in-process engine.
@MainActor
@Observable
final class AppHost {
  static let shared = AppHost()

  let mode = LaunchMode.current
  var menuBarInserted: Bool
  var model: AppModel?
  var startupError: String?
  private(set) var engineHost: EngineHost?
  private var refreshTimer: Timer?
  private var observer: NSObjectProtocol?

  private init() {
    if case .snapshot = mode { menuBarInserted = false } else { menuBarInserted = true }
    if case .snapshot = mode { return }
    RenderServices.factory = { Renderer(store: $0) }
    do {
      Log.shared.configure(.standard)
      let store = try Store(paths: .standard)
      model = AppModel(store: store)
    } catch {
      startupError = "Can't open the database: \(error)"
      Log.shared.error(startupError!)
    }
  }

  func startEngine() {
    guard let model, engineHost == nil else { return }
    let h = EngineHost(model: model)
    engineHost = h
    model.engineInProcess = h.start()
    if model.engineInProcess {
      // Only the process that owns the engine may tick it; others ask via ChangeSignal.
      model.engine = h.engine
      h.engine.onTick = { _ in Task { @MainActor in model.refresh() } }
    }
    startRefreshing()
  }

  func startRefreshing() {
    guard let model else { return }
    // 5 s while a window or the menu-bar popover is open, else 30 s (menu-bar badge only). Loads run off-main.
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in model.timerRefresh(visible: WindowManager.shared.anyVisible || model.popoverVisible) }
    }
    observer = DistributedNotificationCenter.default().addObserver(forName: .init(ChangeSignal.name), object: nil, queue: .main) { _ in
      Task { @MainActor in model.refresh() }
    }
    // A second launch of the app (or a first-run install) asks the running instance to show its window.
    openObserver = DistributedNotificationCenter.default().addObserver(forName: .init(Self.openSignal), object: nil, queue: .main) { _ in
      Task { @MainActor in WindowManager.shared.showMain() }
    }
  }

  static let openSignal = "com.djlovd.queue.open"
  private var openObserver: NSObjectProtocol?

  /// Decision Q28: run at login. Only for the installed app (~/Applications/DJ Queue.app) and never in dev runs
  /// (DJQ_HOME set); asked once.
  var shouldOfferLaunchAgent: Bool {
    guard let model, mode == .normal else { return false }
    let env = ProcessInfo.processInfo.environment
    let installed = Bundle.main.bundleURL.standardizedFileURL.path
      == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DJ Queue.app").path
    return installed && env["DJQ_HOME"] == nil && env["DJQ_ROOT"] == nil
      && !LaunchAgent.isInstalled(paths: model.store.paths)
      && !UserDefaults.standard.bool(forKey: "djq.askedLaunchAgent")
  }

  /// Installs + loads the agent; the agent instance takes over the engine and window, this one quits.
  func installLaunchAgent() {
    guard let model else { return }
    UserDefaults.standard.set(true, forKey: "djq.askedLaunchAgent")
    model.agentError = nil
    do {
      if let o = openObserver { DistributedNotificationCenter.default().removeObserver(o) }
      engineHost?.stop()
      try LaunchAgent.install(appPath: Bundle.main.bundlePath, paths: model.store.paths, load: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        DistributedNotificationCenter.default().postNotificationName(.init(Self.openSignal), object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        NSApp.terminate(nil)
      }
    } catch {
      // LaunchAgent.install refuses dev environments and copies outside ~/Applications: say why, in place.
      model.agentError = "Couldn't install the background engine: \(error.localizedDescription)"
      model.show(model.agentError!, error: true)
      model.engineInProcess = engineHost?.start() ?? false
      if model.engineInProcess, let e = engineHost?.engine { model.engine = e }
    }
  }

  func stop() { engineHost?.stop() }

  /// Notification action routing (APP.N). Post now / Shift plan / Skip go through `PostActions.perform`
  /// (the engine already shifted the platform's plan when it marked the post missed).
  func handleNotification(action: String, key: String, postId: String?, videoId: String?, text: String?) {
    guard let model else { return }
    model.refreshNow()
    let post = postId.flatMap { id in model.posts.first { $0.id == id } }
    let act = NotificationAction(rawValue: action)
    switch act {
    case .postNow, .shiftPlan, .skip:
      guard let postId else { break }
      do {
        try model.postActions.perform(act!, postId: postId)
        ChangeSignal.post()
        model.refresh()
        if act == .postNow {
          model.highlightPostId = postId
          WindowManager.shared.showMain(screen: .today)
        }
      } catch {
        UserNotifier.shared.deliver(AppNotification(key: "error:\(UUID().uuidString)", title: "Couldn't \(action.replacingOccurrences(of: "_", with: " "))",
                                                    body: error.localizedDescription, actions: [.open], postId: postId))
      }
    case .markPosted:
      guard let post else { break }
      let url = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      do {
        guard !url.isEmpty else { throw EditorlessError("Paste the post URL") }
        try model.postActions.markPosted(postId: post.id, url: url, at: Date())
        ChangeSignal.post()
        model.refresh()
      } catch {
        // Invalid or missing URL: open the sheet with what was typed and the error visible.
        model.markPostedPrefill = url
        model.markPostedTarget = post
        WindowManager.shared.showMain(screen: .today)
      }
    case .open, .none:
      model.highlightPostId = postId
      let screen: Screen
      if key.hasPrefix("alert.approve") || key.hasPrefix("alert.weekly") {
        screen = .week
        model.goToNextWeek()
      } else if key.hasPrefix("alert.record") {
        screen = .queue
      } else if key.hasPrefix("problem:") || key.hasPrefix("renderfail:") || post?.state.isProblem == true {
        screen = .posts
        model.postsSelection = postId
      } else if key.hasPrefix("invalid:"), let videoId {
        screen = .queue
        model.queueSelection = [videoId]
      } else {
        screen = .today
      }
      WindowManager.shared.showMain(screen: screen)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    if case .snapshot = AppHost.shared.mode { return }
    UserNotifier.shared.setUp()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let host = AppHost.shared
    switch host.mode {
    case .snapshot(let dir):
      NSApp.setActivationPolicy(.prohibited)
      Task { @MainActor in
        let code = await SnapshotRunner.run(outputDir: dir)
        exit(code)
      }
    case .agent:
      NSApp.setActivationPolicy(.accessory)
      host.startEngine()
    case .normal:
      host.startEngine()
      WindowManager.shared.showMain()
      if host.shouldOfferLaunchAgent { host.model?.offerLaunchAgent = true }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    WindowManager.shared.showMain()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { AppHost.shared.stop() }
  }
}

/// Main window and settings window are AppKit-managed hosting windows so the process can switch between
/// `.accessory` (menu bar only) and `.regular` (Dock + menu) as windows open and close.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
  static let shared = WindowManager()
  private var main: NSWindow?
  private var settings: NSWindow?

  var anyVisible: Bool { [main, settings].contains { $0?.isVisible == true && $0?.occlusionState.contains(.visible) == true } }

  func showMain(screen: Screen? = nil) {
    guard let model = AppHost.shared.model else {
      showStartupError()
      return
    }
    if let screen { model.screen = screen }
    if main == nil {
      let w = Self.makeMainWindow(model: model)
      w.delegate = self
      w.setFrameAutosaveName("DJQueueMain")
      main = w
    }
    NSApp.setActivationPolicy(.regular)
    main?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func showSettings(section: SettingsSection? = nil) {
    guard let model = AppHost.shared.model else { return }
    if settings == nil {
      let w = Self.makeSettingsWindow(model: model, section: section ?? .platforms)
      w.delegate = self
      w.setFrameAutosaveName("DJQueueSettings")
      settings = w
    }
    NSApp.setActivationPolicy(.regular)
    settings?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  static func makeMainWindow(model: AppModel, make: @MainActor (NSRect, NSWindow.StyleMask) -> NSWindow = WindowManager.plainWindow) -> NSWindow {
    let hc = NSHostingController(rootView: MainWindowView(model: model).modifier(SnapshotActive(on: model.frozen)))
    hc.sceneBridgingOptions = [.toolbars, .title]
    let w = make(NSRect(x: 0, y: 0, width: 1440, height: 900), [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    w.contentViewController = hc
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.title = "DJ Queue"
    w.toolbarStyle = .unified
    w.minSize = NSSize(width: 1100, height: 700)
    w.setContentSize(NSSize(width: 1440, height: 900))
    w.isReleasedWhenClosed = false
    w.center()
    return w
  }

  static func plainWindow(_ r: NSRect, _ style: NSWindow.StyleMask) -> NSWindow {
    NSWindow(contentRect: r, styleMask: style, backing: .buffered, defer: false)
  }

  static func makeSettingsWindow(model: AppModel, section: SettingsSection,
                                 make: @MainActor (NSRect, NSWindow.StyleMask) -> NSWindow = WindowManager.plainWindow) -> NSWindow {
    let hc = NSHostingController(rootView: SettingsView(model: model, initial: section).modifier(SnapshotActive(on: model.frozen)))
    hc.sceneBridgingOptions = [.toolbars, .title]
    let w = make(NSRect(x: 0, y: 0, width: 900, height: 640), [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    w.contentViewController = hc
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.title = "Settings"
    w.toolbarStyle = .unified
    w.setContentSize(NSSize(width: 900, height: 640))
    w.minSize = NSSize(width: 760, height: 520)
    w.isReleasedWhenClosed = false
    w.center()
    return w
  }

  private func showStartupError() {
    let a = NSAlert()
    a.messageText = "DJ Queue can't start"
    a.informativeText = AppHost.shared.startupError ?? "Unknown error"
    a.runModal()
  }

  func windowWillClose(_ notification: Notification) {
    DispatchQueue.main.async {
      let open = [self.main, self.settings].compactMap { $0 }.contains { $0.isVisible }
      if !open, case .snapshot = AppHost.shared.mode {} else if !open { NSApp.setActivationPolicy(.accessory) }
    }
  }
}

/// Snapshot windows are never key (the app stays in the background), so render controls in their active state.
struct SnapshotActive: ViewModifier {
  let on: Bool
  func body(content: Content) -> some View {
    if on { content.environment(\.controlActiveState, .key) } else { content }
  }
}
