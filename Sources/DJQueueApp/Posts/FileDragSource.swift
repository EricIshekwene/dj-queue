import AppKit
import SwiftUI

/// Sits over a file link: a click runs `onClick` (reveal in Finder) and a drag takes every one of `urls` out of the app
/// as files, for Finder or a browser's upload box. SwiftUI's own drag carries one item, and a photo post's render is
/// one file per photo (round 21), so this hands AppKit one dragging item per file.
struct FileDragSource: NSViewRepresentable {
  let urls: [URL]
  let onClick: () -> Void

  final class Source: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onClick: () -> Void = {}
    private var down: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
      down = event
      dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
      guard !dragging, let down, !urls.isEmpty else { return }
      let a = down.locationInWindow, b = event.locationInWindow
      guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
      dragging = true
      let at = convert(a, from: nil)
      let items = urls.enumerated().map { i, url -> NSDraggingItem in
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // A small fanned stack, so several files read as several.
        let step = CGFloat(min(i, 4)) * 4
        item.setDraggingFrame(NSRect(x: at.x - 16 + step, y: at.y - 16 - step, width: 32, height: 32), contents: icon)
        return item
      }
      beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
      if !dragging, down != nil { onClick() }
      down = nil
      dragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
      down = nil
      dragging = false
    }
  }

  func makeNSView(context: Context) -> Source { Source() }

  func updateNSView(_ v: Source, context: Context) {
    v.urls = urls
    v.onClick = onClick
  }
}
