import SwiftUI

// MARK: - List header (round 4 S3 + S4)

/// The one header every clip list uses (Score, Edit, Queue, Library, Posts), in a fixed
/// order: **title + count · search · view modes · page status chips · Filters · sort**, then the applied filters as
/// removable chips with **Clear all**.
///
/// ```
/// page:     Library 63 · 12 of 63          [⌕ Search clips  ⌘F] [▦ ▤ ▭ ≡] [extras] [primary]
///           (All 63) (Posted 4) (Missing 1)                         [≡ Filters 2] [⇅ Session order ▾]
///           [Session: Nov 1 ✕] [Kind: Talking ✕]  Clear all
///
/// compact:  Clips 6  [⌕ Search]  (chips)                             [≡ Filters] [⇅ Queue order ▾]
/// ```
/// - Page layout: row 1 is the 52 pt toolbar (title + count left; search, view modes, extras, the screen's one
///   primary right). Row 2 holds the status chips, then Filters and sort at its trailing edge. Row 3 appears only
///   while a filter is applied. `columnWidth` centres rows 2–3 in the reading column (Cards/List screens).
/// - Compact layout (drawers): one row, smaller type, no view modes; the applied row under it.
/// - Filters are data (`DSFilterSection`), so every list draws the same popover and chips. An unapplied filter is
///   never highlighted: the Filters trigger keeps its outline look and only shows a count; the chips row says
///   what is applied.
struct DSListHeader<Modes: View, Chips: View, Sort: View, Trailing: View>: View {
  let title: String
  var count: Int?
  var total: Int?
  var detail: String?
  var search: Binding<String>?
  var searchPlaceholder: String
  var searchFocus: Int
  /// Focus the search as soon as it appears (a ⌘F that arrived before the field existed).
  var searchAutoFocus: Bool
  var onSearchFocused: () -> Void
  var filters: [DSFilterSection]
  var onFilter: (String, String?) -> Void
  var onClearAll: () -> Void
  var compact: Bool
  var columnWidth: CGFloat?
  /// Space beside the reading column taken by a side panel (Posts' inspector): rows 2–3 stay over the list.
  var columnTrailingInset: CGFloat
  @ViewBuilder var modes: Modes
  @ViewBuilder var chips: Chips
  @ViewBuilder var sort: Sort
  @ViewBuilder var trailing: Trailing

  init(_ title: String, count: Int? = nil, of total: Int? = nil, detail: String? = nil,
       search: Binding<String>? = nil, searchPlaceholder: String = "Search", searchFocus: Int = 0,
       searchAutoFocus: Bool = false, onSearchFocused: @escaping () -> Void = {},
       filters: [DSFilterSection] = [], onFilter: @escaping (String, String?) -> Void = { _, _ in },
       onClearAll: @escaping () -> Void = {}, compact: Bool = false, columnWidth: CGFloat? = nil,
       columnTrailingInset: CGFloat = 0,
       @ViewBuilder modes: () -> Modes = { EmptyView() }, @ViewBuilder chips: () -> Chips = { EmptyView() },
       @ViewBuilder sort: () -> Sort = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.title = title
    self.count = count
    self.total = total
    self.detail = detail
    self.search = search
    self.searchPlaceholder = searchPlaceholder
    self.searchFocus = searchFocus
    self.searchAutoFocus = searchAutoFocus
    self.onSearchFocused = onSearchFocused
    self.filters = filters
    self.onFilter = onFilter
    self.onClearAll = onClearAll
    self.compact = compact
    self.columnWidth = columnWidth
    self.columnTrailingInset = columnTrailingInset
    self.modes = modes()
    self.chips = chips()
    self.sort = sort()
    self.trailing = trailing()
  }

