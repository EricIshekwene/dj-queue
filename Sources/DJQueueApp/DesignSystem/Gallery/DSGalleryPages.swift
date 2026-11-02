import AppKit
import DJQCore
import SwiftUI

// MARK: - 1 Foundations

struct GalleryFoundations: View {
  private let swatches: [(String, [(String, Color)])] = [
    ("Backgrounds & surfaces", [("background", DS.color.background), ("sidebar", DS.color.sidebar), ("canvas", DS.color.canvas),
                  ("surface", DS.color.surface), ("surfaceSunken", DS.color.surfaceSunken), ("hover", DS.color.hover),
                  ("selected", DS.color.selected), ("scrim", DS.color.scrim)]),
    ("Lines & text", [("border", DS.color.border), ("borderStrong", DS.color.borderStrong), ("text", DS.color.text),
                      ("textSecondary", DS.color.textSecondary), ("textTertiary", DS.color.textTertiary)]),
    ("Primary & accent", [("primary", DS.color.primary), ("primaryText", DS.color.primaryText), ("accent", DS.color.accent),
                          ("focusRing", DS.color.focusRing)]),
    ("Status + tint", [("success", DS.color.success), ("successTint", DS.color.successTint), ("warning", DS.color.warning),
                       ("warningTint", DS.color.warningTint), ("danger", DS.color.danger), ("dangerTint", DS.color.dangerTint),
                       ("info", DS.color.info), ("infoTint", DS.color.infoTint)]),
  ]

  var body: some View {
    HStack(alignment: .top, spacing: DS.space.xxl) {
      VStack(alignment: .leading, spacing: DS.space.lg) {
        ForEach(swatches, id: \.0) { group in
          GSection(group.0) {
            HStack(spacing: DS.space.sm) {
              ForEach(group.1, id: \.0) { name, c in swatch(name, c) }
            }
          }
        }
        GSection("Radius", note: "continuous corners") {
          HStack(alignment: .bottom, spacing: DS.space.md) {
            radius("xs 6", DS.radius.xs)
            radius("sm 10", DS.radius.sm)
            radius("md 12", DS.radius.md)
            radius("lg 16", DS.radius.lg)
            radius("xl 20", DS.radius.xl)
            radius("pill", 30)
          }
        }
        GSection("Spacing") {
          HStack(alignment: .bottom, spacing: DS.space.md) {
            ForEach([2, 4, 8, 12, 16, 20, 24, 32, 48], id: \.self) { s in
              VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(DS.color.accentSoft)
                  .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(DS.color.accent.opacity(0.4)))
                  .frame(width: CGFloat(s), height: CGFloat(s))
                Text("\(s)").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
              }
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Type", note: "SF Pro · rounded only for numbers") {
          VStack(alignment: .leading, spacing: 10) {
            typeRow("display 28", DS.type.display, "Everything is scored")
            typeRow("title 20", DS.type.title, "Queue")
            typeRow("headline 15", DS.type.headline, "Chanel x Ke Star")
            typeRow("body 14", DS.type.body, "Scored clips that aren't ready yet.")
            typeRow("callout 13", DS.type.callout, "Afroween Jazz Piano · 0:14")
            typeRow("caption 12", DS.type.caption, "158/1500 · helper text")
            typeRow("micro 11", DS.type.micro, "Browse · 0:42")
            typeRow("score 22", DS.type.score, "41")
            typeRow("mono 12", DS.type.mono, "2026-10-23_0412")
          }
        }
        GSection("Elevation", note: "dark: border + lighter surface, no shadow") {
          HStack(spacing: DS.space.lg) {
            elevation("e0", DS.elevation.e0)
            elevation("e1", DS.elevation.e1)
            elevation("e2", DS.elevation.e2)
            elevation("e3", DS.elevation.e3)
          }
        }
        GSection("Motion", note: "all off under Reduce Motion") {
          VStack(alignment: .leading, spacing: 4) {
            motionRow("hover", "ease-out 120 ms — background + opacity")
            motionRow("layout", "spring 0.30 / 0.85 — reorder, bulk bar, select")
            motionRow("popover", "150 ms — scale from 0.97 + fade")
            motionRow("fade", "200 ms — proxy over poster, save & next")
          }
        }
      }
      .frame(width: 420)
    }
  }

