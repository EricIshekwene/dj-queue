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
7. **`PostizLive.disabled` kill switch.** Tests (Fixture) and `DJQ_POSTIZ_OFFLINE=1` turn off the real transport and the real `/usr/bin/security`; injected fakes are unaffected, so no test can reach Postiz or the Keychain even by accident.
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

## UI (agent/r6-ui)

Mobbin references (viewed 2026-11-03): Meetup "Mailchimp sync" (status chip + one action; dependent controls wait for
the connection) https://mobbin.com/screens/9a6077fe-c60a-4d32-8ce4-743766568e57 · Unify Integrations (one row per
integration, "● Connected") https://mobbin.com/screens/6717566f-1d46-4fb0-8432-8f7554342584 · Mintlify agent settings
(Connected chip + Disconnect) https://mobbin.com/screens/d0da4f87-9b9f-4786-85ce-d3d7b1dcf0ce · Buffer queue (a failed
post is a loud bar above the post with its message) https://mobbin.com/screens/af871c1d-00d1-4c74-a4a4-87ae2e9455c8 ·
Customer.io Deliveries (a quiet "Test mode" chip on every affected row next to its status)
https://mobbin.com/screens/c2bc5440-c6ca-4dd4-bfd2-ec70a26039c5.

1. **Publishing is its own Settings section, right after Platforms.** The connection, six platform rows with details and Test run don't fit under Platforms' rows and limits table in a 560 pt modal, and core's fallback sentences already say "Settings → Publishing". Platforms keeps a one-line "Who posts" summary with "Open Publishing".
2. **Manual | Postiz is a two-segment control, not a menu.** Two options read at a glance; the Postiz segment is dimmed with its reason on hover (no key, key refused, no channel) — native menus can't show why an item is off. `DSSegment` gained `disabledReason` (stays hoverable, like `DSChip`).
3. **One row per platform; the channel and options sit in a ⌄ detail.** The row says who posts it and through which channel ("Postiz · DJ Lovd · tiktok-business"); a disabled channel is a red "Channel disabled" chip, any other fallback an amber "Goes to Today" chip with core's sentence as its tooltip.
4. **"Match channels" (auto-map) only fills platforms without a usable channel**, picking the first enabled channel of the platform's provider (or the only one even if disabled, so the row says why). Undoable like every setting.
5. **The key field is a `DSTextField(isSecure:)` with Save (the pane's one primary).** Once saved: "Saved in Keychain · never shown here" with Replace / Remove; Remove asks first (it can't be undone from the app). Saving runs Check connection at once.
6. **Test run sits in the Postiz group (not at the bottom)** because it changes what every Postiz post does; the sidebar footer shows a quiet "Test run · On" row while it's on (click → Settings → Publishing). A header badge truncated "DJ Queue".
7. **Snapshots and dev runs never touch the Keychain or the network.** `--snapshot` uses an in-memory key store (shots set the key's presence) and `DJQ_FAKE_POSTIZ=1` an in-memory key plus a sample transport answering `is-connected` / `integrations` with six made-up channels. Run dev builds with `DJQ_POSTIZ_OFFLINE=1` too, so the in-process engine's live store stays off.
8. **Snapshots get a third model (`SnapshotContext.postiz`)**: a copy of the seeded sample with Postiz on for five platforms (Facebook Manual, Threads' channel disabled). Existing shots keep their all-Manual look; `r6-*` shots show Postiz.
9. **Limits: TikTok's title (90) is editable next to YouTube's (100)**, since core made it a real default; the other platforms still show "—".
