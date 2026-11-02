# Tooltip & one-click-safety audit (round 3, F5 — Phase A)

Eric: *"a lot of the buttons, especially in larger components, I don't know what they mean… when I hover over a button there should be some tooltip… they click to an action I didn't want to do… it needs a page pass on every single page."*

This is the inventory for the Phase B page pass. It lists every button, icon, chip, menu item, gesture and shortcut on every screen and component, says whether each one is clear today, gives the proposed tooltip (a short verb phrase plus a shortcut), and flags every one-click action that changes data without a confirmation or Undo. Phase A changed no screen files. The component is `DSTooltip` (`.dsTooltip`); its decisions are in `design/TOOLTIPS-DECISIONS.md`.

**Method:** a read of every view file on `main` @ 02bcece (file:line references are as of that commit; Phase B re-checks them after `agent/unqueue` merges), plus the round-2 snapshot set (screens, final review, editor; local evidence, not committed) and a live probe of the real main window (`DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1 DJQueueApp --snapshot <dir>`).

## Summary

| Area | Controls listed | Unclear (⚠️ ambiguous + ❌ unlabelled) | Risky one-click rows |
|---|---|---|---|
| Shell (window, sidebar, shared bars & sheets, ⌘K, menu bar popover), Score, Edit, Queue | 259 | 96 (91 + 5) | 41 |
| Week, Today, Library, Posts, Health (+ shared context menus) | 229 | 81 (73 + 8) | 55 |
| Settings (every section), Editor (every section, timeline, canvas), DS components | 232 | 70 (64 + 6) | 37 |
| **Total** | **720** | **247** | **133** |

Rows that repeat across screens (the shared clip and post context menus, the ⌘K clip page) are listed where they are defined, then referenced. The 133 risky rows collapse into about 45 distinct actions.

### Legend
- **Clear today?** ✅ clear · ⚠️ ambiguous (why) · ❌ unlabelled.
- **Proposed tooltip:** sentence case, starts with a verb, says the consequence, ≤ 45 characters. The shortcut is a keycap, never part of the text. "label is enough" means no tooltip is needed. "Disabled: …" is the `disabledReason`.
- **Risk / fix:** `ok (confirm)` / `ok (undo)` / `⚠️ RISKY: <what changes>` → the proposed fix. Use an Undo toast for reversible single-item changes, and a confirm sheet for destructive, irreversible, many-item or plan-wide changes.

## Phase B status (round 3)

| | Rows |
|---|---|
| ✅ fixed (tooltip, clearer label, disabled reason, Undo or confirm) | 420 |
| ➖ no change needed (label already says it) | 320 |
| ⏭ deferred (reason in the row) | 12 |
| **Total, including the round-3 controls added in Phase B** | **749** |

- **Icon-only lint:** `scripts/check-icon-tooltips.py` (and `IconTooltipLintTests` in `swift test`) finds every `Button`/`Menu` whose label is only an image, or is drawn `.labelStyle(.iconOnly)`, and has no `.dsTooltip`. On `main` before the pass it found 2. Now it finds 0. `DSIconButton` requires its tooltip at compile time. Media actions on grid tiles take their Label title as the tooltip automatically.
- **`.help(`:** the lint fails on any `.help(` (it would draw a second, system bubble) except the menu-bar status item, which lives outside our windows and is marked `// native-help-ok`. It also fails on always-empty `.dsTooltip(nil)` / `.dsTooltip("")`.
- **Undo/confirm:**
  - Every one-click data change is journaled and shows "· Undo".
  - ⌘Z always undoes the most recent change.
  - The editor has its own ⌘Z/⇧⌘Z history.
  - Plan-wide and destructive actions ask first.

  Cross-cutting findings 1–8 below are done, except: "Keep posting it", the caption template/hashtag-set deletes and the long-form URL are confirmed instead of undoable, because they aren't in the journal.
- **Evidence (`DJQ_TOOLTIP_PASS=1`):** 37 real-window cases in light and dark. Each shows the first tile hovered, every tooltip anchor numbered, and a legend of what each says. Coverage:
  - Score: grid, single.
  - Edit: grid, cards, list, bulk bar.
  - Queue: cards, grid, list.
  - Library: grid, cards, list, single.
  - Week (plus the Rebuild-week confirm), Today, Posts (list and inspector), Health.
  - The editor, ⌘K, the compact sidebar.
  - Sheets: Pin and Mark posted (their own controls only), the bulk confirm.
  - Every one of the 10 Settings sections.
  - The menu-bar popover.
- **Not covered:** the long-form section's own cards and the quick-look sheet. They are covered in code by the lint, but there is no capture.
- **Counting caveat:** in-window overlays (Settings, ⌘K, Mark posted, bulk confirm) also count the screen under them, and the legend says so.

## Cross-cutting findings (fix once, in core or DS, before the page pass)

1. **`AppModel.perform(…)` has no Undo, and ⌘Z then undoes the wrong thing.** `perform` is used by kind, score, exclude, pin, post today, skip next, swap/move, approve/propose/rebuild week, push plan, repost, duplicate version, post reset/skip/post-now/shift, platform pause and every immediate setting. It shows a plain toast and doesn't touch `lastBatchId`, so ⌘Z (`undoLast`, `AppModel+Bulk.swift:149`) silently reverts an older, unrelated bulk batch. **Fix:**
   - Route clip edits through the existing `BulkActions` journal (`pipelineBulk`, one item = apply now + "· Undo" toast).
   - Give plan and post operations an inverse (the planner already records before/after) and a "… · Undo" toast.
   - Until then, clear `lastBatchId` in `perform` so ⌘Z can never undo the wrong thing.
2. **The editor autosaves with no undo stack.** ⌘Z only reaches text fields (`MainWindowView.swift:157`). Every Custom ↺ reset (16), title chip, Trim-to-markers, I/O keys, Place L/C/R, Remove X trim, per-platform caption toggle and "Follow the Title" overwrites saved work in one click. **Fix:** an `UndoManager` on `EditorModel` (snapshot of `Edit` per change, coalesced per 300 ms save) wired to ⌘Z/⇧⌘Z, and a "Saved · Undo" affordance in the editor header.
3. **Plan-wide actions need a confirm sheet:**
   - Week › Rebuild week (wipes unpinned future slots and un-approves).
   - Push plan by a day (shifts every week from today on).
   - Approve week (⌘↩ creates posts at once).
   - Repost on <platform> (creates a post).
   - Editor › Delete vN (even when that version is posted or planned).
   - Settings › Rendering cleanup "Delete after a while", and lowering "Delete after".
   - Many-clip context-menu actions (Add N to week, Kind/Score/Exclude for N) must go through `requestBulk` (BulkConfirmSheet).
4. **Disabled native menu items can't show a tooltip** (Rebuild/Propose week, Swap with, Remove from week, Skip platform, Copy agent prompt, Apply defaults). **Fix:** put the reason in the item's title (the RepostMenu pattern: "X — not rendered yet"), or keep the item enabled and answer with a toast that says why.
5. **Expanded sidebar rows have no tooltip and never show ⌘1–⌘8** (`Sidebar.swift:118`). Labelled DS buttons with a `shortcut` but no `tooltip` used to show nothing. **Fixed in Phase A:** `DSButton` now shows "title + keycaps".
6. **Unreachable hover targets.** Editor timeline marker ticks and the grace zone have `allowsHitTesting(false)`. The "File missing · Relink" chip can't be clicked (`DSClipCard.swift:212`). Grid-card hover actions are icon-only with no tooltip. **Fix:** give each a hit area plus a `.dsTooltip`, and make the Relink chip a button.
7. **Settings › Platforms limit cells save on every keystroke** (typing "180" saves 1, then 18, then 180). **Fix:** commit on ↩ or blur.
8. **Bugs found on the way** (Phase B or a follow-up):
   - Queue Cards right-click "Pin N to days…" does nothing for several clips (`QueueCards.swift:58`).
   - ⌘K/context "Re-render" doesn't force a render, unlike bulk Re-render (`AppModel.swift:652`).
   - The Posts inspector advertises esc but nothing binds it (`PostInspector.swift:46`).
   - Library "Space" opens the first *selected* clip, not the hovered one (`LibraryView.swift:46`).
   - `LongformPostedSheet` and `PauseControl` are dead code.

## Phase B plan (after `agent/unqueue` merges)
1. Replace all 51 native `.help(…)` with `.dsTooltip(…)`. Then register `NSInitialToolTipDelay` very high so that no stray native tooltip can double up.
2. Apply every "Proposed tooltip" below, screen by screen, and add `disabledReason` wherever a control can be disabled.
3. Land cross-cutting fixes 1–3 (Undo or confirm) and 5–7. Add a test per new inverse operation.
4. Add a guard: `scripts/audit-tooltips.sh` greps for `Image(systemName:)`-only `Button` labels without `.dsTooltip`, and for `DSButton("",`. Run it in the check plan.
5. Take light and dark snapshots per screen with one tooltip forced visible, and re-run the live probe (`DJQ_TOOLTIP_PROBE=1`).

---

Legend for Risk: "ok (undo)" = goes through `requestBulk`/`pipelineBulk` → 1 clip applies at once with "… · Undo" toast (6 s) and ⌘Z; >1 clip → BulkConfirmSheet first ("ok (confirm+undo)"). Everything that calls `AppModel.perform(…)` (setKind/setScore/setExcluded/pin/postToday/skipNext/swap/approveWeek/rebuildWeek/proposeWeek/pushPlan/repost/duplicateVersion/reset/skip/postNow/shiftPlan/update settings) shows a plain toast with **no Undo**, and ⌘Z then undoes an *older* bulk batch instead (`undoLast` uses `lastBatchId`, AppModel+Bulk.swift:149).

## Shell — window, global shortcuts, overlays

### Global keyboard shortcuts (hidden buttons)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ ⌘1 – ⌘8 (go to screen) | shortcut | MainWindowView.swift:146 | ⚠️ only visible in compact-sidebar tooltips | — | Expanded and compact sidebar rows: "<purpose> · <count meaning>" + ⌘1–⌘8 keycaps | — |
| ➖ ⌘K palette | shortcut | MainWindowView.swift:148 | ✅ | (sidebar hint "⌘K") | — | — |
| ✅ ⌘/ cheat sheet | shortcut | MainWindowView.swift:149 | ⚠️ not advertised anywhere in chrome | — | Add "Keyboard shortcuts ⌘/" to sidebar footer or ⌘K (exists in ⌘K) | ⌘/ is in ⌘K and the cheat sheet itself; ⌘Z/⌘0/digits/⌘⌫/editor keys added to the sheet (parent) |
| ✅ ⌘E open editor | shortcut | MainWindowView.swift:150 | ⚠️ silently does nothing unless exactly 1 clip selected | — | Toast "Select one clip to open it" when 0/many | ⌘E with nothing selected now says "Select one clip to open it in the editor" (parent) |
| ➖ ⌘R refresh | shortcut | MainWindowView.swift:152 | ✅ (cheat sheet) | — | — | — |
| ➖ ⌘A select all on screen | shortcut | MainWindowView.swift:160 | ✅ | — | — | — |
| ✅ ⌘Z undo last bulk change | shortcut | MainWindowView.swift:161-164 | ⚠️ undoes last *batch*, not last action | — | Cheat sheet: "Undo the last change that offered Undo" | Fixed centrally (F8 core): every action is journaled, ⌘Z undoes the most recent. Cheat-sheet text "⌘Z undoes the most recent change": MainWindowView/ShortcutSheet is parent-owned — change listed in agent A report |
| ➖ Esc clear selection | shortcut | MainWindowView.swift:166 | ✅ | — | — | — |
| ✅ ⌘0 Open DJ Queue | menu item | DJQueueApp.swift:27 | ⚠️ missing from cheat sheet | — | Add to cheat sheet · ⌘0 | ⌘0 added to the cheat sheet (parent) |
| ➖ Settings… ⌘, | menu item | DJQueueApp.swift:24 | ✅ | — | label is enough · ⌘, | — |

### Overlays & sheets
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Scrim click (any ModalHost) | gesture | MainWindowView.swift:101 | ⚠️ silently cancels open dialog | — | — (Esc also closes) | — |
| ➖ Pause all posting (confirm dialog) | text button | MainWindowView.swift:27 | ✅ | — | label is enough | ok (confirm) |
| ➖ Cancel (pause dialog) | text button | MainWindowView.swift:28 | ✅ | — | label is enough | — |
| ✅ Not now (run at login) | text button | MainWindowView.swift:120 | ✅ | — | Don't ask again; run only while open · esc | tooltip: Run only while this window is open; ask again from Settings › Engine (parent) |
| ✅ Run at login | text button | MainWindowView.swift:125 | ⚠️ also quits & relaunches app | — | Install background engine; app restarts · ↩ | tooltip: Install the background engine; DJ Queue restarts once (parent) |
| ➖ `xmark` Close (cheat sheet) | icon | MainWindowView.swift:203 (DSOverlays.swift:159) | ✅ | "Close  esc" | — | — |
| ➖ Done (cheat sheet) | text button | MainWindowView.swift:209 | ✅ | — | label is enough · ↩ | label is enough |
| ✅ Close (quick look) | text button | ClipPreviewSheet.swift:33 | ✅ | — | Close · esc | — |
| ✅ Open editor (quick look) | text button | ClipPreviewSheet.swift:34 | ✅ | — | Edit crop, text, caption and cover | — |
| ➖ Score field (⌘K Set score…) | field | CommandPalette.swift:534 | ✅ | error text | — | — |
| ✅ Cancel (score sheet) | text button | CommandPalette.swift:537 | ✅ | — | Cancel · esc | — |
| ✅ Save (score sheet) | text button | CommandPalette.swift:538 | ✅ | Disabled: "Type a score from 0 to 100" | Save score; higher posts sooner · ↩ | ok (undo): `model.setScore` is journaled (Score N · Undo, ⌘Z) |
| ➖ Date picker (⌘K Pin to date…) | field | CommandPalette.swift:562 | ✅ | — | — | — |
| ✅ Cancel (pin sheet) | text button | CommandPalette.swift:566 | ✅ | — | Cancel · esc | — |
| ✅ Pin (pin sheet) | text button | CommandPalette.swift:567 | ✅ | — | Post it on this day; the plan flows around · ↩ | ok (undo): `model.pin` is journaled |

### Toast
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Undo | text button | DSOverlays.swift:239 | ✅ | — | Revert this change · ⌘Z | toast Undo is labelled; ⌘Z does the same (most recent change) |
| ➖ `xmark` | icon | DSOverlays.swift:243 | ✅ | "Dismiss" | Hide this message | "Dismiss" tooltip (DS) |

## Shell — Sidebar (Shell/Sidebar.swift)

### Header, rows, footer
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `sidebar.left` collapse | icon | Sidebar.swift:48 | ✅ | "Collapse sidebar" | Collapse sidebar to icons | — |
| ➖ `sidebar.left` expand (compact) | icon | Sidebar.swift:58 | ✅ | "Expand sidebar" | label is enough | — |
| ✅ Search clips ⌘K | text button | Sidebar.swift:16 | ✅ expanded / ⚠️ compact tooltip lacks ⌘K | compact: "Search clips" (no shortcut: `hint` not passed as `shortcut`) | Search clips and commands · ⌘K (expanded and compact) | — |
| ✅ Score / Edit / Queue / Week / Today rows | text button | Sidebar.swift:18, 65-71 | ⚠️ counts unexplained; expanded rows have NO tooltip (`dsTooltip(compact ? title : nil)` drops the ⌘n shortcut too, line 118) | compact only: "<Title>  ⌘n" | Expanded: "Score new clips · 13 to score" / "Finish clips for posting · 8 need work" / "See ready clips in posting order · 41 ready" / "Plan and approve the week" / "See what to post today · 5 due"; compact: "<Title> · <count meaning>"; all with ⌘1–⌘5 keycaps, side trailing | — |
| ✅ Library / Posts / Health rows | text button | Sidebar.swift:24, 65-71 | ⚠️ Posts red count & Health dot unexplained | compact only | "Browse every clip, posted or not" / "See every post · 3 need attention" / "Check engine and runway · <dot reason>" (engine stopped, database error, posting paused, a platform paused, runway low, all good); ⌘6–⌘8 | — |
| ✅ Compact-row status dots | — | Sidebar.swift:95-99 | ❌ dot meaning unexplained | — | Folded into the row tooltip ("3 need attention", Health dot reason) | — |
| ✅ Engine line "● Running · next 5:00 PM X" | menu | Sidebar.swift:134-153 | ⚠️ chevron only hints at a menu | "Engine and posting" (compact: line text) | Expanded: "Pause or resume posting, or open Health" (paused: "Resume posting or open Health"); compact: the status line | — |
| ✅ Settings ⌘, | text button | Sidebar.swift:30 | ✅ / compact tooltip lacks ⌘, | compact: "Settings" | Open Settings · ⌘, (expanded and compact) | — |

### Engine menu (popover)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Status label | — | Sidebar.swift:174 | ✅ | — | — | — |
| ✅ Resume all posting | menu item | Sidebar.swift:176 | ✅ | — | Title "Resume all posting" | ok (undo): `setPaused` is journaled (Posting resumed · Undo) |
| ✅ Pause all posting | menu item | Sidebar.swift:177 | ✅ | — | Title "Pause all posting…" (asks first) | ok (confirm) |
| ✅ Pause one platform › | menu item | Sidebar.swift:178 | ✅ | — | Title "Pause or resume one platform ›" | — |
| ➖ Back | menu item | Sidebar.swift:165 | ✅ | — | — | — |
| ✅ <Platform> (checked = paused) | toggle | Sidebar.swift:169 | ⚠️ "checked = paused" is inverted from usual | — | Items say what a click does: "Pause TikTok" / "Resume X (paused)"; page label "One platform (the others keep posting)" — no inverted checkmarks | ok (undo): `setPlatformPaused` is journaled |
| ➖ Open Health | menu item | Sidebar.swift:180 | ✅ | — | — | — |

## Shell — Shared (Shared/*)

### Toolbar controls (ToolbarControls.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ "Runway 1 d approved · 24 d ready" | chip | ToolbarControls.swift:14-31 | ⚠️ looks static; click opens explainer | "Runway: how many days of posts are covered" | See how many days of posts are covered | — |
| ✅ Resume posting (PauseControl) | text button | ToolbarControls.swift:70 | ✅ | "Posting is paused — resume it" | — | Deleted dead `PauseControl` (no call sites) |
| ✅ `pause.circle` (PauseControl) | icon | ToolbarControls.swift:74 | ✅ | "Pause all posting" | — | Deleted dead `PauseControl` (no call sites) |

### Attention cards (ScreenScaffold.swift:99-101, items AppModel+Shell.swift:22-46)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Review (problems) | text button | AppModel+Shell.swift:28 | ✅ | — | Open Posts filtered to problems | labelled text button; the card's title says what it opens |
| ✅ Resume (paused) | text button | AppModel+Shell.swift:32 | ✅ | — | Resume posting now | ok (undo): Resume calls `setPaused(false)`, journaled centrally (tooltip: DS card, no slot) |
| ➖ Open Health (engine / load error) | text button | AppModel+Shell.swift:22, 37 | ✅ | — | label is enough | — |
| ⏭ Open Week (approved runway) | text button | AppModel+Shell.swift:41 | ⚠️ goes to *next* week | — | Open next week to approve it | Attention card label lives in AppModel+Shell (parent): suggest "Open next week" |
| ⏭ (Total runway card has no action) | — | AppModel+Shell.swift:45 | ⚠️ "Record a new set" not actionable | — | — | Design follow-up (no action exists); AppModel+Shell is parent-owned |
| ➖ `xmark` hide card | icon | DSOverlays.swift:529 | ⚠️ only on warnings, comes back | "Hide for 24 hours" | Hide this warning for 24 hours | DS tooltip "Hide for 24 hours" |

### Bulk bar (ScreenBulkBar.swift / DSBulkBar)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ `xmark` | icon | DSOverlays.swift:341-344 | ✅ | "Clear selection  esc" | — | — |
| ➖ Select all | text button | DSOverlays.swift:346-348 | ✅ | "Select every clip on this screen  ⌘A" | — | — |
| ✅ More (`chevron.down` drawn left of text) | menu | ScreenBulkBar.swift:44-53 | ⚠️ chevron on left reads oddly | "More bulk actions" | More actions for the selected clips (chevron now right of "More", like Kind ▾) | — |

