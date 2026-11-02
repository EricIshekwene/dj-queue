# R2-SCREENS decisions

## SETTINGS

- **`SettingsModal` moved from `Shell/MainWindowView.swift` into `Settings/SettingsModal.swift`; the foundation's placeholder struct was deleted (one-line pointer left), and `AppModel.settingsSection` now defaults to `.general`.** Why: the leaf owns the modal body; General is the first nav row, like ChatGPT.
- **Nav rows are a local `SettingsNavRow` (DSSidebarItem anatomy, 8 pt icon gap, one line) instead of `DSSidebarItem`.** Why: "Playback & autoplay" wrapped to two lines in a 200 pt nav with DSSidebarItem's spacing.
- **Trailing menus use `DSSelect` with the ghost variant and `.sm` size.** Why: matches the ref's "Push ⌄" (value + chevron, no box until hover).
- **Added `DSXStepper` (capsule surface.sunken track, ghost −/+ icon buttons, tabular value, ends say why they're disabled).** Why: the DS has no stepper and many settings are bounded numbers.
- **Times (slots, approval reminder) are DSSelect menus every 30 minutes, plus the current value when it's off-grid.** Why: keeps the row anatomy (value + chevron) instead of a round-1 date-picker field.
- **Platforms: one On / Paused / Off menu per platform** (Off also clears paused). Why: replaces two controls (switch + checkbox) with one ChatGPT-style row.
- **General holds Pause all posting, Posts per day, Time zone, Week starts on; Approval reminder moved to Alerts; Second post offset stays in Schedule (disabled with a reason when posts per day is 1).** Why: brief; a reminder is an alert.
- **Time zone is a short menu (US zones, London, Paris, Johannesburg, Lagos + the system and current zones).** Why: the full 600-zone list is unusable in a menu; round 1 showed it read-only.
- **Pause all posting is a plain switch (no extra confirm).** Why: it's an explicit settings toggle whose description says exactly what happens; the toolbar control keeps its confirm.
- **New clip defaults edit as a draft kept in `SettingsUIState.shared` until Save or Cancel — closing the modal or switching sections keeps it, and the nav row shows a dot.** Why: never lose edits; Save is the only commit point.
- **"Reset to built-in defaults" confirms, then saves immediately (no second Save).** Why: the confirmation is the commit; asking for Save after a confirm is double work.
- **Footer shows "N unsaved changes" next to Cancel / Save; both are disabled with "No changes" when clean.** Why: spec; the count tells Eric how much Cancel throws away.
- **Text size and positions are preset menus ("Medium · 64 pt", "Centre · 50%") plus a "Custom · …" entry when the saved value isn't a preset.** Why: a value set by dragging or the CLI is shown, never silently snapped.
- **Trim mode is labelled "Marker in and out" / "Whole file" (not the core's "Eric's markers").** Why: Eric reads the UI; second person wording.
- **Default caption template / hashtag sets are chosen only in New clip defaults; Captions & titles shows a "Default" badge and blocks deleting a template or set that a default uses (with the reason).** Why: one place edits the defaults set; no dangling ids.
- **Round-1 caption preview with made-up sample text dropped; the variables are listed under the Caption templates heading.** Why: no prefilled/sample content in the UI (#9).
- **Prefill rules editor, live preview and rules-file rows removed entirely.** Why: north star #9 (Prefill left the app).
- **Captions & titles → Titles offers "Copy prompt for N clips" (`model.copyAgentPrompt(model.needsTitleHelp)`), disabled with a reason when no clip needs help.** Why: the "Ask an agent" path from Settings without guessing anything.
- **New hashtag sets start with no tags (round 1 seeded "#djlovd").** Why: no prefilled content.
- **Engine: install error shows as a danger attention card ("Try again") with the full error under it; Install/Reinstall/Stop confirm inside the modal (DSDialog over a scrim), not with `confirmationDialog`.** Why: in-window overlays match the DS and render in snapshots.
- **Added "Open log" (engine.log, disabled with a reason until it exists); file paths truncate in the middle on one line.** Why: brief; paths are useful at both ends.
- **Modal pane uses `surface.raised` (white / #2F2F2F) rather than `bg.app`.** Why: DESIGN-v2 §2.5 dark e3 = border + one step lighter surface; #212121 vanished into the scrimmed app.
- **A focus parker clears AppKit's automatic first responder when the modal opens or the section changes.** Why: AppKit dropped the caret (and focus ring) into the first template name field.
- **Shots: 40–49 = one per section; 44b = New clip defaults scrolled to Caption/Posting; 44c = unsaved changes (outline style, upper position, +1.5 s before).** Why: brief; shot names keep the 4x prefix.