  private func swatch(_ name: String, _ c: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous).fill(c)
        .overlay(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous).strokeBorder(DS.color.border))
        .frame(width: 76, height: 40)
      Text(name).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1).frame(width: 76, alignment: .leading)
    }
  }

  private func radius(_ label: String, _ r: CGFloat) -> some View {
    VStack(spacing: 5) {
      RoundedRectangle(cornerRadius: min(r, 22), style: .continuous).fill(DS.color.surface)
        .overlay(RoundedRectangle(cornerRadius: min(r, 22), style: .continuous).strokeBorder(DS.color.borderStrong))
        .frame(width: 60, height: 44)
      Text(label).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
  }

  private func typeRow(_ token: String, _ f: Font, _ sample: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(token).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).frame(width: 100, alignment: .leading)
      Text(sample).font(f).foregroundStyle(DS.color.text).lineLimit(1)
    }
  }

  private func elevation(_ label: String, _ s: DSShadow) -> some View {
    VStack(spacing: 8) {
      RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).fill(DS.color.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous).strokeBorder(DS.color.border))
        .frame(width: 84, height: 60)
        .dsElevation(s)
      Text(label).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
  }

  private func motionRow(_ a: String, _ b: String) -> some View {
    HStack {
      Text(a).font(DS.type.calloutMedium).foregroundStyle(DS.color.text).frame(width: 70, alignment: .leading)
      Text(b).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
    }
  }
}

// MARK: - 2 Buttons

struct GalleryButtons: View {
  private let states: [(String, DSInteraction?, Bool, Bool)] = [
    ("Default", nil, false, false), ("Hover", .hover, false, false), ("Pressed", .pressed, false, false),
    ("Focused", .focused, false, false), ("Disabled + reason", nil, true, false), ("Loading", nil, false, true),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xl) {
      GSection("Variants × states", note: "one primary per screen · disabled buttons explain why on hover") {
        Grid(alignment: .leading, horizontalSpacing: DS.space.lg, verticalSpacing: DS.space.sm) {
          GridRow {
            Text("").frame(width: 110)
            ForEach(states, id: \.0) { s in Text(s.0).font(DS.type.caption).foregroundStyle(DS.color.textTertiary) }
          }
          ForEach(DSButtonVariant.allCases, id: \.self) { v in
            GridRow {
              Text(v.rawValue).font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
              ForEach(states, id: \.0) { s in
                DSButton(label(v), icon: v == .primary ? "checkmark" : nil, variant: v, isLoading: s.3,
                         disabledReason: s.2 ? "Render the clip first" : nil) {}
                  .dsForcedState(s.1)
              }
            }
          }
        }
      }
      HStack(alignment: .top, spacing: DS.space.xxxl) {
        GSection("Sizes") {
          HStack(spacing: DS.space.sm) {
            DSButton("Small", icon: "plus", variant: .primary, size: .sm) {}
            DSButton("Medium", icon: "plus", variant: .primary, size: .md) {}
            DSButton("Large", icon: "plus", variant: .primary, size: .lg) {}
            DSButton("Newest", trailingIcon: "chevron.down", variant: .ghost, size: .sm) {}
          }
        }
        GSection("Icon buttons", note: "always tooltipped") {
          HStack(spacing: DS.space.sm) {
            DSIconButton("ellipsis", tooltip: "More", variant: .ghost) {}
            DSIconButton("square.and.arrow.up", tooltip: "Share", variant: .outline) {}
            DSIconButton("speaker.slash", tooltip: "Unmute", variant: .secondary) {}
            DSIconButton("pin", tooltip: "Pin", isOn: true) {}
            DSIconButton("trash", tooltip: "Exclude", variant: .destructive) {}
            DSIconButton("plus", tooltip: "New", variant: .primary, size: .lg) {}
          }
        }
      }
      HStack(alignment: .top, spacing: DS.space.xxxl) {
        GSection("Tooltip", note: "hover 450 ms · inverse bubble · shortcut optional") {
          HStack(spacing: DS.space.xxxl) {
            DSIconButton("calendar.badge.plus", tooltip: "Add to week", variant: .outline) {}
              .dsTooltip("Add to week", shortcut: "⌘W", forceVisible: true)
            DSButton("Post today", icon: "bolt", variant: .outline, disabledReason: "Instagram isn't rendered yet") {}
              .dsTooltip("Instagram isn't rendered yet", forceVisible: true)
          }
          .padding(.top, 44).padding(.bottom, 8).padding(.horizontal, 60)
        }
        GSection("Key hints") {
          HStack(spacing: 6) {
            DSKeyHint("⌘K"); DSKeyHint("↩"); DSKeyHint("⇧↑"); DSKeyHint("esc"); DSKeyHint("⌘Z")
          }
        }
        GSection("Dialog footer pattern") {
          HStack(spacing: DS.space.xs) {
            DSButton("Cancel", variant: .ghost) {}
            DSButton("Exclude 3 clips", variant: .destructiveSolid) {}
            DSButton("Save", variant: .primary) {}
          }
        }
      }
    }
  }

  private func label(_ v: DSButtonVariant) -> String {
    switch v {
    case .primary: "Save"
    case .secondary: "Edit"
    case .outline: "Copy caption"
    case .ghost: "Skip"
    case .destructive: "Exclude"
    case .destructiveSolid: "Delete"
    }
  }
}

