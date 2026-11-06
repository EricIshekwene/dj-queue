import AppKit
import SwiftUI

/// Renders every gallery page at 1440×900 in light and dark to `<dir>/ds-<nn>-<page>-<light|dark>.png`.
///
/// Entry: `DJQ_SNAPSHOT_GALLERY=1 DJQueueApp --snapshot <dir>` (hook in SnapshotRunner; 1x PNGs), or call
/// `await DSGallerySnapshot.run(outputDir:)` from another snapshot flow. `DJQ_SNAPSHOT_ONLY=<substring>` filters
/// pages; `DJQ_GALLERY_MEDIA=<folder>` supplies local covers/video (never committed).
@MainActor
enum DSGallerySnapshot {
  static func run(outputDir: String) async -> Int32 {
    if ProcessInfo.processInfo.environment["DJQ_HOVER_PROBE"] != nil { return await DSHoverProbe.run(outputDir: outputDir) }
    if ProcessInfo.processInfo.environment["DJQ_TOOLTIP_PROBE"] != nil { return await DSTooltipProbe.run(outputDir: outputDir) }
    if ProcessInfo.processInfo.environment["DJQ_TOOLTIP_PASS"] != nil { return await DSTooltipPass.run(outputDir: outputDir) }
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let media = DSGalleryMedia.load()
      var pages = DSGalleryPage.allCases
      if let only = ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_ONLY"] { pages = pages.filter { $0.rawValue.contains(only) } }
      for p in pages {
        // The list-header page is taller than a window: render it whole instead of clipping its lower half.
        try await render(AnyView(DSGallery(page: p, media: media)), size: CGSize(width: 1440, height: p == .lists ? 1560 : 900),
                         name: String(format: "ds-%02d-%@", p.number, p.rawValue), to: out)
        print("ds-gallery: \(p.rawValue)")
      }
      print("ds-gallery: wrote \(pages.count * 2) PNGs to \(out.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("ds-gallery failed: \(error)\n".utf8))
      return 1
    }
  }

  /// Renders any view in a real window (AppKit-backed controls draw correctly) in both appearances.
  static func render(_ view: AnyView, size: CGSize, name: String, to dir: URL) async throws {
    let hv = NSHostingView(rootView: view.frame(width: size.width, height: size.height).modifier(SnapshotActive(on: true)))
    hv.frame = NSRect(origin: .zero, size: size)
    let window = SnapshotWindow.make(hv.frame, [.borderless])
    window.contentView = hv
    window.isReleasedWhenClosed = false
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      window.orderBack(nil)
      try await Task.sleep(for: .milliseconds(suffix == "light" ? 1400 : 900))
      window.displayIfNeeded()
      // Default: AppKit draws the view tree (deterministic, works with the display asleep; no AVPlayer frames).
      // DJQ_SNAPSHOT_WINDOW=1 uses the window-server capture instead (shows playing video; needs an awake display).
      let useWindow = ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_WINDOW"] != nil
      let png = (useWindow ? WindowCapture.png(window) : nil) ?? cached(hv)
      try png?.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
    }
    window.orderOut(nil)
    window.close()
  }

  private static func cached(_ view: NSView) -> Data? {
    view.layoutSubtreeIfNeeded()
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}