  private var applied: [DSFilterSection] { filters.filter { $0.selected != nil } }
  private var hasSearch: Bool { !(search?.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
  private var hasRow2: Bool { Chips.self != EmptyView.self || !filters.isEmpty || Sort.self != EmptyView.self }

  var body: some View {
    if compact { compactBody } else { pageBody }
  }

  // MARK: Page

  private var pageBody: some View {
    VStack(spacing: 0) {
      HStack(spacing: DS.space.sm) {
        DSListTitle(title: title, count: count, total: total, detail: detail)
        Spacer(minLength: DS.space.md)
        HStack(spacing: DS.space.xs) {
          if let search { DSSearchField(placeholder: searchPlaceholder, text: search, focusToken: searchFocus, autoFocus: searchAutoFocus,
                                     onFocused: onSearchFocused).frame(width: 220) }
          modes
          trailing
        }
      }
      .frame(height: DS.size.toolbar)
      if hasRow2 {
        HStack(spacing: DS.space.xs) {
          if Chips.self != EmptyView.self {
            // Many chips (a long list of missing reasons or sessions) scroll sideways; Filters and sort stay put.
            ScrollView(.horizontal) {
              HStack(spacing: DS.space.xs) { chips }.padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
          } else {
            Spacer(minLength: DS.space.xs)
          }
          if !filters.isEmpty { DSFilterButton(sections: filters, onSelect: onFilter, onClearAll: onClearAll, hasSearch: hasSearch) }
          sort
        }
        .modifier(DSColumnFrame(width: columnWidth, trailingInset: columnTrailingInset))
        .padding(.bottom, DS.space.sm)
      }
      if !applied.isEmpty {
        DSAppliedFilters(sections: applied, onRemove: { onFilter($0, nil) }, onClearAll: onClearAll)
          .modifier(DSColumnFrame(width: columnWidth, trailingInset: columnTrailingInset))
          .padding(.bottom, DS.space.sm)
          .transition(.opacity)
      }
    }
    .dsAnimation(DS.motion.layout, value: applied.map(\.id))
  }

  // MARK: Compact

  private var compactBody: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: DS.space.xs) {
        DSListTitle(title: title, count: count, total: total, detail: detail, compact: true)
        if let search {
          DSSearchField(placeholder: searchPlaceholder, text: search, focusToken: searchFocus, size: .sm, autoFocus: searchAutoFocus,
                        onFocused: onSearchFocused)
            .frame(width: 200)
            .padding(.leading, DS.space.xs)
        }
        modes
        chips
        Spacer(minLength: DS.space.xs)
        if !filters.isEmpty {
          DSFilterButton(sections: filters, onSelect: onFilter, onClearAll: onClearAll, size: .sm, hasSearch: hasSearch)
        }
        sort
        trailing
      }
      if !applied.isEmpty {
        DSAppliedFilters(sections: applied, onRemove: { onFilter($0, nil) }, onClearAll: onClearAll, size: .sm)
      }
    }
  }
}

/// Rows 2–3 of a page header: the reading column (centred), less a side panel's width at its trailing edge.
struct DSColumnFrame: ViewModifier {
  let width: CGFloat?
  var trailingInset: CGFloat = 0
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: width ?? .infinity, alignment: .leading)
      .padding(.trailing, trailingInset)
      .frame(maxWidth: width.map { $0 + trailingInset } ?? .infinity, alignment: .leading)
      .frame(maxWidth: .infinity)
  }
}

/// "Library 63", "Library 12 of 63", plus an optional quiet context ("next Thu 5 Nov").
struct DSListTitle: View {
  let title: String
  var count: Int?
  var total: Int?
  var detail: String?
  var compact = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : DS.space.xs) {
      Text(title).font(compact ? DS.type.calloutSemibold : DS.type.title).foregroundStyle(DS.color.text).lineLimit(1)
      if let count {
        Text(countText(count)).font((compact ? DS.type.callout : DS.type.title).monospacedDigit())
          .foregroundStyle(DS.color.textTertiary).lineLimit(1)
          .contentTransition(.numericText())
      }
      if let detail {
        Text(detail).font(compact ? DS.type.caption : DS.type.callout).foregroundStyle(DS.color.textSecondary).lineLimit(1)
      }
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
  }

  private func countText(_ n: Int) -> String {
    guard let total, total != n else { return "\(n)" }
    return "\(n) of \(total)"
  }
}