// MARK: - 3 Inputs & choice

struct GalleryInputs: View {
  var body: some View {
    HStack(alignment: .top, spacing: DS.space.xxl) {
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Text field") {
          Grid(alignment: .topLeading, horizontalSpacing: DS.space.lg, verticalSpacing: DS.space.md) {
            GridRow {
              GCell("Default") { GState("") { DSTextField("Title", placeholder: "Type a title", text: $0) }.frame(width: 230) }
              GCell("Hover", forced: .hover) { GState("") { DSTextField("Title", placeholder: "Type a title", text: $0) }.frame(width: 230) }
            }
            GridRow {
              GCell("Focused + hint", forced: .focused) {
                GState("Chanel x Ke Star") { DSTextField("Title", placeholder: "", text: $0, hint: "Used for overlay text and captions") }.frame(width: 230)
              }
              GCell("Error") {
                GState("tiktok.com/@x") { DSTextField("Post URL", placeholder: "", text: $0, error: "Not an Instagram link") }.frame(width: 230)
              }
            }
            GridRow {
              GCell("Disabled + reason") {
                GState("v1") { DSTextField("Version", placeholder: "", text: $0, disabledReason: "Posted versions can't be renamed") }.frame(width: 230)
              }
              GCell("Search (capsule)") {
                GState("") { DSTextField(placeholder: "Search clips", text: $0, size: .sm, isSearch: true) }.frame(width: 230)
              }
            }
          }
        }
        GSection("Text area", note: "composer look · counter grey → amber at 90% → red over") {
          GState("Late night set at the Afroween party — this one went off. Full mix on YouTube.") {
            DSTextArea("Caption", placeholder: "Write a caption", text: $0, hint: "{text} inserts the title", limit: 90, minHeight: 72)
          }
          .frame(width: 476)
        }
        GSection("Select") {
          HStack(alignment: .top, spacing: DS.space.lg) {
            GCell("Default") { GState("auto") { DSSelect(selection: $0, options: kinds) }.frame(width: 150) }
            GCell("Hover", forced: .hover) { GState("dj") { DSSelect(selection: $0, options: kinds) }.frame(width: 150) }
            GCell("Ghost menu") {
              GState("newest") { DSSelect(selection: $0, options: [DSSelectOption(value: "newest", title: "Newest"), DSSelectOption(value: "score", title: "Score")], size: .sm, variant: .ghost, fullWidth: false) }
            }
          }
        }
      }
      .frame(width: 476)
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Switch") {
          VStack(alignment: .leading, spacing: DS.space.sm) {
            GState(true) { DSToggle("Autoplay clips", description: "Muted, from the 540×960 proxies", isOn: $0) }
            GState(false) { DSToggle("Unmute on hover", isOn: $0) }.dsForcedState(.hover)
            GState(false) { DSToggle("Post to X", isOn: $0, disabledReason: "Over 2:20 — trim for X first") }
          }
          .frame(width: 300)
        }
        GSection("Checkbox") {
          HStack(spacing: DS.space.lg) {
            GCell("Off") { DSCheckbox(isOn: false) {} }
            GCell("Hover", forced: .hover) { DSCheckbox(isOn: false) {} }
            GCell("On") { DSCheckbox(isOn: true) {} }
            GCell("Mixed") { DSCheckbox(state: .mixed) {} }
            GCell("Disabled") { DSCheckbox(isOn: true, disabledReason: "Locked") {} }
            GCell("Clip select") { DSCheckbox(isOn: true, size: 20, shape: .circle) {} }
            GCell("On media") {
              DSCheckbox(isOn: false, size: 20, shape: .circle, onMedia: true) {}.padding(6).background(Color(white: 0.35), in: RoundedRectangle(cornerRadius: 6))
            }
          }
        }
        GSection("Slider") {
          VStack(alignment: .leading, spacing: DS.space.md) {
            GState(41.0) { DSSlider(label: "Score", value: $0) }
            GState(64.0) { DSSlider(label: "Text size", value: $0, range: 24...120, format: { "\(Int($0)) pt" }) }.dsForcedState(.focused)
            GState(3.0) { DSSlider(label: "Extra seconds", value: $0, range: 0...10, step: 0.5, format: { String(format: "%.1f s", $0) }, disabledReason: "Using Eric's markers") }
          }
          .frame(width: 300)
        }
        GSection("Chips", note: "toggle · multi-select · platforms = glyph + name") {
          VStack(alignment: .leading, spacing: DS.space.sm) {
            HStack(spacing: 6) {
              DSChip("All", isSelected: true, count: 9) {}
              DSChip("No crop", isSelected: false, count: 4) {}
              DSChip("Hover", isSelected: false) {}.dsForcedState(.hover)
              DSChip("Too long for X", isSelected: false, tone: .warning, count: 1) {}
              DSChip("Missing", isSelected: false, disabledReason: "Nothing missing") {}
            }
            GState(Set<Platform>([.tiktok, .instagram])) { sel in
              DSChipGroup(options: Platform.allCases.sorted { $0.displayName < $1.displayName }.map {
                DSChipOption(value: $0, title: $0.displayName, icon: $0.dsSymbol)
              }, selection: sel, noneTitle: "None", size: .sm)
            }
            .frame(width: 440, alignment: .leading)
          }
        }
        GSection("Segmented · tabs · view mode") {
          VStack(alignment: .leading, spacing: DS.space.sm) {
            HStack(spacing: DS.space.md) {
              GState("worst") { DSSegmented(selection: $0, segments: [DSSegment(value: "worst", title: "Worst → best"), DSSegment(value: "best", title: "Best → worst")]) }
              GState(DSViewMode.wide) { DSViewModeSwitcher(mode: $0) }
            }
            GState("ready") {
              DSTabs(selection: $0, tabs: [DSTab(value: "all", title: "All", count: 63), DSTab(value: "ready", title: "Ready", count: 31),
                                           DSTab(value: "posted", title: "Posted", count: 20), DSTab(value: "excluded", title: "Excluded", count: 2)])
            }
          }
        }
      }
    }
  }

  private var kinds: [DSSelectOption<String>] {
    [DSSelectOption(value: "auto", title: "Default (DJ vid)", icon: nil), DSSelectOption(value: "dj", title: "DJ vid"), DSSelectOption(value: "talk", title: "Talking")]
  }
}

