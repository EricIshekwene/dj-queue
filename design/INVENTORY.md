# DJ Queue — Inventory (milestone 1)

Every screen, section, control, state, notification and background job in the spec, with stable slot IDs.
Layout = `<ID>.L`, sections `<ID>.S1…`, parts `<ID>.S1.a…`. Spec section in brackets.
States legend used per screen: **E** empty · **Ld** loading · **Er** error · **Off** engine not running / Mac was off.

## APP — shell and global

| Slot | What | Spec |
|---|---|---|
| APP.L | Main window: navigation (Queue, Week, Today, Library, Posts, Health, Settings) + content + optional inspector | §14 |
| APP.TB | Toolbar: runway (approved / ready / total, big number), posts/day, pause-all kill switch, search, ⌘K | §5 |
| APP.TB.a | Runway number (approved runway days, coloured: green ≥ threshold, amber, red) — click → popover with all three | §5 |
| APP.TB.b | Pause all posting (kill switch) — toggled state shows a persistent amber "Paused" bar | §5 |
| APP.ERR | Loud error banner (red, top of every screen) for copyright / failed / overdue; badge count; "Review" | §0.3, §8 |
| APP.WARN | Amber banners: approved runway < 3 d ("Approve next week"), total runway < 14 d ("Record a new set"), engine off | §5 |
| APP.CMD | ⌘K command palette: every action (score, pin, skip, post today, pause platform, rebuild week, re-render, mark posted/failed, reset post, duplicate version, open Doctor, copy report…) | §0.3, §5 |
| APP.CTX | Context menu on any video row/card (same action set, contextual) | §5 |
| APP.KB | Keyboard shortcuts (score digits, ↑/↓ ±1, ⇧↑/↓ ±10, ⌘E edit, ⌘↩ approve, space preview) + cheat sheet (⌘/) | §5 |
| APP.N | macOS notifications: slot due, late, missed (actions Post now / Shift plan / Skip), approve week (Sun 6 pm), low runway, copyright, render failed | §5, §8, §9 |
| APP.MODE | Light / dark (follows system) | §0.3 |

## MB — menu-bar item [§8, §14.9]

| Slot | What |
|---|---|
| MB.ICON | Icon + runway number; red badge with count on errors; grey when engine off; pause glyph when paused |
| MB.S1 | Popover: runway trio, next post (time · platform · video), due-now list (≤ 3) with Copy caption / Mark posted |
| MB.S2 | Errors section (red), "Open app", "Pause all / Resume", "Pause platform ▸" |
| MB.S3 | Engine status line (last tick, rendering 2/7) |

## Q — Queue (home) [§5, §14.1]

| Slot | What |
|---|---|
| Q.L | Header + filter bar + ordered list (+ right inspector when a row is selected) |
| Q.S1 | Header: Sort switch `Worst → best` / `Best → worst` (global), "Ties: older first" note, posts/day stepper (1–5), "Overlap avoid" toggle (off) |
| Q.S2 | Filters: session, kind, state, score range, tag search; tabs/segments `Ready · To score · Needs edit · Excluded` |
| Q.S3 | Ordered rows: position #, thumbnail (cover), name, score (editable inline), kind pill, versions count, platform status dots (6), next planned date |
| Q.S3.a | Inline score field (type number, ↑/↓, ⇧↑/↓) |
| Q.S3.b | Platform dots: grey off / outline not planned / blue planned / green posted / red failed / red ©  |
| Q.S4 | Inspector: big preview, score slider, kind, notes, per-platform sort override, state, posts history mini-list, actions (Edit, Pin to date, Post today, Skip next, Exclude) |
| Q.S5 | Bulk bar on multi-select: set score, kind, exclude, add to week |
| Q.S6 | "To score" lane: unscored videos with fast scoring (number keys, enter → next) |
| Q.states | E: "No videos yet — export clips from CapCut" · Ld: skeleton rows · Er: videos.json parse error → link to Doctor · missing_file rows red |

