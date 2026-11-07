# Decisions: round 18, background verification

Eric's rule (2026-11-06): live click-through checks keep running on every build, without DJ Queue windows on the screen.

1. **Windows go far off every display (`Backstage`).** They stay real windows: the window server draws them, live player and materials included. A virtual display would add a second monitor to the Mac, and a second login can't be set up by an agent.
2. **Each window is captured on its own.** A region capture of that area comes back empty, which gave blank tooltip evidence on the first try. Blank pages now fail the tooltip, page-pass and hover checks.
3. **ScreenGuard fails a run** if a window of that run lands on a display or the app activates. It samples every 0.1 s and sees its own process only. It first caught a real `.sheet`, which pulls its window onto a display.
4. **Stand-ins, labelled in the logs.** The hover probe sends AppKit's menu notifications instead of opening a real menu, so it no longer proves AppKit posts them for a context menu. The tooltip pass shows the pin sheet's view in a backstage window, so it no longer proves the sheet's presentation.
5. **Players are at volume 0 in these runs.** `isMuted`, which the checks read, is unchanged, so nobody hears a run.
6. **Dev binaries refuse to start without `DJQ_HOME` and `DJQ_ROOT`,** and an unknown `--` flag refuses instead of opening the real window. The check is a path under `.build`, so the installed app is never refused.
7. **On a locked Mac the tooltip and hover checks fail on blank captures.** That's correct: nothing was verified. Rerun once it's unlocked.
8. **Animations are off in these runs.** Nothing ticks an animation off a display, so an animated change would never land. Tooltips and forms open at once, and no check covers the animations themselves.
9. **Most checks run on a copy of the newest backup, with every stored path rewritten to the dev root,** because they need clips waiting in Edit. The script stops if a path to the real footage is left. `editor-selftest`, `search`, `send-to-queue`, `editor-caption` and `editor-template` expect clips just read from the session folders, so they run on a fresh database. The window of the first tooltip check keeps a gray background so its capture can't read as blank in dark.
10. **Two old checks stop depending on the data.** The hover probe expects as many covers as days left in the week, up to four, because past days don't play. The tooltip probe hovers an Edit clip with nothing to fix, because a clip with a fix doesn't show the editor button. That second check already failed the same way in round 16.
11. **`editor-group` sets its scroll position directly,** because a wheel event's location can't reach a window off every display.
12. **The caption typing check now types at about 20 keys a second.** At the old 200 to 1,000 keys a second it dropped keys now and then in hidden windows; at this pace it passed 8 runs of 8. Round 7, on a window in front, passed at the old pace, so the hidden window may be the cause, but that isn't proven. A burst at the old speed still runs and logs what it lost, without failing the check.
13. **Two hover checks no longer see a fade.** "Leave during a hover fade" and "come straight back during the fade" run with animations off, so they say NOT DRIVEN in the log and go on Eric's list to try by hand.
