import AppKit
import DJQCore
import SwiftUI

// MARK: - View model (data-agnostic; screens map AppModel → DSClip)

struct DSClipTag: Identifiable, Hashable {
  var text: String
  var style: DSBadgeStyle = .outline
  var icon: String? = nil
  /// What the tag means (hover). Every tag on a card should explain itself.
  var tooltip: String? = nil
  var id: String { text }
}

/// A title suggestion from metadata (never generated in-app): "Chanel x Ke Star" + matched tracks in tertiary.
struct DSTitleSuggestion: Identifiable, Hashable {
  var text: String
  var detail: String? = nil
  var id: String { text }
}

struct DSClipPlatform: Identifiable, Hashable {
  var platform: Platform
  var state: DSPlatformState
  var id: Platform { platform }
}

/// Everything a clip card can show. All optional except id/title; the card hides what's nil/empty.
/// Never put the version here (DESIGN-v2 §4: no versions on cards).
struct DSClip: Identifiable {
  var id: String
  /// Title, or the raw tag when there's no Title.
  var title: String
  /// Session name (meta line).
  var subtitle: String? = nil
  var poster: NSImage? = nil
  /// 540×960 proxy for autoplay (nil = poster only). Crop + aspect + trim already applied (S6).
  var proxyURL: URL? = nil
  /// Part of the proxy that loops (nil = the whole proxy).
  var loopRange: ClosedRange<Double>? = nil
  /// On-video text drawn over the playing proxy during `textWindow` (S6: the clip as it will post).
  var overlay: CGImage? = nil
  /// When `overlay` shows, in seconds of the proxy's timeline.
  var textWindow: ClosedRange<Double>? = nil
  /// The edit changed and its new proxy is being made: the (new) poster shows with a quiet "Updating preview".
  var isUpdatingPreview = false
  /// `AppModel.previewStamp` of what this card shows. Key preview tasks on it (`.task(id: clip.previewStamp)`).
  var previewStamp = ""
  /// "0:42".
  var durationText: String? = nil
  /// "DJ vid" / "Talking".
  var kind: String? = nil
  var score: Int? = nil
  /// Queue position ("1", "2"…).
  var position: Int? = nil
  /// State chip (Ready / Needs edit / Posted …).
  var status: DSClipTag? = nil
  /// Extra chips (e.g. "Long-form", "Cover").
  var tags: [DSClipTag] = []
  /// What's missing (Edit screen) → warning chips. Hard blocks → `blocks` (danger chips).
  var issues: [String] = []
  var blocks: [String] = []
  /// Up to 3 title suggestions (outlined chips, click to accept).
  var suggestions: [DSTitleSuggestion] = []
  /// Only planned/posted platforms (screens decide relevance; never for unplanned clips).
  var platforms: [DSClipPlatform] = []
  /// "Thu 5 Nov" / "Not scheduled". nil hides the chip.
  var dateText: String? = nil
  var isPinned = false
  /// File missing: danger chip "File missing · Relink" and no autoplay.
  var isMissing = false

  /// "Afroween Jazz Piano · 0:42 · DJ vid".
  var meta: String { [subtitle, durationText, kind].compactMap { $0 }.joined(separator: " · ") }
}

/// Card behaviour shared by all modes.
struct DSClipCardConfig {
  /// Autoplay setting (Settings → autoplay). Focus-only mode: pass `autoplay: isFocused`.
  var autoplay = true
  var unmuteOnHover = false
  /// Selection mode: checkbox always visible and a click toggles selection.
  var selectionMode = false
  /// Queue only: ⋮⋮ drag handle on hover at the far left.
  var showsDragHandle = false
}

// MARK: - Card

