# Round 17: YouTube posting times

Postiz support (2026-11-05) said YouTube uploads share one Postiz-wide quota that resets at 07:00 UTC and is often gone hours before. Our
failures at 15:00, 16:27 and 18:00 New York and successes at 05:00 and 08:00 fit that. The facts are in `docs/postiz.md` §5a.

1. **07:00 UTC replaces midnight Pacific.** Unix days are UTC days, so the code has no calendar and DST can't shift it.
2. **The retry is the next 07:30 UTC after the failure, as the brief says.** A failure at 07:10 UTC retries at 07:30 the same day, though
   it came after that day's reset. It costs one try of five at worst, and a reset that runs late would be caught by it. `reset` is the 07:00
   before the retry, so a stagger can still move earlier down to it.
3. **The window is 02:00 up to, not including, 07:00 UTC.** 07:00 sharp is the reset, not inside the window.
4. **One helper, `YouTubeWindow.clear`,** in `Settings.slotTime`, `Sched.staggered`, `Sched.retrySlot`, `reflow`, `newAttempt` and
   `PostizService.remoteDate`. The last is the choke point for every create, because "ever" has to cover a late slot too.
5. **Post now on YouTube inside the window waits for 07:30 UTC when it goes through Postiz.** The brief says anything, and a quota failure
   there would only retry at 07:30 anyway. A manual post is Eric's own upload and isn't touched.
6. **A plan day survives the move.** A 23:00 slot posts at 2:30 am the next morning, and `Placer` keys by plan day, so `Sched.planDay` now
   checks the day before for YouTube. Without it the planner sees that day free and stacks a second clip on the same time.
7. **Settings doesn't re-time posts, so `djq slot` does** (`PostActions.setSlot`). It changes only `scheduledAt`: plan day and position
   stay, so the never-double-post keys don't change, and `decide` replaces Postiz's copy ("moved to…"). Settings itself stays as it was;
   Eric didn't ask for it to change, and a dropdown re-timing a week of posts deserves its own preview.
8. **The hold is 10 minutes,** the crop rule's 5-minute hold plus a margin for a tick. Moved inside 5 minutes, a post would hit `.hold`:
   the database says one time and Postiz keeps the other.
9. **Pinned posts stay, and the command names them.** "Pinned clips never move" is binding, though a pin is a day and this keeps the day.
   A pinned YouTube post keeps its old time, and the command's list is where Eric sees that.
10. **A new time that has passed leaves the post where it is,** with the reason. Running `djq slot youtube 08:00` at 10:00 can't move today's
    15:00 post back, and pushing it to tomorrow would shift the whole plan a day.
11. **Reposts and manual retries follow the slot** through `staggered`, or an 18:00 repost would stay in the failing part of the day.
    Automatic retries keep their own time.
12. **The same time still re-times.** Eric may set the slot in Settings first; `djq slot youtube 08:00` then brings the posts onto it.
13. **The note sits on the YouTube row's existing description,** in UTC because the New York hours change with DST.

Known limits: two posts a day with both YouTube slots in the window land on the same 07:30 UTC, a setting nobody should pick. A retry whose 07:30 passed while the Mac slept still goes at now + 3 min (R9's rule), which can be in the failing afternoon.