## W — Week (approval) [§5, §14.2]

| Slot | What |
|---|---|
| W.L | Week header + 7-day grid (days × enabled platforms, or days × video when all platforms share the video) |
| W.S1 | Header: week picker (‹ This week · Next week ›), status pill (Draft / Approved / Locked), primary **Approve week**, secondary Rebuild week, Push plan by a day |
| W.S2 | Grid: column per day, row per platform with slot time; each day shows the video card once with per-platform slot chips |
| W.S2.a | Video card: thumbnail, name, score, version; drag to reorder/swap; pin icon; context menu (Swap, Remove, Pin, Skip platform) |
| W.S2.b | Platform slot chip: time + state (planned/rendered/due/posted/failed/©/overdue/missed/skipped) |
| W.S3 | Backlog drawer: next ready videos in sort order, drag into a day |
| W.S4 | Missed/overdue markers + Mac-off shading on the past part of the week |
| W.S5 | Reposts and re-queued failures shown as extra chips (staggered ≥ 3 h) |
| W.states | E: "Nothing ready to plan — edit videos" · Draft vs Approved visual difference · Paused overlay |

## T — Today (manual publisher) [§9, §14.3]

| Slot | What |
|---|---|
| T.L | Day header (date, done x / y) + timeline list of today's platform posts |
| T.S1 | Row: time, platform icon, video thumb + name, version, status pill (Rendering / Ready / Due now / Late 2 h / Posted / Failed / ©) |
| T.S1.a | File: drag-out handle, Reveal in Finder, Copy file |
| T.S1.b | Copy caption (platform-specific, hashtags) · Copy title (YouTube) |
| T.S1.c | Open upload page (per platform) |
| T.S1.d | **Mark posted** (primary on the due row) → URL sheet |
| T.S1.e | Report problem (⋯ menu) → problem sheet |
| T.S2 | Mark posted sheet: paste URL (required, validated per platform domain), posted time (default now) |
| T.S3 | Report problem sheet: type (too long, too large, format, upload failed, copyright blocked, copyright muted, removed, other) + message |
| T.S4 | Copyright/failure resolution: Re-upload anyway (optional new version) / Skip this platform / Accept |
| T.S5 | Optional metrics entry (views / likes at 72 h) on posted rows |
| T.states | E: "Nothing due today · next: Tue 12:30 TikTok" · rendering in progress · paused |

## L — Library [§4, §14.4]

| Slot | What |
|---|---|
| L.L | Sessions list (left) → videos grid/table (right) |
| L.S1 | Session list with counts (short / long / missing), missing-session flag |
| L.S2 | Video table: thumb, name, type, kind, duration, audio (rekordbox/camera), score, state, already-posted-on |
| L.S3 | Bulk scoring (multi-select → score field) |
| L.S4 | Long-form rows: "Mark posted" + paste YouTube URL → moves to Posted/Longform; Test & Compare reminder |
| L.S5 | Missing / relinked indicators; "removed from videos.json" ask (Keep / Exclude) |
| L.states | E: "No sessions found in ~/Movies/DJ Video/Sessions" · intake scanning · parse error |

## E — Editor [§6]

