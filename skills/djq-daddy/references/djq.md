# DJ Queue facts and rules (binding for every djq-daddy skill)

## Owner and how Eric works
- Owner: Eric (DJ Lovd). Refer to Eric as they/them.
- Decide minor and mid-level questions yourself. Log each with a one-line why in `DECISIONS-R<N>.md` (repo root) and list them in the final report. Stop only for a real blocker or something only Eric can do. Never block on a decision card; pick the recommended option and keep going.
- "ship it", "merge" or "go" approves every open choice in that round. Don't ask again.
- When Eric says "stage it", stage and don't merge, install or push until Eric says so.
- Messages to Eric: lead with the outcome in a line or two, then only what Eric must do. No replay of the process.
- Verify before saying done. A failed or skipped step is reported plainly.

## Repo and machine
- Repo: `~/code/dj-queue` only (GitHub `EricIshekwene/dj-queue`, **public**). Default and ship branch: `main`.
- Host: Claude Code on Eric's always-on Mac, including Claude project threads running there over Remote Control. A thread cannot switch its own working folder into a worktree; create task worktrees with `git worktree add`.
- Task worktrees: `~/code/worktrees/dj-queue/r<N>-<name>` on branches `agent/r<N>-<name>`.
- Session records: `~/.agent-sessions/daddy/dj-queue-r<N>-<slug>-<YYYY-MM-DD>/` (SESSION.md, HANDOFF.md, reviews/, evidence pointers). Records stay outside the repo.
- Controller lock: `~/.agent-sessions/daddy/DJQ-CONTROLLER` holds the SESSION path, the thread or chat name and the start time of the one controller that may merge into `main`, install, tag and push. Create it when a session starts; remove it at COMPLETE or HANDOFF. If it exists for another live session, don't touch `main`: plan, work in your own worktree on disjoint files, or wait. A lock whose session is HANDOFF/COMPLETE/STOPPED is stale; note it in SESSION and take over.
- Principles: `ARCHITECTURE.md`, `DECISIONS*.md`, `design/DESIGN-v2.md`, `design/DESIGN-SYSTEM.md`, `docs/metadata.md`, `skills/dj-queue-agent/SKILL.md`, and the round-2 north star `~/.agent-sessions/daddy/dj-queue-r2-2026-11-01/NORTH-STAR.md`.
  - The app is a UI over scripts: no in-app intelligence, never guesses titles or text.
  - Agents change data only through `djq`; never write SQLite directly.
  - Calm ChatGPT-like design system; one primary action per screen; every control explains itself (icon-only buttons need a tooltip; the lint enforces it).
  - Never double-post; pinned clips never move; copyright problems are never auto-retried.

## Safety
- Real data: DB `~/Library/Application Support/DJ Queue/queue.sqlite`; sources `~/Movies/DJ Video/`. Dev work and tests never open or change either. Use `scripts/make-devroot.sh`, then `DJQ_ROOT=~/code/dj-queue-dev/"DJ Video" DJQ_HOME=<own scratch dir>`.
- Never modify, move or delete source footage, CapCut projects or `videos.json` ids.
- Schema changes migrate losslessly: test on a **copy** of the newest `~/code/dj-queue-dev/backups/real-queue-before-*.sqlite` and compare counts, scores, titles and edits.
- Don't resume posting, approve weeks, post, or change Settings on Eric's data unless Eric says so. Touch the LaunchAgents only through the ship steps (the auto-update watcher restarts the engine itself; `launchctl kickstart` only on the manual fallback).
- Eric may be at the Mac: never move the real pointer or type into Eric's apps. Hover checks run through the probes; list only what a probe can't drive for Eric to try by hand.
- **Never execute the installed app's `DJQueue` binary**, even with a flag: it runs on real data. Read its version from `Info.plist`. The installed `djq` CLI is fine and required; dev `djq` and app binaries refuse to start without `DJQ_HOME` and `DJQ_ROOT`.
- `rm` with literal paths only. Never force-push, never `gh auth switch`, never rewrite published history.
- Public repo: no secrets, emails other than the GitHub no-reply address, absolute home-directory paths, references to Eric's other projects or third-party images. `refs/` stays gitignored.
- Commits are authored as the repo's configured EricIshekwene no-reply identity and end with the session's Co-Authored-By trailer.

## Checks (from the repo)
- Build: `swift build` with 0 warnings.
- Tests: `swift test` (or `scripts/test.sh` with only the Command Line Tools). Includes the icon-tooltip lint `scripts/check-icon-tooltips.py` once the tooltip pass is merged.
- Live checks: `scripts/live-checks.sh ~/code/dj-queue-dev/evidence/<round>-<name>/live` runs every click-through script, probe and screen render against the dev root (screens and editor scripts in light and dark; probes as each one defines). Name checks to run only some, for example `… live tooltip hover text-layers`. Save evidence there.
- Data: `djq doctor --json` (exit 2 means errors) and `djq videos --json`.

