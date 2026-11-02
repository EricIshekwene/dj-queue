import DJQCore
import SwiftUI

/// Long-form clips in the Library (DESIGN-v2 §6.6): 16:9 tiles with a "Long-form" chip and **Mark posted**
/// (Grid / Cards views), or compact rows (List view). Selection follows the shared rules (checkbox, ⇧ range,
/// ⌘ toggle; a plain click opens the quick look, or toggles while something is selected). Posted status is visible:
/// a green "Posted" chip plus a link to the YouTube URL.
struct LongformSection: View {
  @Bindable var model: AppModel
  let videos: [Video]
  let mode: DSViewMode
  var showsHeader = true
  let onOpen: (Video) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      if showsHeader { LibrarySectionLabel(title: "Long-form", count: videos.count) }
      if mode == .list {
        VStack(spacing: 0) {
          ForEach(videos) { v in LongformRow(model: model, video: v, ordered: ids, onOpen: onOpen) }
        }
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 300), spacing: DS.space.md, alignment: .top)],
                  alignment: .leading, spacing: DS.space.xl) {
          ForEach(videos) { v in LongformTile(model: model, video: v, ordered: ids, onOpen: onOpen) }
        }
      }
    }
    .padding(.bottom, DS.space.md)
  }

  private var ids: [String] { videos.map(\.id) }
}

/// Shared click rule for long-form items (same as ClipCollection's).
@MainActor
private func longformTap(_ model: AppModel, _ v: Video, ordered: [String], onOpen: (Video) -> Void) {
  let flags = NSEvent.modifierFlags
  var m: EventModifiers = []
  if flags.contains(.shift) { m.insert(.shift) }
  if flags.contains(.command) { m.insert(.command) }
  guard model.select(v.id, modifiers: m, ordered: ordered, screen: .library) == .plainClick else { return }
  if model.selected(.library).isEmpty { onOpen(v) } else { model.toggleSelection(v.id, screen: .library) }
}

/// Status chip + Mark posted / link for one long-form clip.
private struct LongformStatus: View {
  @Bindable var model: AppModel
  let video: Video
  var compact = false

  var body: some View {
    // Tiles (260–300 pt) can't fit both chips and "Mark posted" on one line, so the button gets its own row there.
    if compact || video.longformURL != nil {
      HStack(spacing: 6) { chips; Spacer(minLength: DS.space.xs); action }
    } else {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        HStack(spacing: 6) { chips }
        action
      }
    }
  }

  @ViewBuilder private var chips: some View {
    if model.libraryIsMissing(video) {
      DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark", help: "The source file moved or was deleted — Health › Doctor relinks it")
    } else {
      DSBadge("Long-form", style: .outline, help: "A full set — uploaded by hand, never queued")
      DSBadge(model.libraryStateChip(video).text, style: model.libraryStateChip(video).style, help: model.libraryStateChip(video).tooltip)
    }
  }

  @ViewBuilder private var action: some View {
    if let u = video.longformURL, let url = URL(string: u) {
      DSIconButton("arrow.up.right.square", tooltip: "Open on YouTube · \(u)", size: .sm) { NSWorkspace.shared.open(url) }
    } else {
      DSButton("Mark posted", icon: "checkmark.circle", variant: .outline, size: .sm,
               disabledReason: video.excluded ? "Excluded — include it first" : nil,
               tooltip: "Paste the YouTube link; the file moves to Posted/Longform") {
        BrowseUI.shared.longformTargets = [video]
      }
      .fixedSize()
    }
  }
}

struct LongformTile: View {
  @Bindable var model: AppModel
  let video: Video
  let ordered: [String]
  let onOpen: (Video) -> Void
  @State private var hovering = false

  var body: some View {
    let selected = model.isSelected(video.id, in: .library)
    let selectionMode = !model.selected(.library).isEmpty
    VStack(alignment: .leading, spacing: 8) {
      BrowsePoster(model: model, video: video, aspect: 16 / 9, radius: DS.radius.md)
        .overlay(alignment: .topLeading) {
          if hovering || selectionMode || selected {
            DSCheckbox(isOn: selected, size: 20, shape: .circle, onMedia: true) { model.toggleSelection(video.id, screen: .library) }
              .dsTooltip(selected ? "Deselect" : "Select")
              .padding(8)
          }
        }
        .overlay(alignment: .bottomLeading) {
          Text(Fmt.duration(video.duration)).font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Color.black.opacity(0.63), in: Capsule())
            .padding(8)
        }
        .overlay {
          if selected { RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.text, lineWidth: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { longformTap(model, video, ordered: ordered, onOpen: onOpen) }
        .dsTooltip("Click for quick look · ⌘-click to select")
      VStack(alignment: .leading, spacing: 4) {
        Text(model.displayName(video)).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(1)
        Text(meta).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        LongformStatus(model: model, video: video).padding(.top, 2)
      }
      .padding(.horizontal, 2)
    }
    .onHover { hovering = $0 }
    .contextMenu { LongformMenu(model: model, video: video, onOpen: onOpen) }
    .dsAnimation(DS.motion.hover, value: hovering)
  }

  private var meta: String {
    [model.sessionName(video), video.part.map { "Part \($0)" }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
  }
}

struct LongformRow: View {
  @Bindable var model: AppModel
  let video: Video
  let ordered: [String]
  let onOpen: (Video) -> Void
  @State private var hovering = false

  var body: some View {
    let selected = model.isSelected(video.id, in: .library)
    let showCheck = hovering || selected || !model.selected(.library).isEmpty
    HStack(spacing: DS.space.sm) {
      DSCheckbox(isOn: selected, size: 20, shape: .circle) { model.toggleSelection(video.id, screen: .library) }
        .opacity(showCheck ? 1 : 0.0001)
        .dsTooltip(selected ? "Deselect" : "Select")
      BrowsePoster(model: model, video: video, width: 48, height: 27)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.displayName(video)).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
        Text("\(model.sessionName(video)) · \(Fmt.duration(video.duration))").font(DS.type.caption)
          .foregroundStyle(DS.color.textSecondary).lineLimit(1)
      }
      .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
      LongformStatus(model: model, video: video, compact: true).frame(width: 330)
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: DS.size.listRow)
    .background(selected ? DS.color.selected : hovering ? DS.color.hover : .clear,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .overlay(alignment: .bottom) { if !(selected || hovering) { DSSeparator().padding(.horizontal, DS.space.xs) } }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { longformTap(model, video, ordered: ordered, onOpen: onOpen) }
    .contextMenu { LongformMenu(model: model, video: video, onOpen: onOpen) }
    .dsTooltip("Click for quick look · ⌘-click to select")
  }
}

private struct LongformMenu: View {
  @Bindable var model: AppModel
  let video: Video
  let onOpen: (Video) -> Void

  var body: some View {
    Button("Quick look", systemImage: "eye") { onOpen(video) }
    if let u = video.longformURL, let url = URL(string: u) {
      Button("Open on YouTube", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
      Button("Copy YouTube link", systemImage: "link") { model.copy(u); model.show("Link copied") }
    } else {
      Button("Mark posted…", systemImage: "checkmark.circle") { BrowseUI.shared.longformTargets = [video] }
    }
    Divider()
    // AppModel.setExcluded is journaled (toast · Undo, ⌘Z).
    Button(video.excluded ? "Include (post it again)" : "Exclude (stop posting it)", systemImage: video.excluded ? "plus.circle" : "minus.circle") {
      model.setExcluded([video.id], !video.excluded)
    }
  }
}
