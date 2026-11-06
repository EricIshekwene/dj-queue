---
name: djq-daddy-status
description: Read-only status of DJ Queue build sessions, including goal, tree, branches, reviews, checks, controller lock, installed vs main vs GitHub version, and next action. Use when Eric asks what's running, where a DJ Queue round stands, or what version is installed.
---

# DJ Queue status

Read-only: dispatch, write, merge, clean or monitor nothing. Use [session.md](../djq-daddy/references/session.md) to find records under `~/.agent-sessions/daddy/dj-queue-*`. Report "none" without creating anything.

Report compactly:
- The session's goal, state and last update; the controller lock (owner, age, or stale).
- Its tree: each node with branch, latest commit, state and review verdict.
- Checks passed, failed and unrun, with the candidate they ran on, including any `screen-guard: FAIL` from `scripts/live-checks.sh`.
- Versions: installed (`CFBundleShortVersionString` in `~/Applications/DJ Queue.app/Contents/Info.plist`), `git describe --tags` on `main`, and GitHub (`git ls-remote origin main` compared with local `main`).
- Live worktrees (`git worktree list`) and dirty files in each.
- Blockers, any question for Eric, and the exact next action. Point to HANDOFF when paused.

Keep what the record says apart from what's live. A record that disagrees with git is reported as a discrepancy, not fixed.
