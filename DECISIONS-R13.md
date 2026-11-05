# DJ Queue round 13 — decisions

Routine decisions made while building, one line each with the why. The spec's own decisions stand; these are the ones it
left open, or where it needed a safer reading.

## Part A: the Queue is the last step

### Reversal of round 4

1. **Round 4's "stage = readiness" is reversed.** A clip that became valid used to move Edit → Queue by itself. With the Queue now meaning "approved, post it", that would post clips Eric never sent (it happened on 2026-11-05 from an editor save). Only Send to Queue moves a clip there.
2. **`sent_to_queue` is a new positive flag, not a repurposed `held_in_edit`.** Held means "sent back, shows a chip"; unsent is the normal state of an Edit clip and shows no issue, so "1 to fix" never appears on a clip with nothing to fix.
3. **`makeReadyWithDefaults` is a door.** Edit's bulk button reads "Send to Queue with defaults" and its dialog "Send N clips to the Queue?", so it stays a send and now clears a hold too, like the other doors.
4. **The migration leaves an unscored `ready` clip unsent, which narrows the spec's list by one case.** It's in Score whatever its state says; marking it sent would make scoring it promote it. Stored states don't change; such a clip recomputes to `needs_edit` next time, and its stage stays Score.
5. **The flag is cleared in `refreshState` whenever a sent clip computes to Edit, not only on the Queue → Edit move.** One rule keeps "sent and in Edit" impossible, including after an undo restores a flag onto a clip that's invalid.
6. **The column is added before the v6 step, the version written after it.** The v6 migration journals clip snapshots, which read the flag; a v5 database would otherwise fail, or its journal would disagree with the migrated flag.
7. **A sent flag going on → off doesn't block an undo; off → on does.** The engine clears it when a clip goes invalid (often because of the batch being undone), while a later send is Eric's work. Journals from before the flag neither compare nor restore it.
8. **A settings batch records the clips it pushed to Edit,** so undoing a limit change brings them back to the Queue instead of leaving them unsent.
9. **A clip pinned in a draft week before this round is adopted even if unsent.** The pin was Eric's own choice and the pinned-not-ready rule is unchanged; it can't happen for new pins (`readyVideo` refuses unsent clips).

### Auto-schedule

10. **The horizon includes today + 30**, so 31 days can fill: "from today to today + horizon" read literally.
11. **In auto paths a clip with history on a platform skips that platform; it pulls no other clip.** With no review step, one pull shifts that platform off by one clip for the rest of the calendar, with posts under another clip's card, and Back to Edit on one clip would quietly drop another's post. The cost is a gap on that platform that day. `PlatformPicker` stays for sort overrides, and explicit moves keep their behaviour.
12. **A clip usable on no active platform takes no day.** It would hold a day and post nothing. It waits in the Queue and Doctor's `plan.gaps` doesn't count it.
13. **A day never goes past posts/day, even when a position is free.** After lowering posts/day a pinned slot can sit above the range; filling position 0 beside it would post twice that day.
14. **No active platform: nothing is scheduled.** Slots with no posts would never get them.
15. **A draft slot on today inside the lead: unpinned goes back to the Queue; pinned keeps only the platforms still ahead, and goes back to the Queue with its pin removed when none are.** "Never a post inside the lead" is absolute, and a slot with no posts in an approved week would be stuck on Scheduled for good (same reasoning as round 6's F5).
16. **`pin` and `postToday` on today keep their behaviour in an approved week.** They are Eric's explicit actions, not auto-fill, so the lead doesn't apply to them.
17. **The stale-draft drop also runs inside `autoSchedule`,** so `djq schedule` on a copy behaves like a tick.
18. **`autoSchedule` doesn't top up existing slots.** A platform turned on later gets posts on new clips only; topping up would re-create what was deliberately removed and break "no churn".

### Relay

19. **The signature is a canonical string,** because a Swift dictionary encodes in hash order and would look changed at random.
20. **The relay also leaves alone** posts in `due`/`overdue`, handed to the Calendar, published by Postiz, or with a job that isn't `live` (`creating`, unconfirmed, `deleting`). Spec's "live post ≥ 60 min away" also checks the job's `remoteDate`. Each of these could be going out or be with Eric right now.
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
