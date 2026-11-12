# Round 30: trim per version

Eric (2026-11-12): "When he changes a clip's trim while editing v3, only v3 changes. v1 and v2 keep their own start and
end." Requirements: S1-R1 an optional trim per version, falling back to the clip's; editor handles change the version
being edited and say whose trim it is. S1-R2 texts, countdowns, renderer, cover, platform length checks and Postiz use
each version's trim. S1-R3 repair vid 1, vid 2, vid 3a. S1-R4 `djq trim`, trims in `djq video --json` and
`djq overlay list`. S1-R5 tests.

## Decisions

- **D1. Stored on the version, both ends.** `Version.trimIn/trimOut` are absolute seconds in the clip file; a version
  has its own trim only when both are set, so a later change to the defaults (markers, extra seconds) never moves it.
  Never carried forward. A copy of a version takes it (round 27 copies are complete).
- **D2. The clip's per-platform trims belong to the clip's trim.** A version with its own trim never gets them (a
  Facebook cut made for a 2-minute clip makes no sense on a 24 s version); it has its own `Version.platformTrims`,
  which the editor's "Trim for X" lane writes when the version has its own trim.
- **D3. The cover stays one per clip.** A version with its own trim uses the clip's cover frame when it's inside its
  trim; otherwise the default rule (trim start / marker / offset) inside its own trim. A version's trim change never
  moves the clip's cover.
- **D4. Readiness is still v1's** (like text and caption): `Validation.issues` uses v1's trim. Each post's length is
  checked against its own version's trim by the engine's platform check, and the editor shows the version being edited.
- **D5. The editor's switch.** The Trim field gets a two-segment switch, "v3 only · All versions" (the existing
  `DSSegmented`; Mobbin references: Higgsfield's settings switch, Descript's inspector), with a line saying who changes
  ("v1, v2 keep theirs" / "Shared by v1, v2. v3 has its own and keeps it"). Rule: a version with its own trim always
  edits it; otherwise Eric's pick for that clip and version; otherwise "This version" on a clip with more than one
  version (Eric's ask) and "All versions" on a clip with only v1 (nothing else to protect, and the stored data stays
  as before). Choosing "All versions" on a version with its own trim drops it (one undo step, a toast says so). The
  timeline shows a "v3 only" badge when the version has its own trim. Reset / "Trim to markers" act in the switch's
  scope only.
- **D6. Clamping is scoped.** The editor used to clamp every version's text times to the trim being dragged; that is
  what squeezed the v2 quizzes into the last 0.3 s. Now only the versions using the trim that changed are clamped. `djq
  trim` never clamps texts (a text past the end just isn't drawn).
- **D7. Version tiles.** List tiles play v1's trimmed proxy. A version with its own trim inside it loops its own part,
  with its texts shifted to match; one outside it shows its cover (no extra proxies per version).
- **D8. Data repair restores what the clips had before the v3 trims**, read from the backup of 2026-11-12 16:27
  (`real-queue-before-r26b-install-…`): vid 1's clip trim was 22.92–135.20 s (Eric's own trim, the range its v1 text
  and v2 quiz were made on, and the "about 22.9–135.2 s" in the ask), so it goes back to that rather than the markers
  default (3–180 s); vid 2 and vid 3a had no trim, so they go back to the default. vid 1's Facebook trim
  (23.3–47.2 s, made alongside v3's trim) is cleared. Each v3 gets exactly the trim it had, so v3's video is unchanged.
  Done with `djq trim` after install (one undo step each), proven first on a copy of the newest backup.
- **D9. Not repaired: v2's text times.** The old editor already clamped the v2 quiz texts to the 23.7 s / 27.8 s /
  19.4 s trims (answers now sit in the last 0.3 s), and no backup holds the countdown design before that clamp. v1 and
  v2 get their full length back; the quiz texts on v2 need re-timing (the "vid N quiz" clips hold the full design).
- **D10.** `EditorLogic.time(_, tenths:)` printed 179.97 s as "2:60.0"; it now rounds to tenths first ("3:00.0").
