# DJ Queue round 7 — decisions

Routine decisions made while building, one line each with the why.

## Postiz (C2)

1. **Debounce lives in `decide()` as a new `.settle` decision.** Only the content-hash branch (caption, title, hashtags, template, Postiz settings) waits; channel, render and move are checked first and stay immediate, and every cancel returns before it — so cancels can never be delayed by a pending edit.
2. **Stable-since is per job, in kv `postiz.settle.<job id>` (`{hash, since}`), not a schema column.** Schema v6 belongs to another owner this round; kv needs no migration, and a stale row is harmless (swept at the start of every publish step, also when Postiz is off, for jobs no longer open).
3. **`since` is stored as seconds since 1970 (Double).** Exact, so the 120 s boundary can't fire early from a rounded JSON date. A `since` in the future (clock stepped back) restarts the clock at now, so the wait never exceeds 120 s.
4. **Any new hash restarts the clock; an edit back to what Postiz has clears it.** Otherwise "edit → revert → same edit again" would replace without waiting.
5. **The safety window wins.** Within 5 min of the slot a content change is `.hold` exactly as before, also when its 120 s already passed; the debounce never extends past the window and never creates anything (the job stays live, so no second copy can be made).
6. **One quiet "waiting for edits to settle" event per job** (`markNotified("postiz.settle:<job id>")`), plus "waiting on edits for N" in the publish summary; no notification.
7. **Delete-retry notices are keyed on job + kind of failure** (`postiz.deleteRetry:<job id>:<kind>`, kind = the `PostizError` case without its message). Budget-exhausted retries every tick are one event; a different failure (e.g. a 500 after the budget frees up) is logged once more. Attempts and `lastError` are still updated every try.
8. **Content edits are effectively frozen from ~7 min before the slot** (120 s settle + 5 min safety window): accepted, because a late edit replacing a post minutes before it goes out is the riskier side; docs/postiz.md says so.
