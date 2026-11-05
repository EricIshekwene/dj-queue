import AppKit
import DJQCore
import SwiftUI

// MARK: - 5 Surfaces & overlays

struct GallerySurfaces: View {
  var body: some View {
    HStack(alignment: .top, spacing: DS.space.xl) {
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Card", note: "r.lg · e1 · header / content / footer") {
          HStack(alignment: .top, spacing: DS.space.sm) {
            GCell("Default") { card(.outline) }
            GCell("Hover", forced: .hover) { card(.outline, interactive: true) }
            GCell("Selected") { card(.outline, selected: true) }
          }
        }
        GSection("Attention card", note: "replaces full-width bars") {
          VStack(spacing: 8) {
            DSAttentionCard(title: "2 posts need attention", message: "Instagram copyright · X failed", tone: .danger, actionTitle: "Review", action: {})
            DSAttentionCard(title: "Queue running low", message: "Scheduled through Tue 10 Nov", tone: .warning, actionTitle: "Go to Edit",
                            onDismiss: {}, action: {})
          }
          .frame(width: 560)
        }
        GSection("Toolbar", note: "52 pt · transparent · one primary") {
          DSToolbar("Queue", subtitle: "41 · next Thu 5 Nov") {
            EmptyView()
          } trailing: {
            GState(DSViewMode.wide) { DSViewModeSwitcher(mode: $0, size: .sm) }
            DSIconButton("ellipsis", tooltip: "More", size: .sm) {}
            DSButton("Send to Queue", variant: .primary, size: .sm, shortcut: "⌘↩") {}
          }
          .dsSurface(DS.color.background, radius: DS.radius.lg)
          .frame(width: 560)
        }
        GSection("Bulk bar", note: "capsule · e2 · ≤4 labelled actions · More · primary") {
          DSBulkBar(count: 4, onClear: {}) {
            Button {} label: { Label("Post today", systemImage: "bolt") }.dsForcedState(.hover)
            Button {} label: { Label("Exclude", systemImage: "eye.slash") }
          } trailing: {
            DSButton("More", trailingIcon: "chevron.down", variant: .ghost) {}
            DSButton("Pin to days…", variant: .primary) {}
          }
        }
        GSection("Toasts") {
          VStack(alignment: .leading, spacing: 8) {
            DSToast(toast: DSToastModel(message: "Updated 9 clips", tone: .success, actionTitle: "Undo", action: {}), onDismiss: {})
            DSToast(toast: DSToastModel(message: "Couldn't render", detail: "ffmpeg exited with code 1", tone: .danger), onDismiss: {})
          }
        }
      }
      .frame(width: 560)
      VStack(alignment: .leading, spacing: DS.space.lg) {
        HStack(alignment: .top, spacing: DS.space.lg) {
          GSection("Sidebar") {
            VStack(alignment: .leading, spacing: 2) {
              DSSidebarItem("Score", icon: "scope", count: 12, isSelected: true) {}
              DSSidebarItem("Edit", icon: "pencil", count: 9) {}.dsForcedState(.hover)
              DSSidebarItem("Queue", icon: "list.bullet", count: 41) {}
              DSSidebarItem("Today", icon: "sun.max", count: 3, countStyle: .attention) {}
              DSEyebrow("Browse").padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
              DSSidebarItem("Posts", icon: "paperplane", count: 2, countStyle: .danger) {}
              DSSidebarItem("Health", icon: "heart", dot: .success) {}
            }
            .padding(6).frame(width: 240).dsSurface(DS.color.sidebar, radius: DS.radius.lg, border: DS.color.border)
          }
          GSection("Menu / popover") {
            DSPopoverSurface(width: 236) {
              DSMenuList(items: [
                .label("Clip"),
                DSMenuItem(title: "Open editor", icon: "slider.horizontal.3", shortcut: "⌘E"),
                DSMenuItem(title: "Pin to date…", icon: "pin"),
                DSMenuItem(title: "Post today", icon: "bolt", disabledReason: "Not rendered"),
                .separator,
                DSMenuItem(title: "Worst → best", isChecked: true),
                DSMenuItem(title: "Best → worst"),
                .separator,
                DSMenuItem(title: "Exclude", icon: "eye.slash", isDestructive: true),
              ], forcedHoverIndex: 1)
            }
          }
        }
        GSection("Confirmation sheet", note: "e3 · 480 · lists what will change") {
          DSDialog("Send 9 clips to the Queue?", description: "Applies your new-clip defaults. ⌘Z undoes the whole batch.",
                   icon: "wand.and.stars", onClose: {}) {
            DSChangeList(changes: [
              .init(field: "Crop", value: "Default (centre)"),
              .init(field: "Caption", value: "Template “DJ set”"),
              .init(field: "Overlay text", value: "Title"),
            ])
          } footer: {
            DSButton("Cancel", variant: .ghost) {}
            DSButton("Send to Queue", variant: .primary) {}
          }
          .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
        }
        HStack(alignment: .top, spacing: DS.space.lg) {
          GSection("Filled card") { card(.filled) }
          GSection("Elevated card") { card(.elevated) }
        }
      }
    }
  }

  private func card(_ v: DSCardVariant, interactive: Bool = false, selected: Bool = false) -> some View {
    DSCard(variant: v, padding: DS.space.sm, isSelected: selected, interactive: interactive) {
      VStack(alignment: .leading, spacing: 10) {
        DSCardHeader("Render queue", description: "2 clips waiting") {
          DSStatusDot(tone: .success, size: 7)
        }
        DSProgress(value: 0.6)
        DSCardFooter(note: "~3 min") { DSButton("Open", variant: .outline, size: .sm) {} }
      }
    }
    .frame(width: 176)
  }
}

