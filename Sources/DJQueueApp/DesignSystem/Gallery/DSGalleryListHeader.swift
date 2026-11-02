import SwiftUI

// MARK: - 9 List header & filters (round 4 S3 + S4)

/// The shared clip-list header: page and compact layouts, the Filters popover body, applied chips + Clear all, the
/// search field, sort menu and status chips, each in its states. Native popovers can't be captured, so the popover
/// body is drawn in a `DSPopoverSurface`.
struct GalleryListHeader: View {
  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xl) {
      GSection("List header · page", note: "title + count · search · view modes · status chips · Filters · sort") {
        VStack(alignment: .leading, spacing: DS.space.lg) {
          sample(applied: [:]).frame(width: 1080)
          sample(applied: ["kind": "talking", "session": "s1"], search: "yayo").frame(width: 1080)
        }
      }
      GSection("Filters popover", note: "Session · Kind · Score + page sections · nothing highlighted until applied") {
        HStack(alignment: .top, spacing: DS.space.lg) {
          GCell("none applied") {
            DSPopoverSurface(width: 340) { DSFilterPanel(sections: Self.sections([:]), onSelect: { _, _ in }, onClearAll: {}) }
          }
          GCell("two applied") {
            DSPopoverSurface(width: 340) {
              DSFilterPanel(sections: Self.sections(["kind": "talking", "score": "top"]), onSelect: { _, _ in }, onClearAll: {})
            }
          }
          GCell("search only (Clear all on)") {
            DSPopoverSurface(width: 340) {
              DSFilterPanel(sections: Array(Self.sections([:]).prefix(2)), onSelect: { _, _ in }, onClearAll: {}, hasSearch: true)
            }
          }
        }
      }
      HStack(alignment: .top, spacing: DS.space.xxl) {
        VStack(alignment: .leading, spacing: DS.space.lg) {
          GSection("Filters trigger", note: "same look applied or not; a count when on") {
            HStack(spacing: DS.space.md) {
              GCell("idle") { DSFilterButton(sections: Self.sections([:]), onSelect: { _, _ in }, onClearAll: {}) }
              GCell("hover", forced: .hover) { DSFilterButton(sections: Self.sections([:]), onSelect: { _, _ in }, onClearAll: {}) }
              GCell("2 on") { DSFilterButton(sections: Self.sections(["kind": "talking", "score": "top"]), onSelect: { _, _ in }, onClearAll: {}) }
              GCell("focused", forced: .focused) { DSFilterButton(sections: Self.sections([:]), onSelect: { _, _ in }, onClearAll: {}) }
            }
          }
          GSection("Applied chips", note: "click removes · Clear all") {
            VStack(alignment: .leading, spacing: DS.space.sm) {
              DSAppliedFilters(sections: Self.sections(["kind": "talking", "score": "top"]).filter { $0.selected != nil },
                               onRemove: { _ in }, onClearAll: {})
              HStack(spacing: DS.space.md) {
                GCell("idle") { DSRemovableChip("Kind: Talking") {} }
                GCell("hover", forced: .hover) { DSRemovableChip("Kind: Talking") {} }
                GCell("small") { DSRemovableChip("Score: 80 and up", size: .sm) {} }
              }
            }
          }
        }
        .frame(width: 520, alignment: .leading)
        VStack(alignment: .leading, spacing: DS.space.lg) {
          GSection("Search", note: "capsule · ⌘F focuses it · Esc clears") {
            HStack(spacing: DS.space.md) {
              GCell("idle") { GState("") { DSSearchField(placeholder: "Search clips", text: $0).frame(width: 160) } }
              GCell("hover", forced: .hover) { GState("") { DSSearchField(placeholder: "Search clips", text: $0).frame(width: 160) } }
              GCell("focused · text", forced: .focused) { GState("yayo") { DSSearchField(placeholder: "Search clips", text: $0).frame(width: 160) } }
            }
          }
          GSection("Status chips", note: "single choice, All first") {
            VStack(alignment: .leading, spacing: DS.space.sm) {
              HStack(spacing: DS.space.xs) {
                GState(String?.none) { sel in
                  DSStatusChips(options: [DSStatusChipOption(id: "crop", title: "No crop", count: 4),
                                          DSStatusChipOption(id: "text", title: "No text", count: 6),
                                          DSStatusChipOption(id: "x", title: "Too long for X", count: 1, tone: .danger)],
                                selection: sel, allCount: 9)
                }
              }
              HStack(spacing: DS.space.xs) {
                GState(String?.some("problems")) { sel in
                  DSStatusChips(options: [DSStatusChipOption(id: "problems", title: "Problems", count: 2, tone: .danger),
                                          DSStatusChipOption(id: "scheduled", title: "Scheduled", count: 18),
                                          DSStatusChipOption(id: "posted", title: "Posted", count: 26)],
                                selection: sel, allCount: 46)
                }
              }
            }
          }
          GSection("Sort", note: "names the order") {
            HStack(spacing: DS.space.md) {
              GCell("idle") { GState("session") { DSSortMenu(options: Self.sorts, selection: $0) } }
              GCell("hover", forced: .hover) { GState("newest") { DSSortMenu(options: Self.sorts, selection: $0) } }
              GCell("small") { GState("high") { DSSortMenu(options: Self.sorts, selection: $0, size: .sm) } }
            }
          }
        }
        .frame(width: 540, alignment: .leading)
      }
      GSection("List header · compact", note: "drawers (Week › Next up): one row, small controls") {
        GState("") { q in
          HStack(spacing: DS.space.xs) {
            DSIconButton("chevron.down", tooltip: "Hide the backlog", size: .sm) {}
            DSListHeader("Next up", count: 4, of: 6, search: q, searchPlaceholder: "Search clips",
                         filters: Self.sections(["score": "top"]), onFilter: { _, _ in }, onClearAll: {}, compact: true) {
              EmptyView()
            } sort: {
              GState("natural") { DSSortMenu(options: [DSSortOption(id: "natural", title: "Queue order")], selection: $0, size: .sm) }
            } trailing: {
              Text("Drag a clip onto a day").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            }
          }
          .frame(width: 1080)
        }
      }
    }
  }

  private func sample(applied: [String: String], search: String = "") -> some View {
    GState(search) { q in
      DSListHeader("Library", count: applied.isEmpty ? 63 : 4, of: 63, search: q, searchPlaceholder: "Search clips",
                   filters: Self.sections(applied), onFilter: { _, _ in }, onClearAll: {}, modes: {
        GState(DSViewMode.grid) { DSViewModeSwitcher(mode: $0) }
      }, chips: {
        GState(String?.none) { sel in
          DSStatusChips(options: [DSStatusChipOption(id: "posted", title: "Posted", count: 20),
                                  DSStatusChipOption(id: "excluded", title: "Excluded", count: 2),
                                  DSStatusChipOption(id: "missing", title: "Missing", count: 1, tone: .danger),
                                  DSStatusChipOption(id: "long", title: "Long-form", count: 1)],
                        selection: sel, allCount: applied.isEmpty ? 63 : 4)
        }
      }, sort: {
        GState("session") { DSSortMenu(options: Self.sorts, selection: $0) }
      })
    }
  }

  static let sorts = [DSSortOption(id: "session", title: "Session order"), DSSortOption(id: "newest", title: "Newest first"),
                      DSSortOption(id: "high", title: "Score, best first")]

  static func sections(_ applied: [String: String]) -> [DSFilterSection] {
    [
      DSFilterSection(id: "session", title: "Session", options: [
        DSFilterOption(id: "s1", title: "Afroween Jazz Piano", count: 38), DSFilterOption(id: "s2", title: "Lagos Rooftop", count: 25),
      ], selected: applied["session"]),
      DSFilterSection(id: "kind", title: "Kind", options: [
        DSFilterOption(id: "dj", title: "DJ vid", count: 51), DSFilterOption(id: "talking", title: "Talking", count: 12),
      ], selected: applied["kind"]),
      DSFilterSection(id: "score", title: "Score", options: [
        DSFilterOption(id: "unscored", title: "Unscored", count: 9), DSFilterOption(id: "top", title: "80 and up", count: 3),
        DSFilterOption(id: "good", title: "60 – 79", count: 14), DSFilterOption(id: "middle", title: "40 – 59", count: 30),
        DSFilterOption(id: "low", title: "Under 40", count: 7),
      ], selected: applied["score"]),
      DSFilterSection(id: "stage", title: "Stage", options: [
        DSFilterOption(id: "score", title: "Score", count: 9), DSFilterOption(id: "edit", title: "Edit", count: 12),
        DSFilterOption(id: "queue", title: "Queue", count: 21), DSFilterOption(id: "scheduled", title: "Scheduled", count: 6),
        DSFilterOption(id: "posted", title: "Posted", count: 15),
      ], selected: applied["stage"]),
    ]
  }
}
