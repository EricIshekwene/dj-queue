# DJ Queue round 13 — decisions

Routine decisions made while building, one line each with the why. The spec's own decisions stand; these are the ones it
left open, or where it needed a safer reading.

## Part A: the Queue is the last step

### Review corrections

- **The Send to Queue migration is schema 8.** v0.8.3 took 7. The column still goes in before the v6 step, because the v6 and v7 journals snapshot clips.

- **A swap, move, pin or Post today on a slot with a final Postiz job is refused.** Regenerating gives its posts new ids, which forget the job, so a post Eric deleted in Postiz would go back. Back to Edit and Send to Queue stays the explicit way.
- **An undo that would restore a post inside the lead is a conflict ("its slot has passed") unless forced.** Eric's undo doesn't count as an explicit "post it now"; a past slot goes out about 3 minutes after upload.
- **The migration's proof also fails on a later `Moved to Edit` event:** that's a clip round 4 promoted by itself after the send.
- **A partial undo holds the plan back only when a skipped clip's `held` or `sent` differs from the batch's before.** Any other later edit has nothing to do with the plan, so a pin still comes off.
- **A post from Post now keeps its local day for the Placer** until a shift or reset puts it back on a slot time: its time is a moment, not a slot, and subtracting the offset would free the day.
- **The Placer is keyed by plan day, not the local posting day.** With 3 a day and a 180-minute offset, position 2 crosses midnight; the old key made a later pass see the wrong day as free, and two clips landed on one minute. Auto-fill makes later passes routine. `reflow`, `push`, `makeRoom` and `closeGap` use the same key.
- **A partial undo leaves the plan alone.** Restoring only the plan put live posts on a held clip. The batch stays open for a forced undo, and `publish()` also refuses a held clip on its own.
- **A bulk batch refreshes its clips before the journal's after snapshot,** so a batch that invalidates a Queue clip records clearing the flag and its undo brings the clip back, while a later limit change doesn't.
- **`isOpen` applies the lead on every day,** not only today: at 23:50 a slot at 00:10 is inside it too. A slot that still ends up with no posts is deleted.

### Reversal of round 4

1. **Round 4's "stage = readiness" is reversed.** A clip that became valid used to move Edit → Queue by itself. With the Queue now meaning "approved, post it", that would post clips Eric never sent (it happened on 2026-11-05 from an editor save). Only Send to Queue moves a clip there.
2. **`sent_to_queue` is a new positive flag, not a repurposed `held_in_edit`.** Held means "sent back, shows a chip"; unsent is the normal state of an Edit clip and shows no issue, so "1 to fix" never appears on a clip with nothing to fix.
3. **`makeReadyWithDefaults` is a door.** Edit's bulk button reads "Send to Queue with defaults" and its dialog "Send N clips to the Queue?", so it stays a send and now clears a hold too, like the other doors.
4. **Correction of the spec's literal migration rule: a `ready` clip counts as sent only with proof.** That means a score and a "Sent to Queue" event with no later "Sent back to Edit from Queue" or "Moved to Edit"; planned, posting, posted and partial stay sent. The literal rule marked every `ready` clip sent, which on the real data would have scheduled `awuke x nack` and `coachella x organise`, the very clips Eric named, for real on Postiz. Without proof a clip waits in Edit, which fails safe. Stored states don't change in the migration; such a clip recomputes to `needs_edit` next time.
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

## Part B: the Calendar page

Reviewed and corrected once; these are the final calls.

