---
name: djq-daddy-continue
description: Resume a DJ Queue djq-daddy (or older daddy-v1 dj-queue) session from its SESSION/HANDOFF, reconcile branches, worktrees and the controller lock, and carry on to shipping. Use when Eric says continue/resume a DJ Queue session or pastes a /djq-daddy-continue line.
---

# DJ Queue continue

Resume the identified session under [djq-daddy](../djq-daddy/SKILL.md) and [djq.md](../djq-daddy/references/djq.md). Continuing authorizes the session's existing scope, including its ship step, but no new scope.

1. **Find it:** use the supplied SESSION path. Otherwise use the newest `~/.agent-sessions/daddy/dj-queue-*` folder in HANDOFF or ACTIVE state; ask only if two are plausible. Read SESSION, HANDOFF, reviews and the staged list.
2. **Reconcile:** `git -C ~/code/dj-queue status -sb`, `git worktree list`, each branch's tip against what SESSION recorded, dirty files in each worktree, and tags on `main`. Make sure the previous controller and its children have stopped (no live background jobs from it; the lock says HANDOFF or STOPPED, or belongs to this session). Never run two controllers.
3. **Take over:** write the lock with this thread, record the ownership transfer in SESSION, and adopt older `daddy-v1` records by adding the missing fields without rewriting history.
4. **Keep what's valid:** a passed review or check stays valid only while its branch and candidate are unchanged. Re-run only checks affected by new commits.
5. **Act:** do the recorded next action. Reuse the implementation owner's branch; start a fresh reviewer for any unreviewed commits. Carry on through review to the Ship steps, unless the session was only staged.

Give Eric a short resume note, which is the state and what runs next, then work.