// MARK: - Search

/// Capsule search field for list headers: magnifier, clear button, and a ⌘F keycap while empty. Bumping
/// `focusToken` (⌘F) focuses it; `autoFocus` focuses it when it appears (⌘F pressed before it existed).
struct DSSearchField: View {
  let placeholder: String
  @Binding var text: String
  var focusToken = 0
  var size: DSButtonSize = .md
  var shortcut: String? = "⌘F"
  var autoFocus = false
  var onFocused: () -> Void = {}
  @FocusState private var focused: Bool
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(placeholder: String, text: Binding<String>, focusToken: Int = 0, size: DSButtonSize = .md, shortcut: String? = "⌘F",
       autoFocus: Bool = false, onFocused: @escaping () -> Void = {}) {
    self.placeholder = placeholder
    _text = text
    self.focusToken = focusToken
    self.size = size
    self.shortcut = shortcut
    self.autoFocus = autoFocus
    self.onFocused = onFocused
  }

  var body: some View {
    let isFocused = forced == .focused || focused
    let h = size == .sm ? DS.size.controlSm : DS.size.controlMd
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: size == .sm ? 11.5 : 13, weight: .medium))
        .foregroundStyle(DS.color.textTertiary)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(size == .sm ? DS.type.callout : DS.type.body)
        .foregroundStyle(DS.color.text)
        .focused($focused)
        .onExitCommand { if text.isEmpty { focused = false } else { text = "" } }
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.color.textTertiary)
        }
        .buttonStyle(.plain)
        .dsTooltip("Clear the search")
      } else if let shortcut, !isFocused {
        DSKeyHint(shortcut)
      }
    }
    .padding(.horizontal, size == .sm ? 12 : 14)
    .frame(height: h)
    .modifier(DSFieldBox(focused: isFocused, hovering: forced == .hover || hovering, error: false, disabled: false, radius: h / 2))
    .onHover { hovering = $0 }
    .onChange(of: focusToken) { _, _ in focused = true; onFocused() }
    .onAppear {
      guard autoFocus else { return }
      // Next run-loop turn: the field must be in the window before it can take focus.
      DispatchQueue.main.async { focused = true; onFocused() }
    }
    .dsAnimation(DS.motion.hover, value: isFocused)
    .accessibilityLabel(placeholder)
  }
}

// MARK: - Filters

/// One option in a Filters popover section ("Talking", "80 and up", a session).
struct DSFilterOption: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  var count: Int? = nil
  var icon: String? = nil
  /// What it shows, when the title alone doesn't say.
  var tooltip: String? = nil
}

/// A Filters popover section (Session · Kind · Score, plus page sections). Single choice; `selected` nil = not
/// applied (no option highlighted). The applied chip reads "<title>: <option>".
struct DSFilterSection: Identifiable, Sendable {
  let id: String
  let title: String
  var options: [DSFilterOption]
  var selected: String?

  init(id: String, title: String, options: [DSFilterOption], selected: String? = nil) {
    self.id = id
    self.title = title
    self.options = options
    self.selected = selected
  }

  var selectedOption: DSFilterOption? { selected.flatMap { s in options.first { $0.id == s } } }
  /// "Kind: Talking" (the chip under the header). An option no longer listed still reads by its id.
  var chipText: String { "\(title): \(selectedOption?.title ?? selected ?? "")" }
}