- **Deep links set the view for the session only (`openCalendarDay`); only Eric's own switch is remembered.** A notification must not change the view he chose.
- **Clicking a Week or 3 Day day header opens Day.** The same gesture as a month cell; found no reason to make headers dead.
- **Removed the backlog drawer, drop-from-backlog and `ListPage.backlog`.** The engine fills open days from the Queue, so pinning from a drawer duplicates Queue's Pin to date.
- **Calendar loads the visible range plus one span each side and shows a skeleton only when a jump lands outside it.** ‹ › never flash empty, and no DB work in `body`.
- **Keys use a local NSEvent monitor (the editor's `EditorKeyMonitor`), not `.keyboardShortcut` with no modifier.** A plain-key shortcut can swallow letters typed into a field; the monitor checks text focus and overlays first.
- **`noOverlayOpen` now backs both ⌘F and the Calendar keys.** One definition of "something is on top".
- **Today button is always enabled and its group is fixed-size.** The toolbar's trailing group squeezed it to no width at every size; T and the click must always be there.
- **Removed the draft status from `DSXPostStatus`.** A slot with no post yet reads "Planned"; drafts are gone from Eric's world.
- **Score capsule dropped from Calendar covers; StageControl dropped from the card's hover row.** Scores aren't this page's job, and Unschedule is in ⋯.
- **Past days stay at 50 % in columns, 60 % on month chips.** Columns inherit the Week rule; month chips are too small to survive 50 %.
- **Day clip rows are 52 pt and keep a 20 pt thumb.** The thumb is the per-platform file drag handle, so removing it would lose a Today action.
- **`alert.queuelow` opens Edit, the old `alert.approve` and `alert.weekly` open Calendar.** Its body says "Send more clips from Edit"; old keys may still sit in Notification Center.
- **Chip, card and Health use Core's `Runway.isLow`, so the chip goes amber only when the Queue is out too.** One rule everywhere; a short schedule with clips waiting fills itself on the next tick.
- **"Total runway" card kept as it was.** The spec keeps "Record a new set" and this is not an approval word.
- **Settings "Runway" group renamed "Queue"; approval reminder row removed; the struct fields stay.** B11, no migration.
- **Chip tap on Month opens Day.** The spec only sets number and empty area; a chip inside the cell should not be the one dead spot.
- **Move and Post today are disabled together for posted or past clips.** Both need an unposted slot from today on.
- **Added `tooltip:` to DSPlatformIcon and `shortcut:` to DSSegment.** The two smallest design-system changes that give each platform its time and each view its key.
- **Filter chip "Nothing to fix" appears only when such clips exist.** Status chips hide at zero everywhere else.
- **`Shot.size` added to snapshots, with narrow = 1100 × 700.** Narrow width has to be looked at, and that's the window minimum.
- **README screenshots moved to docs/screenshots/calendar-*.jpg, and week.jpg and today.jpg removed.** They showed Approve week. This is outside the owned paths, flagged in the report.
- **Queue card hover uses the icon Back button, and the card's text column minimum is 176.** The labelled button pushed the row past 880 pt and rows slid off-centre by the width of their date chip.
- **"Nothing to fix" comes first among Edit's status chips.** It's the actionable one, and the last chip scrolls under Filters at 880 pt.
- **Move to… reuses the pin dialog with `moving: true`.** It's the same action; the words match the menu item and the drag toast.
- **DSToolbar title never wraps; the Day progress reads "2 / 6" under 1100 pt.** At the narrowest window the title broke into "Calend / ar".
- **Sample data sends every finished clip to the Queue except one, kept in Edit with nothing to fix.** It gives a real B16 state in the snapshots.
- **A drop or Move to… landing on today inside `Planner.autoScheduleLead` asks through the Post today sheet and names the platforms going out at once.** Eric must always have time to say no. A swap that would put the other clip there is refused by Core (`StageWording.todayTooSoon`) and shows as the error toast.
- **Post today always asks, everywhere, with the same line.** One rule for "this goes out now".
- **A day's cards are built from the posts going out that day; a post shifted off shows on its real day as an extra chip.** Day, Week, 3 Day and Month must agree on what goes out when.
- **A clip whose posts have all shifted away leaves its day's card.** Nothing goes out from that card; the chips on the real days carry it.
- **Unschedule is off for past slots and for clips outside Queue and Scheduled, and `stageBack(unschedule:)` refuses them.** On an Edit clip back means Back to Score, which clears the score.
- **A day the filter emptied reads "Nothing on TikTok", not Open.** The day is full. Today reads "Nothing going out" once no position has time left (same rule as `Planner.isOpen`).
- **"N in Queue waiting" shows only when not paused and the schedule reaches the horizon, and counts `Planner.schedulable`.** Otherwise it describes clips about to get a day, or that never will.
- **Move to… goes through `calendarMove`.** The drag's checks, swap toast and pinned-day wording in one place.
- **"Pin to this day" joins the card menu; "Swap with" stays removed.** Pinning in place had no other home, and drag swaps while the list of every slot in a week doesn't scale to a month.
- **Columns tint while a drag is over them.** Most days have cards now, so the old placeholder highlight rarely showed.
- **Awake data loads from the visible range, at most two weeks back, and never for Month; older days show no strip.** It was read on every refresh for a strip nobody could see.
- **The toolbar uses short words under 1100 pt of content ("2 / 6", "Through Sun 29 Nov", compact platform name).** At a 1200 pt window the sidebar is still open and Day on today didn't fit.
- **Send to Queue with defaults says it releases held clips.** It does, and the old tooltip only spoke of the crop.
- **`DJQ_SEND_TO_QUEUE_SCRIPT` proves B16 in the real window with the real editor.** The promise is about what Eric sees, not only about Core's states.
- **The Postiz sample gets a failed slot post yesterday, not the main sample.** "1 failed" needs a shot, and a problem in the main sample would put a card on every other shot.
- **Every pin goes through one check (`pinAsking`, `platformsTooSoon`): Queue, the palette, a drop on a Queue row and the Calendar.** The lead protects Eric wherever the pin starts.
- **The confirmation names the clip a swap moves ("Swaps with") or a pin replaces ("Replaces").** He should see every clip the yes touches.
- **A move never pulls another clip onto a slot (`regenerateMany`, `pullForHistory: false`).** A platform the clip has history on gets no post, as in auto paths. This one Core line was made on the Calendar branch at the re-review's request.
- **Undo of a swap inside the lead stays refused and says so in plain words.** The other clip's posts were regenerated and their times have passed; Core's message named an action and a force the app doesn't offer.
- **A post just past midnight sits on the day it goes out with no "moved" wording; a shifted post has no retry arrow.** Neither is a retry or a repost.
- **"Pin to this day" hides when the day shown isn't the slot's.** Otherwise it would pin a different day from the one on screen.
- **A failed post stays on its own day while its retry waits, and says when (`CalendarClip.dayPosts`).** Day shows r9's badge, 3 Day the chip, Week a line on the card; the attempt itself is a chip on the day it goes out.
- **Going back from Scheduled drops waiting retries (r9) on the way to Edit.** The merge kept both rules: the clip lands in Edit, and no retry fires for a clip taken off the calendar.
- **⌘K lands on the Calendar: a week row opens Week view on that week, and "today" finds Open Calendar.** Search keeps its Week rows without a state, since no week has one Eric can see.
- **Weeks rank above Posts when a date matches both.** Every scheduled day has posts now, so a date would otherwise open six post rows.
