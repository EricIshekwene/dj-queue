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

## CLI (agent/r6-cli)

1. **Doctor's Postiz checks live in `Doctor.swift`, not core's `PostizDoctor.findings`.** The brief fixes severities that differ from core's (stuck and channel_disabled are errors, link_missing a warning) and adds rate_limited, fallback and test_mode; one implementation in the file Doctor owns avoids two diverging lists. Core's `PostizDoctor` is unused now (see CLI-NEEDS). They pass as one group, `postiz`.
2. **Every platform Manual → one info, "Postiz not in use", and no Keychain question.** That's Eric's installed state today, so Doctor stays clean and no `security` process runs (tests never touch the Keychain either).
3. **`postiz.mapping_missing` is a warning, an error when that platform has posts in the next 48 h** (they'll go to Today). A mapped channel that vanished from Postiz's list counts as missing.
4. **`postiz.delete_pending` kept** (core's id): a post DJ Queue can't remove from Postiz after 3 tries is worth a warning.
5. **`postiz.fallback` looks 7 days ahead** and gives each post's reason: Postiz refused it, it was deleted in Postiz, a test-run TikTok in the inbox, or the route's reason (no key, no channel, disabled).
6. **`djq doctor --live` is one `GET /integrations`, only when a key is saved.** It refreshes the channel cache and the key flag; a refused key shows as key_invalid at once, no answer as a not_connected warning. Plain `doctor` stays offline and read-only.
7. **Settings changes go through `BulkActions.record(settings: true)`** (undo with `djq bulk undo <batch>`) and log one "Settings → Publishing changed from djq" event.
8. **`--yes` is needed only when a change makes approved posts go out for real**: a platform to Postiz with a channel, a new channel on a Postiz platform, or test run off, for enabled platforms. Mapping while Manual, test run on and back to Manual never need it. Without it nothing changes and the exit code is 1.
9. **`djq postiz test` never schedules real posts, even with `--yes`.** A real test post would bypass DJ Queue's tracking (no job, no link back, double-post risk with the week); real posts go out only from an approved week. No flag → refused, pick `--dry-run` or `--draft`.
10. **`status` makes one live check when a key is saved.** Exit 0 only when connected and all six channels are mapped to current, enabled channels; otherwise 2 with the reasons listed (3 with `--offline`, see 20). Without a key no call is made (no budget slot spent).
11. **Channel ids appear only with `--ids`**, also in `test` bodies (`<channel id>`), so output pasted into chat or Notion carries names and providers only.
12. **Auto-map uses exact provider identifiers** and keeps a mapping that is still valid. Two channels with the same provider (a second account) or none are left for Eric with a hint; `map <platform> "<name>"` picks by name and refuses a channel of another platform (e.g. Instagram-via-Facebook for Instagram is allowed with a note, X for Instagram is refused).
13. **A failed live channel list falls back to the cached one with a note** (map and channels), so offline work and dry runs still show what would change.
14. **Caption limits are cached a day per channel** (kv `postiz.captionLimits`) and fetched only for channels of DJ platforms: six calls once, not every `djq postiz channels`.
15. **`postiz sync` doesn't race the app's engine**: when DJ Queue holds the engine lock it sets the sync-now flag and posts ChangeSignal (as `djq tick` does); `--force` syncs here.
16. **Added `djq postiz release <post> --yes`** for releasing a test-run draft (core's `releaseDraft`), guarded like the other real-post switches.
17. **The CLI tests run the built `djq`** against a throwaway file database with `DJQ_POSTIZ_OFFLINE=1`; it is found next to the test bundle (so `--scratch-path` works).
18. **Two small `PostizService` helpers (`captionLimits`, `requestSync`) sit in `Doctor.swift`**: the CLI module can't reach the service's internal budgeted call path, and Doctor.swift is the core file this branch owns. Core may move them.
19. **`djq bulk undo` checks Postiz going live** (review M1): the undo runs in a savepoint, Settings → Publishing before and after are compared with the same go-live rule, and it's rolled back with exit 2 unless `--yes`. The core-level guard in `BulkActions.undo` is core's.
20. **`status --offline` exits 3, never 0** (review L6): without a check, "ready" can't be claimed.
21. **`DJQ_NO_SIGNAL=1` turns off the CLI's ChangeSignal** (review L5), so tests that run `djq` never make the installed app reload or tick.
