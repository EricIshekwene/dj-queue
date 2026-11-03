# DJ Queue — DESIGN-v2.md (round 2 redesign)

**Status:** LOCKED for round 2 (2026-11-01). Supersedes the visual direction, tokens and screen anatomy in `DESIGN.md`. Behaviour that `DESIGN.md` describes and this file doesn't change (preview == export, the Core Text overlay PNG, the engine process, keyboard scoring, text defaults) still applies. Eric delegated every decision for this round. Each call below gives its reason in one line (**Why:**).

Every reference was viewed before it was locked. Screenshots live only in the local, gitignored `refs/r2/` folder and are never committed. Source links are in `design/REFS-v2.md` and in the index at the end of this file.

Slots that changed: the round-1 slots (`INVENTORY.md`) map onto the pipeline as follows. Q.S6 Score mode becomes **Score**. "To score" / "Needs edit" become **Score** / **Edit**. Q becomes **Queue**. W/T/L/P/H/S/MB keep their jobs.

---

## 1. Visual direction — the ChatGPT feel, translated to macOS

Locked feel: `R2.FEEL` ChatGPT web (sidebar + centred composer + popover menu), with ChatGPT iOS (pill segmented + floating round buttons) and Claude web (suggestion chips under the input) as alternates. `R2.DARK` ChatGPT Images in dark mode sets the dark palette.

