---
name: djq-daddy-complete
description: Ship a reviewed DJ Queue session that stopped before shipping (READY_FOR_REVIEW, PUSH_PENDING or after a handoff) by merging its branches to main, testing, backing up, tagging, installing, verifying, pushing as EricIshekwene and cleaning only its own worktrees. Use when Eric says ship it, merge, install or finish a DJ Queue session.
---

# DJ Queue complete

Ship an existing result; add no scope. Rules and the exact Ship steps are in [djq.md](../djq-daddy/references/djq.md).

1. **Reconcile:** read SESSION and the reviews. Every requirement needs a PASS review on its branch's current tip and green checks. A commit made after review gets a focused fresh review first. Check the controller lock (take it if it's free or stale) and make sure no other writer is active in the branches being merged.
2. **Integrate:** in `~/code/dj-queue` on `main`, merge each task branch with `--no-ff` in dependency order. Resolve routine conflicts by the spec and the current code, never by dropping newer behaviour from `main`. A material conflict gets a targeted re-review.
3. **Ship:** run Ship steps 1–8 from djq.md (8: README media, committed and pushed). If verification fails, stop: keep the backup, don't push, mark NEEDS_FIX and report it.
4. **Clean:** only after the push is confirmed, remove the worktrees and branches this session recorded, if they're merged and clean (`git worktree remove <literal path>`, `git branch -d`). Delete scratch DJQ_HOME dirs and DB copies the session created. Keep the real-DB backups. Never force-remove dirty work or touch other sessions' branches.
5. **Record:** SESSION gets the shipped SHA, tag, GitHub confirmation, cleanup and any leftovers. Mark it COMPLETE, then remove the lock.

Report: the version installed, a link to the commit on GitHub, decisions to review, and what Eric should try by hand.
