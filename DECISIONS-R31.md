# Decisions: round 31, every version posts its count

Eric (2026-11-13): each version of a clip is its own unit in the Queue and the planner, and all versions of a clip use
the clip's score. Every version posts 2 times on each platform (a per-version count, default 2, editable); posting the
identical video again is fine, and reposts go by count, never by performance. Never post the same version, or two
versions of the same clip, back to back; interleave across clips. Show the version and the post number ("1 of 2") on the
Calendar and the Queue. Posts per day, the YouTube quiet window, automatic retries, the double-post guard and Postiz
behave as before. Long-form is never reposted. The spacing numbers were left to us.

## The unit

1. **A version post is the unit (`PostUnit`: version, post number).** A clip's units are each version × that version's
   count, `Settings.postsPerVersion` (2) unless the version sets its own (`Version.postCount`, 0–9; 0 = that version
   doesn't post). A plan slot carries one unit (`plan_slots.version_no`, `post_no`) and its posts carry it too
   (`platform_posts.version_no`, `post_no`). One slot still means one day and position, and creates one post per active
   platform, exactly as before.
2. **A unit is done on a platform once any post of it exists there** (posted, on its way, failed with its retries,
   skipped by Eric), and v1 · post 1 also where Eric marked the clip already posted. A unit needs a day while it has no
   slot and an active platform the clip isn't off for still lacks it. A slot whose unit a platform already has gets no
   post there; another clip is only pulled onto a clip's first post (v1 · 1), where a platform's own order applies.
3. **Every version uses the clip's score.** The Queue order (score, Settings → Queue sort, its tie rule) is the order of
   clips; versions follow their clip.
4. **The clip's stage follows its units.** A clip stays Scheduled ("Posting") from its first post until every unit is
   out, including the days between its posts when the next one is still waiting for a day. It's Posted when nothing is
   left. Back to Edit is still refused once something posted: lower the version's count to stop the rest.
5. **The Queue's backlog is every clip with a unit waiting for a day**, whether or not it already has days. A clip with
   no day and nowhere left to post is still counted as before ("nowhere left to post").

## Spacing (settings, Settings → Schedule and `djq post-spacing`)

6. **Two posts of one clip are at least 2 days apart (`sameClipGapDays` = 2, at least 1).** With 2 posts a day, one day
   apart would still allow the same clip in the evening and the next morning, which reads as back to back; two days
   never does.
7. **The same version posts again at least 7 days after its previous post (`sameVersionGapDays` = 7).** A week keeps the
   identical video out of the same audience's feed for a full cycle, and is longer than the clip gap as asked.
8. **Round robin by clip.** Each open position goes to the clip that went longest without a post (a clip with none yet
   first), so new clips go out before any repeat and the calendar goes round the clips. A tie goes to the Queue order.
9. **Inside a clip, every version's first post comes before any repeat, older versions first:** v1 · 1, v2 · 1, v3 · 1,
   then v1 · 2, v2 · 2, … This puts the longest possible time between a version and its repeat.
10. **Repeats look a week ahead, first posts a month.** A clip's first post takes any open day up to the 30-day horizon,
    as before. A clip that already has a day or a post (its repeats and later versions) only takes days up to 7 days
    ahead (`Planner.repeatHorizonDays`). With every version posting twice the Queue always has more posts than the
    month has days; filling the month with reposts would leave a clip Eric sends today waiting 30 days. This way a new
    clip always finds a day at most a week after what's already planned, and the reposts fill in as the week rolls on.
11. **Nothing fits → the position stays open.** The gaps are rules, not preferences: when no clip may post on a day (few
    clips in the Queue, or all of them inside their gaps), that day stays empty and the next pass fills it once
    something fits. Eric's own Pin and Post today ignore the gaps (they are his explicit choice) and take the clip's
    next waiting unit.
12. **The calendar isn't reshuffled.** Days that were already scheduled keep their clips; new units fill open days after
    them. A relay (posts per day or the sort changed) re-lays units the same way it re-laid clips.

## What stays the same

13. **Posts per day, slot times, the YouTube quiet window (`YouTubeWindow`), the 30-minute lead, the 30-day horizon,
    automatic retries, Post now, Shift plan, the Placer's one regular post per platform, day and position** are untouched:
    a unit's slot creates its posts through the same code. A retry or a fix is the same unit again (its version and post
    number), so self-healing counts per unit.
14. **Never double-post, per unit.** The Postiz lineage is one version post on one platform: `video#platform#main` for
    v1 · 1 (unchanged), `#v<N>` for version N's first post (what a repost of version N always was), `#v<N>p<K>` for its
    post K. The automatic-retry key gets the same `p<K>` suffix from post 2 on. Every existing job and retry key keeps
    its string.
15. **Long-form is never reposted:** it has no units, and `djq post-count` refuses it.
16. **Ready to repost (round 20) stays a mark**, not an input: every version of a Queue clip now posts its count anyway.
    `djq repost <video> <platform>` posts the clip's next unit that platform doesn't have yet (with its cooldown); the
    planner then gives that unit a day for the other platforms.

## Data

17. **Schema 12, additive and lossless:** three nullable columns (NULL reads as 1, so every slot, post and journal snapshot
    from before reads v1 · post 1 exactly as it was). The database is backed up to
    `<app support>/backups/queue-before-schema12-*.sqlite` first.
18. **The back catalogue doesn't go out again by itself.** Clips that had finished posting at the upgrade (Posted or
    Partial) are recorded with their highest version (`plan.finishedBeforeR31`): those versions keep the one post they
    had (v1 once, an older v2+ never by itself). A version Eric adds to such a clip later, or a count he sets, follows
    the new rule. Clips still scheduled or posting get their second posts and their other versions.
19. **The count is per version and never part of how it looks:** setting it writes only that version's JSON
    (`updated_at` stays, no preview or render change), a copied version posts the default number of times, an open
    editor keeps a count set from `djq`, and bulk undo ignores it like Ready to repost.
20. **A copyright re-upload as another version** is that version's next post on that platform.
