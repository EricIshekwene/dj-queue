# DJ Queue round 8 — decisions

Routine decisions made while building, one line each with the why.

## Temporary failures retry by themselves

A post failed in Postiz with "YouTube's daily upload quota is exhausted for today, please reschedule this post for a
later time." and sat as Failed waiting for a manual Fixed. There is nothing for Eric to fix in a temporary platform
limit, so DJ Queue now does what Fixed would have done. It stays loud and bounded, so a wrong guess costs one or two
extra attempts, never a silent loop or a double post.

1. **Classified on clear wording only (`PostizService.isTemporary`).** An unclear message stays a normal failure: a wrong "normal" costs Eric one click, a wrong "temporary" hides a real problem for two days. `quota` is matched as a word, so "quotation" doesn't count.
2. **Copyright wins inside `isTemporary` itself,** so no caller can get it wrong. A copyright job on the clip + platform also blocks later retries (even after Re-upload anyway): "never for copyright" read strictly.
3. **No new error type; the classification is re-read from the job's stored error.** It needs no schema change, and every older build still reads the post.
4. **The note goes into the post's `errorMessage`,** which every screen and the alert already show, so no UI change. `displayState` now prefers that message over the job's raw error. Past the cap the note says "automatic retries used up, mark Fixed when it's ready".
5. **The `retry` step runs right after `alerts`, and only for a post whose alert went out.** A retried post leaves `problems()`, so re-queueing first would lose the alert. After `alerts` also gives it this tick's render and publish steps.
6. **Re-queued at once, not tomorrow.** `newAttempt` schedules the next day from today, so the step acts as soon as the alert is out. The Failed row stays, with resolution "retried".
7. **The cap is per clip + platform + version, kept in kv.** It outlives posts. The version, not `PostizJob.lineage`, is in the key because `fixed` turns a repost into a `.retry`, which changes its lineage and would have allowed a third retry. It is a lifetime cap: Eric's Fixed doesn't reset it.
8. **Waiting versus never.** Held clip, platform off Postiz and an open job are re-read every tick: the post stays Failed and retries if they clear. Published, copyright, skipped and removed never retry. A platform skipped in the editor counts as skipped.
9. **The double-post guard looks at the whole clip + platform, not one lineage.** Stricter than the claim, and required because a retry of a repost lands on the main lineage. So a repost of a clip Postiz published stays Failed for Eric.
10. **`fixed` is now one transaction,** so Eric's Fixed and the retry step can't both pass its "not handled yet" check. The step re-reads the post inside `BEGIN IMMEDIATE`; the event and the count are in the same transaction, so they happen exactly once.
11. **A retry of a test run stays a test run, by attempt id (kv), forced in `submit`.** It was cleanly possible, so test jobs do retry. The id is stable: the planner only re-creates regular posts, and a replace keeps the post. Written in the same transaction as the attempt, so the publish step can't see it unmarked.
12. **Eric's own Fixed on a failed test-run post follows the Test run switch,** as before. Only the automatic path is forced: Fixed is a decision, and otherwise a post could never leave test mode.
13. **Failures already sitting Failed at install qualify too,** because classification reads stored errors. Postiz has only been live for days, and these are the failures this round is for.
14. **Only `ERROR` from Postiz counts.** A 429 on our own calls already pauses and resumes; a 400 on create still goes to Today.
15. **Open follow-up, not changed here: a manual Fixed on a failed repost of a clip Postiz published never reaches Postiz.** `fixed` makes a `.retry`, which sits on the main lineage, so the publish step records it as posted with the original's link (reproduced with the fake transport). It predates this round; decision 9 keeps the automatic path out of it.
