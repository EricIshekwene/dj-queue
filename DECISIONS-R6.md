# DJ Queue round 6 — decisions (Postiz publisher)

Routine decisions made while building, one line each with the why. Session-level decisions (one request per platform
post, API key in the Keychain, 25 calls/hour, replace instead of edit, reconcile in the tick, no per-clip overrides,
Facebook keeps 90 s, one v0.7.0 ship) are in the session record and docs/postiz.md.

## Core (agent/r6-core)

1. **Settings → `publishing` decodes field by field and never fails.** Each field falls back to its own default (string-keyed maps, unknown platforms/values dropped), so a hand-edited or older row can never send Eric's whole Settings back to defaults.
2. **Limits carry a revision (`Settings.limitsRevision`, 2).** A row without it is revision 1: a field moves to the new default only when it still equals the old default (TikTok caption 4000 → 2200, TikTok title — → 90, Instagram 4 GB → 300 MB); Eric's own values stay, and once saved at revision 2 an explicit 4000 is never "migrated" again. Migration is in memory until the next save.
3. **TikTok title limit 90 is a real `PlatformLimits` default now.** It only feeds the Postiz payload and the title notice; nothing else read TikTok's `titleLimit` before.
4. **Long YouTube/TikTok titles: a non-blocking notice, not a new blocking issue kind.** `Validation.titleChecks` / `TitleCheck` says when the template title had to be shortened (the editor shows it); the payload clamps at 100 / 90. A new blocking kind would move Queue/Scheduled clips to Edit at install. An explicit YouTube title over the limit still blocks (`.titleTooLong`), as before.
5. **F5: past draft-week days with no posts are dropped, pinned ones too.** A pin on a day that passed without approval can't post, and keeping it hides the clip from the Queue for good; approved weeks and slots with any post are never touched. `Queue.ordered()` ignores such slots even before the plan step deletes them.
6. **Key save through `security -i` with the command on stdin.** The key never appears in a process argument list; the item is created by `/usr/bin/security`, which therefore stays trusted, so reads after every rebuild don't prompt. The key must be one token (letters, digits, `-_.:+/=`), which also keeps the `security -i` line unambiguous.
7. **`PostizLive.disabled` kill switch, and no test ever holds the real Keychain store.** Tests (Fixture) and `DJQ_POSTIZ_OFFLINE=1` turn off the real transport and the real `/usr/bin/security`; every test injects a fake transport and a recording `security` runner (M1 review #2), so nothing in `swift test` can reach Postiz or Eric's Keychain item.
8. **One open job per post is a unique partial index** (`post_id` where `closed_at IS NULL`). A job being replaced stays open (`deleting`) until Postiz answered OK/404, so "no create after a failed delete" holds structurally, across processes.
9. **Final vs non-final close reasons.** Published, inbox, error, copyright, vanished and rejected end Postiz delivery for that post (never resubmitted by itself); replaced, cancelled and interrupted don't. `PostActions.reset` releases error/rejected/vanished/interrupted only — never published/inbox/copyright.
10. **The engine gets Postiz by default.** `Engine.init` builds a live `PostizService` when none is passed, so the app and `djq tick` need no code change; with every platform on Manual (the default) it reads no Keychain and makes no call.
11. **No manual "due" notification for a post Postiz will deliver** — one with an open job, or routed to Postiz with no final job (its render may land after the slot and it's submitted then). The router's fallback reasons (no key, bad key, no/disabled channel) still notify as Manual.
12. **Budget reserves.** Creates leave one call per hour for sync; analytics leaves eight. Uploads count as calls (a create needs up to three).
13. **403 counts as "key refused"** (wrong organization means the key doesn't belong to this Postiz).
14. **An interrupted create** (network/5xx after the create was sent) keeps its claim; the sync step adopts the Postiz post with the same channel and date, or releases the claim after 10 minutes. Errors before the create was sent release it at once.
15. **YouTube `tags` as `[{value, label}]` and `thumbnail` as `{id, path}`**, the Postiz DTO shapes (not seen live; a 400 would fall back to Today with Postiz's message).
16. **Test-mode TikTok PUBLISHED closes the job as "inbox"** and the post goes back to Manual with a notification ("finish it in the app, then Mark posted"); it is never resubmitted.
17. **A cancelled job sets the post's `publisher` back to "manual"**; the `publisher` column always says who delivers the post now.
18. **Marked posted by hand while Postiz still holds it → the Postiz copy is deleted** (unless Postiz already published it), so it never posts twice.
19. **A delete close to (or after) the slot waits for fresh states.** If the slot is < 5 min away and the last sync is older than 90 s, the publish step asks the sync step (same tick) to look first; a post Postiz already published is then recorded, never deleted.
20. **Approving a week mid-week drops its passed draft days first** (M1 review #9), the same rule as the plan step, so their clips never read "Scheduled" in an approved week without posts.
21. **Transport hardening (M1 review #7):** `apiBase` must be https (otherwise the cloud base is used), redirects are never followed (the key would follow them), stale upload temp files are swept, and `hourlyBudget` is at least 10 so the reserves can't starve creates.
22. **Keychain read: only exit 44 means "no key"** (M1 review #8); a locked or refused Keychain is an error, so Eric isn't told to re-paste a key that is fine.
23. **`final` is written only when a job closes or is released** (M1 review #4), so a later save of the row never undoes a reset.
24. **A wrong-typed top-level `publishing` or `limitsRevision` is dropped before decoding** (M1 review #5): that field takes its default, everything else in Settings is kept.
25. **Doctor checks live in core as `PostizDoctor.findings(store:keyStore:)`** (no network); the CLI owner adds them to `Doctor.run()` because `Doctor.swift` belongs to that branch.
26. **`djq postiz test --draft` records** are `kind = "test"` rows, closed at once (`test_draft`); reconciliation never touches them.
27. **Analytics parsing:** a never-decreasing series reads as cumulative (last value), anything else as daily counts (sum); an unknown shape stores nothing and is logged once.
28. **The reconcile loop decides from the database every tick** (no hooks in planner paths): every path that removes, moves or re-states a post (planner remove/unplan/move/swap/push/rebuild/skip-next, reflow from missed, skip/reset/fixed/repost, bulk unqueue + undo, revalidation, settings) is covered by a test plus a seeded fuzz with failing deletes and creates.
