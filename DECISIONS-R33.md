# Round 33 decisions: Post today is never refused by a rule of the app's own

Eric (2026-11-15): Post today on a photo + audio clip was refused on Saturday evening with no reason he could see and nothing to do; it worked the next morning. Rule: an immediate post is held back only when Postiz itself won't take it, and then the app says why and what happens.

Cause: every regular slot of the day had already posted, so `Planner.postToday` had no position to give and threw "Today's slots are pinned or already posted — unpin one first". The confirmation showed "0 will change · 1 skipped" with the reason behind "Why skipped", and the button was off. Nothing was logged.

- **D1** Today has no position to give (every one posted or pinned): the item goes out now on its own, as a set time at the next minute on every platform it goes to. Nothing else on the Calendar moves and posts per day doesn't stop it. It reuses the set-time path, so YouTube's quiet window and every Postiz safety check still apply; only the 10-minute lead a typed time needs is skipped.
- **D2** A clip that has posted before can't take a set time (its next version post keeps its count), so it takes an extra position on today instead (positions from posts per day up to the set-time range). Its posts go at the next minute on every platform (YouTube out of its quiet window), as Post now does; nothing is pushed.
- **D3** Post today on an item with a set time posts it now (the set time is replaced) instead of "change the time instead".
- **D4** A move or pin onto a today with no room is Post today (D1/D2) instead of a refusal.
- **D5** Post now on one platform post keeps its refusal when that platform's slot today is held by a posted or pinned post ("use Shift plan"). Lifting it let the engine's missed-day reflow carry the post days later (a test showed it). Follow-up if Eric wants it.
- **D6** The confirmation lists, from Core's dry run, when each platform goes out ("Right away", a time) and, in plain view, why one waits when Postiz is the reason: YouTube's shared upload quota (19:00–24:00 Pacific, goes at 00:30 Pacific by itself) or a channel to reconnect. The app no longer guesses these rows.
- **D7** Any one-clip confirmation that can't apply shows its reason in the dialog, and the button's tooltip gives the same reason, never "Nothing would change" behind a disclosure.
