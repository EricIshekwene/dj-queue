# Session record

Folder: `~/.agent-sessions/daddy/dj-queue-r<N>-<slug>-<YYYY-MM-DD>/` with SESSION.md, HANDOFF.md (when paused), `reviews/<name>.md` and `evidence/`. Screenshots and logs larger than a few KB go under `~/code/dj-queue-dev/evidence/<round>-<name>/` and are linked.

SESSION.md is the compact current state:
- **Identity:** UUID, profile `djq-daddy-v1`, start and update time, goal, finish line, sources, requirement table (ID · requirement · acceptance), exclusions, Eric's amendments.
- **Repo:** base SHA of `main` at start, target version tag, task branches and worktrees, integrated candidate.
- **Controller:** thread or chat name, machine, lock status, ownership transfers.
- **Tree:** node · branch/worktree · owned files · child handle · state · latest commit · review verdict.
- **Checks:** command, candidate SHA, result, evidence path. Unrun checks are listed as unrun.
- **Resources:** dev roots and scratch DJQ_HOME dirs created, DB copies made, background watchdogs (IDs), anything to clean.
- **Decisions** (also in `DECISIONS-R<N>.md`), follow-ups, next action.

States: PLANNED, ACTIVE, WAITING_ON_TASK, NEEDS_INPUT, NEEDS_FIX, HANDOFF, STOPPED, READY_FOR_REVIEW (only when Eric said "stage it"), SHIPPING, PUSH_PENDING, COMPLETE. A child's DONE isn't session acceptance.

HANDOFF.md: goal and sources, current state of every node and branch (commit, dirty or clean), checks passed and pending, resources, decisions, the exact next action, and the line `/djq-daddy-continue <SESSION path>`.

Older sessions (profile `daddy-v1`, for example `dj-queue-r3-fixes-2026-11-02`) can be continued: read their SESSION and HANDOFF, add the missing lock, branch and check fields, and keep their history.
