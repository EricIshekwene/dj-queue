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
  /// `.sm` for the Queue's version-post tags (round 31), which sit several to a row.
  var size: DSBadgeSize = .md
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

/// A photo post on a card (round 21): its photos as they will post. A card with this has no player, no length and
/// nothing that moves on hover.
struct DSClipPhotos {
  var count: Int
  /// "Photo" · "Carousel · 5": the mark a clip's kind or length would be.
  var label: String
  /// Width ÷ height as posted, until a picture is loaded.
  var aspectRatio: Double = Aspect.r4x5.ratio
  /// Photo `i` at preview size, when loaded. Large previews step through these; the card's `poster` is photo 0.
  var image: (Int) -> NSImage? = { _ in nil }
  var load: (Int) -> Void = { _ in }

  var symbol: String { count > 1 ? "photo.stack" : "photo" }
  var help: String { count > 1 ? "\(count) photos, posted together as a carousel" : "One photo, posted as a picture" }
}

/// Everything a clip card can show. All optional except id/title; the card hides what's nil/empty.
/// DESIGN-v2 §4 kept versions off cards; round 31 makes each version post its own post in the plan, so the Queue card says
/// which one goes out next (`dateUnit`) and where the others stand (`units`). Nothing else on a card names a version.
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
  /// On-video texts drawn over the playing proxy, each during its window (S6: the clip as it will post).
  var overlays: [DSTimedOverlay] = []
  /// The edit changed and its new proxy is being made: the (new) poster shows with a quiet "Updating preview".
  var isUpdatingPreview = false
  /// `AppModel.previewStamp` of what this card shows. Key preview tasks on it (`.task(id: clip.previewStamp)`).
  var previewStamp = ""
  /// Text exists but an overlay image was evicted; `reloadOverlay` draws it again (called only while playing).
  var overlayMissing = false
  var reloadOverlay: (() -> Void)? = nil
  /// "0:42".
  var durationText: String? = nil
  /// Why the score reads "—" on purpose (a photo post, a photo with audio): the dash's tooltip. nil = just not scored.
  var noScoreHelp: String? = nil
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
  /// Round 31: the version post going out on `dateText`'s day ("v1 · 1 of 2"), shown in the date chip after the day.
  var dateUnit: String? = nil
  /// Round 31: the clip's other version posts, in planning order. Cards show as many as fit on one line (at most
  /// `UnitLines.cap`) and "+N" for the rest; Single shows them all.
  var units: [DSClipTag] = []
  var isPinned = false
  /// File missing: danger chip "File missing · Relink" and no autoplay.
  var isMissing = false
  /// A photo post: the card shows the first photo, a "Photo" / "Carousel · 5" mark and never plays.
  var photos: DSClipPhotos? = nil

  /// "Afroween Jazz Piano · 0:42 · DJ vid".
  var meta: String { [subtitle, durationText, photos == nil ? kind : nil].compactMap { $0 }.joined(separator: " · ") }
}

