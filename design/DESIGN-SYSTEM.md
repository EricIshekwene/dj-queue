# DJ Queue design system (round 2)

One central SwiftUI design system with ChatGPT-calm tokens (`design/DESIGN-v2.md` §2). It mirrors the component anatomy of shadcn/ui and Base UI. Code lives in `Sources/DJQueueApp/DesignSystem/`. Decisions and deviations are in `design/DS-DECISIONS.md`.

- **Gallery:** `DSGallery()` is a standalone view with a sidebar of pages, showing every component in every state.
- **Tooltip probe:** `DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1 .build/debug/DJQueueApp --snapshot <dir>` hovers every tooltip type in the real main window (in front but click-through, never activating the app) and captures the window plus the tooltip panel on hover and after leaving, along with `probe.json`; it exits 1 on an empty bubble or one that stays or flashes (TOOLTIPS-DECISIONS #41).
- **PNG render:** `DJQ_SNAPSHOT_GALLERY=1 [DJQ_GALLERY_MEDIA=<local folder>] .build/debug/DJQueueApp --snapshot <dir>` writes `ds-0N-<page>-{light,dark}.png` at 1440×900. You can also call `await DSGallerySnapshot.run(outputDir:)`, or `DSGallerySnapshot.render(_:size:name:to:)` for any view.

## Rules (read first)
1. Use only `DS.*` tokens in screens. If a role is missing, add a token; never write a raw colour or number.
2. **At most one `.primary` per screen.** Everything else is ghost or outline.
3. Blue (`accent`) means only toggle-on, focus ring, link or checked box. Selection is a 2 pt `text` ring plus `selected` fill.
4. Capsules for buttons, chips, segmented controls, search and the bulk bar. Radius 16 for cards and popovers, 10 for rows, inputs and menu items.
5. Status is a chip or a dot, never a sentence. Platforms are a generic glyph plus their name, never a brand colour or logo.
6. Every icon-only or disabled control explains itself. Pass `tooltip:` or `disabledReason:`.
7. No shadows in dark mode (handled by the tokens). Lists use no boxes: rows plus hairlines.

## Tokens

| Group | Tokens (light / dark) |
|---|---|
| Background | `background` #FFF/#212121 · `sidebar` #F9F9F9/#181818 · `canvas` #F4F4F4/#171717 |
| Surface | `surface` = `surfaceRaised` #FFF/#2F2F2F · `surfaceSunken` #F3F3F3/#2A2A2A · `hover` #ECECEC/#2F2F2F · `selected` #E8E8E8/#383838 · `scrim` 40 %/60 % black |
| Lines | `border` 6 %/8 % · `borderStrong` 15 %/15 % · `separator` = border |
| Text | `text` #0D0D0D/#ECECEC · `textSecondary` #5D5D5D/#B4B4B4 · `textTertiary` #8F8F8F |
| Primary | `primary` #0D0D0D/#ECECEC · `primaryText` #FFF/#0D0D0D |
| Accent | `accent` #0285FF/#3B9EFF · `accentSoft` · `focusRing` |
| Status | `success` #10A37F/#19C37D · `warning` #D97706/#F5A524 · `danger` #E02E2A/#FF5B57 · `info` #0285FF/#3B9EFF · `tint(tone)` 10 %/16 % |
| Radius | `xs` 6 · `sm` 10 · `md` 12 · `lg` 16 · `xl` 20 · `pill` (use `Capsule()`) |
| Space | `hair` 2 · `xxs` 4 · `xs` 8 · `sm` 12 · `md` 16 · `lg` 20 · `xl` 24 · `xxl` 32 · `xxxl` 48 |
| Type | `display` 28 · `title` 20 sb · `headline` 15 sb · `body` 14 · `callout` 13 · `caption` 12 · `micro` 11 md · `score` 22 rounded · `mono` 12 · `stat` 28 rounded sb (plus `…Medium`/`…Semibold`) |
| Elevation | `e0` · `e1` (cards) · `e2` (popovers, menus, toasts, bulk bar) · `e3` (modals). Apply with `.dsElevation(_)` |
| Motion | `hover` 120 ms · `layout` spring 0.30/0.85 · `popover` 150 ms · `fade` 200 ms. Use `.dsAnimation`, `dsWithAnimation`, `.dsMove(edge)`, `.dsPop` (all respect Reduce Motion) |
| Size | controls 28/34/40 · sidebar 260 · sidebar row 36 · toolbar 52 · list row 52 · clip card 132 · inspector 340 · reading column 880 · bulk bar 48 |

## Components

States everywhere: default · hover · pressed · focused (accent ring) · disabled with reason (tooltip) · loading where it applies. The gallery renders each one with `.dsForcedState(_)`.

| Component | Anatomy | Variants / states | shadcn / Base UI | Do / don't |
|---|---|---|---|---|
| `DSButton` | [icon/spinner] title [trailing icon] | primary, secondary, outline, ghost, destructive, destructiveSolid × sm/md/lg; `isLoading`, `disabledReason`, `tooltip`, `shortcut`, `fullWidth` | Button | One primary per screen. destructiveSolid only in confirm sheets |
| `DSIconButton` | circle + symbol | same variants; `isOn`; tooltip **required** | Button size=icon + Tooltip | Never icon-only without a tooltip |
| `DSMediaActionButton` | round icon-only button on media (grid tile hover actions) | `disabledReason` (dimmed, still hoverable); tooltip **required** | Button size=icon + Tooltip | Only on media; the tooltip names the consequence |
| `DSButtonStyle` | style for any `Button` | variant, size | buttonVariants() | Use on custom labels |
| `DSTooltip` (`.dsTooltip`) / `DSTooltipBubble` | trigger → positioner (side, 6 pt, flip + shift) → inverse popup in a click-through panel; label · keycaps · disabled reason | `shortcut`, `disabledReason`, `side`, `forceVisible` (gallery); one delay group (500 ms, instant hand-off for 400 ms to the trigger under the pointer); plain text only | Tooltip (Provider/Trigger/Positioner/Popup) | A verb phrase that says the consequence; ≤ 45 chars; required for icon-only controls. See `TOOLTIPS-DECISIONS.md` |
| `DSKeyHint` | keycap | inverted | Kbd | Put shortcut hints at the right edge |
| `DSCard` + `DSCardHeader` / `DSCardFooter` | header (title, description, action) · content · footer | outline (e1), filled, elevated; interactive hover; selected | Card | Don't nest cards |
| `DSBadge` (`DSPill`) | [icon] text capsule | soft(tone), outline, solid; sm/md | Badge | Keep text short |
| `DSCount` | number / capsule | plain, attention (near-black), danger (red) | — | Zero shows nothing |
| `DSStatusDot` | dot | tone, hollow, pulse | — | Use for engine and health state |
| `DSPlatformIcon` / `DSPlatformRow` | glyph in circle + state dot | planned (outlined), due, posted (green dot), failed (red), skipped (dashed), off; `showsLabel` | — | Only for planned/posted clips. No brand colours |
| `DSChip` / `DSChipGroup` | [check][icon] text [count] capsule | selected, tone tint, disabled; multi-select, `noneTitle` | Toggle / ToggleGroup | Use for filters, platforms, hashtag sets |
| `DSSegmented` | sunken track + sliding thumb | text or icon segments (icon needs tooltip); sm/md/lg | Tabs (pill) / ToggleGroup | Use for 2–5 options that change a view |
| `DSTabs` | text tabs, selected grey capsule, count | sm/md | Tabs | Use for page sections |
| `DSViewModeSwitcher` | icon segmented | `DSViewMode` wide(Cards)/grid/single/list | — | Remember the mode per screen (the screens' job) |
| `DSTextField` | label · field (icon, clear) · hint/error · counter | hover, focus, error, disabled reason, `isSearch` capsule, sm/md/lg | Input + Field | Errors say what to fix |
| `DSTextArea` | label · composer box · hint · counter | counter turns amber at 90 %, red over the limit | Textarea | Use for captions |
| `DSSelect` / `DSSelectTrigger` | trigger (value + chevron) → native menu with check | outline / ghost, full width or hug, disabled reason | Select | Don't hand-roll popups |
| `DSToggle` / `DSSwitch` | label + description ← → switch | on = accent, hover, disabled reason, sm | Switch | Use for settings that apply immediately |
| `DSCheckbox` | box/circle + label + description | off/on/mixed, square/circle, onMedia, disabled reason | Checkbox | Circle = clip selection |
| `DSSlider` | label · value chip · track/knob | hover, focused (arrow keys), dragging, disabled reason; step, range, format | Slider | Always show the value |
| `DSProgress` / `DSProgressRing` / `DSSpinner` | track + fill | value or indeterminate, tone | Progress | — |
| `DSSkeleton` | pulsing rounded block | width/height/radius | Skeleton | Match the real layout's shapes |
| `DSSeparator` | hairline | vertical, inset | Separator | Prefer a separator over a box |
| `DSAvatar` | initials or image | size | Avatar | — |
| `DSStat` | big number · label · hint | sm/md/lg, tone | — | Use for runway and counts |
| `DSSectionHeader` / `DSEyebrow` | title · count · description · action | — | — | Sentence case |
| `DSEmptyState` | 40 pt sunken tile icon · title · line · one primary, optional outline second action | — | Empty | One primary action; the second is a quieter way out |
| `DSPopoverSurface` / `.dsPopover` | r.lg e2 panel | — | Popover | — |
| `DSMenuList` / `DSMenuItem` | label · item (icon, shortcut/check) · separator · destructive | hover, disabled reason | DropdownMenu | Context menus stay native |
| `DSDialog` / `.dsSheet` / `DSChangeList` | icon · title · description · close · body · footer | width 480, e3 | Dialog / AlertDialog | A bulk action lists its changes, Cancel + primary |
| `DSToast` / `.dsToast` | tone icon · message · detail · action · close | auto-dismiss, sticky | Sonner | "Updated 9 clips · Undo" |
| `DSBulkBar` / `.dsBulkBar` / `DSBulkActionStyle` | ✕ · count · [Select all] · divider · ≤4 ghost actions · trailing (More ▾ + primary) | — | — (Cosmos pattern) | Never more than 4 visible actions |
| `DSToolbar` | title · context line · centre · trailing | divider optional | — | Trailing = view toggle, ⋯, one primary |
| `DSSidebarItem` | symbol · label · count/dot | selected, hover, countStyle | Sidebar (menu button) | — |
| `DSAttentionCard` (`DSBanner`) | icon · title · message · action · [dismiss] | danger (not dismissible), warning (24 h) | Alert | Top of content, never full-bleed |
| `DSFlowLayout` | wrapping layout | spacing | — | For chip rows |
| `DSVideoPreview` | poster → muted looping proxy (fade 200 ms) · mute 24 pt · scrubber | `isActive`, `isPriority`, `loopRange`, `unmuteOnHover`, `muteAlignment`, `showsScrubber` | — | Budget ≤4 players (`DSPlaybackBudget.shared.maxPlayers`). Never auto-unmute |
| `DSListHeader` (+ `ListHeader` app wrapper) | title + count · search · view modes · status chips · Filters · sort; applied chips + Clear all | page (2 rows + applied row; `columnWidth` for reading-column screens) / compact (drawers) | — | The ONE header on every clip list (Score, Edit, Queue, Library, Posts). State per page in `ListPrefs` (UserDefaults), ⌘F focuses search |
| `DSFilterButton` / `DSFilterPanel` | "≡ Filters N" outline capsule → popover: sections (eyebrow + option chips with counts) · Clear all | same look applied or not (count only) | Popover + ToggleGroup | Sections are data (`DSFilterSection`): Session · Kind · Score + page sections. No "Any" chip; click a chosen option to remove it |
| `DSAppliedFilters` / `DSRemovableChip` | "Kind: Talking ✕" chips · Clear all | hover, sm | Badge + remove | Shown only while a filter is on |
| `DSSearchField` | capsule: ⌕ · field · ✕ / ⌘F keycap | hover, focused, sm; `focusToken` | Input | Esc clears, then unfocuses |
| `DSSortMenu` | "⇅ Session order ▾" → native menu with check (+ notes) | hover, sm | DropdownMenu (radio) | Names the order, never just "Sort" |
| `DSStatusChips` | All N · chip N … single choice | tone for trouble chips | ToggleGroup (single) | Page status only (missing reasons, Scheduled / Not scheduled, Problems …) |
| `DSClipCard` | see below | `.wide` (Cards) / `.grid` / `.single` / `.list` | — | Feed it a `DSClip`. Never put the version on a card |

### DSClipCard (DESIGN-v2 §4)
- **Model `DSClip`:** id, title (Title or raw tag), subtitle (session), poster, proxyURL, loopRange, durationText, kind, score, position, status, tags, issues (warning chips), blocks (danger chips), suggestions (`DSTitleSuggestion`, outlined chips), platforms (`DSClipPlatform`), dateText, isPinned, isMissing. Meta line = session · duration · kind.
- **Config `DSClipCardConfig`:** autoplay, unmuteOnHover, selectionMode, showsDragHandle.
- **Callbacks:** `onToggleSelect`, `onTap(EventModifiers)` (⇧ range / ⌘ toggle, implemented by the screen), `onAcceptSuggestion`. The `actions` slot holds hover actions and ⋯.
- **Cards (`.wide`):** 132 tall, r.lg, e1, padding 12, max 880. Layout: drag handle · 20 pt circle checkbox (on hover or in selection mode) · position · 63×112 thumb (cover at rest, plays while hovered) · title/meta/chips · platforms · date chip · score · actions.
- **Grid:** cover r.md 9:16, checkbox top-left, score capsule top-right, duration bottom-left, mute bottom-right, hover actions on the cover. Below: title, meta, ≤2 chips.
- **Single:** player r.xl with sound toggle and hover scrubber. 280 pt side panel with title, meta, chips, platforms, and the `actions` slot (score field, Kind, Exclude). Not selectable.
- **List:** 52 pt row, hairline separators, hover fill r.sm, 24×42 thumb (cover at rest, plays while hovered). Columns: kind chip · score · date · platforms · actions.

## Notes for the screen and editor builders
- Map AppModel to `DSClip` in one helper per screen. Pass `isFocused` for the keyboard-focused card (it gets autoplay priority). Use `Lazy` stacks/grids so previews release when scrolled away.
- Bulk flow: `.dsBulkBar(isPresented:)` → `DSDialog` + `DSChangeList` confirmation → `.dsToast` "Updated N clips · Undo".
- Settings modal rows: `DSToggle` / `DSSelect` with descriptions. A "Default/Custom ↺" tag isn't a component yet: build it from a `DSBadge(.outline)` plus a `DSIconButton("arrow.uturn.backward")`.
- Phone mocks, timeline and the ⌘K palette are screen/editor work. Build them from `DSPopoverSurface`, `DSMenuList`, `DSTextField(isSearch:)` and `DSKeyHint`. The palette's type chips are `DSStatusChips` at size `.sm`.
