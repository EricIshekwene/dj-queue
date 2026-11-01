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
    model.engine = h.engine
    model.engineInProcess = h.start()
    startRefreshing()
  }

  func startRefreshing() {
    guard let model else { return }
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in model.refresh() }
    }
    observer = DistributedNotificationCenter.default().addObserver(forName: .init(ChangeSignal.name), object: nil, queue: .main) { _ in
      Task { @MainActor in model.refresh() }
    }
  }

  func stop() { engineHost?.stop() }

  /// Notification action routing (APP.N): Post now / Shift plan / Skip / Mark posted / Open.
  func handleNotification(action: String, postId: String?, videoId: String?, text: String?) {
    guard let model else { return }
    model.refresh()
    let post = postId.flatMap { id in model.posts.first { $0.id == id } }
    switch NotificationAction(rawValue: action) {
    case .postNow:
      if let post {
        model.highlightPostId = post.id
        WindowManager.shared.showMain(screen: .today)
      } else if let videoId {
        model.postToday(videoId)
        WindowManager.shared.showMain(screen: .today)
      }
    case .shiftPlan:
      model.pushPlan(days: 1)
    case .skip:
      if let post { model.skip(post) }
    case .markPosted:
      if let post, let url = text?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
        model.markPosted(post, url: url, at: Date())
      } else if let post {
        model.markPostedTarget = post
        WindowManager.shared.showMain(screen: .today)
      }
    case .open, .none:
      model.highlightPostId = postId
      WindowManager.shared.showMain(screen: post?.state.isProblem == true ? .posts : .today)
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