// MARK: - 6 Clip cards

struct GalleryClips: View {
  let media: DSGalleryMedia
  var autoplay = ProcessInfo.processInfo.environment["DJQ_GALLERY_AUTOPLAY"] != nil

  var body: some View {
    let clips = DSGallerySamples.clips(media, autoplayVideo: autoplay)
    HStack(alignment: .top, spacing: DS.space.xl) {
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Cards", note: "Edit/Queue default · 132 tall · r.lg · e1 · max 880") {
          VStack(spacing: DS.space.xs) {
            DSClipCard(clips[0], mode: .wide, config: .init(autoplay: autoplay, showsDragHandle: true), onToggleSelect: {}) { queueActions }
            DSClipCard(clips[1], mode: .wide, config: .init(autoplay: false, showsDragHandle: true), onToggleSelect: {}) { queueActions }
              .dsForcedState(.hover)
            DSClipCard(clips[2], mode: .wide, isSelected: true, config: .init(autoplay: false), onToggleSelect: {}, onAcceptSuggestion: { _ in }) {
              DSButton("Open editor", variant: .outline, size: .sm) {}
              DSIconButton("ellipsis", tooltip: "More", size: .sm) {}
            }
            DSClipCard(clips[4], mode: .wide, config: .init(autoplay: false), onToggleSelect: {}) {
              DSIconButton("ellipsis", tooltip: "More", size: .sm) {}
            }
          }
        }
        GSection("List", note: "row 52 · hairlines · hover fill · poster only") {
          VStack(spacing: 0) {
            DSClipCard(clips[3], mode: .list, config: .init(autoplay: false), onToggleSelect: {}) { rowActions }
            DSClipCard(clips[0], mode: .list, config: .init(autoplay: false), onToggleSelect: {}) { rowActions }.dsForcedState(.hover)
            DSClipCard(clips[1], mode: .list, isSelected: true, config: .init(autoplay: false), onToggleSelect: {}) { rowActions }
          }
        }
      }
      .frame(width: 820)
      GSection("Grid", note: "tiles 168–220 · cover r.md") {
        Grid(horizontalSpacing: DS.space.md, verticalSpacing: DS.space.md) {
          GridRow {
            GCell("Default") { tile(clips[0]) }
            GCell("Hover", forced: .hover) { tile(clips[1]) }
          }
          GridRow {
            GCell("Selected") { tile(clips[3], selected: true) }
            GCell("Selection mode") { tile(clips[2], selectionMode: true) }
          }
        }
      }
    }
  }

  private func tile(_ c: DSClip, selected: Bool = false, selectionMode: Bool = false) -> some View {
    DSClipCard(c, mode: .grid, isSelected: selected, config: .init(autoplay: autoplay && c.id == "a", selectionMode: selectionMode),
               onToggleSelect: {}) {
      DSMediaActionButton("Edit", systemImage: "slider.horizontal.3", tooltip: "Open editor") {}
      DSMediaActionButton("Pin", systemImage: "pin", tooltip: "Pin to date") {}
    }
    .frame(width: 140)
  }

  @ViewBuilder private var queueActions: some View {
    DSIconButton("bolt", tooltip: "Post today", size: .sm) {}
    DSIconButton("pin", tooltip: "Pin to date…", size: .sm) {}
    DSIconButton("ellipsis", tooltip: "More", size: .sm) {}
  }

  @ViewBuilder private var rowActions: some View {
    DSIconButton("ellipsis", tooltip: "More", size: .sm) {}
  }
}