## Background verification (standing rule, Eric 2026-11-06)
Every build still does live click-through checks and screenshots, and none of it may show on Eric's screen or take focus.
- Run live checks only through `scripts/live-checks.sh`. Don't launch the app any other way: a plain dev launch opens a real window in front. If a one-off env run is needed, it uses `--snapshot` with `DJQ_HOME` and `DJQ_ROOT`, or it is refused.
- Windows sit off every display (`Backstage`), where the window server still draws them, live player and materials included. Clicks, keys and hovers are events sent to that window, so they stay real. Players run at volume 0, so a run is silent too. Animations are off, because nothing ticks one off a display, so no check covers an animation: list those for Eric to look at by hand. Checks run on a scratch copy of the newest backup, or on a fresh database for the ones that expect it (`fresh` in the script). Capture one window at a time with `WindowCapture` or `DSTooltipProbe.captureImage`: a region capture of that area comes back empty.
- `ScreenGuard` watches each run. A `screen-guard: FAIL` line or exit 3 means something reached Eric's screen or took focus: treat it as a failed check and fix it, even if the script's own checks passed. A run's log must end with `screen-guard: clean`.
- New scripts call `Backstage.show(window)` and add a line to `checks` in `scripts/live-checks.sh`. `BackgroundWindowTests` fails on the known ways to bring a window forward, and ScreenGuard catches the rest for anything in `checks`. Anything macOS forces onto a display, such as a real `NSMenu` or a real `.sheet`, can't run in a check: use a stand-in, label it one in the log and list it in the report.
- Locked Mac: the window server draws nothing, so the tooltip and hover checks fail on blank captures and text-layers falls back to the view tree with a black player. Rerun them once the Mac is unlocked; that isn't a product failure.
- Scope: the guard samples every 0.1 s and sees this process's windows only. Eric seeing anything from DJ Queue during a build is a bug: find it, fix it, and add it to this list.

## Ship (Eric has authorized pushing `main`; no extra approval needed unless the round was only staged)
From v0.6.0 on, the auto-update watcher installs every commit that lands on `main` (`djq autoupdate status` says whether it's on). Sessions merge and tag; the watcher gates (tests + app build in a scratch checkout), backs up the DB, installs, restarts the engine and verifies. Never run `build-app.sh --install` while the watcher is on: two installers would race.
1. All task branches have passed independent review. Before merging, snapshot the data: `djq videos --json > <session>/evidence/pre-install-videos.json`, and back up the real DB with SQLite's backup API: `sqlite3 "$HOME/Library/Application Support/DJ Queue/queue.sqlite" ".backup '$HOME/code/dj-queue-dev/backups/real-queue-before-r<N>-install-<YYYYMMDD-HHMM>.sqlite'"`; confirm the copy with `PRAGMA integrity_check`.
2. Integrate on a local branch, never one merge at a time on `main` (every move of `main` starts the watcher): `git switch -c integrate/r<N> main`, merge each reviewed branch into it (`--no-ff`, dependency order), run `swift build` + `swift test` there, then move `main` in one step and tag it at once: `git switch main && git merge --ff-only integrate/r<N> && git tag -a v0.<X>.0 -m "<one-line summary>"` (the watcher's 20 s debounce sees the tag; a tag that lands later only re-labels the same code). Delete the integrate branch after.
3. Follow the install with `djq autoupdate status` and `djq autoupdate log` (a gate takes a few minutes). Outcomes: **installed** (go on); **ready** (Eric's window is open: it installs when the window closes or on Restart & update; report that, don't force it); **blocked** (tests or build failed on main: nothing was installed; fix on a branch, review, merge again; `djq autoupdate log --run` has the output); **rolled back** (its checks failed after install; Eric's data is as before; investigate). If `djq autoupdate status` fails (an installed build older than v0.6.0 has no `autoupdate`) or says off, the watcher isn't installing: use the manual steps: `swift build` + `swift test` on `main`, `scripts/build-app.sh --install`, `launchctl kickstart -k gui/$(id -u)/com.djlovd.queue.engine`.
4. Verify: ids, scores, titles and edits are identical to the pre-install snapshot (plus the round's intended changes), `djq doctor --json` shows 0 errors, and the installed version matches the tag (`git describe --tags` versus `CFBundleShortVersionString` in `~/Applications/DJ Queue.app/Contents/Info.plist`). For a UI round, copy the installed app to a scratch folder and run the checks on the copy, still hidden: `DJQ_BIN=<scratch>/"DJ Queue.app"/Contents/MacOS/DJQueue scripts/live-checks.sh <dir> tooltip`. If verification fails, stop, keep the backup and report it; don't push.
5. Push as EricIshekwene:
   `GH_TOKEN=$(gh auth token --user EricIshekwene) git -c credential.helper= -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' push origin main --follow-tags`
   A rejected push means fetch and reconcile, never force. Confirm with `git ls-remote origin main` and the tag.
6. Docs-only commits (README, DECISIONS, design/, skills) are skipped by the watcher, so post-ship doc refreshes don't reinstall.
   Bootstrap (v0.6.0 only, already done once): the first auto-update build was installed with the manual steps, then `djq autoupdate on` loaded the watcher.
7. Refresh affected docs: README (screenshots when screens changed), `ARCHITECTURE.md`, `DECISIONS-R<N>.md`, and the knowledge pack in `~/code/dj-queue-dev/claude-project-docs/`. Update the Notion DJ Queue hub when the Notion connector is available; otherwise say so.
