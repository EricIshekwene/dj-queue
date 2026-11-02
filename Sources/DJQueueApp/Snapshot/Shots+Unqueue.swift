import DJQCore
import SwiftUI

/// "Back to Edit" (formerly Remove from queue) + stage moves (prefix 5x): the Queue card's hover stage control and ⋯ menu, the
/// confirmation listing scheduled days, the toast, Edit's "Sent back from Queue" chip + "Send to Queue", the Week
/// card's stage control, the bulk back confirmation, Library's pill and the editor header. Holds made here are
/// undone by the last shot.
extension SnapshotShots {
  static var unqueueBatch: String?

  static func unqueue(_ c: SnapshotContext) -> [Shot] {
    func mode(_ m: AppModel, _ s: Screen, _ v: DSViewMode) {
      m.viewModes[s] = v
      m.screen = s
    }
    /// Two ready backlog clips sent back to Edit (once).
    func holdTwo(_ m: AppModel) -> [String] {
      if unqueueBatch == nil {
        let ids = m.ordered.suffix(2).map(\.id)
        unqueueBatch = (try? m.bulk.removeFromQueue(ids))?.batchId
      }
      m.refreshNow()
      return m.videos.filter(\.heldInEdit).map(\.id)
    }
    /// The first planned clip with in-flight posts (the confirmation then lists its days).
    func scheduled(_ m: AppModel) -> String? {
      m.queueClips.first { m.hasScheduledDays([$0.id]) && m.stageBlocker($0, .back) == nil }?.id
    }
    return [
      c.view("50-unqueue-queue-menu", width: 1180, height: 760) {
        let m = c.model
        SnapshotContext.resetUI(m)
        SampleData.pipelineRevert(m)
        mode(m, .queue, .wide)
        let v = m.queueClips.first { ClipStage.of($0) == .scheduled && m.stageBlocker($0, .back) == nil } ?? m.queueClips[0]
        SnapshotHover.id = v.id
        return AnyView(
          ZStack(alignment: .topTrailing) {
            QueueView(model: m).environment(\.screenGutter, 24)
            SnapshotMenuMock(items: [
              .init(icon: "bolt", title: "Post today"),
              .init(icon: "pin", title: "Pin to date…"),
              .init(icon: "forward.end", title: "Skip next"),
              .divider,
              .init(icon: "arrow.uturn.backward", title: m.stageBackTitle(v), help: m.stageBackHelp(v)),
              .init(icon: "arrow.forward", title: m.stageForwardTitle(v), help: m.stageForwardHelp(v)),
              .divider,
              .init(icon: "slider.horizontal.below.rectangle", title: "Open editor"),
              .divider,
              .init(icon: "minus.circle", title: "Exclude"),
            ])
            .padding(.top, 150).padding(.trailing, 60)
          })
      },
      c.main("51-unqueue-confirm") { m in
        SnapshotHover.id = nil
        mode(m, .queue, .wide)
        guard let id = scheduled(m) else { return }
        m.removeFromQueue([id])
        m.pendingBulk?.preview = try? m.bulk.removeFromQueue([id], dryRun: true)
      },
      c.main("52-unqueue-toast") { m in
        SnapshotHover.id = nil
        mode(m, .queue, .wide)
        m.show(DSToastModel(message: "Removed 2 from queue", detail: "Back in Edit · 1 scheduled day removed", tone: .success,
                            actionTitle: "Undo", action: {}, duration: 60))
      },
      c.main("53-edit-sent-back") { m in
        SnapshotHover.id = nil
        _ = holdTwo(m)
        mode(m, .edit, .wide)
        // Put the sent-back clips first so they're on screen.
        ListPrefs.shared.setStatus(.edit, EditFilter(kind: .heldInEdit, platform: nil).id)
      },
      c.main("54-week-card-stage") { m in
        m.screen = .week
        SnapshotHover.id = m.weekSlots.first { s in
          s.date >= m.todayKey && m.video(s.videoId).map { m.stageBlocker($0, .back) == nil } == true
        }?.videoId
      },
      c.main("55-queue-bulk-back") { m in
        SnapshotHover.id = nil
        mode(m, .queue, .wide)
        let ids = Array(m.queueClips.prefix(2).map(\.id) + m.queueClips.suffix(1).map(\.id))
        m.visibleIds[.queue] = m.queueClips.map(\.id)
        m.setSelection(ids, screen: .queue)
        m.stageBack(ids)
        m.pendingBulk?.preview = try? m.bulk.back(ids, dryRun: true)
      },
      c.main("56-library-sent-back") { m in
        SnapshotHover.id = nil
        _ = holdTwo(m)
        mode(m, .library, .wide)
      },
      c.main("57-editor-stage") { m in
        SnapshotHover.id = nil
        let held = holdTwo(m)
        if let id = held.first { m.openEditor(id) }
      },
      // Last: put the sample data back (the holds are one undoable batch).
      c.view("5z-unqueue-revert", width: 10, height: 10) {
        if let b = unqueueBatch { _ = try? c.model.bulk.undo(b, force: true) }
        unqueueBatch = nil
        SnapshotHover.id = nil
        for s in [Screen.edit, .queue, .library] { c.model.viewModes[s] = nil }
        c.model.refreshNow()
        return AnyView(Color.clear)
      },
    ]
  }
}

/// Snapshot-only stand-in for a native context menu (AppKit menus can't be captured with the window): the same
/// items, with each item's tooltip shown under it.
struct SnapshotMenuMock: View {
  struct Item: Identifiable {
    var icon = ""
    var title = ""
    var help: String? = nil
    var isDivider = false
    var id = UUID()
    static var divider: Item { Item(isDivider: true) }
  }

  let items: [Item]

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(items) { i in
        if i.isDivider {
          DSSeparator().padding(.vertical, 3)
        } else {
          VStack(alignment: .leading, spacing: 1) {
            Label(i.title, systemImage: i.icon).font(DS.type.callout).foregroundStyle(DS.color.text)
            if let h = i.help {
              Text(h).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).padding(.leading, 24)
            }
          }
          .padding(.horizontal, 8).padding(.vertical, 3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(i.title == "Back to Edit" ? DS.color.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    .padding(6)
    .frame(width: 320)
    .dsFloatingSurface(radius: DS.radius.md, elevation: DS.elevation.e3)
  }
}
