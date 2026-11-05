# DJ Queue round 13 — decisions

Routine decisions made while building, one line each with the why. The spec's own decisions stand; these are the ones it
left open, or where it needed a safer reading.

## Part A: the Queue is the last step

### Review corrections

- **The Placer is keyed by plan day, not the local posting day.** With 3 a day and a 180-minute offset, position 2 crosses midnight; the old key made a later pass see the wrong day as free, and two clips landed on one minute. Auto-fill makes later passes routine. `reflow`, `push`, `makeRoom` and `closeGap` use the same key.
- **A partial undo leaves the plan alone.** Restoring only the plan put live posts on a held clip. The batch stays open for a forced undo, and `publish()` also refuses a held clip on its own.
- **A bulk batch refreshes its clips before the journal's after snapshot,** so a batch that invalidates a Queue clip records clearing the flag and its undo brings the clip back, while a later limit change doesn't.
- **`isOpen` applies the lead on every day,** not only today: at 23:50 a slot at 00:10 is inside it too. A slot that still ends up with no posts is deleted.

### Reversal of round 4

1. **Round 4's "stage = readiness" is reversed.** A clip that became valid used to move Edit → Queue by itself. With the Queue now meaning "approved, post it", that would post clips Eric never sent (it happened on 2026-11-05 from an editor save). Only Send to Queue moves a clip there.
2. **`sent_to_queue` is a new positive flag, not a repurposed `held_in_edit`.** Held means "sent back, shows a chip"; unsent is the normal state of an Edit clip and shows no issue, so "1 to fix" never appears on a clip with nothing to fix.
3. **`makeReadyWithDefaults` is a door.** Edit's bulk button reads "Send to Queue with defaults" and its dialog "Send N clips to the Queue?", so it stays a send and now clears a hold too, like the other doors.
4. **Correction of the spec's literal migration rule: a `ready` clip counts as sent only with proof.** That means a score and a "Sent to Queue" event with no later "Sent back to Edit from Queue"; planned, posting, posted and partial stay sent. The literal rule marked every `ready` clip sent, which on the real data would have scheduled `awuke x nack` and `coachella x organise`, the very clips Eric named, for real on Postiz. Without proof a clip waits in Edit, which fails safe. Stored states don't change in the migration; such a clip recomputes to `needs_edit` next time.
5. **The flag is cleared in `refreshState` whenever a sent clip computes to Edit, not only on the Queue → Edit move.** One rule keeps "sent and in Edit" impossible, including after an undo restores a flag onto a clip that's invalid.
6. **The column is added before the v6 step, the version written after it.** The v6 migration journals clip snapshots, which read the flag; a v5 database would otherwise fail, or its journal would disagree with the migrated flag.
7. **A sent flag going on → off doesn't block an undo; off → on does, and undo restores the flag only if that batch changed it.** A later send is Eric's work; a limit or a missing file that took a clip out since still stands, because only Send to Queue reverses that. Journals from before the flag neither compare nor restore it.
8. **A settings batch records the clips it pushed to Edit,** so undoing a limit change brings them back to the Queue instead of leaving them unsent.
9. **A clip pinned in a draft week before this round is adopted even if unsent.** The pin was Eric's own choice and the pinned-not-ready rule is unchanged; it can't happen for new pins (`readyVideo` refuses unsent clips).

### Auto-schedule

10. **The horizon includes today + 30**, so 31 days can fill: "from today to today + horizon" read literally.
11. **In auto paths a clip with history on a platform skips that platform; it pulls no other clip.** With no review step, one pull shifts that platform off by one clip for the rest of the calendar, with posts under another clip's card, and Back to Edit on one clip would quietly drop another's post. The cost is a gap on that platform that day. `PlatformPicker` stays for sort overrides, and explicit moves keep their behaviour.
12. **A clip usable on no active platform takes no day, and doesn't count as waiting.** It would hold a day and post nothing, and counting it could hide "Queue running low". The report says why and Doctor has an info finding, `plan.nowhereToPost`.
13. **A day never goes past posts/day, even when a position is free.** After lowering posts/day a pinned slot can sit above the range; filling position 0 beside it would post twice that day.
14. **No active platform: nothing is scheduled.** Slots with no posts would never get them.
15. **A draft slot on today inside the lead: unpinned goes back to the Queue; pinned keeps only the platforms still ahead, and goes back to the Queue with its pin removed when none are.** "Never a post inside the lead" is absolute, and a slot with no posts in an approved week would be stuck on Scheduled for good (same reasoning as round 6's F5).
16. **`pin` and `postToday` on today keep their behaviour in an approved week.** They act on the clip Eric chose, so the lead doesn't apply. A swap (`move` onto a full day, `swap`, `skipNext`) puts a clip he didn't touch on that slot, so inside the lead it's refused: "Today's slot is too soon". Re-creating only the platforms still ahead would silently split that clip's day.
17. **The stale-draft drop also runs inside `autoSchedule`,** so `djq schedule` on a copy behaves like a tick.
18. **`autoSchedule` doesn't top up existing slots.** A platform turned on later gets posts on new clips only; topping up would re-create what was deliberately removed and break "no churn".

### Relay

19. **The signature is a canonical string,** because a Swift dictionary encodes in hash order and would look changed at random.
20. **The relay also leaves alone** posts in `due`/`overdue`, handed to the Calendar, published by Postiz, with a job that ended Postiz delivery for good (vanished, rejected, `--not-in-postiz`: a new post id would forget the promise), or with a job that isn't `live` (`creating`, unconfirmed, `deleting`). Spec's "live post ≥ 60 min away" also checks the job's `remoteDate`. Each of these could be going out or be with Eric right now.
21. **A relay always clears and re-creates, even for a clip that lands on the same day.** Skipping those needs a dry layout first; a relay is rare and the lineage guards make the extra Postiz calls safe.

### Stages, undo, alerts, Doctor, djq

22. **`planConflict` treats only unpinned new slots and regular posts as derived.** A pin, a retry or a repost after the batch is Eric's or the engine's real work, so it still conflicts.
23. **`requeue` and make-ready journal the plan,** so undoing a send also takes back the day the scheduler gave it; otherwise an undone clip would stay on the calendar with live posts.
24. **"Queue running low" needs both few scheduled days and less than a day's worth waiting (`Runway.isLow`),** shared by the notification, Doctor and the app. While paused the calendar drains with a full Queue, and that isn't low.
25. **The runway counts from tomorrow when today has no slot.** A clip queued at 9 pm can't take today, and "0 days" would be false with a month scheduled. `Runway.scheduledThrough` is new; the existing initializer still works.
26. **`plan.gaps` lists at most as many open positions as there are clips waiting,** and stays quiet while paused.
27. **`djq bulk add-to-week` is gone from the CLI as well as its help;** `BulkActions.addToWeek` stays until the app stops calling it.
28. **`djq week --json` keeps `state` and `approved_at`:** they're internal fields agents read, not words aimed at Eric.
29. **`remove-slot` stays and its help says the clip gets a day again;** `djq stage <video> back` is what holds a clip. A Queue clip is approved, so taking only its slot can't stick.
