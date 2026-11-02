import AppKit
import DJQCore
import SwiftUI

/// Page-pass evidence (round 3, F5): `DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PASS=1 DJQueueApp --snapshot <dir>`.
///
/// For every screen (and the overlays), the REAL main window on a throwaway copy of the dev DB, in light and dark:
/// the first clip tile is drawn in its hover state (its overlay controls visible), one real tooltip panel is shown
/// on its first control, and every tooltip anchor in the window is numbered on the capture with a legend of what
/// each says (label · keys — disabled reason). Nothing is hovered with the user's pointer and the app never
/// activates. Also writes `<case>.json` (all anchors) and `summary.json` (counts per case).
@MainActor
enum DSTooltipPass {
  struct Case {
    var name: String
    var screen: Screen
    var mode: DSViewMode? = nil
    var setup: (AppModel) -> Void = { _ in }
  }

  static func run(outputDir: String) async -> Int32 {
    let out = URL(fileURLWithPath: outputDir)
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let model = try DSTooltipProbe.makeModel()
      let cases: [Case] = [
        Case(name: "01-score-grid", screen: .score, mode: .grid),
        Case(name: "02-score-single", screen: .score, mode: .single),
        Case(name: "03-edit-grid", screen: .edit, mode: .grid),
        Case(name: "04-edit-cards", screen: .edit, mode: .wide),
        Case(name: "05-queue-cards", screen: .queue, mode: .wide),
        Case(name: "06-queue-grid", screen: .queue, mode: .grid),
        Case(name: "07-queue-list", screen: .queue, mode: .list),
        Case(name: "08-week", screen: .week),
        Case(name: "09-today", screen: .today),
        Case(name: "10-library-grid", screen: .library, mode: .grid),
        Case(name: "11-posts", screen: .posts),
        Case(name: "12-health", screen: .health),
        Case(name: "13-settings", screen: .queue) { $0.showSettings = true },
        Case(name: "14-editor", screen: .queue) { m in if let id = m.queueList.first?.id { m.openEditor(id, in: m.queueList.map(\.id)) } },
        Case(name: "15-command-palette", screen: .queue) { $0.showPalette = true },
        Case(name: "16-edit-bulk-bar", screen: .edit, mode: .wide) { m in
          m.setSelection(Array(m.editList.prefix(3).map(\.id)), screen: .edit)
        },
        Case(name: "17-compact-sidebar", screen: .library, mode: .grid) { $0.sidebarCollapsed = true },
        Case(name: "18-confirm-rebuild-week", screen: .week) { m in m.rebuildWeek(m.weekStart) },
      ]
      let only = ProcessInfo.processInfo.environment["DJQ_SNAPSHOT_ONLY"]
      var summary: [[String: String]] = []
      let c = DSTooltipController.shared
      c.requireActiveApp = false
      let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      for k in cases where only.map({ k.name.contains($0) }) ?? true {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
          SnapshotContext.resetUI(model)
          DSClipCardDebug.hoverIds = []
          if let mode = k.mode { model.viewModes[k.screen] = mode }
          model.screen = k.screen
          k.setup(model)
          let w = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
          w.isReleasedWhenClosed = false
          w.appearance = NSAppearance(named: appearance)
          w.setFrameOrigin(NSPoint(x: screen.midX - 720, y: screen.midY - 450))
          w.orderBack(nil)
          try await Task.sleep(for: .milliseconds(1400))
          // Hover the first tile of the screen, then let it redraw.
          if let first = model.visibleIds[k.screen]?.first, model.editor == nil, !model.showSettings, !model.showPalette {
            DSClipCardDebug.hoverIds = [first]
            let s = model.screen
            model.screen = s == .library ? .health : .library
            try await Task.sleep(for: .milliseconds(50))
            model.screen = s
            try await Task.sleep(for: .milliseconds(900))
          }
          w.displayIfNeeded()
          // A media action's automatic tooltip (its Label title) sits inside the button's own explicit one: list the
          // explicit text; keep the automatic one only where it is the only tooltip.
          let found = DSTooltipProbe.anchors(in: w)
          let explicit = found.filter { $0.content.richLabel == nil }
          let anchors = found.filter { a in
            guard a.content.richLabel != nil, let r = a.visibleScreenRect else { return true }
            return !explicit.contains { $0.visibleScreenRect?.contains(CGPoint(x: r.midX, y: r.midY)) ?? false }
          }.sorted {
            let a = $0.visibleScreenRect!, b = $1.visibleScreenRect!
            return abs(a.maxY - b.maxY) > 6 ? a.maxY > b.maxY : a.minX < b.minX
          }
          // One real panel on the hovered tile's first control (else the first anchor in reading order).
          let tileAnchor = anchors.first { ($0.content.label ?? "").hasPrefix("Select for bulk") } ?? anchors.first
          if let t = tileAnchor { c.debugShow(t) }
          try await Task.sleep(for: .milliseconds(250))
          let image = DSTooltipProbe.captureImage(w, panel: c.debugPanelWindow)
          c.hide(resetGroup: true)
          let name = "\(k.name)-\(suffix)"
          if let image {
            try annotate(image, window: w, anchors: anchors, dark: appearance == .darkAqua)?
              .write(to: out.appendingPathComponent("\(name).png"))
          }
          if suffix == "light" {
            let rows = anchors.map { a -> [String: String] in
              let r = a.visibleScreenRect!
              return ["label": a.content.label ?? "", "shortcut": a.content.shortcut ?? "", "disabledReason": a.content.disabledReason ?? "",
                      "rich": a.content.richLabel == nil ? "" : "title of an icon-only Label",
                      "at": "\(Int(r.minX - w.frame.minX)),\(Int(w.frame.maxY - r.maxY)) \(Int(r.width))×\(Int(r.height))"]
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
              .write(to: out.appendingPathComponent("\(k.name).json"))
            summary.append(["case": k.name, "anchors": "\(anchors.count)", "distinct": "\(Set(anchors.map(legendText)).count)"])
          }
          print("tooltip-pass: \(name) · \(anchors.count) tooltips")
          w.orderOut(nil)
          w.close()
          model.editor = nil
          model.pendingConfirm = nil
        }
      }
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("summary.json"))
      DSClipCardDebug.hoverIds = []
      return 0
    } catch {
      FileHandle.standardError.write(Data("tooltip-pass failed: \(error)\n".utf8))
      return 1
    }
  }

  static func legendText(_ a: DSTooltipAnchorView) -> String {
    let c = a.content
    var t = c.label ?? (c.richLabel != nil ? "(the action's own label, shown as its tooltip)" : "")
    if let k = c.shortcut, !k.isEmpty, c.disabledReason == nil { t += "  [\(k)]" }
    if let r = c.disabledReason, !r.isEmpty { t += t.isEmpty ? r : " — disabled: \(r)" }
    return t
  }

  /// The capture with a numbered dot on every tooltip anchor and a legend column (one number per distinct text).
  static func annotate(_ img: CGImage, window w: NSWindow, anchors: [DSTooltipAnchorView], dark: Bool) -> Data? {
    let scale = CGFloat(img.width) / max(1, w.frame.width)
    var numbers: [String: Int] = [:]
    var order: [String] = []
    for a in anchors {
      let t = legendText(a)
      if numbers[t] == nil { order.append(t); numbers[t] = order.count }
    }
    let legendW: CGFloat = 470
    let lineH: CGFloat = 17
    let H = max(CGFloat(img.height) / scale, CGFloat(order.count) * lineH + 60)
    let size = NSSize(width: w.frame.width + legendW, height: H)
    let bg = dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    let fg = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.08, alpha: 1)
    let out = NSImage(size: size, flipped: true) { _ in
      bg.setFill()
      NSRect(origin: .zero, size: size).fill()
      NSGraphicsContext.current?.cgContext.saveGState()
      // CGImage draws y-up; flip locally.
      let ctx = NSGraphicsContext.current!.cgContext
      ctx.translateBy(x: 0, y: CGFloat(img.height) / scale)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
      ctx.restoreGState()
      let font = NSFont.systemFont(ofSize: 9, weight: .bold)
      for a in anchors {
        guard let r = a.visibleScreenRect, let n = numbers[legendText(a)] else { continue }
        let p = CGPoint(x: r.minX - w.frame.minX, y: w.frame.maxY - r.maxY)
        let dot = NSRect(x: p.x - 3, y: p.y - 3, width: 15, height: 13)
        NSColor.systemPink.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: dot, xRadius: 6, yRadius: 6).fill()
        ("\(n)" as NSString).draw(in: dot.insetBy(dx: 1, dy: 0), withAttributes: [.font: font, .foregroundColor: NSColor.white])
      }
      var y: CGFloat = 16
      let title = "\(anchors.count) tooltips · \(order.count) distinct" as NSString
      title.draw(at: CGPoint(x: w.frame.width + 16, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg])
      y += 24
      for (i, t) in order.enumerated() {
        let s = "\(i + 1). \(t)" as NSString
        s.draw(in: NSRect(x: w.frame.width + 16, y: y, width: legendW - 28, height: lineH),
               withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: fg])
        y += lineH
      }
      return true
    }
    guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}