| Slot | What |
|---|---|
| E.L | Preview centre at output aspect, inspector side, timeline strip bottom; header with video name, prev/next video, Done |
| E.S1 | Preview + crop: 4K frame with crop box (drag move, scroll/pinch/slider zoom), aspect presets 9:16 · 4:5 · 1:1 · 16:9, upscale warning |
| E.S2 | Timeline strip: filmstrip, trim in/out handles, Eric's marker ticks (snap), playhead, text timing bar, per-platform trim lane (when overridden) |
| E.S3 | Inspector tabs: **Frame** (aspect, zoom, crop) · **Text** (versions, text, style, size, align) · **Caption** (caption, hashtags, YouTube title, per-platform overrides, counts) · **Cover** |
| E.S4 | Versions list v1…vn: carry-forward indicator (inherited fields shown faded), duplicate version, which platforms used which version |
| E.S5 | Text: field (emoji, multi-line), 3 style presets, size, alignment, drag on preview, "No text" explicit toggle, Prefill from tag |
| E.S6 | Safe-zone overlay toggle (TikTok/Reels right rail + bottom caption, Shorts bottom) |
| E.S7 | Cover: filmstrip scrub, default first frame of trim, "include text on cover" |
| E.S8 | Caption composer: caption, hashtag set chips + extra tags, YouTube title (≤ 100), per-platform override toggles, char count vs limit per platform |
| E.S9 | Validation strip: what's missing for `ready` (crop, text/"no text", caption, platform checks) + "Too long for X (2:32 > 2:20) → Trim for X" |
| E.states | Ld: proxy generating · Er: file missing · unsaved/auto-saved indicator · re-render queued |

## P — Posts / History [§3, §14.6]

| Slot | What |
|---|---|
| P.L | Errors pinned on top, then full table |
| P.S1 | Error cards (red): platform, video, error type, message, time, raw response (disclosure), actions (Fix → editor, Re-upload anyway, Skip, Accept, Reset post) |
| P.S2 | Table: date, platform, video, version, attempt, state pill, publisher, URL; filters (platform, state, date, video) |
| P.S3 | Post detail: history log (every state change with time), render used, metrics |
| P.states | E: "No posts yet" |

## H — Health / Doctor [§8, §11, §14.7]

| Slot | What |
|---|---|
| H.L | Status tiles on top, awake timeline, Doctor findings list |
| H.S1 | Tiles: engine (running / stopped, LaunchAgent loaded), last tick, render queue, disk free, last backup, ffmpeg |
| H.S2 | Mac awake timeline (last 7 days, bars, missed slots marked) |
| H.S3 | Doctor findings: severity icon, what, where, suggested fix; Run again; **Copy report (Markdown)** |
| H.S4 | Logs: open engine.log |

## S — Settings [§3, §14.8]

| Slot | What |
|---|---|
| S.L | macOS-style settings (sections list + forms) |
| S.S1 | Platforms: on/off per platform, pause one platform, upload URL, limits table (max length / size, editable) |
| S.S2 | Schedule: posts/day, slot times per platform, week start, approval reminder time, repost cooldown |
| S.S3 | Queue: sort global + per-platform override, tie-break, overlap avoid + N days |
| S.S4 | Alerts: approved runway threshold, total runway threshold |
| S.S5 | Rendering: loudness target, render-ahead horizon, bitrate, cleanup policy |
| S.S6 | Text & captions: style presets defaults, templates per kind, caption template, hashtag sets |
| S.S7 | Engine: LaunchAgent status/reinstall, wake before first slot (pmset, off), folders, backups |
| S.S8 | (phase 2) Postiz key in Keychain — placeholder only |

## Background jobs [§4, §7, §8]

| ID | Job | Trigger |
|---|---|---|
| J.INTAKE | Read Sessions/*/videos.json, upsert, fingerprint relink, missing detection | launch, FSEvents, tick |
| J.PLAN | Propose next week; apply shifts; re-queue fixed failures (next day, ≥ 3 h stagger) | tick |
| J.RENDER | Render ahead for approved slots within horizon; re-render on edit change; delete stale renders; validate with ffprobe | tick |
| J.DUE | Hand due posts to publisher (manual → notify) | tick |
| J.MISS | Late < 6 h → due; day passed → shift that platform + notify | tick, wake |
| J.ALERT | Runway thresholds, weekly approval reminder | tick |
| J.MOVE | Move renders to Posted/Shortform when all terminal; cleanup after N days | tick |
| J.HB | Heartbeat + awake/asleep periods | tick, wake, sleep |
| J.BACKUP | Daily DB backup, keep 14 | daily |
| J.PROXY | 720p proxies for scrubbing (if needed) | on edit open / idle |
| J.DOCTOR | `djq doctor [--json]` | on demand, Health screen |
