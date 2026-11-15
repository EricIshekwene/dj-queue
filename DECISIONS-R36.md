# Decisions: round 36, Repost is off by default

Eric (2026-11-15): "this new version … is reposting everything but I never said I wanted that, I would rather have it
off by default and then I switch it on for videos"; "my current queue shows I have 41 days of content and multiple
videos reposting that I never marked to be reposted"; "allow me to even edit how many times I want a version to be
posted as some form of override". Also: mark Travel Safe's TikTok as posted.

## Decisions

1. **Repost is a switch per clip, off by default.** Off: each version of the clip posts once on each platform. On: each
   version posts `Settings.postsPerVersion` times (2), spaced by round 31's rules (2 days between posts of one clip, a
   week before a version posts again, first posts before repeats, in the clip's version order). This replaces round 31's
   "every version posts twice" default. A clip with one version and Repost on posts twice; a clip with three versions
   posts six times.
2. **A version's own count is the override, Repost on or off.** The editor's Posts row and a Posts stepper on every row of
   the versions list (next to the ↑/↓ order) set it; 0 means the version never posts; Default goes back to the clip's
   Repost (once, or 2 times). `djq post-count` does the same.
3. **Stored as planning data** (kv `plan.repost`, the ids of the clips with Repost on), like the version order: switching
   never touches a version or the clip's edit, so nothing re-renders. Not an editor undo step: one click turns it back.
   `djq reposts <video> on|off`, `djq reposts --list`, and `repost` in `djq video --json`.
4. **Turning it off takes the planned repeats off at once** where they can still move (unpinned, no set time, nothing
   posted, every post an hour or more away and untouched, the relay's rule), and the next pass **closes the gaps**: a
   relay of the movable days in their old order, so later clips move up. The same happens on the engine's first pass
   after this update, which is what shrinks Eric's 41 days of content back to first posts only (19 days on the 15 Nov
   data, through Thu 3 Dec).
5. **A repost that already went out counts as the version's one post.** Maladie x DJ Tassouman x Bobo posted its
   "2 of 2" today before its "1 of 2" (the round-34 bug): with Repost off its later "1 of 2" comes off instead of
   posting the same video again. Generally a version's later day comes off when its other posts already make its count.
   A day that can't move (posted, in Postiz, within the hour, pinned, set time) is never taken off.
6. **Ready to repost (round 20) stays a mark** with the same wording; it doesn't turn Repost on. Whether to merge the two
   is a question for Eric.
7. **Travel Safe's TikTok** was marked posted with the account link (`https://www.tiktok.com/@dj.lovd`, as the other
   TikToks marked by hand are): Postiz left the draft in the TikTok inbox and has no video link for it. The clip now
   reads Posted.
8. **Settings › Schedule "Posts per version"** now says it's the count for clips with Repost on.