/// "Filters" trigger: an outlined capsule that opens the Filters popover. Applied filters add a count but never a
/// highlight (S4: unapplied and applied triggers look the same; the chips row shows what's on).
struct DSFilterButton: View {
  let sections: [DSFilterSection]
  let onSelect: (String, String?) -> Void
  let onClearAll: () -> Void
  var size: DSButtonSize = .md
  /// A search is typed (Clear all also clears it).
  var hasSearch = false
  @State private var open = false
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  var body: some View {
    let n = sections.filter { $0.selected != nil }.count
    let hot = forced == .hover || forced == .pressed || hovering || open
    let h: CGFloat = size == .sm ? 26 : 30
    Button { open.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease").font(.system(size: size == .sm ? 10.5 : 11.5, weight: .semibold))
          .foregroundStyle(DS.color.textSecondary)
        Text("Filters")
        if n > 0 { Text("\(n)").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textTertiary) }
      }
      .font(size == .sm ? DS.type.caption : DS.type.captionMedium)
      .foregroundStyle(DS.color.text)
      .padding(.horizontal, size == .sm ? 10 : 12)
      .frame(height: h)
      .background(hot ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(DS.color.borderStrong))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsFocusRing(forced == .focused, radius: h / 2)
    .dsTooltip(n == 0 ? "Filter by " + Self.list(sections.map { $0.title.lowercased() }) : "\(n) filter\(n == 1 ? "" : "s") on — change or clear")
    .dsAnimation(DS.motion.hover, value: hot)
    .accessibilityLabel(n == 0 ? "Filters" : "Filters, \(n) on")
    .dsPopover(isPresented: $open, width: 340) {
      DSFilterPanel(sections: sections, onSelect: onSelect, onClearAll: onClearAll, hasSearch: hasSearch)
    }
  }

  /// "session, kind or score".
  static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " or " + items.last!
  }
}

/// The Filters popover body: one section per filter (eyebrow + option chips with counts) and Clear all. Clicking
/// the chosen option again removes that filter.
struct DSFilterPanel: View {
  let sections: [DSFilterSection]
  let onSelect: (String, String?) -> Void
  let onClearAll: () -> Void
  var hasSearch = false

