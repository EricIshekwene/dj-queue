---
name: djq-daddy-triage
description: Split a batch of staged DJ Queue issues (e.g. STAGED-R<N>.md) into djq-daddy sessions with briefs and paste-ready prompts, ordered by file overlap and dependencies. Prepare only; launches nothing. Use when Eric asks to triage a DJ Queue round or turn staged items into session prompts.
---

# DJ Queue triage

Decide **what belongs together and in what order** for a batch of DJ Queue issues. Each session's [djq-daddy](../djq-daddy/SKILL.md) parent does its own detailed planning. Rules in [djq.md](../djq-daddy/references/djq.md) apply. Triage writes files only in its output folder: no code changes, no branches, no sessions launched.

## Steps
1. **Batch:** only the items Eric named (usually `STAGED-R<N>.md` plus any reviews or handoff it points to). Read every item whole. Give it a stable ID and numbered requirements (`S1-R1`), keeping every obligation, exclusion and acceptance point word for word.
2. **Change surface:** read the code at current `main` (record the SHA) to list the likely files, contracts and shared consumers for each item: `AppModel`, `DesignSystem`, cards, `Library/BrowseUI.swift`, Core stage and validation, `djq`, migrations, `SnapshotRunner`, skills. Mark guesses "provisional".
3. **Group:**
   - **Combine** one coupled change (one owner, one acceptance).
   - **Sequence** when one item needs another, or when they would write the same files.
   - **Separate** independent items with disjoint files.

   Shared files alone don't justify combining unrelated work. Two sessions that write the same file never run in the same wave.
4. **Order:** an acyclic list of waves, with a reason for every edge. A dependent session starts only from the prerequisite's shipped result (its tag on `main`), not from a child saying it finished.
5. **State per session:** PREPARED, WAITING_ON_SESSION or NEEDS_INPUT. NEEDS_INPUT is only for a real product choice, and comes with a recommendation. Decide everything else and log why.
6. **Coverage:** every requirement maps to exactly one owning session, plus any session that must re-check it.

## Output
Folder `~/.agent-sessions/daddy/dj-queue-r<N>-triage-<YYYY-MM-DD>/`:
- `TRIAGE.md`: sources, recon SHA, session table (ID · goal · requirements · depends on · wave · state · target version), grouping rationale, edges, files touched by several sessions and their owner, coverage list, decisions.
- `sessions/<ID>-<slug>/BRIEF.md`: goal and finish line, requirements in full, exclusions, provisional files, owned files, prerequisite, proposed milestones, risks and decisive checks.
- `sessions/<ID>-<slug>/PROMPT.txt`: self-contained and paste-ready. It starts with `/djq-daddy`, points at its BRIEF, states the prerequisite check (for example `git -C ~/code/dj-queue tag -l v0.4.0` exists and is on `main`; otherwise stop and say so), the version it ships as, and "ship per djq.md". The rules live in the skill, so prompts don't repeat them.

Report to Eric: the session table, the run order (which threads can run at the same time), and any NEEDS_INPUT questions with recommendations.