// MARK: - 4 Status & data

struct GalleryStatus: View {
  var body: some View {
    HStack(alignment: .top, spacing: DS.space.xxl) {
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Badges", note: "short words, never sentences") {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              DSBadge("Ready", style: .soft(.success))
              DSBadge("Planned", style: .soft(.info))
              DSBadge("Needs edit", style: .soft(.warning))
              DSBadge("Failed", style: .soft(.danger), icon: "exclamationmark")
              DSBadge("Skipped")
              DSBadge("Talking", style: .outline)
              DSBadge("Due now", style: .solid)
            }
            HStack(spacing: 10) {
              ForEach(Platform.allCases.sorted { $0.displayName < $1.displayName }) { p in DSPlatformIcon(platform: p, size: 20, showsLabel: true) }
            }
            HStack(spacing: 6) {
              DSBadge("Posted", style: .soft(.success), icon: "checkmark", size: .sm)
              DSBadge("Late 1h", style: .soft(.warning), size: .sm)
              DSBadge("v2", style: .outline, size: .sm)
              DSCount(count: 13)
              DSCount(count: 3, style: .attention)
              DSCount(count: 2, style: .danger)
            }
          }
        }
        GSection("Platform icons × state", note: "generic glyph + dot · no logos, no brand colours") {
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
              Text("").frame(width: 100)
              ForEach(DSPlatformState.allCases, id: \.self) { s in Text(s.label).font(DS.type.caption).foregroundStyle(DS.color.textTertiary) }
            }
            ForEach(Platform.allCases.sorted { $0.displayName < $1.displayName }) { p in
              GridRow {
                Text(p.displayName).font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
                ForEach(DSPlatformState.allCases, id: \.self) { s in DSPlatformIcon(platform: p, state: s, size: 24) }
              }
            }
          }
        }
        GSection("Status dots · avatar") {
          HStack(spacing: DS.space.md) {
            HStack(spacing: 6) { DSStatusDot(tone: .success, pulse: true); Text("Engine running").font(DS.type.callout).foregroundStyle(DS.color.textSecondary) }
            HStack(spacing: 6) { DSStatusDot(tone: .warning); Text("Paused").font(DS.type.callout).foregroundStyle(DS.color.textSecondary) }
            HStack(spacing: 6) { DSStatusDot(tone: .danger); Text("Failed").font(DS.type.callout).foregroundStyle(DS.color.textSecondary) }
            HStack(spacing: 6) { DSStatusDot(tone: .neutral, hollow: true); Text("Off").font(DS.type.callout).foregroundStyle(DS.color.textSecondary) }
            DSAvatar(name: "DJ Lovd")
          }
        }
      }
      .frame(width: 560)
      VStack(alignment: .leading, spacing: DS.space.lg) {
        GSection("Stats") {
          HStack(alignment: .top, spacing: DS.space.xxl) {
            DSStat(value: "5d", label: "Approved runway")
            DSStat(value: "21d", label: "Ready runway", hint: "+3 this week")
            DSStat(value: "1d", label: "Low runway", tone: .warning)
            DSStat(value: "41", label: "Score (card)", size: .sm)
          }
        }
        GSection("Progress") {
          VStack(alignment: .leading, spacing: DS.space.md) {
            DSProgress(value: 17.0 / 29, label: "Scored", valueLabel: "17 of 29")
            DSProgress(value: 0.82, tone: .success, height: 6, label: "Render queue", valueLabel: "82%")
            DSProgress(value: nil, label: "Generating proxies")
            HStack(spacing: DS.space.md) {
              DSProgressRing(value: 0.66, centerText: "4/6")
              DSProgressRing(value: 0.3, tone: .warning)
              DSSpinner(size: 18)
            }
          }
          .frame(width: 320)
        }
        GSection("Skeleton") {
          HStack(spacing: DS.space.sm) {
            DSSkeleton(width: 40, height: 64, radius: DS.radius.sm)
            VStack(alignment: .leading, spacing: 8) {
              DSSkeleton(width: 180, height: 12)
              DSSkeleton(width: 120, height: 10)
              DSSkeleton(width: 80, height: 18, radius: 9)
            }
          }
          .padding(DS.space.sm).dsSurface(radius: DS.radius.lg)
          .frame(width: 320, alignment: .leading)
        }
        GSection("Section header · separator") {
          VStack(alignment: .leading, spacing: 10) {
            DSSectionHeader("Planned", count: 8, description: "in posting order") {
              DSButton("Worst → best", trailingIcon: "chevron.down", variant: .ghost, size: .sm) {}
            }
            DSSeparator()
            DSSectionHeader("Backlog", count: 23)
          }
          .frame(width: 400)
        }
        GSection("Empty state") {
          DSEmptyState(icon: "checkmark.circle", title: "Everything is scored", message: "New clips land here after intake.",
                       actionTitle: "Go to Edit", action: {})
            .frame(width: 400, height: 210)
            .dsSurface(DS.color.background, radius: DS.radius.lg, border: DS.color.border)
        }
      }
    }
  }
}