1. **Flat, white, quiet.** Content sits on pure white (dark: #212121). The sidebar is one step darker and flat, with no vibrancy material. Lists use no boxes: rows are separated by space or a hairline. **Why:** ChatGPT's calm comes from almost no chrome. Translucent macOS sidebars read as busy next to video.
2. **One near-black primary.** Each screen has at most one filled button: a near-black capsule with white text (dark mode: a white capsule with near-black text). Everything else is a ghost or outlined capsule. Blue (#0285FF) appears only on the toggle-on state, focus rings, links and checked checkboxes. **Why:** this matches ChatGPT ("Save", send ↑, "Log in"), and Principle 3 asks for a single restrained accent.
3. **Soft radii everywhere.** Use capsules for buttons, chips, segmented controls, the bulk bar and the search field. Use 16 pt for cards, modals and the inspector, and 10 pt for rows, menu items and inputs. **Why:** soft rounding is the ChatGPT signature (composer pill, settings modal, account menu).
4. **Media is the only colour.** Clip covers and autoplaying proxies carry the colour. The UI stays greyscale, plus semantic status colour used sparingly. **Why:** DJ footage is saturated, so a neutral frame keeps it the hero.
5. **Centred reading column.** Text-heavy screens (Today, Edit, Queue in Cards view, Posts, Health) centre a column of at most 880 pt in the content area, the way ChatGPT centres its conversation. Media-heavy views (grids, Week, Score) use the full width. **Why:** the scan line stays short and the 1440 pt window feels calm instead of stretched.
6. **Every control explains itself.** Each control has a visible label, or a tooltip when it is icon-only. A disabled control's tooltip says why it is disabled. A field changed from the default shows a small "Custom" tag with ↺ to reset it. **Why:** Principle 3 and staged edits #6/#7/#10.
7. **Status is a chip or a dot, never a sentence.** Missing requirements appear as chips on the card (the `R2.EDIT` pattern). Platform state is a small icon plus dot, shown only when the clip is planned or posted.
8. **Native, not web-imitation.** Keep `NavigationSplitView`, a unified transparent toolbar, SF Pro, SF Symbols, real `Menu`/`Picker`/`Toggle` behaviour, ⌘K, and context menus. Restyle these through the design system; don't hand-roll replacements. **Why:** native SwiftUI is a binding decision. The design system mirrors shadcn/ui and Base UI anatomy with ChatGPT tokens.

---

## 2. Tokens (proposed, for `DS/Tokens.swift`)

### 2.1 Colour — light / dark (hex)

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg.app` | #FFFFFF | #212121 | content background |
| `bg.sidebar` | #F9F9F9 | #181818 | sidebar, settings-modal nav |
| `bg.canvas` | #F4F4F4 | #171717 | editor canvas behind the preview |
| `surface.raised` | #FFFFFF | #2F2F2F | cards, inspector, popovers, bulk bar, composer-style fields |
| `surface.sunken` | #F3F3F3 | #2A2A2A | input fill, segmented track, empty-state icon tile |
| `fill.hover` | #ECECEC | #2F2F2F | row hover, ghost button hover |
| `fill.selected` | #E8E8E8 | #383838 | selected sidebar row, selected segment |
| `border.subtle` | #0000000F (6 %) | #FFFFFF14 (8 %) | hairlines, card border |
| `border.strong` | #00000026 (15 %) | #FFFFFF26 (15 %) | inputs, outlined buttons, focus-less chips |
| `text.primary` | #0D0D0D | #ECECEC | titles, body |
| `text.secondary` | #5D5D5D | #B4B4B4 | meta, labels |
| `text.tertiary` | #8F8F8F | #8F8F8F | placeholders, counts, disabled |
| `primary.bg` / `primary.fg` | #0D0D0D / #FFFFFF | #ECECEC / #0D0D0D | the one filled button per screen |
| `accent` | #0285FF | #3B9EFF | toggle-on, focus ring, link, checked checkbox |
| `status.success` | #10A37F | #19C37D | posted, healthy |
| `status.warning` | #D97706 | #F5A524 | missing, late, low runway |
| `status.danger` | #E02E2A | #FF5B57 | failed, copyright, missing file |
| `status.info` | #0285FF | #3B9EFF | planned, rendering |
| `tint.success/warning/danger` | 10 % of the status colour over `bg.app` | 16 % over `bg.app` | chip and attention-card backgrounds |
| `overlay.scrim` | #00000066 | #00000099 | settings modal and sheet scrim |

Platform colours are **not** used. Platforms are identified by a drawn generic glyph plus their name, never a logo or brand colour.

### 2.2 Radii

| Token | pt | Where |
|---|---|---|
| `r.xs` | 6 | list thumbnails, duration badge |
| `r.sm` | 10 | rows, menu items, inputs, tile thumbnails, segmented segment |
| `r.md` | 12 | grid tiles, Week day cards, toasts |
| `r.lg` | 16 | horizontal clip cards, inspector, popovers, settings modal, attention cards |
| `r.xl` | 20 | Score large player, phone mock screen (device bezel 44) |
| `r.full` | capsule | buttons, chips, segmented track, search, bulk bar, pills |

### 2.3 Spacing (4-pt grid)

`2 · 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48`. Card padding 12. Gap between cards 8 (Cards view) or 16 (grid). Screen gutters 24, or 32 when the content area is 1100 pt or wider. Section gap 32. Inspector section padding 16.

### 2.4 Type (SF Pro, Dynamic Type off on macOS; tabular figures for every number)

| Token | Size/line | Weight | Use |
|---|---|---|---|
| `display` | 28/34 | Regular | empty-state hero, Score number field |
| `title` | 20/26 | Semibold | screen title in toolbar area |
| `headline` | 15/20 | Semibold | card title, section header |
| `body` | 14/20 | Regular | default text, fields |
| `callout` | 13/18 | Regular | meta lines, menu items, sidebar rows |
| `caption` | 12/16 | Regular | counts, chip text, helper text |
| `micro` | 11/14 | Medium | badges, duration, eyebrow (sentence case, no all-caps) |
| `score` | 22/26 | Semibold rounded, tabular | score on cards |
| `mono` | 12/16 | SF Mono | ids, durations in tables |

### 2.5 Elevation

| Token | Recipe | Where |
|---|---|---|
| `e0` | none | rows, page |
| `e1` | 1 pt `border.subtle` + shadow 0 1 2 #0000000A | cards, tiles, inspector, composer-like fields |
| `e2` | 1 pt `border.subtle` + shadow 0 8 24 #0000001F | popovers, menus, bulk bar, toasts, menu-bar window |
| `e3` | shadow 0 24 64 #0000002E + `overlay.scrim` | settings modal, confirmation sheets |

In dark mode, swap shadows for `border.subtle` plus a surface one step lighter (#2F2F2F). Shadows on dark backgrounds read as dirt.

### 2.6 Motion

- Hover/press: 120 ms ease-out (background and opacity only).
- Layout (reorder, card expand, bulk bar in/out): spring response 0.30, damping 0.85.
- Bulk bar: slides up 12 pt and fades in. Popovers scale from 0.97 and fade, 150 ms.
- Score "save & next": the current clip slides left 24 pt and fades, the next fades in (200 ms).
- Autoplay: proxies fade in over the poster in 200 ms. Never auto-unmute.
- `accessibilityReduceMotion` replaces every movement with an opacity fade.

---

## 3. Shell at 1440×900

Locked: `R2.NAV` ChatGPT web sidebar (alt: ChatGPT iOS drawer). Menus follow `R2.MENU` (the ChatGPT account menu).

```
┌ sidebar 260 ─────────┬ toolbar 52 (title · context · view toggle · primary) ─────────────┐
│ DJ Queue        [⇤]  │ [attention card, only when something failed]                       │
│ ⌕ Search clips   ⌘K  │                                                                    │
│                      │                     content (gutters 24/32)                        │
│ ◎ Score          12  │                                                                    │
│ ✎ Edit            9  │                                                                    │
│ ≡ Queue          41  │                                                                    │
│ ▦ Week               │                                                                    │
│ ☀ Today         3 ●  │                                                                    │
│ Browse               │                                                                    │
│ ▤ Library            │                                                                    │
│ ✉ Posts          2 ● │                                                                    │
│ ♥ Health          ●  │                                                                    │
│ …                    │                                    [floating bulk bar when ≥1 sel] │
│ ● Running · next 7pm │                                                                    │
│ ⚙ Settings           │                                                                    │
└──────────────────────┴────────────────────────────────────────────────────────────────────┘
```

- **Sidebar (260 pt, `bg.sidebar`)**: rows 36 pt tall, radius 10, with a 16 pt SF Symbol, `callout` label and a right-aligned count (`caption`, tertiary, tabular). The selected row uses `fill.selected`. The pipeline group (Score → Edit → Queue → Week → Today) has no header, like ChatGPT's top items. The "Browse" eyebrow (`micro`, tertiary) heads Library/Posts/Health. Count rules: Score = unscored, Edit = scored but not ready, Queue = ready + planned, Today = posts due today (count turns into a filled near-black capsule when something is due now), Posts = problems (a red capsule, shown only when there are problems), Health = dot only (green, amber or red). A row with zero shows no number.
- **Sidebar footer** (the slot ChatGPT uses for its account row) shows the engine line (`● Running · next 7:00 PM TikTok`, or an amber `Paused` / red `Engine stopped` dot) and Settings. Clicking the engine line opens a small menu: Pause all posting, Pause one platform ▸, Open Health.
- **Toolbar (52 pt, transparent, unified)**: left has the screen title (`title`) and a secondary context line (`callout`, e.g. "41 ready · next Thu 5 Nov"). Right has the view-mode segmented control when the screen has one, a ⋯ menu, and the screen's single primary capsule. The runway appears as a quiet chip on Queue and Week (`Runway 5 d approved · 21 d ready`, amber below threshold); its popover lists all three numbers.
- **Attention card** replaces the round-1 red bar. It is a 16-radius card at the top of the content, `tint.danger` background, with an icon, "2 posts need attention · Instagram copyright, X failed" and a **Review** button that opens Posts → Problems. It can't be dismissed while unresolved. The amber version (low runway, engine off) can be dismissed for 24 h. **Why:** this keeps loud-error visibility (§0.3) without a full-bleed red stripe that breaks the calm.
- ⌘K palette: a 640 pt `e2` popover with a capsule search field, Recents and Actions, and shortcuts right-aligned in `caption` tertiary.
- Window: minimum 1100×700, default 1440×900. The sidebar collapses to icons under 1200 pt.

---

### 3.1 Clip list header (round 4, S3/S4/S1)

Every clip list (Score, Edit, Queue, Library, Posts, Week's Next up drawer) uses one header (`DSListHeader`), in this
order: **title + count** ("Library 12 of 63") · **search** (⌘F) · **view modes** · [extras, the one primary] /
**status chips** · **Filters** · **sort** / applied filters as removable chips + **Clear all**. Status chips: Score =
sessions, Edit = why clips are in Edit (core reason chips), Queue = Scheduled / Not scheduled, Library = All · Posted
· Excluded · Missing · Long-form, Posts = Problems · Scheduled · Posted. Filters popover: Session · Kind · Score, plus
Stage (Library) and Platform (Posts); an unapplied filter is never highlighted. Search, chip, filters and sort are
remembered per page across relaunch. No "Ready" / "Needs edit" wording anywhere: the stage is the readiness (Edit = not
yet, Queue = complete); Library tiles show the stage name.

---

## 4. Clip card spec — one component, four view modes

Locked: Cards `R2.QUEUE` (Hootsuite horizontal post cards; alt Buffer queue with Grid/List/Calendar toggle). Mode switching follows `R2.VIEWMODES` (Arcade filter pills + grid/list segmented control; alt Frame.io compact list). Grid follows `R2.LIBRARY` (Frame.io portrait tiles with fields under the cover). Single follows `R2.SCORE`. The large wide layout follows `R2.TODAY-alt` (Open's wide media cards with an action).

The view toggle is a segmented capsule in the toolbar, icons only with tooltips: **Cards · Grid · Single · List**. The choice is remembered per screen.

| | **Cards** (horizontal rounded card — default for Edit, Queue) | **Grid** (tiles — default for Library, Score grid) | **Single** (large — default for Score) | **List** (compact — default for Posts history) |
|---|---|---|---|---|
| Size | full column width (max 880), height 132 | tile width 168–220 adaptive (fit columns, 16 gap), cover 9:16 | player height = content height − 168 (≈ 620 at 900 window) → 349×620 | row 52 |
| Container | `surface.raised`, `r.lg`, `e1`, padding 12 | no container. Cover `r.md` + text below | no container. Player `r.xl` on `bg.app` | no container. Hairline separators, hover `fill.hover` `r.sm` |
| Media | 9:16 thumb 63×112 `r.sm`, muted autoplay when visible | cover fills the tile. Autoplay muted. Duration badge bottom-left (`micro` on #000000A0 capsule). Mute button bottom-right 24 pt circle | autoplay with sound toggle, scrub bar on hover | 24×42 thumb `r.xs`, poster only |
| Text | title `headline` (Title or raw tag) · meta `callout` secondary: session · 0:42 · DJ vid | title `callout` semibold, 1 line · meta `caption` secondary | title `headline` + meta beside the player in the side panel | title `callout` + session `caption` |
| Chips | one row: missing (warning-tint), suggestions (outlined, click to accept), state | max 2 chips under the meta | full chip list in the side panel | kind chip only |
| Right side | score (`score`) · next date chip ("Thu 5 Nov" / "Not scheduled") · platform state icons (only planned/posted) · hover actions · ⋯ | score top-right on the cover in a `micro` capsule | big score field | columns: score · next date · platforms · ⋯ |
| Selection | checkbox 20 pt circle at left edge on hover or in selection mode. Selected = 2 pt `text.primary` ring + `fill.selected` | checkbox top-left on the cover | not selectable (one at a time) | checkbox column |
| Drag | handle ⋮⋮ appears on hover at the far left (Queue only) | — | — | — |

Rules: never show the version on cards. Never show platform icons for a clip that isn't planned. Missing-file clips get a danger chip ("File missing · Relink") and no autoplay. Autoplay is capped at four concurrent players, using the focused card and those nearest the viewport centre.

## 5. Bulk selection bar

Locked: `R2.BULK` Cosmos floating pill bar (alts: Grok top floating selection, Recraft dark pill).

- Appears when at least one item is selected (checkbox, ⇧-click range, ⌘-click toggle, ⌘A selects every item in the screen). It floats 16 pt above the bottom edge, centred in the content area, and its width hugs its contents (max 720).
- Container: capsule, height 48, `surface.raised`, `e2`, padding 6. It slides and fades in.
- Contents, left to right: `✕` clear (ghost circle 36) · "**4 selected**" (`callout` semibold) · hairline divider · up to **4 labelled ghost buttons** chosen per screen (icon + short label, `callout`) · `More ▾` menu with the remaining bulk actions · the **primary capsule** on the right for the screen's main bulk action.
  - Score: `Set score…` · `Kind ▾` · `Exclude` · More (`±1/±10`) · primary **Save scores** (only when scores are typed in grid mode).
  - Edit: `Accept top title` · `Caption template ▾` · `Hashtags ▾` · `Kind ▾` · More (apply defaults per section, skip platform, re-render) · primary **Make ready with defaults**.
  - Queue: `Pin to days…` · `Post today` · `Skip platform ▾` · `Exclude` · More · primary **Add to week**.
  - Library: `Score…` · `Kind ▾` · `Exclude/Include` · `Mark long-form posted` · More.
  - Week/Posts: per their actions (swap/remove, reset/skip/retry).
- Any action touching more than one clip opens a confirmation sheet (`e3`, 480 wide). The sheet lists what will change ("9 clips: crop → Default, caption → Template 'DJ set'"), with Cancel and the primary button. After applying, a toast reads "Updated 9 clips · Undo" (⌘Z undoes the whole batch).

---

## 6. Per-screen anatomy at 1440×900

Content area = 1180 × 848 (window minus sidebar and toolbar). "Hidden" lists what deliberately does not appear on the screen.

### 6.1 Score — `R2.SCORE` Google Photos review card (alts: Midjourney ranking with progress and key hints; Runway large player with ‹ ›)
- **Job:** give every new clip a score from 0 to 100, fast.
- **Toolbar:** "Score" · "12 to score" · view toggle (Single · Grid) · no primary button (Enter is the primary).
- **Single (default):** a thin progress strip at the top ("17 of 29 scored", 4 pt bar, `r.full`). In the centre, the 349×620 autoplaying player (`r.xl`) with ‹ › ghost circles at its sides. Under the player sits a **floating control pill** (capsule, `e2`, 56 tall): `[ score field 96 wide, display 28 ] [ Save & next ↩ (primary) ] [ Skip ]`. A 280 pt side panel on the right shows the title/raw tag, session, duration, Kind segmented (DJ vid · Talking), Exclude (ghost) and notes. A key-hint line sits under the pill in `caption` tertiary: "Type 0–100 · ↩ save & next · ⇥ skip · ←/→ previous/next · ⌘⌫ exclude".
- **Grid:** tiles with an inline score field under each. Tab moves to the next tile. The bulk bar appears for multi-select.
- **Hidden:** platforms, dates, captions, versions, editor controls.
- **Empty:** "Everything is scored" + **Go to Edit**.

### 6.2 Edit — `R2.EDIT` Searchable issue cards with chips and actions (alt: Copy.ai inline "missing" chips)
- **Job:** turn scored clips into ready clips.
- **Toolbar:** "Edit" · "9 need work · 0 of 9 ready" · filter chips row under the toolbar (`All 9 · No crop 4 · No text 6 · No caption 3 · Too long for X 1`) · view toggle · primary **Make ready with defaults** (acts on the selection, or on all filtered clips after confirmation).
- **Cards:** each card shows its **missing chips** in warning tint ("No crop", "No text", "No caption") and danger tint for hard blocks ("Too long for X · 2:32 > 2:20 · Trim for X"). Up to 3 **title suggestions** from metadata appear as outlined chips with the matched track in tertiary text (click a chip to set the Title). If there are no suggestions, an inline "Add title" field shows instead. The cover thumb has a "Cover" badge when one is set. The right side has **Open editor** (outlined) and ⋯.
- **Hidden:** dates, platform post state, queue order.
- **Empty:** "Nothing to edit" + **Open Queue**.

### 6.3 Queue — `R2.QUEUE` Hootsuite horizontal cards (alt: Buffer queue tabs + view toggle)
- **Job:** keep ready clips in posting order.
- **Toolbar:** "Queue" · "41 ready · next Thu 5 Nov" · runway chip · sort menu ("Worst → best ▾", tie rule inside) · view toggle. There is **no filled primary**, because the primary act is direct manipulation (drag to reorder).
- **Cards (default):** position number (`caption` tertiary) · drag handle on hover · thumb · title + meta · score · next-date chip · platform state icons (planned = outlined glyph, posted = glyph + green dot, failed = red dot) · pin glyph if pinned. Hover actions: **Post today**, **Pin to date…**, ⋯ (Skip next, Exclude, Open editor).
- **Hidden:** unscored and not-ready clips (those live in Score/Edit), excluded clips, versions.
- **Empty:** "Nothing ready yet" + **Go to Edit**.

### 6.4 Week — `R2.WEEK` Hootsuite week with media cards (alt: TikTok Studio scheduler with portrait tiles)
- **Job:** check and approve the next week.
- **Toolbar:** "‹ Week of 2 Nov ›" · Draft/Approved status pill · runway chip · ⋯ (Rebuild week, Push plan by a day) · primary **Approve week** (⌘↩).
- **Grid:** 7 equal columns with 12 pt gaps. Each day has a header ("Thu 5" in `callout` semibold; today in a near-black capsule) and one day card (`r.md`, `e1`): 9:16 cover full column width (≈ 150×267), title, score, then a stack of slot chips (`TikTok 7:00 PM ●`, state-coloured dot). Drag cards between days to swap. Past days at 50 % opacity. Mac-off periods hatched. Backlog drawer collapsed at the bottom ("Next up · 6").
- **Hidden:** captions, editor controls, history.

### 6.5 Today — `R2.TODAY` Todoist centred Today column (alt: Open wide media cards)
- **Job:** post what's due, by hand, and mark it posted.
- **Layout:** centred 720 column. Header "Today · Sat 1 Nov" + "3 of 6 posted" progress ring. A **Next-up card** (`r.lg`, `e1`) shows "Next: TikTok · 7:00 PM · in 2h 21m", the thumb and the title, with actions [Copy caption] [Open upload page] [**Mark posted**] (primary, only on the due post). Below it come rows (64 pt): time (`mono`), platform glyph + name, thumb, title, status pill (Rendering / Ready / Due now / Late 2 h / Posted / Failed / ©) and per-row ghost actions. The file drag-out handle sits on the thumb.
- **Hidden:** scores, queue order, editor controls.
- **Empty:** "Nothing due today · next Tue 12:30 PM TikTok".

### 6.6 Library — `R2.LIBRARY` Frame.io portrait tiles with fields (alt: ClickUp clips with sub-nav counts)
- **Job:** find any clip in any state.
- **Toolbar:** "Library" · "214 clips" · capsule search · filter pills (`All · Posted · Excluded · Missing · Long-form`, plus `Session ▾`, `Kind ▾`, `Score ▾`) · sort menu · view toggle (Grid default).
- **Grid tiles** show a state chip (Unscored / Needs edit / Ready / Planned / Posted / Excluded / Missing). Long-form tiles are 16:9 with a "Long-form" chip and a **Mark posted** action.
- **Hidden:** pipeline actions beyond the bulk bar. Clicking a clip opens the editor or a quick-look sheet.

### 6.7 Posts — `R2.POSTS` Substack posts list with segmented counts (alt: n8n executions status table)
- **Job:** see what was posted, and fix problems.
- **Toolbar:** "Posts" · segmented `Problems 2 · Scheduled · Posted · All` · search · `Platform ▾` filter.
- **Problems** render as attention cards (`tint.danger`, `r.lg`): platform glyph + name, clip, error type, message, time, a "Raw response" disclosure, and actions (**Fix in editor** = primary, Re-upload anyway, Skip platform, Accept, Reset).
- **List rows:** thumb, title, platform, version (shown here), attempt, state pill, date, URL link icon. Selecting a row opens a 360 pt inspector with the attempt history.

### 6.8 Health — `R2.HEALTH` OpenAI Platform service health (alt: Vanta OK / Needs-attention summary)
- **Job:** prove the engine is running, and give Eric a report to paste.
- **Layout:** centred 880 column. The header row reads "● All systems running" (green check, `headline`), or "2 checks need attention" in amber/red, with **Copy report** (primary) and Run again (outlined) on the right. Next comes the 7-day awake chart (`r.lg` card, 160 tall): green = awake, grey = asleep, red ticks = missed slots. Below it, collapsible **check rows** (48 pt, chevron): Engine, Last tick, Render queue, Disk, Backup, ffmpeg, LaunchAgent. Each row has a status icon, a one-line value and expands to detail plus a suggested fix. Last, the Doctor findings list (severity icon, what, where, fix).
- **Hidden:** clips and posts (they link out).

### 6.9 Settings — `R2.SETTINGS` ChatGPT settings modal rows (alt: ChatGPT fields + toggles + Cancel/Save)
- **Container:** an in-app modal of 760×560, `r.lg`, `e3`, opened from the sidebar Settings row or ⌘,. The left nav (200, `bg.sidebar`) has a ✕ at top-left and 16 pt icon rows: General, Platforms, Schedule, Queue, **New clip defaults**, Captions & titles, Rendering, Playback & autoplay, Alerts, Engine. The right pane (`body`) shows the section title (`headline`) and a hairline.
- **Row anatomy** (ChatGPT): label (`body`) with a description under it (`caption` secondary, at most 2 lines), and the trailing control right-aligned (a menu showing its current value + chevron, a toggle in `accent`, a stepper or a short field). Rows are 56–72 pt with hairline separators. Most settings apply immediately. Sections that edit as a set (New clip defaults) end with Cancel / **Save**.
- Per Principle 1, no setting may imply the app guesses: wording says "Default …", never "Smart" or "Auto-suggest".

### 6.10 Menu bar — `R2.MENUBAR` Crouton anchored popover with metric + chips (alt: Lyssna next-session countdown) — **weak match**
- `MenuBarExtra` window, 320 wide, `r.lg`, `e2`. The header shows "Next post" (`caption` secondary) with the countdown "2h 21m" (`display`) and a row (platform glyph, time, thumb, title). Below it, a chip row: [Copy caption] [**Mark posted**] (primary only when due). Then a due list (at most 3 rows), a danger row when there are problems ("2 need attention › Review"), and a footer: Open DJ Queue · Pause posting (toggle).
- Icon: template glyph + runway number; red dot on errors; grey when the engine is off; pause glyph when paused.

### 6.11 Empty states — `R2.EMPTY` v0 (alt: Babbel)
- Centred in the content area: a 20 pt SF Symbol in a 40 pt `surface.sunken` tile (`r.sm`), a title (`headline`), one line (`callout` secondary), and **one** near-black capsule button. No illustrations.

---

## 7. Editor layout + inspector

Locked: `R2.EDITOR` Arcade floating inspector with segmented controls (alts: ElevenLabs vertical preview with sliders and value fields; ChatGPT iOS composer chips for suggestion and option chips). Round-1 `E.S1`–`E.S9` interaction specs (crop drag/zoom, timeline handles, cover filmstrip) stay. Only the look and layout change.

```
┌ header 52: ‹ Back · Title ▾ · ‹ › clip · [2 to fix] chip ······················· Done ┐
│ canvas (bg.canvas)                                          ┌ inspector 340, r.lg, e1 ┐ │
│      [ Frame | Safe zones | Phone ]   ← segmented capsule   │ Title                    │ │
│                                                             │  (chip)(chip)(chip)      │ │
│            ┌───────────┐                                    │  [ Title field      ] ↺  │ │
│            │  preview  │  9:16 at 340×604 (Frame/Safe)      │ Frame   9:16 4:5 1:1 16:9│ │
│            │           │  or phone mock 300×650 (Phone)     │  Zoom ───●──── 1.2×      │ │
│            └───────────┘                                    │ Text  …  Caption …       │ │
│   [TikTok][Reels][FB][Shorts][Threads][X]  ← platform chips │ Cover …  Platforms …     │ │
├ timeline 148: filmstrip · trim handles · markers · grace zone · text bar ──────────────┤ │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Full window.** The editor takes over the window, with the sidebar hidden. ‹ Back returns to the screen it came from. **Why:** the preview must be as large as possible, and Edit → editor → Edit is a loop.
- **Header 52:** ‹ Back · Title (click to rename) · ‹ › previous/next clip in the current list · validation chip ("2 to fix" in warning tint, or "Ready" in success tint; click scrolls to the first problem) · version picker `v1 ▾` (versions are only visible here) · **Done** (primary).
- **Canvas (`bg.canvas`):** a mode segmented control at the top centre: **Frame** (crop on the dimmed 16:9 source), **Safe zones** (platform overlays tinted and labelled, multi-select chips: all six or None), and **Phone** (realistic mock, §8). In Phone mode the platform chips under the preview are single-select. The preview sits at 340×604 in Frame/Safe modes and in a 300×650 device in Phone mode.
- **Inspector (340 wide, floating card inset 12 from top/right/bottom, scrolls):** sections separated by a full-width hairline (`DSSeparator`, 20 pt above and below) with `DSSectionHeader` titles and secondary field labels (round 5: sections ran together at 24 pt gaps). There are no tabs: one scrolling column with a sticky mini-index at the top (Title · Frame · Text · Caption · Cover · Platforms). **Why:** Arcade and ChatGPT settings both show one calm column, and tabs hide what's missing.
  - **Title:** "Title suggestions" chips (outlined capsules, `caption`, tracks in tertiary text) from `title_suggestions`, then the raw tag as a ghost chip, then a text field. No suggestions shows just the field and the hint "No title suggestions yet".
  - **Frame:** aspect segmented (9:16 · 4:5 · 1:1 · 16:9), zoom slider with a value field ("1.2×"), anchor menu, and an amber "Upscaled 1.4×" chip when needed.
  - **Text:** field (grows to 2–5 lines), "Text suggestions" chips from `text_suggestions` (same capsules, up to 4 lines each, confidence in tertiary text; a click puts it on this version, the current one has a check; none = "No text suggestions yet" + Ask an agent; round 5), 3 style tiles drawn in their own style (selected = 2 pt ring), size slider + value, align segmented, timing (from/to fields), "No text" toggle.
  - **Caption:** multi-line field (composer look: `surface.raised`, `r.lg`, `border.strong`), a single labelled length line ("412 characters"; per-platform warnings appear only near or over a limit, e.g. "X: 412 / 280 · Drop hashtags for X · Write an X caption"), hashtag set chips, YouTube title field (100 limit), per-platform override disclosure.
  - **Cover:** frame filmstrip selector + "Include text" toggle.
  - **Platforms:** "Post to" chips (six) and safe-zone chips.
  - Every field shows a `micro` tag at its right: "Default" (tertiary) or "Custom" (primary text) with ↺ reset.
- **Timeline (148 tall, spans canvas width):** filmstrip with yellow trim handles. Eric's markers are ticks (snap). The 3 s grace extension zone is a hatched, extendable band. The text bar track sits above. Per-platform trim lanes appear only when used. Playback controls are centred above the filmstrip (ElevenLabs pattern).

---

## 8. Per-platform phone mock geometry

Sources: `R2.MOCK.<platform>` (all iOS, measured on 1179×2556 / 1125×2436 screenshots with a 5 % grid). The mocks are **drawn generically**: SF Symbols for icons, a plain wordmark-free top bar, the clip's real Title/caption/handle, and a placeholder avatar. **No logos and no brand colours** (the TikTok red follow badge is drawn as a white circle with a black ＋; YouTube's red progress bar is drawn white).

**Device:** screen aspect 9:19.5 (393×852 pt logical) with a 44 pt corner radius, status bar 0–4.5 %, home indicator at 98 %. **Video placement (TikTok, Reels, FB Reels, Shorts):** the 9:16 video is **aspect-filled** into the content area (y 0 → top of bottom nav, full width). On this device that crops ≈ 4.4–4.7 % of the frame off each side; it never letterboxes. All four use white text and icons with a soft shadow (0 1 2 #00000066), plus a bottom gradient (#00000000 → #00000080 over the lowest 35 % of the content area).

Rects are `x0, y0, x1, y1` in percent. **Screen %** = of the full phone screen (draw the mock with these). **Frame %** = the same rect mapped onto the 1080×1920 source frame after aspect-fill (use for the safe-zone overlays). Frame values beyond 0–100 fall outside the video, behind the nav.

### 8.1 TikTok — For You feed (content 0–90 %)

| Element | Screen % | Frame % |
|---|---|---|
| Top bar: LIVE glyph (x 4–10) · tabs "Following · For You" centred (x 31–70; active bold white, other 60 % white) · search (x 90–96) | 3, 7.5, 97, 11.5 | 7.2, 8.3, 92.8, 12.8 |
| Right rail (centre x 92.2) | 86, 44.5, 98, 88.5 | 82.8, 49.4, 93.7, 98.3 |
| ↳ rail order (icon centre y / count y): avatar 46 pt + follow "+" badge 47.5 · like 55 / 57.7 · comment 62.7 / 65.6 · bookmark 70.4 / 72.9 · share 77.5 / 80.1 · spinning sound disc 86.3 | | |
| Handle (bold 17 pt) | 3, 77.8, 40, 80.2 | 7.2, 86.4, 40.9, 89.1 |
| Caption, 2 lines, ends "… more" (15 pt) | 3, 81.4, 74, 85.6 | 7.2, 90.4, 71.9, 95.1 |
| Music ticker "♫ title · artist" (scrolling, 14 pt) | 3, 86.4, 55, 89 | 7.2, 96.0, 54.6, 98.9 |
| Bottom nav (black, 5: Home, Friends, ＋, Inbox, Profile) | 0, 90, 100, 100 | — |
| Optional location/"posted" pill above handle | 3, 73.5, 74.5, 76.5 | 7.2, 81.7, 72.3, 85.0 |

### 8.2 Instagram Reels (content 0–90 %)

| Element | Screen % | Frame % |
|---|---|---|
| Top bar: ＋ (x 4–10) · tabs "Reels · Friends" (x 29–70) · filter glyph (x 88–96) | 4, 7.5, 96, 12 | 8.1, 8.3, 91.9, 13.3 |
| Right rail (centre x 92) | 87, 45.5, 97, 88 | 83.7, 50.6, 92.8, 97.8 |
| ↳ rail order: like 47 / 50.6 · comment 55.7 / 58.9 · repost 64.7 / 68.1 · send 73 / 76.2 · ⋯ 80.8 · audio tile (rounded square 30 pt) 86.3 | | |
| Avatar (36 pt, ring) + handle bold + verified · **Follow** outlined capsule (x 50–65) | 4, 74.5, 75, 79.5 | 8.1, 82.8, 72.8, 88.3 |
| Audio line under handle "♫ handle · Original audio" | 17, 77.5, 60, 79.2 | 19.9, 86.1, 59.1, 88.0 |
| Caption, 1 line, ends "…" | 4, 80, 82, 82.5 | 8.1, 88.9, 79.2, 91.7 |
| Bottom nav (5: Home, Reels, Send, Search, Profile) | 0, 90, 100, 100 | — |

Without an audio line, the avatar row drops to y 79.5–84 and the caption to 85.5–88 (primary ref). DJ clips always have audio, so draw the audio line.

### 8.3 Facebook Reels (content 0–90.5 %)

| Element | Screen % | Frame % |
|---|---|---|
| Top bar: "Reels" title bold 28 pt, left | 3, 8.5, 21, 11.5 | 7.4, 9.4, 23.7, 12.7 |
| Right rail (centre x 93) | 88, 52, 98, 87.5 | 84.4, 57.5, 93.5, 96.7 |
| ↳ rail order: like (thumb) 53.5 / 56.8 · comment 62 / 65.2 · share 70.7 / 73.7 · save 79 / 82.2 · ⋯ 86.8 | | |
| Avatar (rounded square 32 pt) + name bold + badge · **Follow** translucent capsule (x 61–77) | 3, 80.5, 77, 84.5 | 7.4, 89.0, 74.5, 93.4 |
| Music line under name "♫ song · artist" | 14, 82.8, 58, 84.5 | 17.4, 91.5, 57.2, 93.4 |
| Caption, 1 line, hashtags bold, ends "… more" | 3, 85.8, 85, 88 | 7.4, 94.8, 81.7, 97.2 |
| Bottom nav (6 with labels: Home, Reels, Friends, Profile, Notifications, Menu) | 0, 90.5, 100, 100 | — |

### 8.4 YouTube Shorts (content 0–90.5 %)

| Element | Screen % | Frame % |
|---|---|---|
| Top bar: search (x 78–84) · ⋮ (x 92–95), right only | 78, 8.5, 95, 11 | 75.4, 9.4, 90.8, 12.2 |
| Right rail (centre x 92) | 86, 39.5, 98, 88.5 | 82.6, 43.6, 93.5, 97.8 |
| ↳ rail order: like 41 / 44.2 · dislike 50 / "Dislike" 53.2 · comment 59 / 62.2 · share 68 / "Share" 71.2 · remix 77 / 80.2 · sound tile (rounded square 36 pt) 86 | | |
| Avatar (32 pt) + @handle · **Subscribe** white capsule (x 41–62) | 4, 77, 62, 81 | 8.3, 85.1, 60.9, 89.5 |
| Title/caption, 1 line, ends "…" | 4, 82, 82, 84.5 | 8.3, 90.6, 79.0, 93.4 |
| Music ticker "♫ artist · song" | 4, 86.3, 84, 88.5 | 8.3, 95.4, 80.8, 97.8 |
| Progress bar (2 pt) | 0, 89.8, 100, 90.1 | — |
| Bottom nav (5: Home, Shorts, ⊕, Subscriptions, You) | 0, 90.5, 100, 100 | — |

YouTube uses the YouTube title field (≤ 100) as the line under the handle.

### 8.5 Threads — post with video (feed card, white UI; % of screen width × height)

| Element | Geometry |
|---|---|
| Top bar | centred app glyph at y 7.5–11 (draw a generic "@"-free mark: a plain circle) |
| Avatar | circle 36 pt, x 3.5–12.5, top at post top + 4 pt. Thread line (2 pt, `border.strong`) under it to the footer |
| Header row | handle bold 15 pt + verified at x 16 · time "9m" tertiary right (x 82–88) · ⋯ (x 92–96) |
| Body | 15 pt, line height 21, x 16–96.5, directly under the header |
| Video | starts x 16, **≈ 61 % screen width (229 pt)**, 9:16 → ≈ 407 pt tall, radius 8. Mute badge 24 pt dark circle bottom-right, inset 8. *Height unverified (top cropped in ref).* |
| Action row | 12 pt under media: heart · comment · repost · send, 20 pt icons at x 16, 26, 36, 46 % (≈ 37 pt pitch). Current Threads shows counts beside icons; draw counts as `caption` text after each icon |
| Footer | "2 replies · 6 likes" tertiary at x 16 (older UI; omit when counts are inline) |
| Bottom nav | y 90–100: home, search, compose, heart, profile |

### 8.6 X — post with video (feed card; % of screen width × height)

| Element | Geometry |
|---|---|
| Top bar | avatar x 4–12 y 7.5–11 · centred glyph (generic) · tabs "For you · Following" y 13.5–16, active underline 4 pt `accent`-neutral (draw `text.primary`) under the active tab |
| Avatar | circle 40 pt, x 2.5–13.5 |
| Header row | display name bold · verified · "@handle · 7h" secondary · ⋯ right (x 92–97) |
| Body | 15 pt, x 15.5–97.5 |
| Video | x 15.5–97.5 (322 pt), radius 16. **Portrait clips are cropped to ≈ 4:5** (322×400 pt, from the tall-video ref). Duration badge bottom-left "1:01" (`micro` on #000000A0 capsule, inset 10). Mute badge 24 pt circle bottom-right |
| Action row | 10 pt under media, 13 pt counts: reply · repost · like · views at x 15.5, 34, 50, 67 %, then bookmark (x 85) and share (x 94) |
| FAB | ＋ circle 56 pt at x 83–98, y 82.5–89 (draw neutral, not blue) |
| Bottom nav | y 90–100: home, search, (generic) spark, bell, mail |

Text in mocks uses the real caption with each platform's truncation: TikTok 2 lines + "more", Reels 1 line + "…", FB 1 line + "more", Shorts 1 line + "…", Threads/X full text up to 5 lines, then "Show more". These rects also drive the **Safe zones** overlay. Use the Frame % rects for each platform's right rail, bottom block (handle → music) and top bar, tinted at 30 % and labelled.

---

## 9. Locked-reference index

All images are local only, in `refs/r2/` (gitignored). The Mobbin links are the source of truth for re-fetching.

| Slot | File (`refs/r2/`) | Mobbin |
|---|---|---|
| R2.FEEL | R2.FEEL--chatgpt-web-composer-menu.webp | https://mobbin.com/screens/18548847-534b-4263-9ffb-3f6cfdda7582 |
| ↳ considered | R2.FEEL-alt--chatgpt-ios-project-segmented.webp — pill segmented + floating round buttons | https://mobbin.com/screens/b6ad5d40-1980-432a-bc68-e547bbc07dcc |
| ↳ considered | R2.FEEL-alt--claude-web-composer-suggestion-chips.webp — calm alternate, chips under input | https://mobbin.com/screens/99067951-15dc-4fba-8ca8-94686a70985c |
| R2.DARK | R2.DARK--chatgpt-web-images-dark.webp | https://mobbin.com/screens/163f007a-ec3d-4796-b9f6-950f8d639f3c |
| R2.MENU | R2.MENU--chatgpt-web-account-menu.webp | https://mobbin.com/screens/7eb619eb-3da0-47f8-a7a5-6061b1d6becb |
| R2.NAV | R2.NAV--chatgpt-web-sidebar-sections.webp | https://mobbin.com/screens/eebd03db-a802-47aa-a61b-8d68a5fe78f7 |
| ↳ considered | R2.NAV-alt--chatgpt-ios-drawer-sections.webp — section headers, floating action | https://mobbin.com/screens/ab1d0c55-4180-4ad4-b9b6-5a21242092f1 |
| R2.SCORE | R2.SCORE--googlephotos-ios-large-card-review.webp | https://mobbin.com/screens/fe08f11d-55f0-43b7-a506-2acc10e4bc26 |
| ↳ considered | R2.SCORE-alt--midjourney-rank-progress-keys.webp — progress, key hints, undo/skip | https://mobbin.com/screens/6886324f-b99f-4152-8625-aa657a04f0be |
| ↳ considered | R2.SCORE-alt--runway-large-player-prev-next.webp — large player, ‹ ›, side panel | https://mobbin.com/screens/aa016d55-74f1-47fb-8918-2ccb33a6c9b3 |
| R2.EDIT | R2.EDIT--searchable-issue-cards-chips-actions.webp | https://mobbin.com/screens/2f0fbd3a-a396-4545-90c4-10da4ccba41c |
| ↳ considered | R2.EDIT-alt--copyai-inline-missing-chips.webp — "missing X" chips inline | https://mobbin.com/screens/6074b8e9-f289-468e-8e17-74cd825e224f |
| R2.QUEUE | R2.QUEUE--hootsuite-horizontal-post-cards.webp | https://mobbin.com/screens/a7fce7a6-32e4-4886-9f7e-32794fcf72f8 |
| ↳ considered | R2.QUEUE-alt--buffer-queue-tabs-viewtoggle.webp — tabs with counts, Grid/List/Calendar | https://mobbin.com/screens/72d4bfa1-5c2b-46a7-8165-cc6050b32f63 |
| R2.VIEWMODES | R2.VIEWMODES--arcade-library-filters-grid-list.webp | https://mobbin.com/screens/40ecfb3c-1903-43fb-9470-3dbc47004c82 |
| ↳ considered | R2.VIEWMODES-alt--frameio-compact-list-rating.webp — compact list with rating column | https://mobbin.com/screens/5ada6f2e-a1e2-4a3b-af69-7b232eed2b94 |
| R2.BULK | R2.BULK--cosmos-floating-pill-bar.webp | https://mobbin.com/screens/ca5fc71d-56ce-4486-934a-586bbbefa500 |
| ↳ considered | R2.BULK-alt--grok-top-floating-selection.webp — top floating bar, Full/Compact toggle | https://mobbin.com/screens/9f74b211-14d5-4d8c-a78e-521ce19a27f9 |
| ↳ considered | R2.BULK-alt--recraft-dark-pill-bar.webp — dark pill variant | https://mobbin.com/screens/338b6ed9-5452-4432-a847-bd9b31491f30 |
| R2.WEEK | R2.WEEK--hootsuite-week-media-cards.webp | https://mobbin.com/screens/fcb9a7cc-9ae1-4ee7-87b6-acf74e33e7c7 |
| ↳ considered | R2.WEEK-alt--tiktok-web-scheduler-portrait-tiles.webp — portrait tiles per day | https://mobbin.com/screens/0c5202c7-2201-4d78-aa94-f5b82f2522a4 |
| R2.TODAY | R2.TODAY--todoist-today-centered-column.webp | https://mobbin.com/screens/15d32901-2cde-4eaf-9dce-142c4507eac4 |
| ↳ considered | R2.TODAY-alt--open-wide-media-cards-action.webp — wide media card + action | https://mobbin.com/screens/d5d00070-d101-403a-a0f9-1f468e4117dc |
| R2.LIBRARY | R2.LIBRARY--frameio-portrait-tiles-fields.webp | https://mobbin.com/screens/a1d6dd05-728c-470d-90c1-0677a7d09fca |
| ↳ considered | R2.LIBRARY-alt--clickup-clips-subnav-counts.webp — clip grid + filter list with counts | https://mobbin.com/screens/cd13cd94-378a-4421-800f-462b79571473 |
| R2.POSTS | R2.POSTS--substack-posts-segmented-list.webp | https://mobbin.com/screens/07d006c3-724e-48ba-ab5d-e34873263beb |
| ↳ considered | R2.POSTS-alt--n8n-executions-status-table.webp — status table + bulk bar | https://mobbin.com/screens/b759b3dc-8a0f-4575-8f63-f25b15485fbf |
| R2.HEALTH | R2.HEALTH--openai-platform-service-health.webp | https://mobbin.com/screens/fd98bb68-c8c4-446c-a0fc-0e1089003e1c |
| ↳ considered | R2.HEALTH-alt--vanta-ok-needs-attention-summary.webp — OK / needs-attention summary | https://mobbin.com/screens/7b3e98c2-b1fd-4c66-b4f4-51fbbb0a346f |
| R2.SETTINGS | R2.SETTINGS--chatgpt-web-settings-rows.webp | https://mobbin.com/screens/07c4b5b1-7857-47f0-ad2e-5ab6619e84d7 |
| ↳ considered | R2.SETTINGS-alt--chatgpt-web-fields-toggles.webp — fields, toggles, Cancel/Save | https://mobbin.com/screens/87187ade-b0ee-4a89-9cd9-6b696bd0451f |
| R2.MENUBAR *(weak)* | R2.MENUBAR--crouton-anchored-popover-metric-chips.webp | https://mobbin.com/screens/d4f7df3b-0b48-4401-b10a-81fa1514dcff |
| ↳ considered | R2.MENUBAR-alt--lyssna-next-session-countdown.webp — "next in 2h 21m" hero | https://mobbin.com/screens/177f7dff-bab7-42ea-9d53-92fc89f9affa |
| R2.EMPTY | R2.EMPTY--v0-icon-line-pill-button.webp | https://mobbin.com/screens/6e23d772-5780-4383-8aa9-50bf26b2c952 |
| ↳ considered | R2.EMPTY-alt--babbel-icon-black-pill.webp — icon + line + black pill | https://mobbin.com/screens/274c64f1-0d4f-410c-ab11-11ca75f329b4 |
| R2.EDITOR | R2.EDITOR--arcade-floating-inspector-segmented.webp | https://mobbin.com/screens/f8c71b76-f0e3-4615-a6b4-dadd3c93becc |
| ↳ considered | R2.EDITOR-alt--elevenlabs-vertical-preview-sliders.webp — 9:16 preview, slider + value fields | https://mobbin.com/screens/68b0f986-d0cd-4269-b44e-ef0744bb2dc3 |
| ↳ considered | R2.EDITOR-alt--chatgpt-ios-composer-chips.webp — option chips inside a composer | https://mobbin.com/screens/02cdd130-9866-42d3-b19f-45b717ed9692 |
| R2.MOCK.tiktok | R2.MOCK.tiktok--tiktok-ios-foryou-feed.webp | https://mobbin.com/screens/e8a9730d-ff55-4ed9-b969-3918178bdf4a |
| ↳ considered | R2.MOCK.tiktok-alt--tiktok-ios-foryou-tabs-more.webp | https://mobbin.com/screens/05e0b98a-bd68-441c-bb71-84f051944c9b |
| R2.MOCK.instagram | R2.MOCK.instagram--instagram-ios-reels-feed.webp | https://mobbin.com/screens/c1ecdb34-ebee-4b77-adc8-9f33f56a0eb2 |
| ↳ considered | R2.MOCK.instagram-alt--instagram-ios-reels-audio-line.webp — audio line under handle | https://mobbin.com/screens/04ad8bc0-e993-4a42-a869-145a1a462713 |
| R2.MOCK.facebook | R2.MOCK.facebook--facebook-ios-reels-feed.webp | https://mobbin.com/screens/a76da39c-a061-4eed-8bff-d4173be83782 |
| ↳ considered | R2.MOCK.facebook-alt--facebook-ios-reels-playlist-chip.webp | https://mobbin.com/screens/1cb5d1bd-dd9b-479b-b434-1aa8ae93d39f |
| R2.MOCK.youtube | R2.MOCK.youtube--youtube-ios-shorts-feed.webp | https://mobbin.com/screens/5af0915b-bced-4ce0-8a2c-3638cc7712bb |
| ↳ considered | R2.MOCK.youtube-alt--youtube-ios-shorts-progress.webp — progress bar | https://mobbin.com/screens/a0b84ac6-c02c-4d28-af29-238e53a3316f |
| R2.MOCK.threads *(weak: older UI)* | R2.MOCK.threads--threads-ios-post-media.webp | https://mobbin.com/screens/c4fff05d-c5fb-4e8c-a82a-3b9e3fc01572 |
| ↳ considered | R2.MOCK.threads-alt--threads-ios-video-mute-badge.webp — portrait video + mute badge | https://mobbin.com/screens/ec30d387-78bf-4963-95ee-9955cfb09cdd |
| R2.MOCK.x | R2.MOCK.x--x-ios-post-video.webp | https://mobbin.com/screens/db2de9cd-1339-4e10-81a2-8bf08f152258 |
| ↳ considered | R2.MOCK.x-alt--x-ios-post-tall-video.webp — portrait crop ≈ 4:5 | https://mobbin.com/screens/25e68b95-4af7-4319-bca6-759ebfbe26d9 |

## 10. Weak matches and rejected directions

- **Menu bar:** Mobbin has no macOS menu-bar extras. The iOS anchored popover sets only the shape and density.
- **Edit cards:** no app shows "per-media missing requirements". The SEO issue cards (Searchable) set the card, chip and action anatomy, and Copy.ai sets the inline "missing" chip wording.
- **Score:** no app pairs a single large video with a numeric score. The Google Photos keep/delete card gives the calm layout (big rounded card + floating control pill + progress header); the control itself is ours.
- **Threads:** the reference is an older Threads build (no inline counts), and the portrait-video height was not visible.
- Rejected: dark-first creative-tool UIs (Frame.io, Riverside) as the default theme, because they're too heavy. Their anatomy is reused in light. Also rejected: social-scheduler month calendars (week is the unit), and coloured platform badges (they break "media is the only colour").
