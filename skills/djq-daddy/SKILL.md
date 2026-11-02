---
name: djq-daddy
description: Run one DJ Queue build session (a round or a single fix in ~/code/dj-queue) from a spec through planning, task branches in worktrees, independent review, and then merge to main, install, tag and push as EricIshekwene. Use when Eric asks for a DJ Queue / DJQ build, round, fix or "/djq-daddy".
---

# DJ Queue Daddy

You are the session parent for one DJ Queue session. You own the outcome: understand the change surface, make routine decisions, run task parents in their own worktrees, integrate their work, and ship. The flow is **plan → implement → milestone review → integrate → ship**. Read [djq.md](references/djq.md) first; its rules are binding. Read [session.md](references/session.md) when creating or resuming the record, and [roles.md](references/roles.md) when delegating.

## Start
1. Read the spec (pasted text, a STAGED-R<N>.md file, a triage PROMPT/BRIEF). Read it whole; give each requirement an ID (`S1-R2`).
2. Check the controller lock and repo state: `~/.agent-sessions/daddy/DJQ-CONTROLLER`, `git -C ~/code/dj-queue status -sb`, `git worktree list`, latest tag. If the spec names a prerequisite (a tag or merged branch), confirm it exists on `main`. If not, stop and report that it isn't met. Planning and reading are still fine.
3. Create the session folder and SESSION.md, and write the lock.
4. Plan read-only: map each requirement to files, contracts, shared consumers (`AppModel`, `DesignSystem`, `SnapshotRunner`, `djq`, Core stage/validation), tests, risk, owner and acceptance. Investigate the riskiest part first.

## Branches and ownership
- One task branch and worktree per task parent: `agent/r<N>-<name>` at `~/code/worktrees/dj-queue/r<N>-<name>`, branched from the current `main`. A small fix may use a single branch owned by the session parent.
- File ownership is disjoint. Shared files go to one owner, or writers take turns. Two writers never edit the same file at once.
- Leaves never stage, commit, switch branches or create worktrees; the task parent commits milestones after writers stop. Subagents can't spawn their own subagents on this host, so the session parent dispatches leaves for task parents and records the logical tree separately.
- Never build in the `~/code/dj-queue` checkout itself. It only receives merges.

## Execute
Give every child its goal, requirement IDs, owned files, worktree and branch, relevant SESSION sections, decisions, exact checks (`swift build`, `swift test`, snapshot command, dev root env) and its return format. Keep corrections with the same implementation owner. Use a [watchdog](../djq-watchdog/SKILL.md) on every child that runs in the background. Continue other ready work while children run.

## Review and verify
- At each milestone, one **fresh, read-only, independent reviewer** checks spec fidelity and repo standards on the actual diff (`git diff main...agent/r<N>-<name>`). Its verdict is written to `<session>/reviews/<name>.md`. Send in-scope defects back to the owner as one batch. Re-review when a fix changes behaviour or risk materially.
- Focused checks during implementation; `swift build` (0 warnings) and `swift test` on each candidate before review, and again on `main` after integration.
- Migrations: prove they're lossless on a copy of the newest real-DB backup.
- UI: take light and dark snapshots for every changed screen and compare them with DESIGN-v2. Hover behaviour Eric must try by hand goes in the report.
- After two materially different fixes fail on the same defect, stop and rethink the approach; a product tradeoff goes to Eric as one batched question while other work continues.

## Ship
When every requirement has passed review and checks, run the **Ship** steps in [djq.md](references/djq.md): merge, test on `main`, back up, tag, install, kickstart, verify, push as EricIshekwene, refresh docs. Eric has authorized pushing `main`, so don't stop for approval unless Eric said "stage it". Then clean up exactly the worktrees and branches this session created (merged, clean ones only), remove the lock, and mark SESSION COMPLETE. [djq-daddy-complete](../djq-daddy-complete/SKILL.md) covers shipping a session that stopped at READY_FOR_REVIEW.

## Context and handoff
Keep SESSION current: state, tree, candidates, check results, decisions, next action. Near 400K tokens of context, or when Eric asks, stop new dispatch, let writers finish, save HANDOFF.md with a paste-ready `/djq-daddy-continue <SESSION path>` line, and update the lock to HANDOFF.

## Report
Children return at most 200 words and artifact paths. The final report to Eric: what shipped (version, commit, GitHub link), decisions to review, anything unverified or for Eric to try by hand.
