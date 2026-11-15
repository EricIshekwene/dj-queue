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
2. **A new clip still goes out within about a week (replaces round 31 rule 10).** Round 31 kept repeats to a week ahead
   so a clip sent today never waits behind a month of reposts. Now a clip new to the Queue (no day and no post yet)
   takes the earliest open position, or, from `Planner.firmDays` (7) days on, the day of the earliest repeat (a post of a
   clip that already has an earlier day) that can still move: unpinned, not a set time, nothing posted, every live post
   an hour or more away and untouched (the relay's rule). That repeat goes back to waiting and takes the next open day in
   the same pass, and the log says "moves to a later day to make room for a new clip". The next week never changes when
   a clip is sent, and first posts never move for one another.
3. **Travel Safe posts once.** It went out everywhere 4–6 Nov, before round 31, so it is back catalogue (round 31 rule 18).
   Its v1 count is set to 1 with `djq post-count fd8573b7 --version 1 1`; `--version 1 default` brings the second post
   back. Its TikTok copy is still waiting in the TikTok inbox: finish it there and Mark posted with the link. No other
   Queue clip had a post from before 13 Nov.
4. **The Calendar's "N in Queue waiting" line** now means the schedule is full a year ahead; its tooltip says so.
