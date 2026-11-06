---
name: djq-watchdog
description: Watch DJ Queue session children (builders, reviewers) and long jobs for real progress, stalls and results using git commits, worktree file activity and review files. Use alongside djq-daddy whenever a child runs in the background.
---

# DJ Queue watchdog

Watch identified work without adding an acceptance gate. Record each watchdog's ID, its target and its stop condition in SESSION Resources.

**Signals of progress** (any of these resets the stall timer):
- a new commit on the child's branch (`git -C <worktree> rev-parse HEAD`);
- files modified in its worktree (`find <worktree> -newer <marker> -not -path '*/.build/*'`);
- its review or evidence file appearing or growing;
- new downloads in `refs/` or the evidence folder during research;
- a `run.log` growing under `<evidence>/live/<check>/` during `scripts/live-checks.sh`.

**How:** use one background shell loop per child (or the host's Monitor tool) that exits on the first meaningful event: a new commit, the result file written, or no signal for **30 minutes** (45 for research or reviews that only read). Exiting wakes the parent, which decides what to do. Silence during one long tool call isn't a stall.

**Background verification:** a child's live checks must stay off Eric's screen. Watch their logs for `screen-guard: FAIL` or exit 3 and wake the parent on the first one. If a child launches the app any way other than `scripts/live-checks.sh`, or runs the installed app, stop it and wake the parent ([djq.md](../djq-daddy/references/djq.md), Background verification).

**On a stall:** inspect the worktree and the child's status before acting. If the child is still working, restart the watchdog with a wider window. If it's dead, preserve its work (commit a WIP checkpoint on its branch through the task parent) and send the same owner, or a fresh one, the remaining steps. Never start a second writer on the same files while the first might be alive.

**Limits:** a watchdog lives only as long as the thread or chat that started it. If the Mac sleeps or the thread ends, watchdogs stop. SESSION stays the source of truth, and `/djq-daddy-continue` picks up. Stop every watchdog at HANDOFF, STOPPED or COMPLETE, and record that it stopped. Report only meaningful changes to Eric.
