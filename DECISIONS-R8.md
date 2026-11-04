# DJ Queue round 8 — decisions

Routine decisions made while building, one line each with the why.

## Temporary failures retry by themselves

A post failed in Postiz with "YouTube's daily upload quota is exhausted for today, please reschedule this post for a
later time." and sat as Failed waiting for a manual Fixed. There is nothing for Eric to fix in a temporary platform
limit, so DJ Queue now does what Fixed would have done. It stays loud and bounded, so a wrong guess costs one or two
extra attempts, never a silent loop or a double post.

1. **Classified on clear wording only (`PostizService.isTemporary`).** An unclear message stays a normal failure: a wrong "normal" costs Eric one click, a wrong "temporary" hides a real problem for two days. Phrases match on word boundaries, so "quotation" and "moderate limit" don't count. A veto word anywhere beats a temporary word, because re-posting a flagged clip risks a strike on the account.
2. **Copyright wins inside `isTemporary` itself,** so no caller can get it wrong. `isCopyright` keeps its five words: widening it changes what gets `copyright_blocked`, so the veto words stay plain Failed, with no retry. A copyright job on the clip + platform also blocks later retries (even after Re-upload anyway): "never for copyright" read strictly.
3. **No new error type; the classification is re-read from the job's stored error.** It needs no schema change, and every older build still reads the post.
4. **The note goes into the post's `errorMessage`,** which every screen and the alert already show, so no UI change. `displayState` now prefers that message over the job's raw error. Past the cap the note says "automatic retries used up, mark Fixed when it's ready". The note promises a retry only when nothing permanent rules one out; those posts get "no automatic retry for this one, mark Fixed when it's ready". Reasons to wait keep the promise.
5. **The `retry` step runs right after `alerts`, and only for a post whose alert went out.** A retried post leaves `problems()`, so re-queueing first would lose the alert. After `alerts` also gives it this tick's render and publish steps.
6. **Re-queued at once, not tomorrow.** `newAttempt` schedules the next day from today, so the step acts as soon as the alert is out. The Failed row stays, with resolution "retried".
7. **The cap is per clip + platform + version, kept in kv.** It outlives posts, and a repost counts apart from the clip's regular post. It is a lifetime cap: Eric's Fixed doesn't reset it.
8. **Waiting versus never.** Held clip, platform off Postiz and an open job are re-read every tick: the post stays Failed and retries if they clear. Published, copyright, skipped and removed never retry. A platform skipped in the editor counts as skipped.
9. **The double-post guard looks at the whole clip + platform, not one lineage.** Stricter than the claim, as asked: no new attempt while any job of the clip + platform is open or published. So a repost of a clip Postiz published stays Failed for Eric, whose Fixed sends it (decision 15).
10. **`fixed` is now one transaction,** so Eric's Fixed and the retry step can't both pass its "not handled yet" check. The step re-reads the post inside `BEGIN IMMEDIATE`; the event and the count are in the same transaction, so they happen exactly once.
11. **A retry of a test run stays a test run, by attempt id (kv), forced in `submit`.** It was cleanly possible, so test jobs do retry. The id is stable: the planner only re-creates regular posts, and a replace keeps the post. Written in the same transaction as the attempt, so the publish step can't see it unmarked.
12. **Eric's own Fixed on a failed test-run post follows the Test run switch,** as before. Only the automatic path is forced: Fixed is a decision, and otherwise a post could never leave test mode.
13. **Failures already sitting Failed at install qualify too,** because classification reads stored errors. Postiz has only been live for days, and these are the failures this round is for.
14. **Only `ERROR` from Postiz counts.** A 429 on our own calls already pauses and resumes; a 400 on create still goes to Today.
15. **An attempt at a repost stays a repost (`newAttempt`).** A manual Fixed on a failed repost of a clip Postiz published used to make a `.retry`, which sits on the main lineage, so the publish step recorded it as posted with the original's link and nothing was sent. Keeping the kind keeps its own lineage (`#v<N>`): it gets its own job, and only that job can mark it posted. It also stays out of the `kind IN ('regular','retry')` checks that decide whether the clip itself has posted. A repost fixed before this shipped keeps its wrong row. `newAttempt` is shared, so a manual repost's Fixed is a `.repost` too; only the label changes, and it leaves the same `kind IN` checks, which is more correct.
16. **Reset forgets the post's alert.** The key is once-only per post id and a reset keeps the id, so a later failure would have retried with no alert of its own.
17. **Re-upload anyway refuses a version already posted on that platform.** A repost attempt now really sends, so an older published version would be a double post.
