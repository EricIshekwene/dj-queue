# Decisions: round 34, every post in the Queue has a day

Eric (2026-11-15): the Queue showed clips as "Not scheduled" (Travel Safe Grooties x Mal'engaka, score 12, the lowest),
some of which had posted long ago. Everything in the Queue must be scheduled at posts per day; nothing sits there
without a day.

## What was wrong (real data, read-only, 15 Nov)

- 44 clips in the Queue had 80 version posts waiting. The calendar was full 15–28 Nov at 3 a day and empty from 29 Nov.
  Every waiting post belonged to a clip that already had a day, and round 31 rule 10 let those take days only up to a
  week ahead (`repeatHorizonDays`). The week ahead was full, so all 80 waited and the engine said "no open day" every
  tick while December stood empty.
- Travel Safe posted on 4 Nov (Facebook, Threads, X, Instagram; YouTube 6 Nov). Its TikTok copy was handed to the TikTok
  inbox on 5 Nov and never marked posted, so when round 31 installed on 13 Nov the clip still counted as posting, not
  finished, and got a second post like a new clip. That is the "already posted" clip back in the Queue.

## Decisions

1. **Every version post in the Queue gets a day.** The planner fills open days out to `Planner.autoScheduleHorizonDays`
   (now 365; only a runaway bound, a pass stops as soon as nothing is left to place). On the 15 Nov data that is 80 posts
   on 28 Nov–25 Dec, none waiting. Round 31's spacing (2 days per clip, 7 per version, round robin, first posts before
   repeats) is unchanged; a day that no clip may take under those rules still stays open.
2. **A clip's posts go out in order.** Eric's screenshot showed Maladie x DJ Tassouman x Bobo at "Today · v1 · 2 of 2"
   with its "1 of 2" on 23 Nov: the first post sat a week out and the picker only checked the gaps in both directions,
   so the repeat took an earlier open day. A clip's next post now only takes a day after every day the clip already has,
   pinned and set-time days included (Eric's own days count as the clip's order too).
   The two clips already laid out that way (Maladie x DJ Tassouman x Bobo, Maladie x DJ Tassouman) keep their days:
   relabelling posts that may already be with Postiz could break the never-double-post guard, and both posts are the
   same video, so only the "1 of 2" / "2 of 2" order reads backwards.
3. **A new clip still goes out within about a week (replaces round 31 rule 10).** Round 31 kept repeats to a week ahead
   so a clip sent today never waits behind a month of reposts. Now a clip new to the Queue (no day, no post, nothing
   marked posted by hand) takes the earliest open position, or, from `Planner.firmDays` (7) days on, the day of the
   earliest repeat (a post of a clip that already has an earlier day) that can still move, together with that clip's
   later posts, so its posts stay in order. Every one of them must move like a relayed slot: unpinned, not a set time,
   nothing posted, every live post an hour or more away and untouched. They go back to waiting and take the next open
   days in the same pass; the log says the repeat "made room for a new clip in the Queue; it gets another day". The next
   week never changes when a clip is sent, pinned and set-time days never move, and first posts never move for one
   another. A clip that can't take the day it was offered isn't offered another in that pass, so a failed placement
   can't keep moving repeats.
4. **Travel Safe posts once.** It went out everywhere 4–6 Nov, before round 31, so it is back catalogue (round 31 rule 18).
   Its v1 count is set to 1 with `djq post-count fd8573b7 --version 1 1`; `--version 1 default` brings the second post
   back. Its TikTok copy is still waiting in the TikTok inbox: finish it there and Mark posted with the link. No other
   Queue clip had a post from before 13 Nov.
5. **The Calendar's "N in Queue waiting" line** now means the schedule is full a year ahead; its tooltip says so.
