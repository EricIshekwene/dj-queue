# DJ Queue — DESIGN.md

**Status:** LOCKED — Eric answered round 1 on 2026-11-01 (`DECISIONS.md`); ⟨Qn⟩ markers point at those answers, which win over any default written here.

Process: inventory → locked references → one decision page. Slot IDs from `INVENTORY.md`. Every image in `refs/` was looked at before it was locked.

## Visual direction

- **Native macOS first.** SwiftUI `NavigationSplitView`, unified toolbar, system materials, SF Pro, SF Symbols, system accent ⟨Q26⟩. Light + dark follow the system.
- **Calm and dense like Linear**: 28–32 pt rows, hairline separators, no card chrome in lists, one primary button per screen.
- **Status is a shape, not a sentence.** Pills (capsule, 11 pt semibold, tinted background) and 8 pt dots. Numbers big (runway 28 pt rounded, tabular), labels short (11 pt secondary, uppercase only for section eyebrows).
- **Colour is semantic only**: accent for selection and the one primary action; green posted; blue planned/rendered; amber late/paused/low runway; red failed/copyright/missing. Red is loud by design (§0.3): full-width banner at the top, badge on the menu-bar icon.
- **Progressive disclosure**: defaults visible, advanced in the inspector under a "More" disclosure, everything in ⌘K and the context menu.
- **Media is the hero**: thumbnails are the video's cover (9:16, 4 pt radius); the editor preview is the largest thing on screen.

### Tokens (SwiftUI)

| Token | Value |
|---|---|
| Spacing | 4 · 8 · 12 · 16 · 24 · 32 |
| Radius | 4 (thumb) · 6 (control) · 10 (card/sheet) |
| Row height | 32 (list) · 56 (queue row with 9:16 thumb 28×50) |
| Type | Large title 22/28 semibold · runway 28 rounded semibold tabular · body 13 · secondary 11 · mono 11 (ids, durations) |
| Status colours | `.green` posted · `.blue` planned/rendered · `.orange` late/paused/warn · `.red` failed/©/missing · `.secondary` off/skipped |
| Platform glyphs | monochrome template icons (TikTok, IG, FB, YT, Threads, X), tinted by state |

## Window and shell (APP.L) ⟨Q20 sidebar vs tabs⟩

- Locked: `refs/APP.L--linear-sidebar-issue-list.webp` (Linear). Considered: `APP.L-alt--unify-top-tabs.webp`.
- Window min 1100×700, default 1440×900. Sidebar 220 pt: Queue, Week, Today (badge = due count), Library, Posts (red badge = errors), Health (dot = engine state), Settings at the bottom.
- Toolbar (APP.TB, ref `APP.TB--unify-active-toggle-metrics.webp`): left = screen title; centre = runway trio `5d · 21d · 58d` (approved bold, others secondary; click → popover); right = posts/day stepper, Pause switch (confirm sheet, then a persistent amber "Paused" bar), ⌘K.
- APP.ERR (ref `APP.ERR--wix-failed-requests-banner.webp`): 40 pt red banner under the toolbar on every screen: icon, "2 posts need attention · Instagram © blocked, X failed", **Review** → Posts filtered. Never dismissable while unresolved.
- APP.WARN: same shape, amber, dismissable for 24 h.
- APP.CMD (ref `APP.CMD--magnific-command-palette.webp`): 640 pt panel, Recents + Actions, shortcut hints right-aligned.
- APP.MB (ref `APP.MB--bonsai-timer-popover.webp`, weak match — no real menu-bar extras on Mobbin): `MenuBarExtra` window style, 320 pt wide: runway number large, next post row, due rows with two icon buttons, red errors section, Open app / Pause footer.
- Empty states (ref `EMPTY--heidi-empty-list.webp`): SF Symbol 32 pt, one line, one button.

## Queue (Q) ⟨Q21 list vs board⟩