### Bulk confirm sheet (BulkConfirmSheet.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ `xmark` close | icon | BulkConfirmSheet.swift:16 | ✅ | "Close  esc" | — | — |
| ✅ Cancel | text button | BulkConfirmSheet.swift:22 | ✅ | — | Cancel · esc | — |
| ✅ <verb> (Make ready / Exclude / …) | text button | BulkConfirmSheet.swift:24 | ✅ | Disabled: "Checking what will change…" / "Nothing would change" / "The check failed — see the message above" | "Apply to N clips (you can undo)" / "Apply it (you can undo)" · ↩; disabled reasons unchanged | ok (confirm+undo) |
| ➖ Why skipped / Hide reasons | text button | BulkConfirmSheet.swift:52 | ✅ | — | — | — |
| ✅ Ask an agent for these M | text button | BulkConfirmSheet.swift:93 | ✅ | "Copies a prompt for these M clips; your agent answers…" (>45) | Copy a title prompt for your agent | — |
| ✅ Use raw tag as title for these M | text button | BulkConfirmSheet.swift:97 | ✅ | "Sets each clip's title to its marker tag exactly as written (undoable)"; Disabled: "Applying…" | Set each title to its marker tag (undoable) | ok (undo) |

### Clip collection (ClipCollection.swift, DSClipCard.swift) — shared by Edit/Queue
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Select circle | toggle | DSClipCard.swift:163-164 | ✅ | "Select" / "Deselect" | Select · ⇧-click range · ⌘-click add | DS: Select for bulk actions · ⌘-click |
| ➖ Card body click | gesture | ClipCollection.swift:197-200 | ⚠️ opens editor when nothing selected, toggles when something is | — | (cursor/hover hint) "Click to open in editor" | — |
| ➖ `chevron.left` (Single) | icon | ClipCollection.swift:141 | ✅ | "Previous clip  ←"; Disabled: "This is the first clip" | — | — |
| ➖ `chevron.right` (Single) | icon | ClipCollection.swift:147 | ✅ | "Next clip  →"; Disabled: "This is the last clip" | — | — |
| ➖ ← / → (Single) | shortcut | ClipCollection.swift:162-163 | ✅ | — | — | — |
| ✅ Suggestion chip `text.badge.plus` "<song>" | chip | DSClipCard.swift:403-426 | ⚠️ looks like a tag, not a button | "Use as title" | Set this as the clip's title | DS: Set the Title to “<song>” |
| ✅ Issue badges "No crop / No text / Too long for X…" | chip (static) | DSClipCard.swift:213-214 | ⚠️ look clickable, aren't | — | Explain what is missing / what fixes it | DS: issue chips explain themselves (Still needed before it's ready — open the editor / Blocks posting…) |
| ✅ "File missing · Relink" badge | chip (static) | DSClipCard.swift:212 | ❌ says Relink but does nothing | — | Make it a button, or drop "· Relink" | DS: chip says "File missing"; tooltip points to Health › Doctor (it was never clickable) |
| ✅ Score number (e.g. "40") | — | DSClipCard.swift:170 | ⚠️ unlabelled number on Cards | — ("—" → "Not scored") | Score 0–100 (higher posts sooner) | DS: Score N — it sets the posting order |
| ✅ Position "1, 2…" | — | DSClipCard.swift:241 | ⚠️ unlabelled | — | Place in posting order | DS: Number N in the posting order |
| ✅ Date chip | chip (static) | DSClipCard.swift:199 | ✅ | "Next post" / "Pinned to this date" / "Not in the plan yet" | Next planned post day | DS: Pinned to this day / Next planned post / Not in the plan yet |
| ➖ Platform icons | icon (static) | DSBadge.swift:211 | ✅ | "<Platform> · <state>" | — | — |
| ➖ Mute/Unmute on media | icon | DSVideoPreview.swift:104 | ✅ | "Mute"/"Unmute" | — | — |

## Shell — ⌘K Command palette (Shell/CommandPalette.swift)

### Palette chrome
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Search field | field | CommandPalette.swift:308 | ✅ | placeholder | — | — |
| ✅ Clip capsule "<clip> ✕" | chip | CommandPalette.swift:290-306 | ✅ | "Back to all commands" | Back to all commands · esc | — |
| ➖ ↑/↓, ↩, esc, ⌫ | shortcut | CommandPalette.swift:313-321 | ✅ (footer) | — | — | — |
| ➖ Row click / hover | gesture | CommandPalette.swift:341-342 | ✅ | disabled rows: reason (line 433) | — | — |
| ➖ Scrim click closes | gesture | CommandPalette.swift:255 | ✅ | — | — | — |

### Commands — Actions / Go to (no clip chosen)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Go to <Screen> | menu item | CommandPalette.swift:27 | ✅ | hint ⌘1–⌘8 | — | — |
| ➖ Open Settings | menu item | CommandPalette.swift:32 | ✅ | hint ⌘, | — | — |
| ➖ Actions for "<clip>" | menu item | CommandPalette.swift:41 | ✅ | — | — | — |
| ✅ Copy agent prompt for N clips | menu item | CommandPalette.swift:45 | ⚠️ "agent prompt" jargon | — | subtitle: "Ask your agent for song-name titles" | — |
| ✅ Remove N from queue (round 3, new) | menu item | CommandPalette.swift `selection.unqueue` | ✅ | subtitle = removeFromQueueHelp; disabled: blocker | — (subtitle already says it) | ok (confirm+undo via `removeFromQueue`) |
| ✅ Move N back / forward a stage (round 3, new) | menu item | CommandPalette.swift `selection.stageBack/Forward` | ✅ | — | — | ok (confirm+undo via `stageBack/stageForward`) |
| ✅ Pause all posting | menu item | CommandPalette.swift:48-52 | ✅ | — | Title "Pause all posting…", subtitle "Asks first" | ok (confirm) |
| ✅ Resume all posting | menu item | CommandPalette.swift:48-52 | ✅ | — | subtitle: "Hand posts to you again from now (undoable)" | ok (undo): `setPaused` journaled |
| ➖ Review N problems | menu item | CommandPalette.swift:54 | ✅ | — | — | — |
| ✅ Approve next week | menu item | CommandPalette.swift:60 | ✅ | hint "⌘↩" (only bound on Week, WeekView.swift:70); Disabled: "Next week is already approved" | subtitle: "Lock its plan and create its posts (undoable)"; dropped the misleading ⌘↩ hint (only bound on Week) | ok (undo): `approveWeek` journaled (parent chose undo over confirm) |
| ✅ Propose next week | menu item | CommandPalette.swift:63 | ⚠️ "propose" unclear | — | subtitle: "Fill next week with ready clips as a draft" | ok (undo) |
| ✅ Rebuild next week | menu item | CommandPalette.swift:65 | ⚠️ consequence unclear | — | Title "Rebuild next week…", subtitle "Clear its unpinned days and plan them again" | ok (confirm+undo): `rebuildWeek` asks first |
| ✅ Push plan by a day | menu item | CommandPalette.swift:66 | ⚠️ which plan/direction | — | Title "Push plan by a day…", subtitle "Move every unpinned planned day one day later" | ok (confirm+undo): `pushPlan` asks first |
| ✅ Pause / Resume <Platform> | menu item | CommandPalette.swift:70 | ✅ | — | subtitle: "Stop its posts; other platforms keep going" / "Hand out its posts again" | ok (undo) |
| ➖ Mark posted… (post) | menu item | CommandPalette.swift:78 | ✅ | — | — | — (opens sheet) |
| ➖ Report problem… (post) | menu item | CommandPalette.swift:81 | ✅ | — | — | — (opens sheet) |
| ✅ Reset post (post) | menu item | CommandPalette.swift:85 | ⚠️ "reset" unclear | Disabled: "Its time has passed or it's still planned" | subtitle: "Put this post back to planned" | ok (undo): `reset` journaled |
| ✅ Skip post (post) | menu item | CommandPalette.swift:87 | ✅ | Disabled: "Already <state>" | — | ok (undo): `skip` journaled |
| ✅ Post now (overdue post) | menu item | CommandPalette.swift:90 | ⚠️ it hands it to you, doesn't post | — | subtitle: "Make it due now and open Today" | ok (undo): `postNow` journaled |
| ✅ Shift plan (overdue post) | menu item | CommandPalette.swift:91 | ⚠️ unclear | — | subtitle: "Move it to the next free slot" | ok (undo): `shiftPlan` journaled |
| ✅ Run engine tick now | menu item | CommandPalette.swift:95 | ⚠️ "tick" jargon | — | subtitle: "Check and prepare due posts now" | — |
| ✅ Open Doctor | menu item | CommandPalette.swift:96 | ⚠️ jargon | — | subtitle: "Check the app for problems" | — |
| ➖ Copy Doctor report | menu item | CommandPalette.swift:100 | ✅ | — | — | — |
| ➖ Open engine log | menu item | CommandPalette.swift:105 | ✅ | — | — | — |
| ➖ Keyboard shortcuts | menu item | CommandPalette.swift:106 | ✅ | hint ⌘/ | — | — |

### Commands — one clip's action page
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Clip row "Actions ›" | menu item | CommandPalette.swift:114 | ✅ | — | — | — |
| ➖ Open in editor | menu item | CommandPalette.swift:138 | ✅ | hint ⌘E; Disabled: "Long-form clips aren't edited here" / "File missing — relink it first" | — | — |
| ✅ Quick look | menu item | CommandPalette.swift:142 | ⚠️ hint "Space" not bound here (only Library, LibraryView.swift:46) | Disabled: "File missing" | Dropped the "Space" hint (not bound in ⌘K) | — |
| ➖ Set score… / Change score (N)… | menu item | CommandPalette.swift:144 | ✅ | Disabled: "Long-form clips have no score or plan" | — | opens sheet (see Save above) |
| ➖ Pin to date… | menu item | CommandPalette.swift:146 | ✅ | Disabled: long-form / "Excluded" | — | opens sheet (see Pin above) |
| ✅ Pin to tomorrow | menu item | CommandPalette.swift:149 | ✅ | Disabled: long-form / "Excluded" | — | ok (undo): `pin` journaled |
| ✅ Post today | menu item | CommandPalette.swift:154 | ⚠️ plan shifts for others | Disabled: long-form / "Excluded" | subtitle: "The rest of the plan moves a day later" | ok (undo): `postToday` journaled |
| ✅ Move up / Move down | menu item | CommandPalette.swift:158, 160 | ⚠️ actually swaps days with neighbour | Disabled: "Not planned — order follows score…" / "Already first/last" | subtitles: "Swap days with the clip before it" / "…after it" | ok (undo): `swap` journaled |
| ✅ Skip next slot | menu item | CommandPalette.swift:162 | ⚠️ jargon | Disabled: long-form / not planned | Renamed "Move one slot later", subtitle "Swap with the next open slot" | ok (undo): `skipNext` journaled |
| ✅ Exclude / Include | menu item | CommandPalette.swift:165 | ✅ | — | subtitle: "Never post this clip" / "Let the planner post this clip again" | ok (undo): `setExcluded` journaled |
| ✅ Copy agent prompt | menu item | CommandPalette.swift:169 | ⚠️ jargon | — | subtitle: "Ask your agent for a title" | — |
| ➖ "<Back title> (back a stage)" / "<Forward title> (forward a stage)" (round 3, new) | menu item | CommandPalette.swift `clip.*.stageBack/Forward` | ✅ | subtitle: stage help; disabled: blocker | — | ok (confirm/undo via AppModel+Stages) |
| ✅ Set kind: <Kind> | menu item | CommandPalette.swift:171 | ✅ | — | — | ok (undo): `setKind` journaled |
| ✅ Re-render | menu item | CommandPalette.swift:173 | ⚠️ `model.reRender` = `ensureRender(v1)`: no-op if a render exists, unlike bulk Re-render | Disabled: "File missing" | subtitle: "Make the post video again on the next tick" | ✅ now `forceReRender` → `requestBulk` + `BulkActions.reRender` (forced, undoable), same as bulk Re-render |
| ✅ Duplicate latest version | menu item | CommandPalette.swift:175 | ⚠️ "version" concept hidden elsewhere | — | subtitle: "Copy its edits into a new version (for reposts)" | ok (undo): `duplicateVersion` journaled |
| ✅ Repost on <Platform> | menu item | CommandPalette.swift:179 | ✅ | (blocked platforms hidden) | subtitle: "Plan a new <P> post of the latest version" | ok (undo): `repost` journaled (single, reversible — undo instead of confirm) |
| ➖ Mark long-form posted… | menu item | CommandPalette.swift:184 | ✅ | — | — | — (opens Library sheet) |

### Shared context menus defined here (used by Library/Week/Posts/Today — listed for completeness)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Edit / Preview | menu item | CommandPalette.swift:447-448 | ✅ | — | Renamed "Edit" → "Open editor" (app-wide verb) | — |
| ➖ Back / Forward a stage (StageMenuItems, round 3, new) | menu item | AppModel+Stages.swift (parent) | ✅ | `.help` (parent file) | — | ⏭ its `.help` is in AppModel+Stages.swift (parent-owned) → titles should carry the reason |
| ✅ Post today | menu item | CommandPalette.swift:450 | ✅ | — | — | ok (undo): `postToday` journaled |
| ✅ Pin to tomorrow | menu item | CommandPalette.swift:451 | ✅ | — | — | ok (undo): `pin` journaled |
| ✅ Skip next slot | menu item | CommandPalette.swift:452 | ⚠️ jargon | — | Renamed "Move one slot later" | ok (undo): `skipNext` journaled |
| ✅ Repost on ▸ <Platform> | menu | CommandPalette.swift:509-517 | ✅ | blocked: reason in label | — | ok (undo): `repost` journaled |
| ✅ Duplicate version | menu item | CommandPalette.swift:455 | ⚠️ | — | — | ok (undo): `duplicateVersion` journaled |
| ✅ Re-render | menu item | CommandPalette.swift:456 | ⚠️ (see above) | — | Disabled with "— file missing" in the title when the file is gone | ✅ `forceReRender` (requestBulk + BulkActions.reRender, undoable) |
| ✅ Add N to week | menu item | CommandPalette.swift:458 | ✅ | — | Title "Add N to week…" | ok (confirm+undo): `menuAddToWeek` → requestBulk + `bulk.addToWeek` (first week with room, like Queue) |
| ✅ Kind ▸ | menu | CommandPalette.swift:460-462 | ✅ | — | Title "Kind (N)" for several | ok (confirm+undo): `menuSetKind` → requestBulk |
| ✅ Score ▸ 90…30 / Clear | menu | CommandPalette.swift:463-466 | ✅ | — | Title "Score (N)" for several | ok (confirm+undo): `menuSetScore` → requestBulk |
| ✅ Exclude / Include | menu item | CommandPalette.swift:468 | ✅ | — | Title "Exclude N" / "Include N" for several | ok (confirm+undo): `menuSetExcluded` → requestBulk |
| ➖ Post menu: Mark posted…, Report problem… | menu item | CommandPalette.swift:480, 489 | ✅ | — | — | — (sheets) |
| ➖ Post menu: Copy caption / Copy title / Open upload page / Reveal in Finder / Copy file / Edit video | menu item | CommandPalette.swift:481-485, 499 | ✅ | — | — | — |
| ✅ Post menu: Post now / Shift plan / Reset post / Skip this platform | menu item | CommandPalette.swift:492-496 | ⚠️ see palette rows | — | Post now / Shift plan titles carry the consequence ("Post now (due on today's slot)", "Shift plan (to the next free slot)") or why not ("— sent back to Edit"); .help removed | ok (undo): reset/skip/postNow/shiftPlan journaled |

## Shell — Menu bar popover (MenuBar/MenuBarView.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Menu bar icon "▶ 5d" (+ red dot) | icon | MenuBarView.swift:49-57 | ❌ "5d" and dot unexplained (a11y only) | — (accessibilityDescription) | Can't `.help` a MenuBarExtra label → add a caption line in popover: "5 d of approved posts" | status-item help tag: "5 days of approved posts left · Something needs attention (2)" (+ paused / engine stopped) |
| ✅ Copy caption | text button | MenuBarView.swift:172 | ✅ | — | Copy the <Platform> caption | — |
| ➖ `textformat` | icon | MenuBarView.swift:174 | ✅ | "Copy title for YouTube" | — | — |
| ➖ Mark posted (opens URL field) | text button | MenuBarView.swift:177 | ✅ | "Paste the post URL" / "Not due yet — you can still mark it posted early" | — | — |
| ✅ `text.quote` (due row) | icon | MenuBarView.swift:220 | ✅ | "Copy caption" | Copy this post's caption | — |
| ✅ `checkmark.circle` (due row) | icon | MenuBarView.swift:221 | ✅ | "Mark posted" | Mark posted (paste its URL) | — |
| ➖ URL field | field | MenuBarView.swift:245 | ✅ | placeholder | — | — |
| ✅ Save (URL) | text button | MenuBarView.swift:247 | ✅ | Disabled: "Paste the post URL first" | Mark this post as posted (undoable) · ↩ | ✅ journaled with `bulk.record("mark-posted")` → "<P> marked posted · Undo" toast and ⌘Z; bad URL still errors inline |
| ➖ "N need attention · Review ›" | text button | MenuBarView.swift:270 | ✅ | problem summary detail | — | — |
| ➖ "Engine stopped … Health ›" | text button | MenuBarView.swift:291 | ✅ | "Nothing is posted or handed to you while…" | — | — |
| ✅ Open DJ Queue | text button | MenuBarView.swift:329 | ✅ | — | Open the main window · ⌘0 | — |
| ✅ Pause posting switch | toggle | MenuBarView.swift:332-336 | ✅ | "Pause all posting (asks first)" / "Posting is paused — switch off to resume" | "Pause all posting (asks first)" / "Resume posting (switch off)" | on: ok (confirm); off: ok (undo) — `setPaused` journaled |
| ✅ Cancel / Pause (inline confirm) | text button | MenuBarView.swift:319-320 | ✅ | Pause: "Nothing is handed to you or posted until you resume" | Pause: "Stop handing out posts until you resume" | ok (confirm) |
| ✅ `ellipsis` More | menu | MenuBarView.swift:337 | ⚠️ generic | "More" | Pause a platform, open Health or quit | — |
| ✅ Pause one platform ▸ <Platform> | toggle | MenuBarView.swift:338-341 | ✅ | — | Submenu "Pause or resume one platform" with items "Pause TikTok" / "Resume X (paused)" (no inverted toggles) | ok (undo): `setPlatformPaused` journaled |
| ➖ Open Health | menu item | MenuBarView.swift:343 | ✅ | — | — | — |
| ✅ Quit DJ Queue | menu item | MenuBarView.swift:345 | ✅ | `.help` "The background engine restarts it automatically…" | .help removed; section header "The engine reopens it — stop it in Settings → Engine" | — |
| ➖ Quit (startup error) | text button | MenuBarView.swift:71 | ✅ | — | — | — |

## Score (Sources/DJQueueApp/Score)

### Toolbar & empty state
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ View switcher Single / Grid | segmented | ScoreView.swift:24 | ⚠️ tooltip is just the mode name | "Single" / "Grid" | Single: "Score one clip at a time by keyboard"; Grid: "Score many clips, typing under each" (PipelineViewModeSwitcher) | — |
| ➖ Go to Edit (empty) | text button | ScoreView.swift:29-30 | ✅ | — | label is enough | — |

### Single view (ScoreSingle.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ "46 of 59 scored" strip | — | ScoreSingle.swift:95-96 | ✅ | "Clips in the sets you're scoring now" | — | — |
| ➖ `chevron.left` | icon | ScoreSingle.swift:47 | ✅ | "Previous clip  ←"; Disabled: "This is the first clip" | — | — |
| ➖ `chevron.right` | icon | ScoreSingle.swift:53 | ✅ | "Next clip  →"; Disabled: "This is the last clip" | — | — |
| ✅ Score box "0–100" | field | ScoreSingle.swift:118, 207-237 | ✅ | "Score 0–100 — type digits, ↩ saves" | Type a score 0–100, then save & next · ↩ | — |
| ✅ Save & next ↩ | text button | ScoreSingle.swift:119 | ✅ | only Disabled: "Type a score from 0 to 100 first" (shortcut lost when enabled: `tooltip` nil) | Save score and show the next clip · ↩ | ok (undo) |
| ✅ Skip | text button | ScoreSingle.swift:121 | ⚠️ sounds like "skip posting" | "Leave this clip for later  ⇥" | Leave unscored for now, show the next · ⇥ | — |
| ✅ Kind DJ vid / Talking | segmented | ScoreSingle.swift:141-143 | ✅ | "Talking clips get no text by default" | Talking clips get no text overlay (undoable) | ok (undo): `setKind` journaled centrally |
| ➖ Notes | field | ScoreSingle.swift:145 | ✅ | — | — (autosaves) | — |
| ✅ Exclude `minus.circle` | text button | ScoreSingle.swift:146 | ⚠️ ⌘⌫ only in tooltip/hint line | "Leave this clip out — it never posts (find it in Library → Excluded)  ⌘⌫" (>45) | Never post this clip (Library → Excluded) · ⌘⌫ | ok (undo) |
| ✅ Keys: digits / ↩ / ⇥ ⇧⇥ / ←→ / ⌫ / esc / ⌘⌫ | shortcut | ScoreSingle.swift:156-176 | ✅ (hint line 57) | — | Add ⌘⌫ & digits to ⌘/ cheat sheet | digits and ⌘⌫ added to the cheat sheet (parent) |
| ➖ Player mute | icon | ScoreSingle.swift:101-103 | ✅ | "Mute"/"Unmute" | — | — |

