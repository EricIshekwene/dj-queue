# Decisions: round 18, background verification

Eric's rule (2026-11-06): live click-through checks keep running on every build, without DJ Queue windows on the screen.

1. **Windows go far off every display (`Backstage`).** They stay real windows: the window server draws them, live player and materials included. A virtual display would add a second monitor to the Mac, and a second login can't be set up by an agent.
2. **Each window is captured on its own.** A region capture of that area comes back empty, which gave blank tooltip evidence on the first try. Blank pages now fail the tooltip, page-pass and hover checks.
3. **ScreenGuard fails a run** if a window of that run lands on a display or the app activates. It samples every 0.1 s and sees its own process only. It first caught a real `.sheet`, which pulls its window onto a display.
4. **Stand-ins, labelled in the logs.** The hover probe sends AppKit's menu notifications instead of opening a real menu, so it no longer proves AppKit posts them for a context menu. The tooltip pass shows the pin sheet's view in a backstage window, so it no longer proves the sheet's presentation.
5. **Players are at volume 0 in these runs.** `isMuted`, which the checks read, is unchanged, so nobody hears a run.
6. **Dev binaries refuse to start without `DJQ_HOME` and `DJQ_ROOT`,** and an unknown `--` flag refuses instead of opening the real window. The check is a path under `.build`, so the installed app is never refused.
7. **On a locked Mac the tooltip and hover checks fail on blank captures.** That's correct: nothing was verified. Rerun once it's unlocked.