- Locked: header `Q.S1--n8n-stat-strip-header.webp`; rows `Q.S3--linear-issue-list.webp`; inspector `Q.S4--linear-inspector-panel.webp`. Considered: `Q.S3-alt--linear-board.webp`.
- Q.S1: segmented `Worst → best | Best → worst`, small "Ties: older first" text button, overlap toggle in a "More" menu.
- Q.S2: segmented tabs `Ready 41 · To score 12 · Needs edit 9 · Excluded 0`, filter chips (session, kind, score), search field.
- Q.S3 row (56 pt): `#` (mono, secondary) · 28×50 cover · name (13 semibold) + session (11 secondary) · kind pill · score (inline editable, 15 rounded tabular) · `v2` · six platform dots · next date (11 secondary). Drag handle on hover.
- Q.S4 inspector 300 pt: cover preview, score slider, kind, notes, per-platform sort override (More), mini post history, actions list.
- Q.S6 Score mode ⟨Q10⟩: full-window player, big number field, Enter → next unscored.

## Week (W) ⟨Q22 grid vs list⟩

- Locked: header `W.S1--assembly-calendar-header.webp`; grid `W.S2--hootsuite-week-cards.webp`. Considered: `W.S2-alt--buffer-queue-list.webp`.
- W.S1: ‹ week › picker, status pill Draft/Approved, **Approve week** (primary, ⌘↩), "Rebuild" and "Push a day" in the ⋯ menu.
- W.S2: 7 equal columns; each day one video card (cover 9:16 at 72 pt wide, name, score, version) and below it six slot chips `TT 7:00p ●` coloured by state. Drag cards between days (swap on drop). Past days shaded; Mac-off periods hatched (W.S4).
- W.S3 backlog drawer at the bottom (collapsed by default): next ready videos in sort order.

## Today (T)