### Grid view (ScoreGrid.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Tile click | gesture | ScoreGrid.swift:47-48 | ⚠️ focuses score field, unlike Edit/Queue (opens editor) | — | — | — |
| ➖ Tile select circle | toggle | ScoreGrid.swift:46 | ✅ | "Select"/"Deselect" | — | — |
| ✅ Score field under tile | field | ScoreGrid.swift:82, 94 | ⚠️ typing silently selects the tile | "Type 0–100 · ⇥ next tile · Save scores in the bar below" / "Scores go from 0 to 100" | Type 0–100; Save scores in the bar below (invalid: "Scores go from 0 to 100") | — (not saved until Save scores) |
| ➖ Hover actions / ⋯ / context menu | — | ScoreGrid.swift:45 | — none in Score grid | — | — | — |

### Bulk bar (ScoreView.swift:71-152)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Set score… `number` | text button | ScoreView.swift:82 | ✅ | "Give every selected clip the same score" | — | (opens popover) |
| ➖ Score field (popover) | field | ScoreView.swift:125 | ✅ | hint "Replaces any score typed under these tiles" | — | — |
| ➖ Set score (popover) | text button | ScoreView.swift:129 | ✅ | Disabled: "Type a score from 0 to 100" | — | ok (confirm+undo) |
| ➖ Kind ▾ → DJ vid / Talking | menu | ScoreView.swift:85-92 | ✅ | "Set DJ vid or Talking for the selected clips" | — | ok (confirm+undo) |
| ✅ Exclude `minus.circle` | text button | ScoreView.swift:94 | ✅ | "Leave the selected clips out (find them in Library → Excluded)" | Never post these (Library → Excluded) | ok (confirm+undo) |
| ✅ More ▸ +1 / −1 / +10 / −10 on typed scores | menu item | ScoreView.swift:103-105 | ⚠️ disabled with no per-item reason | (line 108 text "Type scores under the tiles first") | Disabled items say why in their title ("+1 on typed scores — type scores under the tiles first") | — (typed only) |
| ✅ Save score(s) | text button | ScoreView.swift:112 | ⚠️ saves ALL typed scores, not only selected | "Save the N scores typed under the tiles" | Save the score / all N scores typed under the tiles | ok (undo, no confirm by design) |

## Edit (Sources/DJQueueApp/EditScreen)

### Toolbar, filter chips, empty state
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ View switcher Cards / Grid / Single / List | segmented | EditView.swift:27 | ⚠️ names only | "Cards"/"Grid"/"Single"/"List" | "Show clips as cards with their actions" / "Show many clips at a glance" / "Show one big clip at a time" / "Show clips as compact rows" | — |
| ✅ Make ready with defaults | text button | EditView.swift:28-33 | ⚠️ acts on all shown when nothing selected; doesn't set titles | "Confirm the default crop for the N shown/selected"; Disabled: "Nothing to edit" | Confirm default crop for N clips shown / selected | ok (confirm+undo; 1 clip = undo) |
| ✅ All N | chip | EditView.swift:36 | ✅ | — | Show every clip that needs work | — |
| ✅ No crop / No text / Too long for X … N | chip | EditView.swift:38 | ⚠️ filter vs. fix unclear | — | Show only clips with this issue (selected: "Show every clip again") | — |
| ➖ Open Queue (empty) | text button | EditView.swift:47-49 | ✅ | — | label is enough | — |

### Card actions — Cards mode (EditClipActions.swift:85-101)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Card click | gesture | EditView.swift:52 | ⚠️ opens editor | — | — | — |
| ✅ Add title (inline field) | field | EditClipActions.swift:89, 152-176 | ✅ | "No suggestions in metadata — click, type a title, ↩ saves" | Type a title; ↩ saves (undoable) | ok (undo) |
| ✅ Ask an agent `sparkles` | text button | EditClipActions.swift:90, 127 | ⚠️ only copies to clipboard | "Copies a prompt for your own agent: it suggests titles…" (>45) | Copy a title prompt for your agent | — |
| ➖ Trim for <Platform> `scissors` | text button | EditClipActions.swift:94; fix at :25 | ✅ | "Open the editor to trim it for <P> (m:ss max)" | — | — |
| ➖ Drop hashtags for <Platform> `number` | text button | EditClipActions.swift:94; fix at :38 | ✅ | "Post the caption without its hashtags on <P> only"; Disabled: "Still too long without hashtags…" / "This caption has no hashtags to drop" | — | ok (undo) |
| ➖ Write a/an <Platform> caption | text button | EditClipActions.swift:94; fix at :44 | ✅ | "Open the editor to write a caption just for <P>" | — | — |
| ➖ Shorten YouTube title | text button | EditClipActions.swift:94; fix at :49 | ✅ | "Open the editor to shorten the YouTube title (100 max)" | — | — |
| ✅ Open editor | text button | EditClipActions.swift:97 | ✅ | "Crop, text, caption, cover and platforms" | Edit crop, text, caption, cover, platforms | — |
| ✅ `ellipsis` ⋯ | menu | EditClipActions.swift:98 | ⚠️ generic | "More actions" | Show kind, caption, defaults and more | — |
| ✅ Suggestion chips | chip | DSClipCard.swift:403 | ⚠️ (see Shared) | "Use as title" | Set this as the clip's title | DS: Set the Title to “<song>” |
| ✅ "Cover" tag | chip (static) | EditView.swift:74 | ⚠️ meaning unclear | — | This clip is a session cover | DSClipTag.tooltip: Cover frame chosen in the editor |

### Card actions — Grid mode (hover, shown only when not missing)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `slider.horizontal.below.rectangle` | icon | EditClipActions.swift:103 | ✅ | `.help` "Open editor" | Edit crop, text, caption, cover, platforms (.help → .dsTooltip) | — |
| ✅ `sparkles` | icon | EditClipActions.swift:105 | ❌ icon only, "sparkles" reads as AI | `.help` askAgentHelp (>45) | Copy a title prompt for your agent (.help → .dsTooltip) | — |
| ✅ `chevron.right` Send to queue (round, on media; round 3, new) | icon | EditClipActions.swift (grid) | ⚠️ `.help` only | `.help` stage help (>45) | "Send to queue"; blocked: reason (soft-disabled) | ok (confirm/undo) |
| ⏭ (no ⋯ in Grid; fixes & Add title not reachable except right-click) | — | EditClipActions.swift:102-106 | ⚠️ | — | add ⋯ to grid hover | Grid hover slot renders Buttons icon-only (DSMediaActionStyle); a ⋯ Menu there needs a DS style — right-click has every action |

