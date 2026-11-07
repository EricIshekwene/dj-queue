# Round 19 decisions: editor keys (2026-11-07)

Eric: Space often doesn't pause while editing; ← / → should move much further, with a setting he can change and try
while changing it; next / previous clip on ↑ / ↓.

1. **Why Space failed.** The editor ignores keys while a text view has the cursor (so Space can type in a Title or
   caption), and nothing took the cursor out of a field when Eric clicked the picture or the timeline: SwiftUI never
   does that by itself. After any typing, Space typed a space into the field. Fix: a click on the picture or timeline
   (not on a text field) ends typing, Esc ends typing, and opening another clip starts with nothing focused. Checked once
   with the click-away switched off in a scratch build: the live check's "click on the picture" and "Space plays"
   steps failed, and pass with it on.
2. **Arrow step default: 2 seconds** (was one frame). Eric's clips are 15–60 s (median ~27 s), so 2 s crosses a clip in
   about a dozen presses; 5 s and 10 s are one click away. ⇧ ← / ⇧ → keep the one-frame nudge for trimming.
3. **Choices:** 1 frame, ½ s, 1 s, 2 s, 5 s, 10 s, stored in the playback prefs (`djq.playback`, lenient decode: old
   prefs and unknown values load as 2 s).
4. **Try it live in two places.** A step chip beside Play in the editor (changes take effect on the open clip at once,
   so the arrows can be tried straight away), and Settings → Playback → "Arrow keys jump" with a 30-second try-it
   strip: click it, press the arrows. Both write the same setting.
5. **The jump buttons beside Play follow the step** (they were fixed at 5 s), so buttons and arrows always agree.
6. **A jump keeps playing** if the clip was playing (hopping through while listening); a frame step (⇧, or the
   1-frame setting) pauses, as frame steps did.
9. **Esc in a form's field** (new hashtag group, caption template) still closes the form in one press: the form's
   Cancel gets Esc first, and only otherwise does Esc just leave the field.
7. **↑ / ↓ open the previous / next clip;** ⌘[ / ⌘] still work. ↑ / ↓ are left alone while typing, when a list has
   focus, and under any overlay (Settings, confirms), which now also keeps Space and the arrows from reaching the
   editor behind Settings.
8. The step chip's menu is a system menu, which can't open in a hidden check: the check sets the same binding the menu
   item sets (labelled a stand-in in its log).