- Locked: `T.S1--todoist-today-list.webp`; sheets `T.S2--arcade-add-url-dialog.webp`.
- T.L: "Today · Sat 1 Nov" + "3 / 6 posted" progress.
- T.S1 row (64 pt): time (mono) · platform glyph · cover · name + version · status pill · actions: [drag-out file] [Copy caption] [Open upload page] [**Mark posted**] [⋯ Report problem, Reveal, Copy file, Send to phone]. Primary button order follows ⟨Q4⟩.
- T.S2 Mark posted sheet: one URL field (validated against the platform's domain), posted time, Cancel / Mark posted.
- T.S3 Report problem: segmented error type, message, Save. Copyright types turn the row red and show Re-upload anyway / Skip platform / Accept.

## Library (L)

- Locked: `L.S2--later-media-grouped-select.webp` (grouped by session, bulk toolbar, inspector).
- L.S1 sessions in the sidebar section list; L.S2 table (sortable columns) with grid toggle; bulk toolbar appears on multi-select (score, kind, exclude).
- Long-form rows: `Long-form` pill, Mark posted + URL.

## Editor (E) ⟨Q23 full window vs sheet, Q24 inspector side⟩

- Locked layout: `E.L--synthesia-editor-inspector-right.webp`. Considered: `E.L-alt--tiktok-studio-sheet.webp`, `E.L-alt--elevenlabs-inspector-left.webp`.
- Anatomy at 1440×900: header 44 (‹ back, name, ‹ › prev/next video, validation pill, Done) · centre preview (9:16 box ~ 380×676 on a neutral canvas) · inspector 320 right · timeline 140 bottom.
- E.S1 crop (`E.S1--runway-crop-portrait.webp`): "Frame" mode shows the whole 16:9 frame dimmed with the crop window bright; drag to move, scroll to zoom, aspect segmented `9:16 4:5 1:1 16:9`; amber "Upscaled 1.4×" when zoom passes source resolution.
- E.S2 timeline (`E.S2--vimeo-text-bar-timeline.webp`): filmstrip track with yellow trim handles and marker ticks (snap), text bar track above it, per-platform trim lane appears only when used.
- E.S3 inspector (`E.S3--magicpath-inspector-sections.webp`): segmented Frame / Text / Caption / Cover, version picker `v1 ▾` in the inspector header.
- E.S4 versions (`E.S4--base44-version-list.webp`): rows `v1 · Posted on TT, IG` with badges; inherited fields rendered in secondary colour with "from v1".
- E.S5 text styles (`E.S5--descript-caption-style-presets.webp`; alts `E.S5-alt--tripcom-text-style-tiles.webp`, `E.S5-alt--tiktok-text-box-style-row.webp`): three tiles, each drawn in its own style; size slider; alignment segmented; "No text" toggle; Prefill button.
- E.S6 safe zones (`E.S6--tiktok-studio-feed-preview.webp`, nearest match): red translucent overlay of TikTok/Reels/Shorts UI, platform picker ⟨Q19⟩.
- E.S7 cover (`E.S7--suno-cover-frame-picker.webp`): big frame + filmstrip selector, "Include text" toggle ⟨Q18⟩.
- E.S8 caption (`E.S8--buffer-caption-composer.webp`; chips `E.S8-alt--semrush-hashtag-chips.webp`): caption field, per-platform counters `TT 412/4000 · X 412/280 ⚠`, hashtag set chips, YouTube title with 100 limit, per-platform override toggles.
- E.S9 validation strip: pills for each missing requirement; "Too long for X (2:32 > 2:20) · Trim for X".
- **Preview == export**: the overlay is a 1080×1920 PNG from Core Text (`design/tools/textpng.swift` prototype) shown over the AVPlayer layer and composited in ffmpeg. Never `drawtext`.

## Posts (P)

- Locked: table `P.S2--gumloop-run-history.webp`; detail `P.S3--stripe-event-detail.webp`.
- Error cards pinned above the table (red stripe, platform, error type, message, raw response disclosure, actions). Table filter segmented `All · Posted · Failed · ©`. Detail panel lists attempts with the history log.

## Health (H)

- Locked: timeline `H.S1--incidentio-uptime-bars.webp`; checks `H.S2--customerio-health-checks.webp`.
- Status tiles (engine, last tick, render queue, disk, backup, ffmpeg) · 7-day awake bars (green awake, grey asleep, red tick = missed slot) · Doctor findings list with severity icons · **Copy report** (primary).

## Settings (S)

- Locked: `S.L--linear-preferences.webp`; slots `S.S2--buffer-posting-slots.webp`. SwiftUI `Settings` scene with sidebar sections; grouped `Form` rows.

## Deviations (recorded)

- **Engine process:** the spec asks for a headless engine run by the LaunchAgent with the GUI talking to it. macOS only delivers notifications from an app bundle, so the LaunchAgent launches `DJ Queue.app --agent`: the engine loop and the menu-bar item run in that process, and the main window opens in it on demand. Closing the window never stops the engine; KeepAlive restarts the process if it quits. The `djq` CLI shares the same SQLite file.
- **Text defaults per Eric:** white box style, centred, medium, draggable; prefill uses "x" and no emoji (DECISIONS.md Q11–Q14).
- **Kinds:** `DJ vid` / `Talking` only (Q9).

## Interaction and motion

- Keyboard first: digits to score, ↑/↓ ±1, ⇧↑/↓ ±10, ⌘E edit, ⌘↩ approve, space Quick Look-style preview, ⌘K palette, ⌘/ shortcut sheet.
- Motion: system defaults only (list reorder, sheet presentation); reduce-motion respected.

## Rejected references

- Generic dashboard templates with chart cards (too much chrome for a queue).
- Social schedulers' month calendars (week is the unit of approval).

## Open decisions

All on `DECISIONS.html` (28 questions). Recorded answers go in `DECISIONS.md` and are applied here before building.

## Image index

`refs/` — 37 images: APP.L, APP.L-alt, APP.TB, APP.CMD, APP.ERR, APP.MB, Q.S1, Q.S3, Q.S3-alt, Q.S4, W.S1, W.S2, W.S2-alt, T.S1, T.S2, L.S2, P.S2, P.S3, H.S1, H.S2, S.L, S.S2, EMPTY, E.L, E.L-alt ×2, E.S1–E.S8, E.S5-alt ×2, E.S8-alt. Mobbin links in `design/REFS.md`.
`design/mock/` — text style / position / size renders on real Afroween frames.