/// Card behaviour shared by all modes.
struct DSClipCardConfig {
  /// May this card's preview play now? Screens pass `PreviewPlayback.plays(…)`.
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
  /// The pointer is really on the card (playback); `hovering` drives its controls.
  @State private var pointerOn = false
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
  private var playHot: Bool { forced == .hover || forced == .pressed || pointerOn || DSClipCardDebug.hoverIds.contains(clip.id) }
  private var showCheck: Bool { onToggleSelect != nil && mode != .single && (config.selectionMode || isSelected || hot) }
  private var autoplay: Bool { config.autoplay && !clip.isMissing && clip.photos == nil }

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
    .dsPlaybackHover { pointerOn = $0 }
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
    if let d = clip.dateText { parts.append(UnitLines.dateText(d, unit: clip.dateUnit)) }
    if let ph = clip.photos { parts.append(ph.label) }
    if clip.isMissing { parts.append("file missing") }
    if clip.isUpdatingPreview && !clip.isMissing { parts.append("updating preview") }
    return parts.joined(separator: ", ")
  }

  // MARK: Shared pieces

  /// The clip's picture. A photo post is a still at its own shape (`photoMat`: on a mat that fills the box;
  /// `photoSteps`: ‹ › and dots for a carousel); a clip is the looping preview.
  @ViewBuilder private func media(radius: CGFloat, active: Bool, mute: Bool = true, muteAlignment: Alignment = .bottomTrailing,
                                  scrubber: Bool = false, updating: DSPreviewUpdatingStyle = .label,
                                  photoMat: Bool = false, photoSteps: Bool = false) -> some View {
    if let ph = clip.photos {
      DSPhotoPreview(count: ph.count, aspectRatio: ph.aspectRatio, poster: clip.poster, image: ph.image, load: ph.load,
                     stamp: clip.previewStamp, steps: photoSteps, cornerRadius: radius, mat: photoMat, alignment: photoSteps ? .top : .center,
                     anchor: "Photo \(clip.id)")
    } else {
      DSVideoPreview(url: clip.isMissing ? nil : clip.proxyURL, poster: clip.poster, isActive: active, isPriority: isFocused,
                     loopRange: clip.loopRange, unmuteOnHover: config.unmuteOnHover, isHovered: playHot, showsMuteButton: mute,
                     muteAlignment: muteAlignment, showsScrubber: scrubber, cornerRadius: radius,
                     overlays: clip.overlays, isUpdating: clip.isUpdatingPreview && !clip.isMissing,
                     updatingStyle: updating, needsOverlay: clip.overlayMissing, onNeedsOverlay: clip.reloadOverlay)
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.color.border) }
    }
  }

  /// A clip's file is found again by fingerprint; a photo post's copy has to be put back (Doctor names it).
  private var missingHelp: String {
    clip.photos == nil ? "The source file moved or was deleted — Health › Doctor relinks it"
      : "A photo of this post is gone from DJ Queue's Photos folder — Health › Doctor names it"
  }

  /// "Photo" / "Carousel · 5", where a clip says its session, length and kind.
  @ViewBuilder private func photoMark(_ ph: DSClipPhotos, size: DSBadgeSize = .md) -> some View {
    DSBadge(ph.label, style: .outline, icon: ph.symbol, size: size, help: ph.help)
      .background(ScriptAnchor("Photo mark \(clip.id) \(ph.label)"))
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
      } else if clip.photos != nil || clip.noScoreHelp != nil {
        // A photo needs no score (nor a photo with audio): say so quietly instead of a dash that reads as something missing.
        Text("No score").font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(1).fixedSize()
          .dsTooltip(clip.photos != nil ? "Photos need no score. Without one it takes the next open day"
                       : "A photo with audio needs no score. Without one it takes the next open day")
      } else {
        Text("—").font(DS.type.score).foregroundStyle(DS.color.textTertiary).dsTooltip("Not scored yet — score it in Score")
      }
    }
  }

  private var durationBadge: some View {
    Group {
      if let ph = clip.photos {
        HStack(spacing: 4) {
          Image(systemName: ph.symbol).font(.system(size: 9, weight: .semibold))
          Text(ph.label).font(DS.type.micro)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: 18)
        .background(Color.black.opacity(0.63), in: Capsule())
        .fixedSize()
        .background(ScriptAnchor("Photo mark \(clip.id) \(ph.label)"))
        .dsTooltip(ph.help)
      } else if let d = clip.durationText {
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
          Text(UnitLines.dateText(d, unit: clip.dateUnit)).font(DS.type.captionMedium).lineLimit(1)
        }
        .foregroundStyle(none ? DS.color.textTertiary : DS.color.text)
        .padding(.horizontal, 10).frame(height: 26)
        .overlay(Capsule().strokeBorder(none ? DS.color.border : DS.color.borderStrong))
        .fixedSize()
        .dsTooltip((clip.isPinned ? "Pinned to this day — the plan works around it" : none ? "No day yet" : "Next planned post")
                   + (clip.dateUnit.map { "\n\($0): the version post going out that day" } ?? ""))
        .background(ScriptAnchor("Date chip \(clip.id)"))
      }
    }
  }

  /// Chip row: blocks (danger) · missing (warning) · suggestions (outlined, click to accept) · state · tags.
  @ViewBuilder private func chips(limit: Int? = nil, units: Bool = true) -> some View {
    let all = chipItems + (units ? unitItems : [])
    ForEach(Array((limit.map { Array(all.prefix($0)) } ?? all).enumerated()), id: \.offset) { _, item in item }
  }

  private var chipItems: [AnyView] {
    var out: [AnyView] = []
    if clip.isMissing {
      out.append(AnyView(DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark", help: missingHelp)))
    }
    out += clip.blocks.map { AnyView(DSBadge($0, style: .soft(.danger), help: "Blocks posting until fixed in the editor")) }
    out += clip.issues.map { AnyView(DSBadge($0, style: .soft(.warning), help: "Still needed before it can go to the Queue — open the editor")) }
    out += clip.suggestions.prefix(3).map { s in
      AnyView(DSSuggestionChip(suggestion: s) { onAcceptSuggestion?(s) })
    }
    if let st = clip.status { out.append(AnyView(DSBadge(st.text, style: st.style, icon: st.icon, help: st.tooltip))) }
    out += clip.tags.map { t in AnyView(DSBadge(t.text, style: t.style, icon: t.icon, size: t.size, help: t.tooltip)) }
    return out
  }

  /// Round 31: the clip's other version posts, after every other chip.
  private var unitItems: [AnyView] { clip.units.map { AnyView(unitBadge($0)) } }

  private func unitBadge(_ t: DSClipTag) -> some View {
    DSBadge(t.text, style: t.style, icon: t.icon, size: t.size, help: t.tooltip)
      .background(ScriptAnchor("Unit tag \(clip.id) \(t.text)"))
  }

  /// Round 31, Cards: one line of version-post tags (the card's height is fixed), as many as fit, then "+N" with the
  /// rest on hover.
  @ViewBuilder private var unitRow: some View {
    let all = clip.units
    if !all.isEmpty {
      ViewThatFits(in: .horizontal) {
        ForEach(Array(stride(from: min(all.count, UnitLines.cap), through: 0, by: -1)), id: \.self) { k in
          HStack(spacing: 6) {
            ForEach(all.prefix(k)) { unitBadge($0) }
            if all.count > k {
              DSBadge("+\(all.count - k)", style: .outline, size: .sm,
                      help: all.dropFirst(k).map(\.text).joined(separator: "\n"))
                .background(ScriptAnchor("Unit tag \(clip.id) +\(all.count - k)"))
            }
          }
          .fixedSize()
        }
      }
    }
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
      // Round 31: the version-post tags take their own line under the title and the right-hand facts, the card's full
      // width, so they never squeeze the title or wrap past the card's fixed height.
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: DS.space.sm) {
          VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text(clip.title).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(1)
                if clip.isPinned && clip.dateText == nil {
                  Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(DS.color.textTertiary)
                    .dsTooltip("Pinned to a day")
                }
              }
              if let ph = clip.photos {
                photoMark(ph)
              } else if !clip.meta.isEmpty {
                Text(clip.meta).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1)
              }
            }
            if !chipItems.isEmpty { DSFlowLayout(spacing: 6) { chips(units: false) } }
          }
          .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
          HStack(spacing: DS.space.md) {
            platformsRow
            dateChip
            // Its own width: a row squeezed by platforms and a date must not push "No score" over the date chip.
            scoreText.frame(minWidth: 34, alignment: .trailing).fixedSize()
            HStack(spacing: 2) { actions }
          }
        }
        unitRow
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
      media(radius: DS.radius.md, active: autoplay, mute: true, muteAlignment: .bottomTrailing, photoMat: true)
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
            HStack(spacing: 4) { actions }.padding(.bottom, 34).transition(.opacity)
          }
        }
        .overlay {
          if isSelected { RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.text, lineWidth: 2) }
        }
      VStack(alignment: .leading, spacing: 4) {
        Text(clip.title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(1)
        if !clip.meta.isEmpty { Text(clip.meta).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
        DSFlowLayout(spacing: 4, lineSpacing: 4) { chips(limit: 2, units: false) }.padding(.top, 2).frame(maxWidth: .infinity, alignment: .leading).clipped()
      }
      .padding(.horizontal, 2)
    }
  }

  // MARK: Single (large — default for Score)

  private var single: some View {
    HStack(alignment: .top, spacing: DS.space.xxl) {
      // A photo keeps the column a clip's player has, and sits at the top of it at its own shape.
      media(radius: DS.radius.xl, active: autoplay, mute: true, muteAlignment: .topTrailing, scrubber: true, photoSteps: true)
        .aspectRatio(9 / 16, contentMode: .fit)
      VStack(alignment: .leading, spacing: DS.space.lg) {
        VStack(alignment: .leading, spacing: 4) {
          Text(clip.title).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(3)
          if let ph = clip.photos {
            photoMark(ph)
          } else if !clip.meta.isEmpty {
            Text(clip.meta).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
          }
        }
        // Score and next date (Queue §6.3) — the same facts the wide card shows on its right edge.
        if clip.score != nil || clip.dateText != nil || clip.photos != nil || clip.noScoreHelp != nil {
          HStack(spacing: DS.space.sm) {
            if clip.score != nil || clip.photos != nil || clip.noScoreHelp != nil {
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
      media(radius: DS.radius.xs, active: autoplay && playHot, mute: false, updating: .none).frame(width: 24, height: 42)
      VStack(alignment: .leading, spacing: 1) {
        Text(clip.title).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
        if let s = clip.subtitle { Text(s).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1) }
      }
      .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
      if clip.isMissing {
        DSBadge("File missing", style: .soft(.danger), size: .sm, help: missingHelp)
      } else if let ph = clip.photos {
        // `kind` carries the mark plus whatever the screen added to it (Library: the stage).
        DSBadge(clip.kind ?? ph.label, style: .outline, icon: ph.symbol, size: .sm, help: ph.help)
          .background(ScriptAnchor("Photo mark \(clip.id) \(ph.label)"))
      } else if let k = clip.kind {
        DSBadge(k, style: .outline, size: .sm, help: "Kind: \(k) (Talking clips start with no text)")
      }
      Group {
        if let s = clip.score {
          Text("\(s)").foregroundStyle(DS.color.text)
        } else {
          Text("—").foregroundStyle(DS.color.textTertiary).dsTooltip(clip.noScoreHelp)
        }
      }
      .font(DS.type.calloutSemibold.monospacedDigit()).frame(width: 40, alignment: .trailing)
      // Round 31: the version post going out that day on a second line, and the clip's other version posts on hover.
      VStack(alignment: .leading, spacing: 1) {
        Text(clip.dateText ?? "").font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        if clip.dateUnit != nil || !clip.units.isEmpty {
          Text(clip.dateUnit.map { $0 + (clip.units.isEmpty ? "" : "  +\(clip.units.count)") } ?? "\(clip.units.count) version posts")
            .font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary).lineLimit(1)
            .background(ScriptAnchor("List unit \(clip.id)"))
        }
      }
      .frame(width: 124, alignment: .leading)
      .dsTooltip(clip.units.isEmpty ? nil : ([clip.dateUnit.map { "Next: \($0)" }].compactMap { $0 } + clip.units.map(\.text)).joined(separator: "\n"))
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
        // In a narrow column (Single's 280 pt panel) the tracks truncate first, then the title; the tooltip has both.
        Text(suggestion.text).font(DS.type.captionMedium).foregroundStyle(DS.color.text).layoutPriority(1)
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
    .fixedSize(horizontal: false, vertical: true)
    .dsTooltip("“\(suggestion.text)” · click to set the Title" + (suggestion.detail.map { "\n" + $0 } ?? ""))
  }
}

/// Small round button floating on media (grid tile hover actions), drawn icon-only. Its tooltip is required, like
/// DSIconButton's: an icon-only action can't be left unexplained (round 3, F5), and neither the lint nor the popup
/// can use the label's title (the bubble is a separate panel, where a `Label`'s title view draws nothing — round 5).
/// `disabledReason` soft-disables it: dimmed, still hoverable, the tooltip says why (the action decides what a click does).
struct DSMediaActionButton: View {
  let title: String
  let systemImage: String
  let tooltip: String
  var disabledReason: String?
  let action: () -> Void

  init(_ title: String, systemImage: String, tooltip: String, disabledReason: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.tooltip = tooltip
    self.disabledReason = disabledReason
    self.action = action
  }

  var body: some View {
    Button(action: action) { Label(title, systemImage: systemImage) }
      .buttonStyle(DSMediaActionStyle())
      .opacity(disabledReason == nil ? 1 : 0.45)
      .dsTooltip(tooltip, disabledReason: disabledReason)
  }
}

private struct DSMediaActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(Color.black.opacity(configuration.isPressed ? 0.75 : 0.55), in: Circle())
      .contentShape(Circle())
  }
}

/// Evidence runs only (DSTooltipProbe): clip ids drawn in their hover state, so a real window shows a tile's
/// hover controls without a pointer.
enum DSClipCardDebug {
  nonisolated(unsafe) static var hoverIds: Set<String> = []
}