### Card actions — List mode (hover)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `slider.horizontal.below.rectangle` | icon | EditClipActions.swift:108 | ✅ | "Open editor" | Edit crop, text, caption, cover, platforms | — |
| ✅ `ellipsis` ⋯ (includes all fixes) | menu | EditClipActions.swift:109 | ⚠️ generic | "More actions" | Show fixes, kind, defaults and more | — |
| ➖ ‹ Back / Forward › stage (StageControl, Cards/List/Single; round 3, new) | icon / text button | AppModel+Stages.swift (parent) | ✅ | "<title> — <help>" / blocker | — (parent's StageControl) | ok (confirm/undo) |

### Card actions — Single mode (side panel)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Title field | field | EditClipActions.swift:112 | ✅ | hint "No suggestions in metadata · ↩ saves" | — | ok (undo) |
| ✅ Ask an agent | text button | EditClipActions.swift:113 | ⚠️ (as Cards) | askAgentHelp | Copy a title prompt for your agent | — |
| ➖ All fixes (Trim / Drop hashtags / Write caption / Shorten title) | text button | EditClipActions.swift:114 | ✅ | (as Cards) | — | Drop hashtags: ok (undo) |
| ✅ Open editor | text button | EditClipActions.swift:116 | ✅ | "Crop, text, caption, cover and platforms" | Edit crop, text, caption, cover, platforms | — |
| ✅ `ellipsis` ⋯ | menu | EditClipActions.swift:118 | ⚠️ generic | "More actions" | Show kind, caption, defaults and more | — |
| ➖ Big card click | gesture | ClipCollection.swift:197 | ⚠️ opens editor (no affordance) | — | — | — |
| ➖ ‹ › and ←/→ | icon / shortcut | ClipCollection.swift:141-163 | ✅ | (see Shared) | — | — |

### ⋯ menu / right-click (EditClipMenu, EditClipActions.swift:204-254) — acts on selection if clip is in it
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Open editor | menu item | EditClipActions.swift:215 | ✅ | — | — | — |
| ✅ Extra fixes (⋯ only: Cards ≥3rd fix, List all) | menu item | EditClipActions.swift:218 | ⚠️ disabled items lose their reason (`.disabled` only) | — | Disabled fixes say why in the title ("Drop hashtags for X — still too long without hashtags (300/280)") | ok (undo) |
| ➖ Kind ▸ DJ vid / Talking | menu | EditClipActions.swift:221-230 | ✅ | — | — | ok (undo / confirm+undo) |
| ✅ Caption template ▸ (right-click only; ⋯ passes `templates: []`) | menu | EditClipActions.swift:231-242 | ⚠️ missing from ⋯ | — | ⋯ now gets `model.captionTemplates` too | ok (undo / confirm+undo) |
| ➖ Copy agent prompt (for N) | menu item | EditClipActions.swift:243 | ⚠️ jargon | — | — | — |
| ✅ Apply defaults ▸ Frame / Trim / Text / Cover / Caption / Platforms / Every section | menu | EditClipActions.swift:246; 194-198 | ⚠️ discards edits; wording hides that | — | Renamed "Reset to New clip defaults ▸" (says the edits go) | ok (undo / confirm+undo) |
| ➖ Exclude (N) | menu item | EditClipActions.swift:248 | ✅ | — | — | ok (undo / confirm+undo) |

### Bulk bar (EditView.swift:103-186)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Top title `text.badge.checkmark` | text button | EditView.swift:114-123 | ⚠️ terse | "Accept top title: each clip's best suggestion…" / Disabled: "None of the selected clips has title suggestions yet — …" (native `.disabled` may hide `.help`) | "Use each clip's top suggested title"; disabled: "No title suggestions yet — More › Copy agent prompt asks your agent" (soft-disabled so the reason shows) | ok (confirm+undo) |
| ✅ Caption ▾ → Default template / <template> | menu | EditView.swift:124-128 | ⚠️ clears written captions — not said in menu | "Caption template and hashtag set for the selected clips" | Set caption template or hashtags | ok (confirm+undo; the sheet says "written captions cleared") |
| ➖ Caption ▾ → Default hashtags / <set> | menu item | EditView.swift:129-132 | ✅ | — | — | ok (confirm+undo) |
| ✅ Kind ▾ | menu | EditView.swift:134-142 | ✅ | "DJ vid or Talking for the selected clips" | Set DJ vid or Talking | ok (confirm+undo) |
| ➖ More ▸ Copy agent prompt for N | menu item | EditView.swift:144 | ⚠️ jargon | — | — | — |
| ✅ More ▸ Send to queue / Back to Score (round 3, new) | menu item | EditView.swift EditBulkBar | ⚠️ `.help` (long) | `.help` | Titles "Send to queue" / "Back to Score (clears their scores)" | ok (confirm+undo) |
| ✅ More ▸ Apply defaults ▸ | menu | EditView.swift:145 | ⚠️ (as above) | — | Renamed "Reset to New clip defaults ▸" | ok (confirm+undo) |
| ➖ More ▸ Skip platform ▸ <P> | menu | EditView.swift:146-156 | ✅ | — | — | ok (confirm+undo) |
| ✅ More ▸ Re-render | menu item | EditView.swift:157 | ⚠️ jargon | — | Title "Re-render (make the post videos again)" | ok (confirm+undo) |
| ✅ Make ready | text button | EditView.swift:165 | ✅ (dup of toolbar button) | "Make ready with defaults: confirm the default crop for the N selected" (>45) | Confirm default crop for N selected | ok (confirm+undo) |

## Queue (Sources/DJQueueApp/Queue)

### Toolbar & empty state
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Runway chip | chip | QueueView.swift:24 | ⚠️ (see Shared) | "Runway: how many days of posts are covered" | See how many days of posts are covered | — |
| ✅ "Worst → best ▾" sort | menu | QueueView.swift:75-102 | ⚠️ "worst→best" of what | "Order of the ready backlog by score" | Order unplanned ready clips by score | ok (undo): `model.update` is journaled |
| ➖ Sort items Best → worst / Worst → best | menu item | QueueView.swift:81-87 | ✅ | — | — | (as above) |
| ✅ View switcher (4 modes) | segmented | QueueView.swift:26 | ⚠️ names only | "Cards"/"Grid"/"Single"/"List" | Per-mode purpose tooltips (PipelineViewModeSwitcher, as Edit) | — |
| ➖ Go to Edit (empty) | text button | QueueView.swift:31-32 | ✅ | — | label is enough | — |

### Card hover actions — Cards mode (QueueCards.swift; shown only while hovered)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Card click | gesture | QueueCards.swift:50-52 | ⚠️ opens editor | — | — | — |
| ✅ `line.3.horizontal` drag handle / drag card | gesture | DSClipCard.swift:235; QueueCards.swift:59-91 | ⚠️ drop only works on planned clips | "Drag to reorder" | Drag onto a planned clip to take its day | DS: Drag to change the posting order |
| ✅ `bolt` | icon | QueueCards.swift:54 → QueueCards.swift:118 | ⚠️ bolt ≠ "today" | "Post today" | Post today; later posts move a day | ok (undo) |
| ✅ `pin` | icon | QueueCards.swift:119 | ✅ | "Pin to date…" | Pin to a day the planner won't change | ok (dialog + undo) |
| ✅ `ellipsis` ⋯ | menu | QueueCards.swift:120 | ⚠️ generic | "More actions" | Show more: move later, remove, exclude | — |
| ➖ ‹ Back / Forward › stage (StageControl, round 3, new) | icon | AppModel+Stages.swift (parent) via QueueCards | ✅ | "<title> — <help>" / blocker | — (DSIconButton, tooltipped by the parent's StageControl) | ok (confirm/undo) |
| ✅ Right-click menu | menu | QueueCards.swift:58 | ❌ BUG: with >1 selected, "Pin N to days…" does nothing (`t.count == 1 ? onPin(t[0]) : ()`) | — | — | ✅ BUG fixed: QueueCardList.onPin takes [String]; "Pin N to days…" opens the multi pin dialog → `bulk.pinConsecutive` (confirm+undo) |

### Card hover actions — Grid mode
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `bolt` (round, on media) | icon | QueueCards.swift:106 | ⚠️ | `.help` "Post today" | Post today; later posts move a day (.help → .dsTooltip) | ok (undo) |
| ✅ `pin` (round, on media) | icon | QueueCards.swift:107 | ✅ | `.help` "Pin to date…" | Pin to a day the planner won't change (.help → .dsTooltip) | ok (dialog + undo) |
| ✅ `chevron.left` Back a stage / Remove from queue (round, on media; round 3, new) | icon | QueueCards.swift (grid) | ⚠️ was `.disabled` + `.help` | `.help` | "<Remove from queue / Back to Queue>"; blocked: reason (soft-disabled, click says why) | ok (confirm+undo) |
| ⏭ (no ⋯ in Grid — Skip next/Exclude only via right-click) | — | QueueCards.swift:105-107 | ⚠️ | — | add ⋯ | Grid hover slot renders Buttons icon-only (DSMediaActionStyle); a ⋯ Menu there needs a DS style — right-click has every action |
| ✅ Date tag on tile | chip (static) | QueueView.swift:40-41 | ⚠️ no tooltip (badge, not dateChip) | — | Next planned post day | DSClipTag.tooltip: Next planned post day / Pinned to this day — the plan works around it |

### Card hover actions — List mode (same view as Cards' `default` case)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `bolt` | icon | QueueCards.swift:118 | ⚠️ | "Post today" | Post today; later posts move a day | ok (undo) |
| ✅ `pin` | icon | QueueCards.swift:119 | ✅ | "Pin to date…" | Pin to a day the planner won't change | ok (dialog + undo) |
| ✅ `ellipsis` ⋯ | menu | QueueCards.swift:120 | ⚠️ | "More actions" | Show more: move later, remove, exclude | — |
| ➖ Row click | gesture | ClipCollection.swift:197 | ⚠️ opens editor | — | — | — |

### Card actions — Single mode (side panel)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Post today `bolt` | text button | QueueCards.swift:110 | ✅ | "Put it on today; the rest of the plan moves a day" (>45) | Post today; later posts move a day | ok (undo) |
| ✅ Pin to date… `pin` | text button | QueueCards.swift:111 | ✅ | "Pin it to a day the planner won't change" | Pin to a day the planner won't change | ok (dialog + undo) |
| ✅ Open editor | text button | QueueCards.swift:113 | ✅ | — | Edit crop, text, caption, cover, platforms | — |
| ✅ `ellipsis` ⋯ | menu | QueueCards.swift:114 | ⚠️ | "More actions" | Show more: move later, remove, exclude | — |
| ➖ Big card click / ‹ › / ←→ | gesture / icon | ClipCollection.swift:141-200 | ⚠️ click opens editor | (see Shared) | — | — |

### ⋯ menu / right-click (QueueClipMenu, QueueCards.swift:132-161)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Post today / Post N today | menu item | QueueCards.swift:142 | ✅ | — | — | ok (undo / confirm+undo) |
| ✅ Pin to date… / Pin N to days… | menu item | QueueCards.swift:147 | ✅ | — | — | ok (dialog + undo); Cards right-click bug fixed |
| ✅ Remove from queue / Remove N from queue (round 3, new) | menu item | QueueCards.swift QueueClipMenu | ⚠️ `.help` reason | `.help` | Disabled: reason in the title ("Remove from queue — already posted on X") | ok (confirm+undo) |
| ✅ <Forward title> / Forward a stage (N) (round 3, new) | menu item | QueueCards.swift QueueClipMenu | ⚠️ `.help` | `.help` | Disabled: reason in the title | ok (confirm+undo) |
| ✅ Skip next | menu item | QueueCards.swift:149 | ⚠️ jargon | `.help` "Moves it one place later in the backlog" / "Swaps it with the next open slot" | Renamed "Move one slot later" (backlog: "Move one place later"); .help removed | ok (undo): `skipNext` journaled |
| ➖ Open editor | menu item | QueueCards.swift:153 | ✅ | — | — | — |
| ➖ Exclude / Exclude N | menu item | QueueCards.swift:155 | ✅ | — | — | ok (undo / confirm+undo) |

### Bulk bar (QueueView.swift:107-179)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Pin to days… `pin` | text button | QueueView.swift:115 | ✅ | "Pin the selected clips to consecutive days, in the order shown" (>45) | Pin to consecutive days, in order shown | ok (dialog → confirm+undo) |
| ✅ Post today `bolt` | text button | QueueView.swift:117 | ✅ | "Put the selected clips on today (clips beyond today's free slots are skipped)" (>45) | Post these today; extras are skipped | ok (confirm+undo) |
| ✅ More ▸ Remove from queue (round 3, new) | menu item | QueueView.swift QueueBulkBar | ⚠️ `.help` | `.help` | Title "Remove from queue (back to Edit)"; disabled: "— <reason>" | ok (confirm+undo) |
| ✅ More ▸ Back a stage / Forward a stage (round 3, new) | menu item | QueueView.swift QueueBulkBar | ⚠️ `.help` | `.help` | Titles "Back a stage (planned → Queue, ready → Edit)" / "Forward a stage (pin ready ones to open days)" | ok (confirm+undo) |
| ➖ More ▸ Skip platform ▸ <P> | menu | QueueView.swift:126 | ✅ | — | — | ok (confirm+undo) |
| ➖ More ▸ Exclude | menu item | QueueView.swift:129 | ✅ | — | — | ok (confirm+undo) |
| ✅ More ▸ Post on a platform again ▸ <P> | menu | QueueView.swift:136 | ⚠️ means "un-skip", reads like "repost" | — | Renamed "Turn a skipped platform back on ▸" | ok (confirm+undo) |
| ➖ More ▸ Kind ▸ | menu | QueueView.swift:139 | ✅ | — | — | ok (confirm+undo) |
| ✅ More ▸ Re-render | menu item | QueueView.swift:148 | ⚠️ jargon | — | Title "Re-render (make the post videos again)" | ok (confirm+undo) |
| ✅ Add to week | text button | QueueView.swift:156 | ⚠️ which week | "Plan the selected clips on the first free days" | Pin to free days of the next open week | ok (confirm+undo) |

### Pin dialog (QueuePinDialog, QueueView.swift:183-222)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Scrim click | gesture | QueueView.swift:57 | ✅ | — | — | — |
| ➖ `xmark` close | icon | QueueView.swift:196 | ✅ | "Close  esc" | — | — |
| ➖ Calendar | field | QueueView.swift:197 | ✅ | — | — | — |
| ✅ Cancel | text button | QueueView.swift:202 | ✅ | — | Cancel · esc | — |
| ✅ Pin / Pin N | text button | QueueView.swift:204 | ✅ | — | "Pin it to this day" / "Pin them one a day from this day" · ↩ | ok (confirm+undo) |

### Risky one-click actions
1. ✅ (undo, F8 core) Score single Kind segmented — kind saved instantly, no undo (ScoreSingle.swift:141) → Undo toast via `pipelineBulk`.
2. ✅ (undo, F8 core; renamed "Move one slot later") Queue ⋯/right-click "Skip next" — plan swap, no undo (QueueCards.swift:149) → Undo toast.
3. ✅ (undo: `model.update` journaled) Queue sort menu — global sort setting, no undo (QueueView.swift:83) → Undo toast (low).
4. ✅ (undo, F8 core; Re-render now forced via requestBulk) ⌘K clip page: Pin to tomorrow, Post today, Move up/down, Skip next slot, Exclude/Include, Set kind, Duplicate latest version (CommandPalette.swift:149-175) — all `perform`, no undo → route through `pipelineBulk`/batches.
5. ✅ (undo — single and reversible, so no confirm) ⌘K Repost on <P> (CommandPalette.swift:179) — creates a post → Confirm sheet.
6. ✅ (Rebuild/Push ask first + undo; Approve/Propose undo) ⌘K Approve / Propose / Rebuild next week, Push plan by a day (CommandPalette.swift:60-66) — plan-wide, no confirm/undo → Confirm sheet (Rebuild, Push, Approve), Undo toast (Propose).
7. ✅ (undo, F8 core) ⌘K post actions Reset / Skip / Post now / Shift plan (CommandPalette.swift:85-91) and same in PostContextMenu (CommandPalette.swift:492-496) → Undo toast.
8. ✅ (undo; items now say "Pause X" / "Resume X (paused)") Pause/Resume a platform — Sidebar engine menu (Sidebar.swift:169), ⌘K (CommandPalette.swift:70), menu bar ⋯ (MenuBarView.swift:340) → Undo toast.
9. ✅ (undo via `setPaused`) Resume all posting — engine menu (Sidebar.swift:176), attention card Resume (AppModel+Shell.swift:32), ⌘K (CommandPalette.swift:51), menu-bar switch off (MenuBarView.swift:333) → Undo toast (low).
10. ✅ (undo) ⌘K score/pin sheets Save/Pin (CommandPalette.swift:538, 567) — no undo after saving → Undo toast.
11. ✅ (journaled with `bulk.record`, Undo toast + ⌘Z) Menu bar URL Save → mark posted, no undo (MenuBarView.swift:247) → Undo toast (low).
12. ✅ (multi-clip → requestBulk confirm+undo; single → journaled AppModel actions) VideoContextMenu multi-clip Add N to week / Kind / Score / Include-Exclude (CommandPalette.swift:458-470) — N clips, no confirm, no undo → `requestBulk`; single-clip Post today / Pin to tomorrow / Skip next slot / Repost / Duplicate version (450-455) → Undo toast / Confirm.
13. ✅ (F8 core: every action journaled, ⌘Z = most recent) ⌘Z after any of the above reverts an older unrelated bulk batch (AppModel+Bulk.swift:149) → clear `lastBatchId` on non-batch writes or make all writes batches.
Also bugs: ✅ Queue Cards right-click "Pin N to days…" no-op (QueueCards.swift:58) — fixed, opens the multi pin dialog (pinConsecutive); ✅ ⌘K/context "Re-render" — now `forceReRender` (requestBulk + BulkActions.reRender); ⏭ "File missing · Relink" badge not clickable (DSClipCard.swift:212, DS-owned); ✅ `PauseControl` unused — deleted; ✅ expanded sidebar rows get no tooltip and lose ⌘1–⌘8 — every row now has a purpose tooltip + keycaps; ➖ (by design, DECISIONS #20) disabled DSButton/DSIconButton drop the shortcut and enabled DSButtons without `tooltip` drop `shortcut` (DSButton.swift:202, e.g. Save & next).


---

## Week

### Toolbar
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `chevron.left` (icon) | icon | WeekView.swift:50 | ✅ clear | Previous week | Show the previous week | — |
| ✅ Today | text button | WeekView.swift:51-53 | ⚠️ reads like the Today screen | — (disabled: "Already showing this week") | Label → "This week" · Jump back to this week · Disabled: already showing this week | — |
| ✅ `chevron.right` (icon) | icon | WeekView.swift:54 | ✅ clear | Next week | Show the next week | — |
| ➖ Draft / Approved / Locked pill | chip | WeekView.swift:73-80 | ✅ clear | "Draft: nothing posts until you approve the week" (and Approved/Locked variants) | label is enough (keep tooltip) | — |
| ➖ Runway N d approved · N d ready | text button | ToolbarControls.swift:14-31 (WeekView.swift:57) | ⚠️ "d approved / d ready" is jargon | Runway: how many days of posts are covered | Show how many days of posts are covered | RunwayChip already has a tooltip + popover |
| ✅ `ellipsis` (icon) | menu | WeekView.swift:58 | ❌ icon only, tooltip vague | Week actions | Rebuild, push or propose this week's plan | — |
| ✅ Rebuild week | menu item | WeekView.swift:59-60 | ⚠️ hides that it un-approves | — (disabled with no reason) | Title "Rebuild week…" · disabled title "Rebuild week — this week is over" | ok — AppModel.rebuildWeek asks first (confirm) + undo; no second confirm added |
| ✅ Push plan by a day | menu item | WeekView.swift:61 | ⚠️ scope (all weeks) not said | — | Title "Push whole plan by a day…" | ok — AppModel.pushPlan asks first (confirm) + undo |
| ✅ Propose week | menu item | WeekView.swift:63-64 | ⚠️ "propose" vague | — (disabled with no reason) | Title "Propose week (fill empty days)" · disabled title "Propose week — week already approved / this week is over" | ok — AppModel journal (toast · Undo, ⌘Z) |
| ✅ Approve week | text button | WeekView.swift:66-70 | ✅ clear | Approve: the engine prepares these posts · ⌘↩ (disabled: approveBlocker reasons) | Approve: the engine prepares these posts · ⌘↩ · Disabled: week over / already approved / nothing planned | ok — AppModel journal (toast · Undo, ⌘Z) |

### Day grid and day card
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Day card double-click | gesture | WeekView.swift:338, 341 | ⚠️ hidden, tooltip-only | Double-click to edit · drag to another day to swap | Double-click to edit · drag to swap days (past/posted: "Double-click to edit") | — |
| ✅ Day card drag onto another day | gesture | WeekView.swift:339, 249-254 | ⚠️ hidden, tooltip-only | (same as above) | — | ok — drop calls AppModel.swap / move (journaled, Undo) |
| ➖ Backlog clip dropped on a planned day | gesture | WeekView.swift:255-259 | ✅ clear | — | — | ok (confirm) |
| ✅ Backlog clip dropped on an empty day | gesture | WeekView.swift:261 | ✅ clear | — | — | ok — drop calls AppModel.pin (journaled, Undo) |
| ➖ Score capsule | chip | WeekView.swift:293-298 | ✅ clear | Score N | label is enough | — |
| ✅ `pin.fill` badge | icon | WeekView.swift:303-306 | ✅ clear | Pinned to this day | Pinned: stays here when the week is rebuilt | — |
| ✅ Needs you badge | chip | WeekView.swift:308 | ⚠️ doesn't say what or where | — | Open Posts: a post failed or is late | — now clicks through to Posts |
| ✅ `ellipsis` hover button | menu | WeekView.swift:313-319 | ⚠️ hover-only, vague tooltip | Clip actions | Swap, remove, pin or skip this clip | — |
| ✅ Slot chip "TikTok 7:00 PM ●" | chip | Week+DSX.swift:85-122; WeekView.swift:359-360 | ⚠️ dot colours unexplained; actions right-click only | "<Platform> · <time> · <status>[ · platform paused]" | <Platform> · <time> · <status>[ · platform paused] · right-click for actions | — (actions: see Shared › Post context menu) |
| ➖ Extra post chip (`arrow.uturn.forward` / `arrow.clockwise`) | chip | WeekView.swift:416-437 | ⚠️ glyphs unexplained without hover | "Repost of … (new version)" / "Re-queued attempt #N of …" | keep | — (actions: see Shared › Post context menu) |
| ➖ Mute (video preview) | icon | DSVideoPreview.swift:93-104 | ✅ clear | Mute / Unmute | label is enough | — |
| ➖ Awake strip | gesture | Week+DSX.swift:194-222 | ✅ clear | Mac awake (green) · off or asleep (hatched) | keep | — |
| ✅ Add from queue (empty day) | text button | WeekView.swift:230-234 | ⚠️ which clip only on hover | Puts "<clip>" on this day (disabled: "Nothing ready in the queue") | Pin “<clip>” here (next in queue) · Disabled: nothing ready in the queue | ok — AppModel.pin (journaled, Undo) |
| ➖ Stage ‹ (hover, compact `chevron.left`) | icon | WeekView.swift (StageControl compact) | ✅ clear | "<Back title> — <what happens>" · Disabled: <stage blocker> | keep (defined in App/AppModel+Stages, parent-owned) | ok — stageBack runs through the bulk flow (confirm + Undo) |
| ➖ Stage › (hover, compact `chevron.right`) | icon | WeekView.swift (StageControl compact) | ✅ clear | "<Forward title> — <what happens>" · Disabled: <stage blocker> | keep (App/AppModel+Stages) | ok — stageForward via bulk flow (confirm + Undo) |

### Card ⋯ menu and right-click (WeekCardMenu; ⋯ on future days, right-click on all days)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Swap with ▸ <day · clip> | menu item | WeekView.swift:391-398 | ✅ clear | — (disabled on past days, no reason) | Disabled title "Swap with — past days are fixed" | ok — AppModel.swap (Undo) |
| ✅ Remove from week | menu item | WeekView.swift:399 | ⚠️ unclear where the clip goes | — (disabled on past, no reason) | Title "Remove from week (day stays empty)" · disabled "… — past days are fixed" | ok — AppModel.removeSlot (Undo) |
| ✅ Pin to this day / Pinned to this day | menu item | WeekView.swift:400-401 | ⚠️ effect of pin unexplained | — | Title "Pin to this day (keeps it on rebuild)" · "Pinned to this day" · past: "… — past days are fixed" | ok — AppModel.pin (Undo) |
| ✅ Skip platform ▸ <platform> | menu item | WeekView.swift:402-407 | ⚠️ disabled in Draft, no reason | — | Items "Skip <Platform>" · disabled titles "Skip platform — approve the week first" / "— nothing left to skip" | ok — AppModel.skip (Undo) |
| ➖ Open editor | menu item | WeekView.swift:409 | ✅ clear | — | label is enough | — |
| ➖ Preview | menu item | WeekView.swift:410 | ✅ clear | — | label is enough | — |
| ➖ Show in Queue | menu item | WeekView.swift:411 | ✅ clear | — | label is enough | — |
| ✅ Back a stage / Forward a stage (StageMenuItems) | menu item | WeekView.swift (WeekCardMenu) | ✅ clear | native `.help` | — | parent: disabled reason now in the item title; no .help |
| ✅ Remove from queue | menu item | WeekView.swift (WeekCardMenu) | ✅ clear | native `.help` (removed) | Title "Remove from queue (back to Edit)" · disabled "Remove from queue — already posted / this day has passed" | ok — removeFromQueue via bulk flow (confirm + Undo) |

### Backlog drawer
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Next up · N (`chevron.up/down`) | text button | WeekView.swift:452-467 | ⚠️ "Next up" = ready backlog unclear | Show the next ready clips / Hide the backlog | keep | — |
| ✅ Backlog tile drag | gesture | WeekView.swift:510, 512 | ✅ clear | Drag onto a day | Drag onto a day to plan it | see drops above |
| ➖ Backlog tile right-click | menu | WeekView.swift:511 | ⚠️ hidden | — | — | see Shared › Video context menu (journaled centrally) |

### Replace dialog / empty state
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Cancel | text button | WeekView.swift:103-104 | ✅ clear | — | label is enough · esc | — |
| ➖ Replace | text button | WeekView.swift:105-109 | ✅ clear | — | label is enough · ↩ | ok (confirm) + AppModel.pin (Undo) |
| ➖ Go to Edit | text button | WeekView.swift:33-34 | ✅ clear | — | label is enough | — |

## Today

### Next-up card
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Thumb (file drag-out, `arrow.up.and.down.and.arrow.left.and.right`) | gesture | TodayView.swift:85; 247-271 | ⚠️ drag affordance tiny | "Drag <file> into the upload page" / "Preparing the file…" / "The file is still rendering" | keep | — |
| ✅ Copy caption | text button | TodayView.swift:93 | ⚠️ which platform's caption | — | Copy the <Platform> caption | — |
| ➖ Copy title | text button | TodayView.swift:95 | ✅ clear | Copy the YouTube title | keep | — |
| ➖ Open upload page | text button | TodayView.swift:97-98 | ✅ clear | Open the <Platform> upload page in your browser | keep | — |
| ➖ Mark posted | text button | TodayView.swift:100-103 | ✅ clear | "Paste the post URL" / "Not due yet — you can still mark it posted early" | keep | ok (confirm) — sheet |

### Post row (default: planned / ready / due / late)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Status badge | chip | TodayView.swift:152-153 | ✅ clear | statusHelp() e.g. "Post it now, then mark it posted" | keep | — |
| ✅ `text.quote` (icon) | icon | TodayView.swift:210 | ❌ glyph reads as a list | Copy caption | Copy the <Platform> caption | — |
| ✅ `textformat` ("Aa") | icon | TodayView.swift:212 | ❌ unlabelled | Copy title for YouTube | Copy the YouTube title | — |
| ✅ `doc.on.doc` (icon) | icon | TodayView.swift:214 | ❌ looks like "copy caption" | Copy file | Copy the video file to paste in upload | — |
| ✅ `folder` (icon) | icon | TodayView.swift:215 | ⚠️ which file | Reveal in Finder | Show the video file in Finder | — |
| ✅ `checkmark.circle` (icon) | icon | TodayView.swift:216 | ❌ looks like a done toggle | Mark posted… | Paste the post URL to mark it posted | ok (confirm) — sheet |
| ✅ `ellipsis` (icon) | menu | TodayView.swift:223 | ❌ "More" says nothing | More | Report, reschedule, reset or skip | — |
| ➖ Row right-click | menu | TodayView.swift:160 | ⚠️ hidden | — | — | see Shared › Post context menu |

### Post row (copyright / failed / posted)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Re-upload anyway ▾ | menu | TodaySheets.swift:152 | ⚠️ version choice unexplained | Upload again despite the copyright claim | Upload again despite the claim; pick a version · Disabled: <held reason> | — |
| ✅ Same version (vN) / vN | menu item | TodaySheets.swift:153-156 | ⚠️ when it posts not said | — | Titles "Same version (vN) on the next day's slot" / "vN on the next day's slot" | ok — new AppModel.reuploadAnyway (Today/AppModel+Today.swift) journals it: Undo · ⌘Z |
| ✅ New version (vN+1)… | menu item | TodaySheets.swift:158 | ✅ clear | — | Title "New version (vN+1), then open the editor…" | ok — AppModel.reuploadAnyway journals version + resolve as one step (Undo) |
| ✅ Skip platform | text button | TodayView.swift:190-192 | ✅ clear | Don't post this clip on <Platform> | Label → "Skip <Platform>" · Don't post this clip on <Platform> | ok — AppModel.resolve (Undo) |
| ✅ Accept | text button | TodayView.swift:193 | ⚠️ "Accept" what? | Keep it as it is (e.g. muted) | Label → "Accept claim" · Leave the post as it is (e.g. muted) | ok — AppModel.resolve (Undo) |
| ✅ Fix… | text button | TodayView.swift:196 | ⚠️ hides auto re-queue on close | Open the editor to fix it | Label → "Fix in editor" · Edit it; closing the editor re-queues it | ok — re-queue on close is AppModel.fixed (journaled, Undo); tooltip now says it |
| ✅ Re-queue | text button | TodayView.swift:197 | ⚠️ "when" unclear | The cause is fixed: try again on the next day's slot | Try again on the next day's slot | ok — AppModel.fixed (Undo) |
| ✅ `arrow.up.right.square` (icon) | icon | TodayView.swift:201 | ✅ clear | Open the post | Open the live post in your browser | — |
| ✅ N views / Metrics | text button | TodayView.swift:203-205 | ⚠️ opens an entry popover | Views and likes after 72 h | Enter views and likes after 72 h | — |

### Row ⋯ menu
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Report problem… | menu item | TodayView.swift:225 | ✅ clear | — | label is enough | ok (confirm) — sheet |
| ➖ Open upload page | menu item | TodayView.swift:228 | ✅ clear | — | label is enough | — |
| ✅ Post now | menu item | TodayView.swift:231 | ⚠️ means "make due", not upload | — | Title "Post now (make it due today)" · disabled "Post now — sent back to Edit" (native .help removed) | ok — AppModel.postNow (Undo) |
| ✅ Shift plan | menu item | TodayView.swift:232 | ⚠️ jargon | — | Title "Shift to next free <Platform> slot" · disabled "… — sent back to Edit" | ok — AppModel.shiftPlan (Undo) |
| ✅ Reset | menu item | TodayView.swift:235 | ⚠️ reset to what? | — | Title "Reset to Planned" | ok — AppModel.reset (Undo) |
| ✅ Skip this platform | menu item | TodayView.swift:236 | ✅ clear | — | Title "Skip <Platform>" | ok — AppModel.skip (Undo) |
| ➖ Open editor | menu item | TodayView.swift:239 | ✅ clear | — | label is enough | — |

### Sheets and popover
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Mark posted › Post URL | field | TodaySheets.swift:29-32 | ✅ clear | hint "Must be a <host> link" | label is enough | — |
| ➖ Mark posted › Posted at | field | TodaySheets.swift:36-39 | ✅ clear | When it went live | keep | — |
| ➖ Mark posted › Cancel | text button | TodaySheets.swift:43 | ✅ clear | — | label is enough · esc | — |
| ➖ Mark posted › Mark posted | text button | TodaySheets.swift:44-46 | ✅ clear | disabled: "Paste the post URL first" / URL error | label is enough · ↩ · Disabled: paste a valid <host> URL | ok (confirm) + AppModel.markPosted (Undo) |
| ✅ Report › Problem type chips | chip | TodaySheets.swift:85-88 | ⚠️ © consequence shown only after pick | — | Copyright: stops this platform, no retry (copyright chips only) | — |
| ➖ Report › What happened? | field | TodaySheets.swift:91 | ✅ clear | — | label is enough | — |
| ➖ Report › Add raw response | text button | TodaySheets.swift:95 | ✅ clear | — | label is enough | — |
| ➖ Report › Raw response | field | TodaySheets.swift:93 | ✅ clear | — | label is enough | — |
| ➖ Report › Cancel | text button | TodaySheets.swift:103 | ✅ clear | — | label is enough · esc | — |
| ✅ Report › Save problem | text button | TodaySheets.swift:104-109 | ⚠️ doesn't say post becomes failed | — | Mark the post failed with this problem · ↩ | ok (confirm) + AppModel.reportProblem (Undo) |
| ➖ Metrics › Views / Likes | field | TodaySheets.swift:175-176 | ✅ clear | — | label is enough | — |
| ➖ Metrics › Save | text button | TodaySheets.swift:180-185 | ✅ clear | disabled: "Numbers only" | label is enough · ↩ · Disabled: numbers only | — |
| ⏭ LongformPostedSheet (whole sheet) | field | TodaySheets.swift:118-143 | — | — | — | ⏭ dead code, but MainWindowView.swift (parent-owned) still references it — not trivially safe to delete here |

### Empty state
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Open Week | text button | TodayView.swift:30-32 | ✅ clear | — | label is enough | — |

## Library

### Toolbar and filters
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Search clips | field | LibraryView.swift:29 | ✅ clear | — | label is enough | — |
| ✅ `xmark.circle.fill` in search | icon | DSInputs.swift:129-131 | ✅ clear | Clear | Clear the search | DS: Clear the text |
| ✅ View mode (Cards / Grid / Single / List icons) | segmented | LibraryView.swift:30; DSChoice.swift:316-323, 333 | ⚠️ tooltip is just the mode name | Cards / Grid / Single / List | Show clips as cards / a grid / one at a time / a list | DS: Show clips as cards / grid of tiles / one big clip / compact rows |
| ➖ All · Posted · Excluded · Missing · Long-form | chip | LibraryView.swift:114-119, 137-145 | ✅ clear | e.g. "File missing, or removed from videos.json" | keep | — |
| ➖ Session ▾ | menu | LibraryView.swift:121-124 | ✅ clear | Show one session | keep | — |
| ✅ Kind ▾ | menu | LibraryView.swift:125-126 | ⚠️ tooltip is a fragment | DJ vid or Talking | Show only DJ vids or Talking clips | — |
| ➖ Score ▾ | menu | LibraryView.swift:127-128 | ✅ clear | Filter short clips by score | keep | — |
| ✅ Clear | text button | LibraryView.swift:130 | ✅ clear | Show every clip | Label → "Clear filters" · Clear filters and search | — |
| ➖ Session order ▾ (sort) | menu | LibraryView.swift:133-134 | ✅ clear | Sort clips | keep | — |
| ✅ Space key | gesture | LibraryView.swift:46-50 | ⚠️ acts on first selected, not hovered | (advertised as "Space" on eye buttons) | Hover eye buttons no longer advertise Space (it opens the first *selected* clip) | — |
| ✅ Digit keys 0–9 | gesture | LibraryView.swift:51-56 | ❌ invisible: typing a number scores | — | Hint on bulk "Score…": Score the selection, or type a number 0–100 | ok — typeDigit → AppModel.setScore (journaled, Undo) |

### Clip cards — hover actions per view mode
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Grid: `eye` (on hover, over media) | icon | LibraryView.swift:208; DSClipCard.swift:291-294 | ✅ clear | Quick look · Space | Preview the clip and its status | — |
| ✅ Cards: `eye` (always shown) | icon | LibraryView.swift:215; DSClipCard.swift:262 | ✅ clear | Quick look · Space | Preview the clip and its status | — |
| ✅ List: `eye` (on hover) | icon | LibraryView.swift:215; DSClipCard.swift:383 | ✅ clear | Quick look · Space | Preview the clip and its status | — |
| ✅ Single: Quick look | text button | LibraryView.swift:211 | ✅ clear | — | Preview the clip and its status | — |
| ✅ Single: Exclude / Include | text button | LibraryView.swift:212 | ⚠️ consequence not stated | — | Keep this clip out of the plan / Put it back into the plan | ok — AppModel.setExcluded (journaled, Undo) |
| ➖ Single: `chevron.left` / `chevron.right` | icon | ClipCollection.swift:141-148 | ✅ clear | Previous clip · ← / Next clip · → (disabled first/last) | keep | — |
| ➖ Select circle (Grid / Cards / List) | toggle | DSClipCard.swift:162-164 | ✅ clear | Select / Deselect | keep | — |
| ⏭ Card click | gesture | DSClipCard.swift:126, 134-139; LibraryView.swift:231-237 | ⚠️ editor vs quick look vs select | — | Click to edit · ⌘-click to select | ⏭ DesignSystem/DSClipCard + Shared/ClipCollection (not in this pass's files) |
| ➖ Mute (video preview) | icon | DSVideoPreview.swift:93-104 | ✅ clear | Mute / Unmute | label is enough | — |
| ➖ Score "—" / date chip | chip | DSClipCard.swift:172, 199 | ✅ clear | Not scored / Pinned to this date / Not in the plan yet / Next post | keep | — |

### Card right-click
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Quick look | menu item | LibraryView.swift:220 | ✅ clear | — | label is enough · Space | — |
| ✅ Look for the file | menu item | LibraryView.swift:222, 243-246 | ⚠️ runs a whole engine tick | — | Title "Look for the file (run intake now)" | — |
| ✅ Keep posting it | menu item | LibraryView.swift:225 | ⚠️ context (left videos.json) missing | — | Title "Keep posting it…" | ok (confirm) — the kept flag (kv ui.keptRemoved) isn't journaled, so it asks first; Undo needs a core change |
| ➖ VideoContextMenu items | menu | LibraryView.swift:228 | — | — | — | see Shared › Video context menu |

### Long-form section
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Tile select circle | toggle | LongformSection.swift:101-102 | ✅ clear | Select / Deselect | keep | — |
| ✅ Tile / row click | gesture | LongformSection.swift:116, 164 | ⚠️ opens quick look, no hint | — | Click for quick look · ⌘-click to select | — |
| ➖ Mark posted | text button | LongformSection.swift:77-81 | ✅ clear | Paste the YouTube link; the file moves to Posted/Longform (disabled: "Excluded — include it first") | keep | ok (confirm) — dialog |
| ➖ `arrow.up.right.square` (icon) | icon | LongformSection.swift:75 | ✅ clear | Open on YouTube · <url> | keep | — |
| ➖ Row select circle | toggle | LongformSection.swift:145-147 | ✅ clear | Select / Deselect | keep | — |
| ➖ Right-click › Quick look | menu item | LongformSection.swift:175 | ✅ clear | — | label is enough | — |
| ➖ Right-click › Open on YouTube | menu item | LongformSection.swift:177 | ✅ clear | — | label is enough | — |
| ➖ Right-click › Copy YouTube link | menu item | LongformSection.swift:178 | ✅ clear | — | label is enough | — |
| ➖ Right-click › Mark posted… | menu item | LongformSection.swift:180 | ✅ clear | — | label is enough | ok (confirm) — dialog |
| ✅ Right-click › Exclude / Include | menu item | LongformSection.swift:183-185 | ⚠️ consequence not stated | — | Titles "Exclude (stop posting it)" / "Include (post it again)" | ok — AppModel.setExcluded (journaled, Undo) |

### Bulk bar
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ `xmark` (clear selection) | icon | DSOverlays.swift:340-344 | ✅ clear | Clear selection · esc | keep | — |
| ➖ Select all | text button | DSOverlays.swift:347-348 | ✅ clear | Select every clip on this screen · ⌘A | keep | — |
| ✅ Score… | text button | LibraryView.swift:257-259 | ✅ clear | Give the selected short clips one score | Score the selection, or type a number 0–100 | ok (confirm + undo) |
| ✅ Kind ▾ (DJ vid / Talking) | menu | LibraryView.swift:261-277 | ✅ clear | Set the kind | Set DJ vid or Talking for the selection | ok (confirm + undo) |
| ➖ Exclude / Include | text button | LibraryView.swift:278-281 | ✅ clear | Keep these clips out of the plan / Put these clips back into the pipeline | keep | ok (confirm + undo) |
| ➖ Mark long-form posted | text button | LibraryView.swift:283-288 | ✅ clear | Paste each YouTube link; the files move to Posted/Longform (disabled: already posted) | keep | ok (confirm) — dialog |
| ✅ More ▾ | menu | ScreenBulkBar.swift:44-53 | ⚠️ "More" says nothing | More bulk actions | Agent prompt, re-render, apply defaults | More ▾: More actions for the selected clips (parent) |
| ➖ Mark N long-form posted… | menu item | LibraryView.swift:291 | ✅ clear | — | label is enough | ok (confirm) — dialog |
| ✅ Copy agent prompt for N clips | menu item | LibraryView.swift:294-295 | ⚠️ "agent" jargon; disabled, no reason | — | Title "Copy agent prompt to find titles (N clips)" · disabled "Copy agent prompt — select short clips" | — |
| ✅ Re-render N clips | menu item | LibraryView.swift:296 | ✅ clear | — | Title "Re-render N clips…" (opens the confirm) | ok (confirm + undo) |
| ✅ Apply defaults to N clips… | menu item | LibraryView.swift:297-298 | ⚠️ which defaults; disabled, no reason | — | Title "Apply defaults (frame, trim, text, caption) to N clips…" · disabled "Apply defaults — select short clips" | ok (confirm + undo) |

### Dialogs
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Quick look › preview + scrubber | gesture | LibraryDialogs.swift:22-24 | ✅ clear | — | — | — |
| ➖ Quick look › Close | text button | LibraryDialogs.swift:79 | ✅ clear | — | label is enough · esc | — |
| ✅ Quick look › Exclude / Include (missing file) | text button | LibraryDialogs.swift:81 | ⚠️ consequence not stated | — | Keep it out of the plan while missing / Put it back into the plan | ok — AppModel.setExcluded (Undo) |
| ✅ Quick look › Look for the file | text button | LibraryDialogs.swift:82-86 | ✅ clear | Runs intake now; it relinks renamed or moved files by fingerprint | Run intake now to relink moved files | — |
| ✅ Quick look › Exclude (removed from videos.json) | text button | LibraryDialogs.swift:88-92 | ⚠️ also marks it kept | — | Stop posting it; keep its history | ok — exclusion is journaled (Undo); the kept flag it also sets isn't (core) |
| ✅ Quick look › Keep posting it | text button | LibraryDialogs.swift:93-96 | ✅ clear | — | Label "Keep posting it…" · Keep posting though it left videos.json | ok (confirm) — not journaled, so it asks first |
| ➖ Quick look › Copy link | text button | LibraryDialogs.swift:99 | ✅ clear | — | label is enough | — |
| ➖ Quick look › Open on YouTube | text button | LibraryDialogs.swift:100 | ✅ clear | — | label is enough | — |
| ➖ Quick look › Mark posted… | text button | LibraryDialogs.swift:102-106 | ✅ clear | disabled: "Excluded — include it first" | label is enough · Disabled: excluded, include it first | ok (confirm) — dialog |
| ➖ Quick look › Open editor | text button | LibraryDialogs.swift:109-112 | ✅ clear | — | label is enough | — |
| ➖ Long-form posted › YouTube link field(s) | field | LibraryDialogs.swift:155-159 | ✅ clear | — | label is enough | — |
| ➖ Long-form posted › Cancel | text button | LibraryDialogs.swift:162 | ✅ clear | — | label is enough · esc | — |
| ✅ Long-form posted › Mark posted / Mark N posted | text button | LibraryDialogs.swift:163-164 | ✅ clear | disabled: "Fix the links marked in red" / "Paste … first" | Save links; files move to Posted/Longform · ↩ | ok (confirm) — no undo for the file move |
| ➖ Score dialog › 0–100 field | field | LibraryDialogs.swift:192-193 | ✅ clear | — | label is enough | — |
| ➖ Score dialog › Cancel | text button | LibraryDialogs.swift:195 | ✅ clear | — | label is enough · esc | — |
| ➖ Score dialog › Set score | text button | LibraryDialogs.swift:196-197 | ✅ clear | disabled: "Type a score from 0 to 100" | label is enough · ↩ | ok (confirm + undo) |

### Empty states
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Check for new clips | text button | LibraryView.swift:158-160 | ⚠️ runs an engine tick | — | label is enough | — |
| ➖ Clear filters | text button | LibraryView.swift:162-164 | ✅ clear | — | label is enough | — |

## Posts

### Toolbar, tabs, empty states
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Search posts | field | PostsView.swift:23 | ✅ clear | — | label is enough | — |
| ➖ Platform ▾ | menu | PostsView.swift:24-26 | ✅ clear | Show one platform | keep | — |
| ✅ Problems · Scheduled · Posted · All | segmented | PostsView.swift:102-107 | ⚠️ "Scheduled" silently excludes missed | — | DSTabs has no per-tab tooltip → one caption line under the tabs describes the open tab (e.g. "Posts still to go out (missed ones are in Problems)") | — |
| ➖ Open Week | text button | PostsView.swift:112-113 | ✅ clear | — | label is enough | — |
| ➖ Show all posts | text button | PostsView.swift:116-117 | ✅ clear | — | label is enough | — |
| ➖ Clear filters | text button | PostsView.swift:119-123 | ✅ clear | — | label is enough | — |

### Problem card
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Card body click | gesture | PostProblemCard.swift:86-87 | ⚠️ opens inspector, no hint | — | Click for details and attempt history | — |
| ➖ Relative time | chip | PostProblemCard.swift:55-56 | ✅ clear | full date/time | keep | — |
| ➖ Raw response (disclosure) | text button | PostProblemCard.swift:65-76 | ✅ clear | Show / Hide what the platform answered | keep | — |
| ✅ Post now | text button | PostProblemCard.swift:91-92 | ⚠️ also jumps to Today | Make it due now on today's <Platform> slot | Make it due now and open Today | ok — AppModel.postNow (Undo) |
| ➖ Shift plan | text button | PostProblemCard.swift:93-94 | ⚠️ jargon label | Move it to the next free <Platform> slot | keep | ok — AppModel.shiftPlan (Undo) |
| ✅ Fix in editor | text button | PostProblemCard.swift:96-99 | ✅ clear | Open the editor; when you close it the post is tried again (disabled: fixReason) | Edit it; closing the editor re-queues it | ok — re-queue on close = AppModel.fixed (journaled, Undo) |
| ➖ Re-upload anyway ▾ (disabled) | text button | PostProblemCard.swift:131-132 | ✅ clear | disabled: "Already handled" / "Only for copyright problems" | keep | — |
| ✅ Re-upload anyway ▾ | menu | PostProblemCard.swift:135-152 | ✅ clear | Try again on the next day: same version, a later one, or a new one | Upload again despite the claim; pick a version | — |
| ✅ Same version (vN) / vN | menu item | PostProblemCard.swift:136-139 | ⚠️ when it posts not said | — | Shared ReuploadItems: "… on the next day's slot" | ok — AppModel.reuploadAnyway (Undo) |
| ✅ New version (vN+1)… | menu item | PostProblemCard.swift:141 | ✅ clear | — | "New version (vN+1), then open the editor…" | ok — AppModel.reuploadAnyway (Undo) |
| ✅ Skip platform | text button | PostProblemCard.swift:102-103 | ✅ clear | Don't post this clip on <Platform> (disabled: skipReason) | Label → "Skip <Platform>" | ok — AppModel.skip (Undo) |
| ✅ Accept | text button | PostProblemCard.swift:104-105 | ⚠️ "Accept" what? | Leave it as it is (e.g. muted audio is fine) (disabled: acceptReason) | Label → "Accept claim" · Leave the post as it is (e.g. muted) | ok — AppModel.resolve (Undo) |
| ✅ Reset | text button | PostProblemCard.swift:106-107 | ⚠️ reset to what? | Back to planned, error cleared (disabled: resetReason) | Back to Planned, error cleared | ok — AppModel.reset (Undo) |
| ✅ `ellipsis` (icon) | menu | PostProblemCard.swift:158-184 | ❌ icon only, vague tooltip | More actions | Retry, mark posted, report or copy details | — |
| ✅ ⋯ › Try again on the next slot | menu item | PostProblemCard.swift:165 | ✅ clear | — | Disabled title "… — sent back to Edit" (native .help removed) | ok — AppModel.fixed (Undo) |
| ➖ ⋯ › Mark posted… | menu item | PostProblemCard.swift:167 | ✅ clear | — | label is enough | ok (confirm) — sheet |
| ➖ ⋯ › Report problem… | menu item | PostProblemCard.swift:169 | ✅ clear | — | label is enough | ok (confirm) — sheet |
| ✅ ⋯ › Copy details | menu item | PostProblemCard.swift:171-174 | ✅ clear | — | Title "Copy details (platform, error, raw response)" | — |
| ➖ ⋯ › Open editor | menu item | PostProblemCard.swift:176 | ✅ clear | — | label is enough | — |

### Post rows (Scheduled / Posted / All)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Select circle | toggle | PostsView.swift:215-217 | ✅ clear | Select / Deselect | keep | — |
| ✅ Row click | gesture | PostsView.swift:254, 259-270 | ⚠️ inspector vs toggle, no hint | — | Click for details · ⌘-click to select | — |
| ✅ vN | chip | PostsView.swift:226-228 | ✅ clear | Version N | Version N (native .help → dsTooltip) | — |
| ✅ #N | chip | PostsView.swift:230-232 | ⚠️ "#" = attempt | Attempt N[ · retry/repost] | Attempt N[ · retry/repost] (native .help → dsTooltip) | — |
| ✅ `arrow.up.right.square` (icon) | icon | PostsView.swift:238-243 | ✅ clear | Open post · <url> (disabled: "No link yet — not posted") | Open the live post · <url> · Disabled: no link yet — not posted | — |
| ➖ Row right-click | menu | PostsView.swift:255 | ⚠️ hidden | — | — | see Shared › Post context menu |

### Grouped post cards (PostGroupCard, round 3 F4) — new since the audit
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Group select circle | toggle | PostGroupCard.swift (header) | ✅ clear | native `.help` | Select / Deselect these N posts (dsTooltip) | — |
| ✅ Show / hide platforms (`chevron.down`) | icon | PostGroupCard.swift (header) | ⚠️ glyph only | native `.help` "Show platforms" | Show each platform's time and actions / Hide the per-platform rows | — |
| ✅ Card header click | gesture | PostGroupCard.swift (header) | ⚠️ hidden | — | Click to show each platform / Click to hide the platforms | — |
| ✅ Platform state chip (collapsed card) | chip | PostGroupCard.swift (PostPlatformChip) | ⚠️ colour only | native `.help` | <Platform> · <state> · <date>[ · attempt] (dsTooltip, hover target = capsule) | — |
| ✅ Per-platform row click | gesture | PostGroupCard.swift (PostGroupRow) | ⚠️ hidden | — | Click for details · ⌘-click to select | — |
| ✅ Per-platform row select circle | toggle | PostGroupCard.swift (PostGroupRow) | ✅ clear | native `.help` | Select / Deselect | — |
| ✅ Per-platform row vN / #N / Retry · Repost badge | chip | PostGroupCard.swift (PostGroupRow) | ✅ clear | native `.help` | Version N / Attempt N · retry / "Tried again after a failure, same day" (dsTooltip) | — |
| ✅ Per-platform row `arrow.up.right.square` | icon | PostGroupCard.swift (PostGroupRow) | ✅ clear | Open post · <url> | Open the live post · <url> · Disabled: no link yet — not posted | — |
| ✅ Per-platform row right-click | menu | PostGroupCard.swift (PostGroupRow) | ⚠️ hidden | — | — | see Shared › Post context menu |
| ✅ +N fine / Hide N fine (Problems) | text button | PostGroupCard.swift (problemBody) | ✅ clear | native `.help` | Show the platforms that posted fine / Hide the platforms without a problem | — |
| ➖ Card right-click | menu | PostGroupCard.swift | ⚠️ hidden | — | — | Post context menu (one post) + Open editor |

### Bulk bar and bulk dialog
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ `xmark` (clear selection) | icon | DSOverlays.swift:340-344 | ✅ clear | Clear selection · esc | keep | — |
| ⏭ Select all | text button | DSOverlays.swift:347-348 | ⚠️ tooltip says "clip" on Posts | Select every clip on this screen · ⌘A | Select every post shown · ⌘A | ⏭ DesignSystem/DSOverlays (DS-owned) — the "clip" wording needs a DS param |
| ✅ Reset (N) | text button | PostsView.swift:158-160 | ⚠️ reset to what? | only when disabled: "None of these can be reset (planned, or their time passed)" | Back to Planned, errors cleared · Disabled: none can be reset | ok (confirm) |
| ✅ Skip (N) | text button | PostsView.swift:161-163 | ✅ clear | only when disabled: "These are already finished" | Don't post these on their platforms · Disabled: already finished | ok (confirm) |
| ✅ Retry (N) | text button | PostsView.swift:164-166 | ✅ clear | only when disabled: "Only failed posts can be retried" | Try failed posts again on the next slot · Disabled: only failed posts | ok (confirm) |
| ➖ Bulk dialog › Cancel | text button | PostInspector.swift:267 | ✅ clear | — | label is enough · esc | — |
| ✅ Bulk dialog › Reset / Skip / Retry N | text button | PostInspector.swift:268-271 | ✅ clear | disabled: "Nothing to …" | label is enough · ↩ | ok (confirm) + now journaled via AppModel.undoable (Undo · ⌘Z); dialog text says "You can undo this" |

### Inspector
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `xmark` (close) | icon | PostInspector.swift:46-48 | ✅ clear | Close inspector · esc | Close details (esc hint removed: the inspector never holds focus and esc already clears the selection) | — |
| ✅ Link (URL) | text button | PostInspector.swift:92 | ✅ clear | <url> | Open the live post | — |
| ✅ Render file name | text button | PostInspector.swift:99-101 | ⚠️ looks like it opens the file | Reveal in Finder | Show the rendered file in Finder | — |
| ➖ Post ID | field | PostInspector.swift:107 | ✅ clear | — | — | — |
| ➖ Metrics › Views / Likes | field | PostInspector.swift:130-131 | ✅ clear | — | label is enough | — |
| ➖ Metrics › Save | text button | PostInspector.swift:132-135 | ✅ clear | disabled: "Whole numbers only" / "Nothing changed" | label is enough | — |
| ➖ Attempt row | gesture | PostInspector.swift:156-158 | ✅ clear | This attempt / Show attempt #N | keep | — |
| ➖ Repost (per platform) | text button | PostInspector.swift:195-196 | ✅ clear | Queue the next version on <Platform> (disabled: repostBlocker) | keep | ok — AppModel.repost (Undo) |
| ➖ Mark posted… | text button | PostInspector.swift:205-208 | ✅ clear | disabled: "Already <state>" | label is enough · Disabled: already <state> | ok (confirm) — sheet |
| ➖ Report problem… | text button | PostInspector.swift:209-212 | ✅ clear | disabled: "Already <state>" | label is enough | ok (confirm) — sheet |
| ✅ Reset | text button | PostInspector.swift:213 | ⚠️ reset to what? | only disabled reason | Back to Planned, error cleared · Disabled: <resetReason> | ok — AppModel.reset (Undo) |
| ✅ Skip | text button | PostInspector.swift:214 | ⚠️ skip what? | only disabled reason | Label → "Skip <Platform>" · Don't post this clip on <Platform> | ok — AppModel.skip (Undo) |
| ➖ Open editor | text button | PostInspector.swift:215 | ✅ clear | — | label is enough | — |

## Health

### Toolbar ⋯
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `ellipsis` (icon) | menu | HealthView.swift:20-31 | ⚠️ icon only | Engine tick, log, Doctor | Run a tick, open the log or re-run Doctor | — |
| ✅ Run engine tick now | menu item | HealthView.swift:21 | ⚠️ "tick" is jargon | — | Title "Run engine tick now (check, render, plan)" | — |
| ➖ Open engine log | menu item | HealthView.swift:22 | ✅ clear | — | label is enough | — |
| ✅ Run Doctor again | menu item | HealthView.swift:23 | ✅ clear | — | Title "Run Doctor again (read-only checks)" | — |

### Header, checks, findings
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Run again | text button | HealthView.swift:90-91 | ✅ clear | Check everything again | keep | — |
| ✅ Copy report | text button | HealthView.swift:92-97 | ✅ clear | Copy the checks and Doctor findings as Markdown to paste to an agent (66 chars) | Copy the report as Markdown for an agent · Disabled: Doctor is still checking | — |
| ➖ Check row (`chevron.down`) | text button | HealthView.swift:185-199 | ✅ clear | Show details and fix / Hide details | keep | — |
| ➖ Check action (Run tick now / Open engine log / Open engine settings) | text button | HealthView.swift:209-211 | ✅ clear | — | label is enough | — |
| ➖ Severity icon | icon | HealthView.swift:236-238 | ✅ clear | Info / Warning / Error | keep | — |
| ➖ Show all N / Show fewer | text button | HealthView.swift:253-254 | ✅ clear | — | label is enough | — |
| ➖ Awake bar / missed tick | gesture | AwakeChartCard.swift:86, 91 | ✅ clear | Awake <start> – <end> / Missed: <Platform> <time> | keep | — |

## Shared menus used by these screens

### Post context menu (PostContextMenu) — Week slot + extra chips (WeekView.swift:360, 436), Today rows (TodayView.swift:160), Posts rows (PostsView.swift:255)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Mark posted… | menu item | CommandPalette.swift:480 | ✅ clear | — | label is enough | labelled menu item |
| ➖ Copy caption | menu item | CommandPalette.swift:481 | ✅ clear | — | label is enough | labelled menu item |
| ➖ Copy title | menu item | CommandPalette.swift:482 | ✅ clear | — | label is enough | labelled menu item |
| ➖ Open upload page | menu item | CommandPalette.swift:483 | ✅ clear | — | label is enough | labelled menu item |
| ➖ Reveal in Finder | menu item | CommandPalette.swift:484 | ⚠️ may render first | — | Show the file in Finder (renders if needed) | labelled menu item |
| ➖ Copy file | menu item | CommandPalette.swift:485 | ⚠️ may render first | — | Copy the video file (renders if needed) | labelled menu item |
| ➖ Report problem… | menu item | CommandPalette.swift:489 | ✅ clear | — | label is enough | labelled menu item |
| ✅ Post now | menu item | CommandPalette.swift:492 | ⚠️ means "make due", jumps to Today | — | Make it due now and open Today | ok — AppModel.postNow is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Shift plan | menu item | CommandPalette.swift:493 | ⚠️ jargon | — | Move it to the next free <Platform> slot | ok — AppModel.shiftPlan is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Reset post | menu item | CommandPalette.swift:495 | ⚠️ reset to what? | — | Back to Planned, error cleared | ok — AppModel.reset is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Skip this platform | menu item | CommandPalette.swift:496 | ✅ clear | — | Don't post this clip on <Platform> | ok — AppModel.skip is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ➖ Edit video | menu item | CommandPalette.swift:499 | ✅ clear | — | label is enough | labelled menu item |

### Video context menu (VideoContextMenu) — Week backlog tiles (WeekView.swift:511), Library cards (LibraryView.swift:228)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Edit | menu item | CommandPalette.swift:447 | ✅ clear | — | label is enough | labelled menu item |
| ➖ Preview | menu item | CommandPalette.swift:448 | ✅ clear | — | label is enough | labelled menu item |
| ✅ Post today | menu item | CommandPalette.swift:450 | ⚠️ which slot / what moves | — | Put it on today's slot; the plan shifts | ok — AppModel.postToday is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Pin to tomorrow | menu item | CommandPalette.swift:451 | ✅ clear | — | label is enough | ok — AppModel.pin is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Skip next slot | menu item | CommandPalette.swift:452 | ⚠️ unclear who takes the slot | — | Let the next clip take its slot | ok — AppModel.skipNext is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Repost on ▸ <Platform> (blocked: "<Platform> — why", disabled) | menu item | CommandPalette.swift:453, 507-519 | ✅ clear | — (reason inline in title) | Queue the next version on <Platform> | ok — AppModel.repost is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Duplicate version | menu item | CommandPalette.swift:455 | ⚠️ which version | — | Copy the latest version as vN+1 | ok — AppModel.duplicateVersion is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Re-render | menu item | CommandPalette.swift:456 | ✅ clear | — | Make the video file again now | agent A: forces a fresh render via requestBulk + bulk.reRender (Undo) |
| ✅ Add N to week (multi-select) | menu item | CommandPalette.swift:458 | ✅ clear | — | Put them on the next open days | agent A: many clips → confirm sheet + Undo |
| ✅ Kind ▸ DJ vid / Talking | menu item | CommandPalette.swift:460-462 | ✅ clear | — | label is enough | ok — AppModel.setKind is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Score ▸ 90 … 30 / Clear | menu item | CommandPalette.swift:463-466 | ⚠️ presets only; "Clear" wipes | — | Set score; higher posts sooner | ok — AppModel.setScore is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |
| ✅ Exclude / Include | menu item | CommandPalette.swift:468-470 | ✅ clear | — | Keep out of the plan / Put back | ok — AppModel.setExcluded is journaled centrally (toast · Undo, ⌘Z); label/confirm changes owned by Shell/CommandPalette (agent A) |

### Risky one-click actions
- **Cross-cutting:** every `model.perform(...)` action (AppModel.swift:508-520) only shows a plain toast — no Undo and no batch id. ⌘Z (`undoLast`, AppModel+Bulk.swift:149-152) undoes the last *bulk* batch, so pressing ⌘Z after a Week swap, Skip, Reset… silently undoes an older, unrelated bulk edit. Fix: give plan/post actions a batch journal (or at least clear `lastBatchId`) and an Undo toast.
- **Cross-cutting:** native menu items that are `.disabled` (Rebuild week, Propose week, Swap with, Remove from week, Skip platform, Copy agent prompt, Apply defaults) can't show a tooltip, so they give no reason. Fix: add the reason to the item title, as RepostMenu does ("<Platform> — why").
- Week › Approve week (button and ⌘↩): creates the week's posts at once → Undo toast ("Back to Draft").
- Week › ⋯ › Rebuild week: wipes unpinned future slots + posts and un-approves → Confirm sheet.
- Week › ⋯ › Push plan by a day: shifts every unpinned slot from today on, across all weeks → Confirm sheet.
- Week › ⋯ › Propose week → Undo toast.
- Week › drag a day card onto another day (swap/move, even when approved) → Undo toast.
- Week › drop a backlog clip on an empty day; "Add from queue" → Undo toast.
- Week › card menu: Swap with, Remove from week, Pin to this day, Skip platform → Undo toast.
- Today › row: Skip platform, Accept, Re-queue, Re-upload anyway (all versions) → Undo toast.
- Today › Fix… and Posts › Fix in editor: closing the editor auto re-queues the post → Undo toast (or ask on close).
- Today › ⋯: Post now, Shift plan, Reset, Skip this platform → Undo toast.
- Library › digit keys with a selection set the score (no visible hint, no undo) → Undo toast.
- Library › Single view Exclude/Include; long-form right-click Exclude/Include; quick look Exclude/Include, Exclude (removed), Keep posting it; card right-click Keep posting it → Undo toast (route through `bulk.setExcluded`).
- Posts › problem card: Post now (also navigates to Today), Shift plan, Skip platform, Accept, Reset, Re-upload anyway (all items), ⋯ › Try again on the next slot → Undo toast.
- Posts › inspector: Repost, Reset, Skip → Undo toast.
- Shared › Post context menu: Post now, Shift plan, Reset post, Skip this platform → Undo toast.
- Shared › Video context menu: Post today, Pin to tomorrow, Skip next slot, Repost on, Duplicate version, Kind, Score, Exclude/Include → Undo toast; Add N to week and multi-clip Kind/Score → Confirm sheet (BulkActions already has these ops with undo).
- Not risky but wrong: the Posts inspector close button advertises "esc", but nothing binds esc to close it (PostInspector.swift:46; no `onExitCommand`). Library "Space" tooltips imply the hovered clip, but Space opens the first *selected* clip (LibraryView.swift:46-50). TodaySheets.swift:118-143 LongformPostedSheet is never shown (dead code).


---

## Settings

**Phase B (agent/tooltips-c):** every immediate setting is now undoable with a specific toast (`model.update("Posts per day set to 3")` · Undo, ⌘Z); New clip defaults Save/Reset go through `model.undoable(settings:)`; limits fields save on ↩/blur; deleting a template or hashtag set and turning on / lowering render deletion ask first (`model.confirm`). The paragraph below is the Phase A state.

Context: every section except New clip defaults applies at once through `model.update` → `perform` (App/AppModel.swift:704/509). `perform` only shows a plain toast and has no Undo. Settings has no ⌘Z, and no Default/Custom ↺ tags appear anywhere in Settings (those are editor-only). Shared row helpers: `SettingsRow` adds a tooltip only for `disabledReason` (SettingsRows+DSX.swift:62). `SettingsSelect` adds none (:126). `DSXStepper` −/+ always carry tooltips (:142, :152).

### Modal shell (SettingsModal.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ `xmark` | icon | SettingsModal.swift:95 | ✅ clear | "Close settings  esc" | Close settings · esc (dirty: “Close settings (unsaved defaults are kept)”) | — |
| ➖ Section nav rows ×10 | text button | SettingsModal.swift:175 | ✅ clear | Only "New clip defaults have unsaved changes" when dirty (:192) | label is enough | — |
| ➖ Unsaved dot | gesture (status) | SettingsModal.swift:180 | ⚠️ dot unexplained unless hovered | (row tooltip above) | label is enough | — (dot + row tooltip; click outside = Cancel is standard) |
| ➖ Confirm scrim | gesture | SettingsModal.swift:146 | ⚠️ click-outside cancels silently | — | — | — (click outside = Cancel, same as esc) |
| ✅ Confirm: Cancel | text button | SettingsModal.swift:150 | ✅ clear | — | Close without changing anything · esc | — |
| ✅ Confirm: primary | text button | SettingsModal.swift:152 | ✅ clear | — | label + ↩ keycap | — |

### General (SettingsSections.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Pause all posting | toggle | SettingsSections.swift:13 | ✅ clear | — | label is enough | ok (undo): setPaused toast “Posting paused” · Undo |
| ✅ Posts per day −/+ | icon | SettingsSections.swift:17 | ✅ clear | "Decrease/Increase posts per day"; disabled "Already at the minimum (1 per day)" | Post fewer clips each day / Post more clips each day. Disabled: at the minimum/maximum | ok (undo): toast “Posts per day set to N” · Undo, ⌘Z |
| ➖ Time zone | menu | SettingsSections.swift:20 | ✅ clear | — | label is enough | ok (undo): toast “Time zone set to …” · Undo, ⌘Z |
| ➖ Week starts on | menu | SettingsSections.swift:23 | ✅ clear | — | label is enough | ok (undo): toast “Week now starts on Monday” · Undo, ⌘Z |

### Platforms
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ On / Paused / Off ×6 | menu | SettingsSections.swift:50 | ✅ clear (note :57) | — | label is enough | ok (undo): toast “TikTok turned off” · Undo, ⌘Z (also Paused / turned on) |
| ✅ Limits cells (length s / size MB / caption / title) ×≈22 | field | SettingsSections.swift:107-111 (SettingsRows+DSX.swift:219) | ⚠️ only the column header says what it is | — | Set TikTok's longest clip (seconds) / largest file (MB) / caption limit (characters) / YouTube title limit | fixed: saves only on ↩ or blur (never mid-typing); invalid input snaps back; ok (undo): toast “TikTok length limit set to 180 s” · Undo, ⌘Z |
| ➖ "—" (no title limit) | gesture (info) | SettingsSections.swift:113 | ✅ clear | "Only YouTube has a title" | keep | — |
| ➖ Postiz API key | field | SettingsSections.swift:67 | ✅ clear | row: "Not available yet — arrives with automatic posting." | keep | — |

### Schedule
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Slot time ×active platforms | menu | SettingsSections.swift:150 | ✅ clear | — | label is enough | ok (undo): toast “TikTok slot set to 7:00 PM” · Undo, ⌘Z |
| ✅ Reset slot times (`arrow.counterclockwise`) | text button | SettingsSections.swift:156 | ⚠️ doesn't say what "built-in" times are | disabled only: "Slot times are already the built-in times" | Put every slot back to its built-in time. Disabled: already built-in | ok (undo): toast “Slot times reset” · Undo, ⌘Z |
| ➖ Second post offset −/+ | icon | SettingsSections.swift:166 | ✅ clear | Decrease/Increase…; row: "Only used with 2 or more posts per day (General)." | keep | ok (undo): toast “Second post offset set to +2 h” · Undo, ⌘Z |
| ➖ Post early | toggle | SettingsSections.swift:171 | ✅ clear | — | label is enough | ok (undo): toast “Post early turned on” · Undo, ⌘Z |
| ➖ Late grace −/+ | icon | SettingsSections.swift:174 | ✅ clear | Decrease/Increase late grace | keep | ok (undo): toast “Late grace set to 3 hours” · Undo, ⌘Z |
| ✅ Retry stagger −/+ | icon | SettingsSections.swift:177 | ⚠️ "stagger" is jargon | Decrease/Increase retry stagger | Retry failed posts sooner/later after the slot | ok (undo): toast “Retry stagger set to …” · Undo, ⌘Z |
| ➖ Repost cooldown −/+ | icon | SettingsSections.swift:180 | ✅ clear | Decrease/Increase repost cooldown | keep | ok (undo): toast “Repost cooldown set to …” · Undo, ⌘Z |

### Queue
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Order | menu | SettingsSections.swift:198 | ✅ clear | — | label is enough | ok (undo): toast “Order set to …” · Undo, ⌘Z |
| ➖ Per-platform order ×active | menu | SettingsSections.swift:208 | ✅ clear | — | label is enough | ok (undo): toast “TikTok order set to …” · Undo, ⌘Z |
| ➖ Avoid overlapping clips | toggle | SettingsSections.swift:216 | ✅ clear | — | label is enough | ok (undo): toast “Avoid overlapping clips turned on” · Undo, ⌘Z |
| ➖ Keep apart for −/+ | icon | SettingsSections.swift:220 | ✅ clear | Decrease/Increase…; row: "Turn on Avoid overlapping clips first." | keep | ok (undo): toast “Keep apart for …” · Undo, ⌘Z |

### Rendering
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Loudness target −/+ (LUFS) | icon | SettingsSections.swift:238 | ⚠️ LUFS jargon (description helps) | Decrease/Increase loudness target | Make renders quieter / Make renders louder | ok (undo): toast “Loudness target set to −14 LUFS” · Undo, ⌘Z |
| ✅ True peak −/+ (dBTP) | icon | SettingsSections.swift:241 | ⚠️ dBTP jargon | Decrease/Increase true peak | Lower / Raise the loudest-sample ceiling | ok (undo): toast “True peak set to …” · Undo, ⌘Z |
| ✅ Loudness range −/+ (LU) | icon | SettingsSections.swift:244 | ⚠️ LU jargon | Decrease/Increase loudness range | Allow less / more loudness variation | ok (undo): toast “Loudness range set to …” · Undo, ⌘Z |
| ➖ Bitrate −/+ | icon | SettingsSections.swift:249 | ✅ clear | Decrease/Increase bitrate | keep | ok (undo): toast “Bitrate set to N Mbps” · Undo, ⌘Z |
| ➖ Render ahead −/+ | icon | SettingsSections.swift:254 | ✅ clear | Decrease/Increase render ahead | keep | ok (undo): toast “Render ahead set to …” · Undo, ⌘Z |
| ✅ Cleanup (Keep forever / Delete after a while) | menu | SettingsSections.swift:259 | ✅ clear | — | label is enough | fixed: “Delete after a while” asks first (model.confirm: files deleted, footage never touched, Undo restores the setting not files); Keep forever is undoable |
| ✅ Delete after −/+ | icon | SettingsSections.swift:265 | ✅ clear | Decrease/Increase…; row: "Only used when Cleanup deletes renders." | Delete posted renders sooner / later | fixed: lowering asks first (older renders go on the next pass); raising is undoable |

### Playback & autoplay
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Autoplay previews | toggle | SettingsSections.swift:290 | ✅ clear | — | label is enough | — |
| ➖ Unmute on hover | toggle | SettingsSections.swift:294 | ✅ clear | row: "Turn on Autoplay previews first." | keep | — |
| ➖ Which clips play | menu | SettingsSections.swift:297 | ✅ clear | row disabled reason | keep | — |
| ➖ Loop | menu | SettingsSections.swift:303 | ✅ clear | row disabled reason | keep | — |

### Alerts
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Approve next week −/+ | icon | SettingsSections.swift:320 | ⚠️ label reads like an action, not a threshold | Decrease/Increase approve next week | Alert when fewer / more approved days are left | ok (undo): toast “Approval alert at N days left” · Undo, ⌘Z |
| ✅ Record a new set −/+ | icon | SettingsSections.swift:323 | ⚠️ label reads like an action | Decrease/Increase record a new set | Alert when fewer / more days of clips are left | ok (undo): toast “New-set alert at N days left” · Undo, ⌘Z |
| ➖ Approval reminder day | menu | SettingsSections.swift:329 | ✅ clear | — | label is enough | ok (undo): toast “Approval reminder moved to Monday” · Undo, ⌘Z |
| ➖ Approval reminder time | menu | SettingsSections.swift:331 | ✅ clear | — | label is enough | ok (undo): toast “Approval reminder moved to 9:00 AM” · Undo, ⌘Z |

### New clip defaults (NewClipDefaultsSettings.swift)
Edits go into a draft (`ui.draft`) and are committed only by Save. Field rows are "ok (save)".
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Aspect | menu | NewClipDefaultsSettings.swift:63 | ✅ clear | — | label is enough | ok (save) |
| ➖ Crop position | menu | NewClipDefaultsSettings.swift:66 | ✅ clear | — | label is enough | ok (save) |
| ➖ Start and end | menu | NewClipDefaultsSettings.swift:75 | ✅ clear | — | label is enough | ok (save) |
| ➖ Extra seconds before −/+ | icon | NewClipDefaultsSettings.swift:81 | ✅ clear | Decrease/Increase…; row: "Only used when the trim follows the markers." | keep | ok (save) |
| ➖ Extra seconds after −/+ | icon | NewClipDefaultsSettings.swift:84 | ✅ clear | same | keep | ok (save) |
| ➖ Style | menu | NewClipDefaultsSettings.swift:91 | ✅ clear | — | label is enough | ok (save) |
| ➖ Size | menu | NewClipDefaultsSettings.swift:94 | ✅ clear | — | label is enough | ok (save) |
| ➖ Vertical position | menu | NewClipDefaultsSettings.swift:98 | ✅ clear | — | label is enough | ok (save) |
| ➖ Horizontal position | menu | NewClipDefaultsSettings.swift:102 | ✅ clear | — | label is enough | ok (save) |
| ➖ Alignment `text.alignleft/center/right` | segmented | NewClipDefaultsSettings.swift:106-110 | ✅ clear | "Align left" / "Align centre" / "Align right" | keep | ok (save) |
| ➖ Show text | menu | NewClipDefaultsSettings.swift:113 | ✅ clear | — | label is enough | ok (save) |
| ➖ First seconds −/+ | icon | NewClipDefaultsSettings.swift:118 | ✅ clear | Decrease/Increase…; row: "Only used when text shows for the first seconds." | keep | ok (save) |
| ➖ Text comes from | menu | NewClipDefaultsSettings.swift:121 | ✅ clear | — | label is enough | ok (save) |
| ➖ No text for Talking clips | toggle | NewClipDefaultsSettings.swift:125 | ✅ clear | — | label is enough | ok (save) |
| ➖ Include text on cover | toggle | NewClipDefaultsSettings.swift:132 | ✅ clear | — | label is enough | ok (save) |
| ➖ Cover frame | menu | NewClipDefaultsSettings.swift:135 | ✅ clear | — | label is enough | ok (save) |
| ➖ Seconds into the trim −/+ | icon | NewClipDefaultsSettings.swift:140 | ✅ clear | Decrease/Increase…; row disabled reason | keep | ok (save) |
| ➖ Caption template | menu | NewClipDefaultsSettings.swift:148 | ✅ clear | — | label is enough | ok (save) |
| ✅ Hashtag set chips `number` | chip | NewClipDefaultsSettings.swift:154 | ⚠️ shows the set name, not its tags | — | Add #a #b to new clips / Stop adding #a #b to new clips (per chip) | ok (save) |
| ➖ Extra hashtags | field | NewClipDefaultsSettings.swift:158 | ✅ clear | — | label is enough | ok (save) |
| ➖ YouTube title template | field | NewClipDefaultsSettings.swift:165 | ✅ clear | — | label is enough | ok (save) |
| ➖ Per-platform caption template ×6 | menu | NewClipDefaultsSettings.swift:170 | ✅ clear | — | label is enough | ok (save) |
| ➖ Post to chips | chip | NewClipDefaultsSettings.swift:182 | ✅ clear | — | label is enough | ok (save) |
| ➖ Safe zones shown chips (+ None) | chip | NewClipDefaultsSettings.swift:185 | ✅ clear | — | label is enough | ok (save) |
| ✅ Reset to built-in defaults `arrow.counterclockwise` | text button | NewClipDefaultsSettings.swift:203 | ✅ clear | disabled only: "Already the built-in defaults" | Put every default back to the built-in value… | ok (confirm), then undoable: model.undoable(settings:) toast “New clip defaults reset” · Undo, ⌘Z |
| ✅ Cancel | text button | NewClipDefaultsSettings.swift:210 | ⚠️ discard or close? | disabled only: "No changes" | Renamed “Discard changes”: Throw away the unsaved default changes. Disabled: No unsaved changes | — (discards the draft only) |
| ✅ Save | text button | NewClipDefaultsSettings.swift:211 | ⚠️ consequence (all clips) not stated | disabled only: "No changes" | Save defaults (clips that follow them change) · ⌘S. Disabled: No unsaved changes | fixed: model.undoable(settings:) toast “New clip defaults saved” · Undo, ⌘Z (clip count not shown: no cheap count of followers) |

### Captions & titles (CaptionsSettings.swift)
Saved as you type (`store.save` in onChange, :80 / :163).
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Template name | field | CaptionsSettings.swift:66 | ✅ clear | — | label is enough | — |
| ✅ Delete template `trash` | icon | CaptionsSettings.swift:70 | ✅ clear | "Delete template"; disabled "Used by New clip defaults (…) — choose another template there first" | Delete this template… (disabled reason kept) | fixed: asks first (model.confirm, names the template; “Missing template” consequence; can’t undo — templates aren’t in the undo journal) |
| ➖ Template body | field | CaptionsSettings.swift:75 | ✅ clear | — | label is enough | — |
| ✅ Add template `plus` | text button | CaptionsSettings.swift:20 | ✅ clear | — | Add an empty caption template | — |
| ➖ Set name | field | CaptionsSettings.swift:147 | ✅ clear | — | label is enough | — |
| ➖ Set hashtags | field | CaptionsSettings.swift:149 | ✅ clear | — | label is enough | — |
| ✅ Delete set `trash` | icon | CaptionsSettings.swift:156 | ✅ clear | "Delete set"; disabled "Used by New clip defaults — remove it from Hashtag sets there first" | Delete this hashtag set… (disabled reason kept) | fixed: asks first (model.confirm, lists the tags clips lose; can’t undo — sets aren’t in the undo journal) |
| ✅ Add set to <category> `plus` | text button | CaptionsSettings.swift:29 | ✅ clear | — | Add an empty hashtag set to <category> | — |
| ➖ New category | field | CaptionsSettings.swift:33 | ✅ clear | — | label is enough · ↩ | — |
| ✅ Add category | text button | CaptionsSettings.swift:35 | ⚠️ also creates an empty "New set" | disabled only: "Type a category name first" | Create the category with one empty set · ↩. Disabled: Type a category name first | — |
| ✅ Copy prompt for N clips `doc.on.doc` | text button | CaptionsSettings.swift:45 | ✅ clear | disabled only: "Every clip has a title or a confident suggestion" | Copy a song-name prompt for untitled clips. Disabled: kept | — |

### Engine (EngineSettings.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Try again (error card) | text button | EngineSettings.swift:14 | ⚠️ try what? | — | Label changed to “Reinstall engine…” (DSAttentionCard has no tooltip slot) | ok (confirm) |
| ✅ Install… / Reinstall… | text button | EngineSettings.swift:23 | ✅ clear | — | Install the engine to run at login / Reinstall and reload the background engine | ok (confirm) |
| ✅ Stop… | text button | EngineSettings.swift:24 | ✅ clear | disabled only: "The background engine isn't loaded." | Stop the engine and remove it from login. Disabled: kept | ok (confirm) |
| ✅ Tick now | text button | EngineSettings.swift:32 | ⚠️ "tick" is jargon | "Run one engine pass now" | Prepare due posts and reminders now | — |
| ➖ Wake before first slot | toggle | EngineSettings.swift:36 | ✅ clear | — | label is enough | ok (undo): toast “Wake before first slot turned on” · Undo, ⌘Z |
| ➖ Open log | text button | EngineSettings.swift:39 | ✅ clear | disabled only: "No log written yet." | keep | — |
| ➖ Reveal ×4 | text button | EngineSettings.swift:96 | ✅ clear | "Show in Finder" | keep | — |
| ✅ Back up now | text button | EngineSettings.swift:53 | ✅ clear | — | Copy the database to Backups now | — |

## Editor

**Phase B (agent/tooltips-c):** the editor now has its own history (EditorModel.undo/redo, ⌘Z / ⇧⌘Z, header Undo/Redo buttons), so every edit made through EditorModel is "ok (⌘Z)"; all `.help` became `.dsTooltip`; Delete vN asks first. The paragraph below is the Phase A state.

Context: the editor autosaves 300 ms after each change (EditorModel.swift:793 `scheduleSave`). The header only says "Saves as you go" (EditorView.swift:175). It has no undo: ⌘Z inside the editor is sent to the responder chain (MainWindowView.swift:157), which undoes text-field typing only, and EditorModel has no UndoManager. So nothing in the editor is "ok (save)" or "ok (⌘Z)". Below, one-click edits that throw away a value are marked RISKY. Toggles that one more click restores are marked "—". The shared ↺ is `EditorCustomTag` (EditorComponents.swift:25, `arrow.uturn.backward`, default tooltip "Reset to the default").

### Header / toolbar (EditorView.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Back `chevron.left` | text button | EditorView.swift:107 | ✅ clear | "Save and go back" | keep | — |
| ✅ Clip title / set name | text button | EditorView.swift:109 | ⚠️ looks like static text | "Rename — edit the Title" | Jump to the Title field to rename | — |
| ✅ Previous clip `chevron.left` | icon | EditorView.swift:125 | ✅ clear | "Previous clip  ⌘["; disabled "This is the first clip in the list" | Save and open the previous clip · ⌘[. Disabled: first clip | — |
| ✅ Next clip `chevron.right` | icon | EditorView.swift:128 | ✅ clear | "Next clip  ⌘]"; disabled "This is the last clip in the list" | Save and open the next clip · ⌘]. Disabled: last clip | — |
| ✅ "N to fix" chip | text button | EditorView.swift:191 | ✅ clear | Issue list + "Click to jump to the first one" | Jump to: <issue> / Jump to the first of N: <issue> | — |
| ✅ Ready / File missing badges | gesture (status) | EditorView.swift:189 / :187 | ⚠️ File missing has no hover text | "Nothing to fix — this clip can be queued" / — | Ready: Nothing to fix; this clip can be queued · File missing: The clip file is gone; relink it in Health | — |
| ✅ Saves as you go / Saved | gesture (status) | EditorView.swift:166-176 | ⚠️ doesn't say that nothing can be undone | — | Every change saves at once; Undo takes it back · ⌘Z | — (editor now has undo; header Undo/Redo buttons added) |
| ✅ Undo `arrow.uturn.backward` / Redo `arrow.uturn.forward` (new) | icon | EditorView.swift (header, before v1 ▾) | ✅ clear | — | Undo the last change · ⌘Z / Redo the change you undid · ⇧⌘Z. Disabled: Nothing to undo yet / Nothing to redo / Editing is off for this clip | — (they are the undo) |
| ✅ v1 ▾ (versions) | menu | EditorView.swift:155 | ⚠️ "v1" is cryptic | "Text version — versions change the text and caption for reposts" | Switch or add text versions for reposts | — |
| ➖ Done | text button | EditorView.swift:140 | ✅ clear | "Save and close  ⌘↩" | keep · ⌘↩ | — |
| ✅ Space / ← → / ⇧← → | gesture (keys) | EditorView.swift:83-85 | ⚠️ undiscoverable outside Play tooltip | — | add a "?" shortcut list | cheat sheet Editor group: Space, I/O, ⌘Z/⇧⌘Z, ⌘[ ⌘], ⌘↩ (parent) |
| ✅ I / O (trim at playhead) | gesture (keys) | EditorView.swift:86-89 | ⚠️ only mentioned in the handle tooltips | — | (on handles: I / O keycaps) | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Versions popover (EditorInspector.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Version row | gesture | EditorInspector.swift:131 | ✅ clear | "Edit vN" | Edit vN's text and caption (none on the selected row) | — |
| ✅ `ellipsis` | menu | EditorInspector.swift:121 | ⚠️ icon only | "Actions for vN" | More actions for vN | — |
| ➖ Duplicate as new version | menu item | EditorInspector.swift:122 | ✅ clear | — | label is enough | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Delete vN | menu item | EditorInspector.swift:123 | ✅ clear | — | Delete vN… (menu item; tooltips don’t show in menus) | fixed: header .confirmationDialog says where vN is posted/planned; ⌘Z brings it back |
| ✅ New version `plus` | text button | EditorInspector.swift:99 | ⚠️ "version" meaning only in the popover text | disabled only: "Editing is off for this clip" | Start a new text version for a repost. Disabled: Editing is off | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Inspector mini-index
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Title…Platforms ×6 (+ warning dot) | text button | EditorInspector.swift:64 | ✅ clear | "Jump to X" / "Jump to X — needs attention" | Jump to X / Jump to X (needs attention) — now DS tooltip, below | — |

### Title + suggestions (EditorTitleSection.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Custom badge (on Title) | gesture (status) | EditorComponents.swift:23 via :51 | ⚠️ tooltip is wrong for the Title | "Changed from your New clip defaults" | Typed or chosen by you (not the raw tag) | — |
| ✅ Title ↺ `arrow.uturn.backward` | icon | EditorTitleSection.swift:51 | ✅ clear | "Clear the Title (screens show the raw tag again)" | Clear the Title (screens show the raw tag) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Ask an agent (callout) `doc.on.clipboard` | text button | EditorTitleSection.swift:73 | ✅ clear | "Copies the prompt (clip id, tag, set position, audio) to the clipboard" | Copy a song-name prompt for your agent | — |
| ✅ Suggestion chips | chip | EditorTitleSection.swift:98 | ✅ clear | "Use “X” as the Title (from src)" / "This is the Title" | Use “X” as the Title (from src) / This is the Title | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Title field | field | EditorTitleSection.swift:132 | ✅ clear | "The Title feeds the overlay text, caption {text}, YouTube title and the name shown everywhere" | Rename: text, caption and YouTube title follow · ↩ | — |
| ✅ Set | text button | EditorTitleSection.swift:141 | ✅ clear | "Save this Title (↩)" | Save this Title · ↩ | — |
| ✅ Use raw tag `tag` | text button | EditorTitleSection.swift:20 | ✅ clear | "Set the Title to the marker tag exactly as typed: “…”"; disabled "The Title already is the raw tag" | Set the Title to “<tag>” as typed. Disabled: kept | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Ask an agent (ghost) `doc.on.clipboard` | text button | EditorTitleSection.swift:26 | ✅ clear | "Copy a prompt for your agent to find the song names (it answers with djq suggest)" | Copy a song-name prompt for your agent | — |
| ✅ Kind DJ vid / Talking | segmented | EditorTitleSection.swift:166 | ⚠️ the text-default side effect is hidden | label only: "Talking clips get “No text” by default (Settings → New clip defaults)" (:164) | Set the kind; Talking clips start with no text | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Frame / crop (EditorSections.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Aspect 9:16/4:5/1:1/16:9 | segmented | EditorSections.swift:15 | ✅ clear | label: "Output shape of the video" | label is enough | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Aspect ↺ | icon | EditorSections.swift:14 | ✅ clear | "Back to the default aspect (9:16)" | Back to the default aspect (9:16) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Crop ↺ | icon | EditorSections.swift:27 | ✅ clear | "Back to the default framing (Centre) — it then needs confirming again" | Back to the Centre framing (confirm again) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Use this crop (inspector) | text button | EditorSections.swift:33 | ✅ clear | "Confirm the framing shown on the canvas"; disabled "The clip file is missing" | keep | — |
| ✅ Zoom | slider | EditorSections.swift:38 | ✅ clear | "Zoom into the recording (scroll or pinch on the Frame view)" | Zoom in; or scroll/pinch on the Frame view | — |
| ✅ Place Left / Centre / Right | text button | EditorSections.swift:43-45 | ⚠️ "Place" is terse | "Centre the crop on the left third" / "Centre the crop" / "…right third" | Centre the crop on the left third / Centre the crop / …right third | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Edit on canvas | text button | EditorSections.swift:56 | ✅ clear | "Show the whole recording to drag the crop" | keep | — |
| ✅ Upscaled badge | gesture (status) | EditorSections.swift:50 | ✅ clear | "The crop has fewer pixels than the 1080-wide output, so it will look softer" | The crop is under 1080 px wide, so it looks softer | — |

### Trim / timeline (EditorSections.swift, EditorTimeline.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Trim ↺ | icon | EditorSections.swift:70 | ⚠️ tooltip is a noun phrase | "Trim to markers" / "Use the whole file" | Reset the trim to your in/out markers / to the whole file | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Trim to markers (inspector) | text button | EditorSections.swift:78 | ✅ clear | "Back to your in/out markers" | Back to your in/out markers | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Trim to markers / Whole file `arrow.uturn.backward` (transport) | text button | EditorTimeline.swift:108 | ⚠️ tooltip mentions markers even on "Whole file" | "Reset the trim to the default (your in/out markers)" | Reset the trim to your in/out markers / Reset the trim to the whole file | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Custom badge (transport) | gesture (status) | EditorTimeline.swift:102 | ✅ clear | "Trim changed from your markers" | Trim changed from your markers / from the whole file | — |
| ✅ `gobackward.5` | icon | EditorTimeline.swift:115 | ⚠️ glyph renders like a timer (screenshots) | "Back 5 seconds" | Jump back 5 seconds | — |
| ➖ `play.fill` / `pause.fill` | icon | EditorTimeline.swift:116 | ✅ clear | "Play the trim" / "Pause"  Space; disabled "The clip isn't loaded" | keep · Space | — |
| ✅ `goforward.5` | icon | EditorTimeline.swift:119 | ⚠️ glyph renders like a timer | "Forward 5 seconds" | Jump forward 5 seconds | — |
| ✅ Gutter `textformat` / `film` | gesture (info) | EditorTimeline.swift:57 / :59 | ✅ clear | "Text: when the overlay text shows" / "The clip file — trim handles, markers, grace zones" | Text lane: when the overlay text shows / The clip file: trim, markers, grace (+ lane icons: “X-only trim”) | — |
| ✅ Filmstrip scrub | gesture | EditorTimeline.swift:159 | ✅ clear | "Click or drag to move the playhead" | Click or drag to move the playhead | — |
| ✅ Trim-in handle (yellow) | gesture | EditorTimeline.swift:174 | ✅ clear | "Trim in (I) — snaps to your markers; drag left into the grace zone to start earlier" | Drag to set the start; snaps to your markers · I | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Trim-out handle (yellow) | gesture | EditorTimeline.swift:181 | ✅ clear | "Trim out (O) — snaps…; drag right into the grace zone to end later" | Drag to set the end; snaps to your markers · O | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Marker ticks `arrowtriangle.down.fill` | gesture (info) | EditorTimeline.swift:202 | ❌ no hit-testing, so no hover text | — | Your in/out marker at 0:03.0; the trim snaps here | fixed: ticks are hoverable and carry the scrub gesture, so dragging still moves the playhead |
| ✅ "Grace" striped zone | gesture (info) | EditorTimeline.swift:164 / :218 | ⚠️ jargon, no hit-testing | — | Grace: drag the trim start/end into these seconds | fixed: zones hoverable, scrub like the filmstrip |
| ✅ Text bar | gesture | EditorTimeline.swift:262 | ✅ clear | "Overlay text — click to edit it" | Edit the overlay text | — |
| ✅ Text bar grips ×2 | gesture | EditorTimeline.swift:265 / :270 (help :295) | ✅ clear | "Drag to set when the text shows" | Drag to set when the text shows | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Per-platform lane in/out handles | gesture | EditorTimeline.swift:323 / :329 | ⚠️ noun-only tooltip | "X trim in" / "X trim out — snaps to the 2:20 limit" | Drag to set where X's cut starts / ends (snaps to 2:20) | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Text (EditorSections.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Text on the video | field | EditorSections.swift:103 | ✅ clear | — (disabled while No text; placeholder says so) | label is enough | — |
| ✅ Text ↺ | icon | EditorSections.swift:101 | ✅ clear | "Back to the Title" / "…raw tag" / "…no text" | Back to the Title / raw tag / no text | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Follow the Title | text button | EditorSections.swift:113 | ✅ clear | "Drop the typed text and use the Title again" | Drop the typed text and use the Title again | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ No text | toggle | EditorSections.swift:117 | ✅ clear | "Post this clip without any text on the video" | Post this clip without any text on the video | — |
| ✅ Style tiles White box / Outline / Shadow | chip | EditorSections.swift:193 | ✅ clear | "Text style: X"; disabled by No text (:128) with no reason | Use the X text style / This is the text style. Disabled: No text is on; turn off No text to style it | — |
| ✅ Style ↺ | icon | EditorSections.swift:123 | ⚠️ generic tooltip | "Reset to the default" | Back to the default style (White box) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Size | slider | EditorSections.swift:131 | ✅ clear | disabled "No text on this clip" | label is enough. Disabled: No text is on; turn off No text to style it | — |
| ✅ Size ↺ | icon | EditorSections.swift:130 | ⚠️ generic tooltip | "Reset to the default" | Back to the default size (64) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Alignment Left / Centre / Right | segmented | EditorSections.swift:137 | ✅ clear | — (disabled by No text :143, no reason) | label is enough. Disabled: No text is on; turn off No text to style it | — |
| ✅ Alignment ↺ | icon | EditorSections.swift:136 | ⚠️ generic tooltip | "Reset to the default" | Back to the default alignment (Centre) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Position ↺ | icon | EditorSections.swift:146 | ✅ clear | "Back to the default position" | Back to the default position | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Timing ↺ | icon | EditorSections.swift:156 | ✅ clear | "Back to the default timing" | Back to the default timing | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ "from vN" badge | gesture (status) | EditorComponents.swift:19 | ✅ clear | "Carried forward from vN — change it here to make this version different" | Carried forward from vN; edit it to change this version | — |

### Caption (EditorCaptionSection.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Template | menu | EditorCaptionSection.swift:50 | ✅ clear | label "Used when no caption is typed below"; disabled "A typed caption is used instead — clear it to use a template" | keep | — |
| ✅ Template ↺ | icon | EditorCaptionSection.swift:49 | ✅ clear | "Back to the default template" | Back to the default template | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Caption | field | EditorCaptionSection.swift:63 | ✅ clear | — | label is enough | — |
| ✅ Caption ↺ | icon | EditorCaptionSection.swift:61 | ⚠️ doesn't say the typed caption is lost | "Use the template again" | Delete the typed caption; use the template | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ "N characters ⓘ" | gesture (info) | EditorCaptionSection.swift:83 | ✅ clear | Per-platform "TikTok: 182 / 4000 …" | TikTok 182/4000 · Instagram 182/2200 … (one paragraph, fits the bubble) | — |
| ✅ Drop hashtags for X | text button | EditorCaptionSection.swift:115 | ✅ clear | "Give X the same caption without hashtags (N characters)"; disabled reasons | Give X the same caption without hashtags (N characters) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Write an X caption | text button | EditorCaptionSection.swift:119 | ✅ clear | "Start a caption just for X from this one" | keep | — |
| ✅ Hashtag set chips | chip | EditorCaptionSection.swift:147 | ⚠️ tooltip lists tags, no verb | the tags, e.g. "#amapiano #djlife" | Add #a #b to this caption / Remove #a #b from this caption | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Hashtags ↺ | icon | EditorCaptionSection.swift:139 | ⚠️ doesn't say it also clears extra hashtags | "Back to the default hashtag sets" | Back to the default sets; clear extra tags | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Extra hashtags | field | EditorCaptionSection.swift:157 | ✅ clear | "Added after the sets, separated by spaces" | Added after the sets, separated by spaces · ↩ | — |
| ➖ YouTube title | field | EditorCaptionSection.swift:185 | ✅ clear | label "The Shorts title (YouTube shows it under the handle)" | keep | — |
| ✅ YouTube title ↺ | icon | EditorCaptionSection.swift:183 | ✅ clear | "Back to the template ({text} \| DJ Lovd)" | Back to the template ({text} \| DJ Lovd) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Captions for one platform `chevron.right` | text button | EditorCaptionSection.swift:198 | ✅ clear | "Give a platform its own caption instead of the shared one" | Give a platform its own caption / Hide the per-platform captions | — |
| ✅ Per-platform caption toggle ×posting | toggle | EditorCaptionSection.swift:222 | ✅ clear | "X uses its own caption — turn off to use the shared one" / "Write a caption just for X" | Write a caption just for X / Delete X's own caption; use the shared one | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Per-platform caption | field | EditorCaptionSection.swift:227 | ✅ clear | — | label is enough | — |

### Cover (EditorSections.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Use playhead `scope` | text button | EditorSections.swift:260 | ✅ clear | "Use the frame under the timeline playhead" | keep | — |
| ✅ Filmstrip frames ×8 | gesture | EditorSections.swift:294 | ✅ clear | "Use the frame at 0:03.0" | Use the frame at 0:03.0 as the cover | — |
| ✅ Cover frame ↺ | icon | EditorSections.swift:244 | ✅ clear | "Back to the default cover frame (First frame of the trim)" | Back to the default cover frame (First frame of the trim) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Include text on the cover | toggle | EditorSections.swift:270 | ✅ clear | "Draw the overlay text on the cover image too" | Draw the overlay text on the cover image too | — |
| ✅ Cover text ↺ | icon | EditorSections.swift:269 | ⚠️ generic | "Back to the default" | Back to the default (with/without text) | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Platforms (EditorSections.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Post to chips ×6 | chip | EditorSections.swift:339 | ✅ clear | "Posting on X — click to skip it for this clip" / "Not posting…"; disabled "X is turned off in Settings → Platforms" | Skip X for this clip / Post this clip on X too. Disabled: kept | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Post to ↺ | icon | EditorSections.swift:335 | ✅ clear | "Back to the default platforms" | Back to the default platforms | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Trim for X | text button | EditorSections.swift:370 | ✅ clear | "Add a X-only trim lane on the timeline" | keep | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ Remove X trim | text button | EditorSections.swift:373 | ✅ clear | "Use the main trim on X too" | Delete the X-only trim; use the main one | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ➖ Skip X | text button | EditorSections.swift:377 | ✅ clear | "Don't post this clip on X" | keep | ok (⌘Z): editor undo history; ⇧⌘Z redo |

### Canvas modes (EditorCanvas.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Frame / Zones / Preview `crop` `rectangle.dashed` `iphone` | segmented | EditorCanvas.swift:107 | ⚠️ one tooltip covers all three | "Frame: crop the recording · Zones: … · Preview: …" | Switch view: crop, safe zones or phone preview (one tooltip) | per-segment tooltips: Crop the 9:16 frame… / Check text against each platform's UI zones / See it in a phone mock… |
| ✅ Crop window drag + scroll/pinch | gesture | EditorCanvas.swift:249-260, :221 | ✅ clear | "Drag to move the crop · scroll or pinch to zoom" | Drag to move the crop; scroll or pinch to zoom | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ⏭ Corner brackets | gesture (info) | EditorCanvas.swift:248 | ⚠️ look like resize handles but aren't | — | (drop them, or make them resize) | deferred: visual change (drop or make resizable), not a tooltip; the crop-window tooltip explains drag/zoom |
| ➖ Use this crop `checkmark` (frame bar) | text button | EditorCanvas.swift:156 | ✅ clear | "Confirm this framing"; disabled "Editing is off for this clip" | keep | — |
| ✅ Show folder in Finder | text button | EditorCanvas.swift:171 | ✅ clear | — | Open the folder where the file should be | — |

### Safe zones (EditorSafeZones.swift, EditorCanvas.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Text drag box (Zones) | gesture | EditorCanvas.swift:326 | ⚠️ invisible until dragging | "Drag to move the text" | Drag to move the text (dashed outline on hover) | ok (⌘Z): editor undo history; ⇧⌘Z redo |
| ✅ None | chip | EditorSafeZones.swift:108 | ⚠️ "None" of what? | — | Hide all safe-zone overlays (none when already empty) | — (view setting, UserDefaults) |
| ✅ Platform zone chips ×6 | chip | EditorSafeZones.swift:110 | ✅ clear | "Show/Hide X's safe zones" | Show/Hide X's safe zones | — (view setting) |
| ✅ "Safe zones" label | gesture (info) | EditorSafeZones.swift:107 | ✅ clear | "Show where each app's buttons and text cover the video (…)" | Where each app's buttons cover the video (per 9:16) | — |

### Preview / phone mocks (EditorCanvas.swift, EditorPhoneMock.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ `chevron.left` | icon | EditorCanvas.swift:412 | ✅ clear | "Previous platform" | keep | — |
| ✅ Platform chips ×6 | chip | EditorCanvas.swift:414 | ✅ clear | "Preview on X" / "(this clip isn't posting there)" | Preview on X / Preview on X (not posting there) | — |
| ➖ `chevron.right` | icon | EditorCanvas.swift:419 | ✅ clear | "Next platform" | keep | — |
| ✅ One / Compare 3 | segmented | EditorCanvas.swift:421 | ✅ clear | "Show one phone, or three platforms side by side" | Show one phone, or three side by side | — |
| ✅ Phone tap (compare) | gesture | EditorCanvas.swift:399 | ❌ no hint that it's clickable | — | Start the comparison from X | — |
| ➖ Mock Follow/Subscribe/rail icons | gesture (decor) | EditorPhoneMock.swift:172-187, :506 | ⚠️ look tappable, are static art | — | (non-interactive; fine) | — (static art) |

## DS components

Status (Phase B): ✅ fixed · ➖ no change needed · ⏭ deferred (reason in the last column).

### DSButton / DSIconButton (DSButton.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ DSIconButton | icon | DSButton.swift:219-240 | ✅ guaranteed (`tooltip:` required; disabledReason replaces it) | caller text | keep | — |
| ✅ DSButton | text button | DSButton.swift:168-204 | ⚠️ tooltip optional; `shortcut:` only shows text and binds no key | caller | caller must also add `.keyboardShortcut` (e.g. Save has a key but no hint) | — |

### DSClipCard (DSClipCard.swift), all four modes
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Select circle (built-in checkbox) | icon | DSClipCard.swift:163 | ✅ guaranteed | "Select" / "Deselect" | Select this clip · ⇧/⌘-click for more | — |
| ✅ Drag handle `line.3.horizontal` (Cards, Queue) | gesture | DSClipCard.swift:234 | ✅ guaranteed on hover | "Drag to reorder" | Drag to change queue order | — |
| ⏭ Card body click | gesture | DSClipCard.swift:126 | ⚠️ relies on caller; no hint (opens? selects?) | — | caller: "Open in editor · ⌘E" | ⏭ per screen (Score/Edit/Queue/Library rows) |
| ✅ Mute (DSVideoPreview) | icon | DSClipCard.swift:153 → DSVideoPreview.swift:93 | ✅ guaranteed | "Mute" / "Unmute" | Play/Mute this preview's sound | — |
| ✅ Suggestion chips `text.badge.plus` | chip | DSClipCard.swift:216 / :410 | ⚠️ generic | "Use as title" | Set the Title to “X” | ok (confirm: ClipCollection.swift:183 → AppModel+Bulk.swift:157 "Set title?") |
| ✅ Score (number) | gesture (info) | DSClipCard.swift:170 / :285 / :375 | ⚠️ bare number, no tooltip | only "Not scored" for "—" (:172) | Your score (0–100) — it sets the posting order | — |
| ✅ Date chip `calendar`/`pin.fill` | gesture (info) | DSClipCard.swift:199 | ✅ guaranteed | "Pinned to this date" / "Not in the plan yet" / "Next post" | keep | — |
| ✅ Pin icon (no date) | gesture (info) | DSClipCard.swift:250 | ❌ no tooltip | — | Pinned to a date | — |
| ✅ "File missing · Relink" | chip (badge) | DSClipCard.swift:212 | ❌ says Relink but can't be clicked | — | shipped: chip says "File missing"; tooltip: The source file moved or was deleted — Health › Doctor relinks it | — |
| ✅ Issue / block / status / tag badges | chip (badge) | DSClipCard.swift:213-219 | ⚠️ no explanation on hover | — | e.g. "Confirm the crop in the editor" | — |
| ➖ Platform icons | gesture (info) | DSClipCard.swift:225 / :337 / :380 | ✅ guaranteed (DSPlatformIcon) | "TikTok · Posted" | keep | — |
| ✅ `actions` slot (hover actions, ⋯) | icon | DSClipCard.swift:262 / :293 / :345 / :383 | ❌ relies on caller; grid uses `DSMediaActionStyle` `.labelStyle(.iconOnly)` (:433), which hides labels | — | callers give every slot action a `.dsTooltip` (grid renders icon-only) | — |

### DSVideoPreview (DSVideoPreview.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Mute `speaker.wave.2.fill`/`speaker.slash.fill` | icon | DSVideoPreview.swift:93 | ✅ guaranteed | "Mute" / "Unmute" | Turn this preview's sound on/off | — |
| ✅ Scrubber (Single mode) | slider | DSVideoPreview.swift:140 | ❌ no tooltip | — | Drag to scrub the preview | — |

### DSOverlays (DSOverlays.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ Bulk bar ✕ `xmark` | icon | DSOverlays.swift:340 | ✅ guaranteed | "Clear selection  esc" | keep · esc | — |
| ➖ Bulk bar Select all | text button | DSOverlays.swift:347 | ✅ guaranteed | "Select every clip on this screen  ⌘A" | keep · ⌘A | — |
| ➖ Bulk bar actions slot | text button | DSOverlays.swift:351 | ⚠️ relies on caller (no tooltip in DSBulkActionStyle) | — | caller | — |
| ➖ Toast action ("Undo") | text button | DSOverlays.swift:240 | ✅ clear | — | label is enough | — |
| ➖ Toast dismiss `xmark` | icon | DSOverlays.swift:243 | ✅ guaranteed | "Dismiss" | keep | — |
| ⏭ Editor toast (no action, no close) | gesture (status) | EditorView.swift:60 | ⚠️ the editor's DSToast passes no Undo | — | — | ⏭ editor has its own ⌘Z/⇧⌘Z history (EditorUndo) + header Undo; toast Undo not needed |
| ➖ Dialog close `xmark` | icon | DSOverlays.swift:159 | ✅ guaranteed | "Close  esc" | keep · esc (binding is the caller's) | — |
| ➖ Menu items (DSMenuRow) | menu item | DSOverlays.swift:88 | ⚠️ tooltip only when disabled; enabled rows rely on title | disabledReason | caller | — |
| ➖ Toolbar trailing slot | icon | DSOverlays.swift:438 | ⚠️ relies on caller | — | caller | — |
| ➖ Sidebar item | text button | DSOverlays.swift:477 | ✅ clear | title + shortcut only when a shortcut is passed | keep | — |
| ➖ Attention card action | text button | DSOverlays.swift:528 | ⚠️ relies on caller (e.g. "Try again") | — | caller | — |
| ➖ Attention card dismiss `xmark` | icon | DSOverlays.swift:529 | ✅ guaranteed | "Hide for 24 hours" | keep | — |

### DSChoice (DSChoice.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ DSChip | chip | DSChoice.swift:39 | ⚠️ tooltip only for disabledReason; enabled relies on caller | disabledReason | caller | — |
| ✅ DSChipGroup chips / None | chip | DSChoice.swift:96 / :99 | ⚠️ no per-option tooltip API except disabledReason | — | add `tooltip` to DSChipOption | — |
| ✅ DSSegmented icon-only segment | segmented | DSChoice.swift:220 | ⚠️ tooltip "required" by comment only; nil compiles | seg.tooltip | make the tooltip non-optional for icon-only | — |
| ✅ DSSegmented titled segment | segmented | DSChoice.swift:197 | ✅ clear | — (tooltip suppressed when titled) | allow an optional consequence tooltip | — |
| ➖ DSTabs | segmented | DSChoice.swift:263 | ✅ clear | — | label is enough | — |
| ✅ View mode switcher Cards/Grid/Single/List | segmented | DSChoice.swift:333 | ⚠️ tooltip is just the name | "Cards" / "Grid" / "Single" / "List" | Show clips as cards / a grid / one at a time / a list | — |

### DSInputs (DSInputs.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ✅ Search/field clear `xmark.circle.fill` | icon | DSInputs.swift:128 | ✅ guaranteed (only when focused and non-empty) | "Clear" | Clear the search | — |
| ➖ DSSelect | menu | DSInputs.swift:222 | ⚠️ tooltip only when disabled | disabledReason | caller | — |
| ➖ DSToggle | toggle | DSInputs.swift:313 | ✅ label; tooltip only when disabled | disabledReason | caller | — |
| ⏭ DSSwitch | toggle | DSInputs.swift:343 | ⚠️ no label/tooltip/disabledReason API; relies on the row | — | add a disabledReason | ⏭ DSSwitch is only used inside DSToggle rows, which carry the reason |
| ➖ DSCheckbox | toggle | DSInputs.swift:400 | ⚠️ tooltip only when disabled | disabledReason | caller | — |
| ➖ DSSlider | slider | DSInputs.swift:483 | ⚠️ tooltip only when disabled | disabledReason | caller · ←/→ when focused (:497) | — |
| ➖ DSTextField / DSTextArea | field | DSInputs.swift:139 | ✅ placeholder; disabledReason tooltip | disabledReason | caller | — |

### DSBadge (DSBadge.swift)
| Control | Kind | Where | Clear today? | Today's tooltip | Proposed tooltip · shortcut | Risk / fix |
|---|---|---|---|---|---|---|
| ➖ DSPlatformIcon (generic glyphs: `music.note`=TikTok, `camera`, `person.2`, `play.rectangle`, `at`, `xmark`=X) | gesture (info) | DSBadge.swift:211 | ✅ guaranteed unless `showsLabel` | "TikTok · Posted" | keep. Note: X's `xmark` glyph reads as "close" | — |
| ✅ DSBadge | chip (badge) | DSBadge.swift:20 | ⚠️ no tooltip API | — | add an optional `help:` | — |

### Risky one-click actions
1. Settings › Platforms limit cells save on every keystroke (SettingsSections.swift:107-111 / SettingsRows+DSX.swift:221) → commit on ↩/blur.
2. Settings › Platforms "Off" drops the platform from the plan at once (SettingsSections.swift:50) → Undo toast.
3. Settings › Schedule "Reset slot times" overwrites all slot times (SettingsSections.swift:156) → Undo toast.
4. Settings › Rendering Cleanup "Delete after a while" and lowering "Delete after" let the engine delete posted renders (SettingsSections.swift:259 / :265) → Confirm sheet.
5. Settings › New clip defaults "Save" changes every clip that follows a default, with no undo (NewClipDefaultsSettings.swift:211) → Undo toast with clip count. "Reset to built-in defaults" is confirmed but also has no Undo (:203).
6. Settings › Captions "Delete template" (CaptionsSettings.swift:70) and "Delete set" (:156) delete at once; their toasts have no Undo → Undo toast.
7. Editor › Versions "Delete vN" has no confirm, even if posted or planned (EditorInspector.swift:123) → Confirm sheet.
8. Editor › Versions "New version" (EditorInspector.swift:99) and "Duplicate as new version" (:122) → Undo toast.
9. Editor › every Custom ↺ reset: Title :51, Aspect :14, Crop :27, Trim :70, Text :101, Style :123, Size :130, Alignment :136, Position :146, Timing :156, Template :49, Caption :61, Hashtags :139, YouTube title :183, Cover frame :244, Post to :335 (EditorTitleSection / EditorSections / EditorCaptionSection) → Undo toast.
10. Editor › Title overwrite: suggestion chips (EditorTitleSection.swift:98) and "Use raw tag" (:20) → Undo toast.
11. Editor › "Follow the Title" drops typed text (EditorSections.swift:113) → Undo toast.
12. Editor › "Trim to markers" ×2 and the transport reset (EditorSections.swift:78, EditorTimeline.swift:108), plus I/O keys (EditorView.swift:86-89) overwrite the trim → Undo toast.
13. Editor › Place Left/Centre/Right overwrites a hand-placed crop (EditorSections.swift:43-45) → Undo toast.
14. Editor › "Remove X trim" (EditorSections.swift:373) → Undo toast.
15. Editor › Per-platform caption toggle off deletes the typed platform caption (EditorCaptionSection.swift:222) → Undo toast.
16. Editor › "Drop hashtags for X" writes a caption; its toast has no Undo (EditorCaptionSection.swift:115, EditorModel.swift:735) → add Undo.
17. Root cause: the editor autosaves with no undo stack, and ⌘Z only reaches text fields (MainWindowView.swift:157). The cleanest fix is an EditorModel UndoManager wired to ⌘Z, plus "Saved · Undo" in the header.