  var body: some View {
    let any = hasSearch || sections.contains { $0.selected != nil }
    VStack(alignment: .leading, spacing: DS.space.sm) {
      HStack {
        Text("Filters").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Spacer()
        DSButton("Clear all", variant: .ghost, size: .sm, disabledReason: any ? nil : "No filters or search on",
                 tooltip: "Remove every filter and the search", action: onClearAll)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: DS.space.md) {
          ForEach(sections) { s in
            VStack(alignment: .leading, spacing: DS.space.xs) {
              DSEyebrow(s.title)
              DSFlowLayout(spacing: 6) {
                ForEach(s.options) { o in
                  let on = s.selected == o.id
                  DSChip(o.title, icon: o.icon, isSelected: on, count: o.count, size: .sm,
                         tooltip: on ? "Remove this filter" : o.tooltip) {
                    onSelect(s.id, on ? nil : o.id)
                  }
                }
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(DS.space.xs)
  }
}

/// The applied filters under a header: one removable chip each, then Clear all.
struct DSAppliedFilters: View {
  let sections: [DSFilterSection]
  let onRemove: (String) -> Void
  let onClearAll: () -> Void
  var size: DSButtonSize = .md

  var body: some View {
    HStack(spacing: 6) {
      ForEach(sections) { s in
        DSRemovableChip(s.chipText, size: size) { onRemove(s.id) }
      }
      DSButton("Clear all", variant: .ghost, size: .sm, tooltip: "Remove every filter and the search", action: onClearAll)
    }
  }
}

/// An applied filter: selected chip look with a trailing ✕; a click anywhere on it removes the filter.
struct DSRemovableChip: View {
  let title: String
  var size: DSButtonSize = .md
  let onRemove: () -> Void
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(_ title: String, size: DSButtonSize = .md, onRemove: @escaping () -> Void) {
    self.title = title
    self.size = size
    self.onRemove = onRemove
  }

  var body: some View {
    let hot = forced == .hover || forced == .pressed || hovering
    let h: CGFloat = size == .sm ? 26 : 30
    Button { dsWithAnimation { onRemove() } } label: {
      HStack(spacing: 6) {
        Text(title).lineLimit(1)
        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
          .foregroundStyle(hot ? DS.color.text : DS.color.textTertiary)
      }
      .font(size == .sm ? DS.type.caption : DS.type.captionMedium)
      .foregroundStyle(DS.color.text)
      .padding(.leading, size == .sm ? 10 : 12)
      .padding(.trailing, size == .sm ? 8 : 10)
      .frame(height: h)
      .background(hot ? DS.color.hover : DS.color.selected, in: Capsule())
      .overlay(Capsule().strokeBorder(DS.color.text.opacity(0.35), lineWidth: 1.2))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .dsFocusRing(forced == .focused, radius: h / 2)
    .dsTooltip("Remove this filter")
    .dsAnimation(DS.motion.hover, value: hot)
    .accessibilityLabel("\(title). Remove filter")
  }
}

// MARK: - Sort

/// One sort choice ("Session order", "Score, best first").
struct DSSortOption: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
}

/// Sort menu at the end of a header row: outlined capsule "⇅ Session order ▾" → native menu with a check on the
/// current order; `notes` add plain lines under a divider (Queue's tie rule).
struct DSSortMenu: View {
  let options: [DSSortOption]
  @Binding var selection: String
  var tooltip = "Change the order"
  var notes: [String] = []
  var size: DSButtonSize = .md
  @State private var hovering = false
  @Environment(\.dsForcedState) private var forced

  init(options: [DSSortOption], selection: Binding<String>, tooltip: String = "Change the order", notes: [String] = [],
       size: DSButtonSize = .md) {
    self.options = options
    _selection = selection
    self.tooltip = tooltip
    self.notes = notes
    self.size = size
  }

  var body: some View {
    let current = options.first { $0.id == selection } ?? options.first
    let hot = forced == .hover || forced == .pressed || hovering
    let h: CGFloat = size == .sm ? 26 : 30
    Menu {
      ForEach(options) { o in
        Button {
          if o.id != selection { dsWithAnimation { selection = o.id } }
        } label: {
          if o.id == current?.id { Label(o.title, systemImage: "checkmark") } else { Text(o.title) }
        }
      }
      if !notes.isEmpty {
        Divider()
        ForEach(notes, id: \.self) { Text($0) }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.arrow.down").font(.system(size: size == .sm ? 10 : 11, weight: .semibold))
          .foregroundStyle(DS.color.textSecondary)
        Text(current?.title ?? "Sort").lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.color.textTertiary)
      }
      .font(size == .sm ? DS.type.caption : DS.type.captionMedium)
      .foregroundStyle(DS.color.text)
      .padding(.horizontal, size == .sm ? 10 : 12)
      .frame(height: h)
      .background(hot ? DS.color.hover : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(DS.color.borderStrong))
      .contentShape(Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { hovering = $0 }
    .dsTooltip(tooltip)
    .accessibilityLabel("Sort: \(current?.title ?? "")")
  }
}

// MARK: - Status chips

/// One page status chip ("No crop 4", "Scheduled 12", "Problems 2").
struct DSStatusChipOption: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  var count: Int? = nil
  var icon: String? = nil
  /// Tint for a chip that signals trouble (Library "Missing", Posts "Problems") while not selected.
  var tone: DSTone? = nil
  var tooltip: String? = nil
}

/// The page status chips of a list header: "All" plus one chip per status, single choice (nil = All). Clicking
/// the chosen chip again goes back to All.
struct DSStatusChips: View {
  let options: [DSStatusChipOption]
  @Binding var selection: String?
  var allTitle: String? = "All"
  var allCount: Int? = nil
  var allTooltip: String? = nil
  var size: DSButtonSize = .md

  var body: some View {
    let current = selection.flatMap { s in options.contains { $0.id == s } ? s : nil }
    if let allTitle {
      DSChip(allTitle, isSelected: current == nil, count: allCount, showsCheck: false, size: size, tooltip: allTooltip) {
        selection = nil
      }
    }
    ForEach(options) { o in
      let on = current == o.id
      DSChip(o.title, icon: o.icon, isSelected: on, tone: on ? nil : o.tone, count: o.count, showsCheck: false, size: size,
             tooltip: on && allTitle != nil ? "Show all again" : o.tooltip) {
        selection = on && allTitle != nil ? nil : o.id
      }
    }
  }
}
