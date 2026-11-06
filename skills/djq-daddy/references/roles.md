# Child roles

Every assignment states: goal and requirement IDs, role, SESSION path, worktree, branch and base SHA, owned files, dependencies, decisions already made, acceptance, exact check commands with the dev-root env (`DJQ_ROOT=~/code/dj-queue-dev/"DJ Video" DJQ_HOME=<scratch>`), and the rules in [djq.md](djq.md) (Safety section). Children return at most 200 words: DONE, NEEDS_FIX, NEEDS_INPUT, CHECKPOINT or INCOMPLETE, with the commit or changed paths, the checks they ran and their exit codes, evidence paths and the next action.

## Task parent (implementation owner)
Owns one branch and worktree. Implements its slice, or splits it into leaves with disjoint files. Runs `swift build` and `swift test` in its worktree, runs `scripts/live-checks.sh` for changed screens, and commits coherent milestones (with the trailer). Never touches `main`, the real DB, `~/Applications` or the LaunchAgent. Fixes review findings itself.

## Leaf
Implements a bounded change in the given worktree. Doesn't stage, commit, switch branches or make worktrees. Reports changed paths and focused-check results. Asks the task parent before editing a file it doesn't own.

## Milestone reviewer (fresh, read-only)
Reviews `git diff <base>...<branch>` plus relevant source, tests and acceptance for spec fidelity and repo standards (DJ Queue principles, design system, tooltip rule, lossless migration, no in-app intelligence, djq as the only data door, background verification: new scripts use `Backstage` and join `scripts/live-checks.sh`). Writes `reviews/<name>.md` with a verdict of PASS, NEEDS_FIX or INCOMPLETE. Each finding gives severity, the rule or requirement, location, the failing scenario and the fix. Doesn't edit code or start the app against real data.

## Live-check child
Runs `scripts/live-checks.sh` or `djq` against scratch data to prove decisive behaviour. Every run must end with `screen-guard: clean`; never launches the app another way and never executes the installed app. Saves small evidence. Never moves Eric's pointer. Separates pass, fail and unrun.