// MARK: - 7 Single

struct GallerySingle: View {
  let media: DSGalleryMedia
  var autoplay = ProcessInfo.processInfo.environment["DJQ_GALLERY_AUTOPLAY"] != nil

  var body: some View {
    let clip = DSGallerySamples.clips(media, autoplayVideo: autoplay)[1]
    VStack(alignment: .leading, spacing: DS.space.md) {
      HStack(spacing: DS.space.md) {
        DSProgress(value: 17.0 / 29).frame(width: 420)
        Text("17 of 29 scored").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        Spacer()
        DSViewModeSwitcher(mode: .constant(.single), modes: [.single, .grid])
      }
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: DS.space.md) {
          HStack(spacing: DS.space.md) {
            DSIconButton("chevron.left", tooltip: "Previous", variant: .outline, size: .lg, shortcut: "←") {}
            DSClipCard(clip, mode: .single, config: .init(autoplay: autoplay)) {
              DSSegmented(selection: .constant("dj"), segments: [DSSegment(value: "dj", title: "DJ vid"), DSSegment(value: "talk", title: "Talking")])
              DSButton("Exclude", icon: "eye.slash", variant: .ghost, size: .sm) {}
            }
            .frame(height: 560)
            DSIconButton("chevron.right", tooltip: "Next", variant: .outline, size: .lg, shortcut: "→") {}
          }
          scorePill
          Text("Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next · ⌘⌫ exclude")
            .font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
        }
        Spacer(minLength: 0)
      }
    }
  }

  /// Floating control pill under the player (DESIGN-v2 §6.1).
  private var scorePill: some View {
    HStack(spacing: 6) {
      GState("47") { v in
        TextField("0–100", text: v)
          .textFieldStyle(.plain)
          .font(DS.type.display.monospacedDigit())
          .multilineTextAlignment(.center)
          .frame(width: 96, height: 44)
          .background(DS.color.surfaceSunken, in: Capsule())
      }
      DSButton("Save & next", icon: "return", variant: .primary, size: .lg, shortcut: "↩") {}
      DSButton("Skip", variant: .ghost, size: .lg, tooltip: "Skip for now", shortcut: "⇥") {}
    }
    .padding(6)
    .frame(height: 56)
    .background(DS.color.surfaceRaised, in: Capsule())
    .overlay(Capsule().strokeBorder(DS.color.border))
    .dsElevation(DS.elevation.e2)
  }
}
