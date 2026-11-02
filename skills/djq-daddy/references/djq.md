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
- Eric may be at the Mac: never move the real pointer or type into Eric's apps. macOS blocks synthetic mouse input, so list hover checks for Eric to try by hand.
- `rm` with literal paths only. Never force-push, never `gh auth switch`, never rewrite published history.
- Public repo: no secrets, emails other than the GitHub no-reply address, absolute home-directory paths, references to Eric's other projects or third-party images. `refs/` stays gitignored.
- Commits are authored as the repo's configured EricIshekwene no-reply identity and end with the session's Co-Authored-By trailer.

## Checks (from the repo)
- Build: `swift build` with 0 warnings.
- Tests: `swift test` (or `scripts/test.sh` with only the Command Line Tools). Includes the icon-tooltip lint `scripts/check-icon-tooltips.py` once the tooltip pass is merged.
- Screens: `.build/debug/DJQueueApp --snapshot <dir>` renders every screen in light and dark, against the dev root. Save evidence under `~/code/dj-queue-dev/evidence/<round>-<name>/`.
- Data: `djq doctor --json` (exit 2 means errors) and `djq videos --json`.

## Ship (Eric has authorized pushing `main`; no extra approval needed unless the round was only staged)
From v0.6.0 on, the auto-update watcher installs every commit that lands on `main` (`djq autoupdate status` says whether it's on). Sessions merge and tag; the watcher gates (tests + app build in a scratch checkout), backs up the DB, installs, restarts the engine and verifies. Never run `build-app.sh --install` while the watcher is on: two installers would race.
1. All task branches have passed independent review. Before merging, snapshot the data: `djq videos --json > <session>/evidence/pre-install-videos.json`, and back up the real DB with SQLite's backup API: `sqlite3 "$HOME/Library/Application Support/DJ Queue/queue.sqlite" ".backup '$HOME/code/dj-queue-dev/backups/real-queue-before-r<N>-install-<YYYYMMDD-HHMM>.sqlite'"`; confirm the copy with `PRAGMA integrity_check`.
2. Merge into `main` (`--no-ff`) in dependency order and tag the final merge **in the same step** (`git tag -a v0.<X>.0 -m "<one-line summary>"`), so the watcher's 20 s debounce builds the release label. (A tag that lands later only re-labels: the watcher rebuilds the same commit.)
3. Follow the install with `djq autoupdate status` and `djq autoupdate log` (a gate takes a few minutes). Outcomes: **installed** (go on); **ready** (Eric's window is open: it installs when the window closes or on Restart & update; report that, don't force it); **blocked** (tests or build failed on main: nothing was installed; fix on a branch, review, merge again; `djq autoupdate log --run` has the output); **rolled back** (its checks failed after install; Eric's data is as before; investigate). With the watcher off, fall back to the manual steps: `swift build` + `swift test` on `main`, `scripts/build-app.sh --install`, `launchctl kickstart -k gui/$(id -u)/com.djlovd.queue.engine`.
4. Verify: ids, scores, titles and edits are identical to the pre-install snapshot (plus the round's intended changes), `djq doctor --json` shows 0 errors, and the installed version matches the tag (`git describe --tags` versus `CFBundleShortVersionString` in `~/Applications/DJ Queue.app/Contents/Info.plist`). If verification fails, stop, keep the backup and report it; don't push.
5. Push as EricIshekwene:
   `GH_TOKEN=$(gh auth token --user EricIshekwene) git -c credential.helper= -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' push origin main --follow-tags`
   A rejected push means fetch and reconcile, never force. Confirm with `git ls-remote origin main` and the tag.
6. Docs-only commits (README, DECISIONS, design/) are skipped by the watcher, so post-ship doc refreshes don't reinstall.
7. Refresh affected docs: README (screenshots when screens changed), `ARCHITECTURE.md`, `DECISIONS-R<N>.md`, and the knowledge pack in `~/code/dj-queue-dev/claude-project-docs/`. Update the Notion DJ Queue hub when the Notion connector is available; otherwise say so.
