# R2-SCREENS decisions

## FOUNDATION

- **`Screen` = score, edit, queue, week, today, library, posts, health (⌘1…⌘8); Settings is the in-window modal (`model.showSettings`, `model.settingsSection`), and `WindowManager.showSettings` opens the main window with it.** Why: pipeline navigation #13 and DESIGN-v2 §6.9; one window keeps the shell calm.
- **Removed the Queue tabs, Score mode, round-1 QueueView, VideoInspector and the separate Settings window.** Why: Score/Edit/Queue are now screens; the inspector's jobs move to the editor and the leaves' screens.
- **Kept ScorePromptSheet/PinPromptSheet where they live (CommandPalette.swift, Browse leaf); replaced PreviewSheet with `Shared/ClipPreviewSheet` (DSDialog, proxy if cached else the source file looping the markers).** Why: the palette still offers Set score/Pin/Preview; only the preview lived in a deleted file.
- **The window title bar is hidden and transparent; the sidebar header and every ScreenScaffold toolbar drag the window (`WindowDragGesture`).** Why: DESIGN-v2 §3 shell runs to the top edge like ChatGPT; macOS 15 gives a native drag gesture.
- **Sidebar is custom (no `List`); compact rail is 76 pt (fits the traffic lights), under 1200 pt or when collapsed.** Why: R2.NAV look; a 60 pt rail would put the traffic lights over the toolbar.
- **Health dot: red = engine stopped or database error; amber = paused, a platform paused or approved runway low; green otherwise.** Why: the dot must be readable at a glance; post problems already have Posts' red count.
- **"Pause one platform ▸" is a second page inside the engine popover (DSMenuList has no submenus).** Why: keeps DS components, no hand-rolled cascading menu.
- **Attention cards: problems + load error (danger, not dismissible), paused (warning, not dismissible — it's a state with Resume), engine off / low approved / low total runway (warning, hide 24 h). The problems card is hidden on Posts.** Why: DESIGN-v2 §3; Posts is where Review leads.
- **Every screen draws its own toolbar through `ScreenScaffold`; round-1 Week/Today/Library/Posts/Health are wrapped in it (`legacyBody`) until their leaves rewrite them.** Why: leaves own their whole screen file and never edit the shell.
- **Plain click on a card opens it (editor) when nothing is selected, and toggles it while a selection exists.** Why: matches DSClipCard's selection mode, so clicking never surprises mid-selection.
- **⌘A / ⌘Z / Esc are hidden window buttons; ⌘A and ⌘Z are forwarded to the responder chain while a text field is editing or the editor is open.** Why: bulk undo/select-all must not steal typing undo/select-all.
- **Bulk dry run and apply run off the main thread; `BulkRequest.run` is `@Sendable` (capture `model.bulk`, which is Sendable).** Why: make-ready may probe source sizes with ffprobe; the UI must not freeze.
- **One clip → apply at once with the same undo toast; > 1 → the shared confirmation sheet (in-window e3 over the scrim, not `.sheet`).** Why: spec #11; in-window overlays also render in snapshots.
- **Suggestions appear on cards only on Score/Edit and only while the clip has no Title; platforms never on Score/Edit; date chip only on Queue.** Why: cards show only what the job needs (DESIGN-v2 §4/§6).
- **Validation issues → chips: no crop/text/caption/title = warning; too long/too large/caption or YouTube title too long/unreadable edit = danger.** Why: DESIGN-v2 §6.2 (danger for hard blocks).
- **Card duration = Eric's markers when set, else the file.** Why: the default trim is the markers; a mechanical rule, not a guess.
- **Issues are computed for Edit + Queue clips (ready, planned, needs edit), suggestions for every active short, on every off-main refresh.** Why: the spec's minimum, cheap enough off-main; no stale cache keys to get wrong.
- **One ProxyService per process: EngineHost hands the app's `model.proxies` to its engine (pausing while rendering).** Why: never encode a clip twice; visible tiles jump the engine's background queue (r2-core b251629 API).
- **Proxies are requested only while autoplay is on; snapshot runs look up cached files only.** Why: no background encoding Eric didn't ask for; deterministic snapshots.
- **UserDefaults (view modes, playback, dismissed cards, recents) is neither read nor written during `--snapshot`, and the model skips its async first load there.** Why: snapshots must not leak into the real defaults domain, and a late async load reset the cover stamps mid-shot.
- **Snapshots render with AppKit `cacheDisplay` by default (`DJQ_SNAPSHOT_WINDOW=1` for window-server capture).** Why: window capture returns white with the display asleep (same as the DS gallery decision).
- **Shots: one file per leaf (`Shots+Shell/Pipeline/Planning/Browse/Settings.swift`), prefixes 0x/1x/2x/3x/4x, UI reset before every main shot.** Why: parallel leaves never touch the same file and shots don't depend on order.
- **SampleData: fixed made-up titles/tracks ("Midnight Run x Afterglow", artists "Sample Artist"/"Demo Collective"), suggestions on untitled clips (high confidence on even clips, 0.35 on odd ones so "Ask an agent" shows), clips 40–47 missing crop/text, one with a whole-file trim.** Why: every screen gets realistic states; no Prefill, no real artist names in a public repo.
- **`markPostedPrefill` renamed `markPostedDraftURL`.** Why: it is the URL Eric typed in a notification, not prefilled content (and keeps the no-Prefill grep clean).