/// One clip in four view modes (DESIGN-v2 §4: Cards · Grid · Single · List).
/// Slots: `actions` (hover actions + ⋯ the screen owns). Clicks: checkbox → `onToggleSelect`; card click →
/// `onTap(modifiers)` (screens implement ⇧ range / ⌘ toggle with the modifiers; in selection mode a plain click
/// toggles selection). Suggestion chips → `onAcceptSuggestion`.
struct DSClipCard<Actions: View>: View {
  let clip: DSClip
  var mode: DSViewMode = .wide
  var isSelected = false
  var isFocused = false
  var config = DSClipCardConfig()
  var onToggleSelect: (() -> Void)? = nil
  var onTap: ((EventModifiers) -> Void)? = nil
  var onAcceptSuggestion: ((DSTitleSuggestion) -> Void)? = nil
  @ViewBuilder var actions: Actions
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(_ clip: DSClip, mode: DSViewMode = .wide, isSelected: Bool = false, isFocused: Bool = false, config: DSClipCardConfig = .init(),
       onToggleSelect: (() -> Void)? = nil, onTap: ((EventModifiers) -> Void)? = nil,
       onAcceptSuggestion: ((DSTitleSuggestion) -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
    self.clip = clip
    self.mode = mode
    self.isSelected = isSelected
    self.isFocused = isFocused
    self.config = config
    self.onToggleSelect = onToggleSelect
    self.onTap = onTap
    self.onAcceptSuggestion = onAcceptSuggestion
    self.actions = actions()
  }

  private var hot: Bool { forced == .hover || forced == .pressed || hovering || DSClipCardDebug.hoverIds.contains(clip.id) }
  private var showCheck: Bool { onToggleSelect != nil && mode != .single && (config.selectionMode || isSelected || hot) }
  private var autoplay: Bool { config.autoplay && !clip.isMissing }

  var body: some View {
    Group {
      switch mode {
      case .grid: grid
      case .single: single
      case .list: list
      case .wide: cards
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { handleTap() }
    .dsAnimation(DS.motion.hover, value: hot)
    .dsAnimation(DS.motion.layout, value: isSelected)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func handleTap() {
    let flags = NSEvent.modifierFlags
    var m: EventModifiers = []
    if flags.contains(.shift) { m.insert(.shift) }
    if flags.contains(.command) { m.insert(.command) }
    if config.selectionMode && m.isEmpty, let onToggleSelect { onToggleSelect() } else { onTap?(m) }
  }

  private var accessibilityText: String {
    var parts = [clip.title]
    if let s = clip.score { parts.append("score \(s)") }
    if let st = clip.status?.text { parts.append(st) }
    if let d = clip.dateText { parts.append(d) }
    if clip.isMissing { parts.append("file missing") }
    if clip.isUpdatingPreview && !clip.isMissing { parts.append("updating preview") }
    return parts.joined(separator: ", ")
  }

  // MARK: Shared pieces

  private func media(radius: CGFloat, active: Bool, mute: Bool = true, muteAlignment: Alignment = .bottomTrailing,
                     scrubber: Bool = false, updating: DSPreviewUpdatingStyle = .label) -> some View {
    DSVideoPreview(url: clip.isMissing ? nil : clip.proxyURL, poster: clip.poster, isActive: active, isPriority: isFocused,
                   loopRange: clip.loopRange, unmuteOnHover: config.unmuteOnHover, isHovered: hot, showsMuteButton: mute,
                   muteAlignment: muteAlignment, showsScrubber: scrubber, cornerRadius: radius,
                   overlay: clip.overlay, textWindow: clip.textWindow, isUpdating: clip.isUpdatingPreview && !clip.isMissing,
                   updatingStyle: updating)
      .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.color.border) }
  }

  /// 20 pt circle (DESIGN-v2 §4).
  private func selectCircle(onMedia: Bool) -> some View {
    DSCheckbox(isOn: isSelected, size: 20, shape: .circle, onMedia: onMedia) { onToggleSelect?() }
      .dsTooltip(isSelected ? "Deselect" : "Select for bulk actions", shortcut: isSelected ? nil : "⌘-click", side: .bottom)
  }

  private var scoreText: some View {
    Group {
      if let s = clip.score {
        Text("\(s)").font(DS.type.score).foregroundStyle(DS.color.text).dsTooltip("Score \(s) — it sets the posting order")
      } else {
        Text("—").font(DS.type.score).foregroundStyle(DS.color.textTertiary).dsTooltip("Not scored yet — score it in Score")
      }
    }
  }

  private var durationBadge: some View {
    Group {
      if let d = clip.durationText {
        Text(d).font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
          .padding(.horizontal, 6).frame(height: 18)
          .background(Color.black.opacity(0.63), in: Capsule())
          .dsTooltip("Length \(d)")
      }
    }
  }

  private var dateChip: some View {
    Group {
      if let d = clip.dateText {
        let none = d == "Not scheduled"
        HStack(spacing: 5) {
          Image(systemName: clip.isPinned ? "pin.fill" : "calendar").font(.system(size: 10.5, weight: .medium))
          Text(d).font(DS.type.captionMedium)
        }
        .foregroundStyle(none ? DS.color.textTertiary : DS.color.text)
        .padding(.horizontal, 10).frame(height: 26)
        .overlay(Capsule().strokeBorder(none ? DS.color.border : DS.color.borderStrong))
        .fixedSize()
        .dsTooltip(clip.isPinned ? "Pinned to this day — the plan works around it" : none ? "Not in the plan yet" : "Next planned post")
      }
    }
  }

  /// Chip row: blocks (danger) · missing (warning) · suggestions (outlined, click to accept) · state · tags.
  @ViewBuilder private func chips(limit: Int? = nil) -> some View {
    let all = chipItems
    ForEach(Array((limit.map { Array(all.prefix($0)) } ?? all).enumerated()), id: \.offset) { _, item in item }
  }

  private var chipItems: [AnyView] {
    var out: [AnyView] = []
    if clip.isMissing {
      out.append(AnyView(DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark",
                                 help: "The source file moved or was deleted — Health › Doctor relinks it")))
    }
    out += clip.blocks.map { AnyView(DSBadge($0, style: .soft(.danger), help: "Blocks posting until fixed in the editor")) }
    out += clip.issues.map { AnyView(DSBadge($0, style: .soft(.warning), help: "Still needed before it's ready — open the editor")) }
    out += clip.suggestions.prefix(3).map { s in
      AnyView(DSSuggestionChip(suggestion: s) { onAcceptSuggestion?(s) })
    }
    if let st = clip.status { out.append(AnyView(DSBadge(st.text, style: st.style, icon: st.icon, help: st.tooltip))) }
    out += clip.tags.map { t in AnyView(DSBadge(t.text, style: t.style, icon: t.icon, help: t.tooltip)) }
    return out
  }

  private var platformsRow: some View {
    Group {
      if !clip.platforms.isEmpty { DSPlatformRow(items: clip.platforms.map { ($0.platform, $0.state) }, size: 22) }
    }
  }

  // MARK: Cards (horizontal rounded card — default for Edit, Queue)

  private var cards: some View {
    HStack(spacing: DS.space.sm) {
      if config.showsDragHandle {
        Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.color.textTertiary)
          .frame(width: 14).opacity(hot ? 1 : 0).dsTooltip(hot ? "Drag to change the posting order" : nil)
      }
      if onToggleSelect != nil {
        selectCircle(onMedia: false).opacity(showCheck ? 1 : 0).allowsHitTesting(showCheck)
      }
      if let p = clip.position {
        Text("\(p)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary).frame(minWidth: 16, alignment: .trailing)
          .dsTooltip("Number \(p) in the posting order")
      }
      media(radius: DS.radius.sm, active: autoplay, mute: true, muteAlignment: .bottomTrailing, updating: .icon)
        .frame(width: 63, height: 112)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(clip.title).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(1)
            if clip.isPinned && clip.dateText == nil {
              Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(DS.color.textTertiary)
                .dsTooltip("Pinned to a day")
            }
          }
          if !clip.meta.isEmpty { Text(clip.meta).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
        }
        DSFlowLayout(spacing: 6) { chips() }
      }
      .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
      HStack(spacing: DS.space.md) {
        platformsRow
        dateChip
        scoreText.frame(minWidth: 34, alignment: .trailing)
        HStack(spacing: 2) { actions }
      }
    }
    .padding(DS.space.sm)
    .frame(height: DS.size.clipCard)
    .frame(maxWidth: DS.size.readingColumn)
    .background(isSelected ? DS.color.selected : DS.color.surface, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous)
        .strokeBorder(isSelected ? DS.color.text : isFocused ? DS.color.focusRing : hot ? DS.color.borderStrong : DS.color.border,
                      lineWidth: isSelected || isFocused ? 2 : 1)
    }
    .dsElevation(DS.elevation.e1)
  }

  // MARK: Grid (tiles — default for Library, Score grid)

  private var grid: some View {
    VStack(alignment: .leading, spacing: 8) {
      media(radius: DS.radius.md, active: autoplay, mute: true, muteAlignment: .bottomTrailing)
        .aspectRatio(9 / 16, contentMode: .fit)
        .overlay(alignment: .topLeading) { if showCheck { selectCircle(onMedia: true).padding(8).transition(.opacity) } }
        .overlay(alignment: .topTrailing) {
          if let s = clip.score {
            Text("\(s)").font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
              .padding(.horizontal, 7).frame(height: 20).background(Color.black.opacity(0.63), in: Capsule())
              .dsTooltip("Score \(s)").padding(8)
          }
        }
        .overlay(alignment: .bottomLeading) { durationBadge.padding(8) }
        .overlay(alignment: .bottom) {
          if hot && !clip.isMissing {
            HStack(spacing: 4) { actions }.buttonStyle(DSMediaActionStyle()).padding(.bottom, 34).transition(.opacity)
          }
        }
        .overlay {
          if isSelected { RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.text, lineWidth: 2) }
        }
      VStack(alignment: .leading, spacing: 4) {
        Text(clip.title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(1)
        if !clip.meta.isEmpty { Text(clip.meta).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
        DSFlowLayout(spacing: 4, lineSpacing: 4) { chips(limit: 2) }.padding(.top, 2).frame(maxWidth: .infinity, alignment: .leading).clipped()
      }
      .padding(.horizontal, 2)
    }
  }

  // MARK: Single (large — default for Score)

  private var single: some View {
    HStack(alignment: .top, spacing: DS.space.xxl) {
      media(radius: DS.radius.xl, active: autoplay, mute: true, muteAlignment: .topTrailing, scrubber: true)
        .aspectRatio(9 / 16, contentMode: .fit)
      VStack(alignment: .leading, spacing: DS.space.lg) {
        VStack(alignment: .leading, spacing: 4) {
          Text(clip.title).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(3)
          if !clip.meta.isEmpty { Text(clip.meta).font(DS.type.callout).foregroundStyle(DS.color.textSecondary) }
        }
        // Score and next date (Queue §6.3) — the same facts the wide card shows on its right edge.
        if clip.score != nil || clip.dateText != nil {
          HStack(spacing: DS.space.sm) {
            if clip.score != nil {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Score").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
                scoreText
              }
            }
            dateChip
          }
        }
        DSFlowLayout(spacing: 6) { chips() }
        if !clip.platforms.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            DSEyebrow("Platforms")
            ForEach(clip.platforms) { p in
              HStack(spacing: 8) {
                DSPlatformIcon(platform: p.platform, state: p.state, size: 22)
                Text(p.platform.displayName).font(DS.type.callout).foregroundStyle(DS.color.text)
                Spacer()
                Text(p.state.label).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
              }
            }
          }
        }
        VStack(alignment: .leading, spacing: DS.space.sm) { actions }
        Spacer(minLength: 0)
      }
      .frame(width: 280, alignment: .leading)
      .padding(.top, DS.space.xxs)
    }
  }

  // MARK: List (compact — default for Posts history)

  private var list: some View {
    HStack(spacing: DS.space.sm) {
      if onToggleSelect != nil {
        selectCircle(onMedia: false).opacity(showCheck ? 1 : 0.0001)
      }
      if let p = clip.position {
        Text("\(p)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary).frame(minWidth: 16, alignment: .trailing)
          .dsTooltip("Number \(p) in the posting order")
      }
      media(radius: DS.radius.xs, active: false, mute: false, updating: .none).frame(width: 24, height: 42)
      VStack(alignment: .leading, spacing: 1) {
        Text(clip.title).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
        if let s = clip.subtitle { Text(s).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
      }
      .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
      if clip.isMissing {
        DSBadge("File missing", style: .soft(.danger), size: .sm, help: "The source file moved or was deleted — Health › Doctor relinks it")
      } else if let k = clip.kind {
        DSBadge(k, style: .outline, size: .sm, help: "Kind: \(k) (Talking clips start with no text)")
      }
      Group {
        if let s = clip.score { Text("\(s)").foregroundStyle(DS.color.text) } else { Text("—").foregroundStyle(DS.color.textTertiary) }
      }
      .font(DS.type.calloutSemibold.monospacedDigit()).frame(width: 40, alignment: .trailing)
      Text(clip.dateText ?? "").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).frame(width: 96, alignment: .leading).lineLimit(1)
      HStack(spacing: 4) {
        ForEach(clip.platforms) { p in DSPlatformIcon(platform: p.platform, state: p.state, size: 20) }
      }
      .frame(width: 150, alignment: .leading)
      HStack(spacing: 2) { actions }.opacity(hot ? 1 : 0.0001)
    }
    .padding(.horizontal, DS.space.xs)
    .frame(height: DS.size.listRow)
    .background(isSelected ? DS.color.selected : hot ? DS.color.hover : .clear,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .overlay(alignment: .bottom) { if !(isSelected || hot) { DSSeparator().padding(.horizontal, DS.space.xs) } }
  }
}

extension DSClipCard where Actions == EmptyView {
  init(_ clip: DSClip, mode: DSViewMode = .wide, isSelected: Bool = false, isFocused: Bool = false, config: DSClipCardConfig = .init(),
       onToggleSelect: (() -> Void)? = nil, onTap: ((EventModifiers) -> Void)? = nil,
       onAcceptSuggestion: ((DSTitleSuggestion) -> Void)? = nil) {
    self.init(clip, mode: mode, isSelected: isSelected, isFocused: isFocused, config: config, onToggleSelect: onToggleSelect,
              onTap: onTap, onAcceptSuggestion: onAcceptSuggestion) { EmptyView() }
  }
}

/// Outlined capsule with the suggestion and its matched track in tertiary (click to set the Title).
struct DSSuggestionChip: View {
  let suggestion: DSTitleSuggestion
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "text.badge.plus").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.color.textTertiary)
        Text(suggestion.text).font(DS.type.captionMedium).foregroundStyle(DS.color.text)
        if let d = suggestion.detail { Text(d).font(DS.type.caption).foregroundStyle(DS.color.textTertiary) }
      }
      .lineLimit(1)
      .padding(.horizontal, 10).frame(height: 22)
      .background(hovering || forced == .hover ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(DS.color.borderStrong))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .fixedSize()
    .dsTooltip("Set the Title to “\(suggestion.text)”")
  }
}

/// Small round buttons floating on media (grid tile hover actions). The label shows only its icon, so its title
/// becomes the tooltip automatically — an icon-only action can't be left unexplained (round 3, F5).
struct DSMediaActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(DSIconWithTitleTooltip())
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(Color.black.opacity(configuration.isPressed ? 0.75 : 0.55), in: Circle())
      .contentShape(Circle())
  }
}

/// Icon only, with the label's title as the tooltip (DSMediaActionStyle).
struct DSIconWithTitleTooltip: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.icon
      .frame(width: 28, height: 28)
      .contentShape(Circle())
      .dsTooltip(view: configuration.title)
  }
}

/// Evidence runs only (DSTooltipProbe): clip ids drawn in their hover state, so a real window shows a tile's
/// hover controls without a pointer.
enum DSClipCardDebug {
  nonisolated(unsafe) static var hoverIds: Set<String> = []
}
