# DJ Queue round 9 — decisions

Routine decisions made while building, one line each with the why.

## Failed posts retry by themselves

"Based on a video failing on a particular platform we should be retrying to send that video automatically and I shouldn't
ever be needing to audit that." Round 8 retried only an explicit quota or rate limit, the next day, twice, and a failure
stayed a Problem with an alert. Now a failure retries unless a retry can't help, on a stored time, with its attempt in
Postiz ahead of that time, and it isn't a Problem while a retry is coming. These replace DECISIONS-R8 #1, #4, #5, #6, #7's
cap and #13's scope; the rest of R8 stands, the double-post guards above all.

1. **The default flips (`retriesByItself`).** A failure that a retry can't fix is the exception, so the veto list is what's written down: R8's policy, account and paid-limit words, plus too long, too large, format, validation and sign-in. A wrong "retry" costs at most 5 attempts of a post that fails again; a wrong "veto" costs one Fixed.
2. **`isTemporary` is gone.** Nothing reads "temporary" any more; `isVetoed` is the one test.
3. **"Duplicate" and "already posted" are vetoes, though the brief doesn't list them.** A platform saying it has the post is the one failure where a retry could double-post.
4. **Codes count as words.** `duration_check_failed` and `spam_risk_too_many_posts` are how TikTok speaks, and `\b` doesn't split on `_`, so `_` reads as a space.
5. **A veto word beats a quota word, as in R8.** "Your storage quota is full" and "Video too large, quota" don't retry.
6. **Tries are retries.** The brief's table has five delays and "cap 5", so try 1 of 5 is the first retry after the failure, and the original post isn't counted. The R8 count in kv carries over.
7. **"Next morning" is 8:00 am in Settings' time zone, at least an hour after the failure.** The brief names no hour; 8:00 matches the quota rule, and the hour stops a failure at 7:59 from retrying at 8:00.
8. **Quota retries follow the first reset after the failure, not the next 8:00.** A failure at 7:00 am New York is after that day's reset, so 8:00 that day would hit the same empty quota and burn a try. The brief's "next one after the failure" reads both ways; its first sentence (skip to the next reset) decides it.
9. **Only YouTube has a known reset.** Other platforms' rate limits use the ordinary backoff. New York and Pacific are fixed in the code: the quota doesn't follow Settings.
10. **`+1 day` is a calendar day; +1 h and +6 h are hours.** A 25-hour day stays the same clock time, and "6 hours" stays 6 hours.
11. **The failure time is the job's `remoteDate`, capped at now.** Postiz gives no failure timestamp, and the job's time is when it tried. `closedAt` is when the Mac noticed, which is what the brief rules out.
12. **The gap ignores posts that went nowhere.** `Sched.staggered` counts failed posts. A retry at +1 h would then always be pushed from its own failure to +3 h, so `retrySlot` counts only posts that went out or still will.
13. **A quota retry moves earlier when 8:00 is taken, down to the reset, then later.** "Never a late slot", and the day's quota goes as the day goes. Everything else moves later.
14. **The attempt is made inside the `errored` transaction.** The failure, its stored time and its attempt exist together, so no tick sees a failed post with nothing coming. The `retry` step stays for what waited and for failures an older build left.
15. **`errored` re-reads the job inside its transaction.** The post's state already stops a second attempt; this stops a second process's second log line, and the whole step is now one transaction.
16. **A past retry time moves `scheduledAt` to now + 3 min (past the gap), not only the Postiz date.** The screens stay truthful, `missed` has nothing to act on, and the gap holds on wake. If the gap and "right away" collide, the gap wins: the brief says "never".
17. **An automatic attempt is never overdue, and never due by hand while it waits (`isRetryAttempt`).** Without this a Mac asleep over midnight, or a pause, turned the retry into a Missed post for Eric, and the sticky "handed to Today" kept it off Postiz for good. A final job (a 400 on create, deleted in Postiz) ends this: it goes to Today like any post.
18. **The R8 rule that a retry waits for the alert is gone.** There's no alert while a retry is coming, so nothing to wait for. A retry that falls through (ruled out later, tries used up) goes back to Problems with a note and gets its alert then.
19. **`problems()` filters, not each screen.** Alerts, badges, Doctor, `djq status` and `djq posts --problems` all read it, so none can disagree.
20. **The kv record is the promise (`failedPostId`), and it counts only while that post is Failed and unhandled.** So Fixed, skip and reset need no cleanup, and new fields are optional so a v0.8 row still decodes.
21. **Pause and Manual stop the attempt being made, and don't take away one already made.** Failing while paused leaves the failure waiting; pausing after the attempt exists deletes the Postiz copy (the usual rule) and the attempt waits. Both run once on resume.
22. **A retry waiting on Manual isn't a Problem, as the brief says, and Doctor warns.** A platform left on Manual never brings it back, so this is the one quiet wait that could become a silent loss. It stays in Scheduled with the reason, and `postiz.auto_retry` turns to a warning. Worth Eric's look: see the report.
23. **Remove from queue hands the attempt back to its failure.** `unplan` deletes every live post of the clip, so the attempt would be gone and the platform lost. `hold` reverts the failure first, marked `tryUnused`, so Send to queue makes one new attempt and the cap isn't charged for a try that never went out. After Undo the restored attempt stands and nothing more is made.
24. **Scheduled → Queue doesn't do that.** Eric took the clip out of the plan on purpose, and the attempt goes with it. The failed row stays "Re-queued", as it did for a Fixed attempt before.
25. **Fixed once the attempt exists is refused ("Already handled").** The failure is handled by then. Fixed before it (a retry waiting) wins, and that attempt replaces the retry.
26. **A waiting badge is "Retry waits (try 2 of 5)", with the reason on the line under it.** The full sentence pushed the inspector past the window edge; the design rule is a chip, not a sentence. The timed form fits everywhere, so it stays whole as the brief wrote it.
27. **The failed row on Today says what the attempt says, and goes when the attempt is on today's list too.** Otherwise Today read Failed, or said it twice.
28. **A waiting failure shows under Scheduled.** It's terminal, so it would have been in no tab at all.
29. **Doctor checks retries with every platform on Manual too.** It returned early there, the very case it must warn about.
30. **`Sched.staggered` and Fixed's next-day rule are unchanged.** Eric's Fixed is a decision, with its own timing.
31. **The YouTube note reads "no automatic retry: YouTube may already have the video, so check the channel, then mark Fixed".** It's added only to an error that isn't vetoed, because a veto has its own reason.
32. **The inbox guard is untouched.** `retryRuledOut`, `versionIsOut` and `publishedPostizJob` still count a closed `inbox` job, and a test proves it, so post 4ab3180d stays out of every retry.
33. **Failures sitting Failed at install qualify, as in R8.** A copy of the last backup has one failed post, already fixed by Eric, so the wider rule starts nothing at install.
