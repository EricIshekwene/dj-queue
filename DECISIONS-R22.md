# Round 22 — Failed posts heal themselves

Eric asked for failed posts to fix themselves and for the app to show only what it truly can't fix. The live failure: a
YouTube post failed six times with Postiz's "daily upload quota is exhausted". `YouTubeWindow` took the quota reset as
07:00 UTC fixed, but Google resets it at midnight Pacific, which is 08:00 UTC since 1 November. Every quota retry went
to 07:30 UTC, 11:30 pm Pacific on the day whose quota was gone, while the regular 8:00 am New York slot posted daily.
Then the five-try cap made it a loud Problem.

## Requirements

| ID | Requirement | Where |
|---|---|---|
| R1 | YouTube's window follows America/Los_Angeles: reset 00:00, quiet 19:00–24:00, moved to 00:30 Pacific; DST-proof; the Settings note in Eric's clock; stored posts in the window move out by themselves. | `YouTubeWindow`, `Store.moveOutOfYouTubeWindow`, `R17YouTubeWindowTests` |
| R2 | A quota retry goes to YouTube's next slot ≥ 30 min after the next Pacific reset and ≥ 1 h after the failure, staggered. | `PostizRetrySchedule.youTubeQuota` |
| R3 | No retry cap: +1 h, +6 h, then the platform's next slot every day; an older build's capped failure re-queues. | `PostizRetry.swift` |
| R4 | Fresh media: every retry re-uploads; cache older than 3 days re-uploads; a create refused over cached media re-uploads quietly once; a media ERROR retries everywhere. | `PostizService.freshMedia`, `submit`, `classify` |
| R5 | Quiet UI: a calm "Retrying Thu 8:00 am" chip; Problems only for what needs Eric; a channel's sign-in is one item per platform and its posts wait, then resume. | `PostizSignIn.swift`, Posts, inspector, shell, menu bar, `djq`, Doctor |
| R6 | The live re-post (session parent, not this branch). | — |
| R7 | Post now on a platform set to Postiz sends it through Postiz at now + the lead time, not to the Calendar by hand; Manual platforms keep hand posting. | `PostActions.postNow`, `PostizService.handedToToday` |

## Decisions

**D1. The window reads the Pacific wall clock, not offsets.** `YouTubeWindow` compares hour and minute in
America/Los_Angeles. *Why:* 7 pm is 7 pm on a 23- or 25-hour day, and the reset is whatever midnight Pacific is that night.

**D2. Quiet 19:00–24:00 Pacific, moved to 00:30 Pacific.** *Why:* it is the old 02:00–07:00 UTC window as it was meant in
summer, now right all year; 00:30 keeps the old "half an hour after the reset".

**D3. A moved post shifts by Pacific days.** `Sched.shift` keeps a 00:30 Pacific post on 00:30 Pacific (`shiftMoved`).
*Why:* a New York clock walks off it on the nights New York changes three hours before Los Angeles.

**D4. Stored posts in the window move in the engine's plan step, pins and set times included.** `moveOutOfYouTubeWindow`
runs every tick, regular posts first; a retry or repost keeps the stagger gap. *Why:* `clear` already applied to pinned
and set-time posts, so moving them out keeps the existing pin rule; the publish step then replaces Postiz's copy.

**D5. The Settings note is computed for Eric's time zone and today's offset.** "10 pm–3 am moves to 3:30 am: Postiz's
YouTube quota resets at midnight Pacific." *Why:* plain words in the clock Eric reads, not UTC.

**D6. Set-time previews say "(00:30 Pacific)" instead of "(07:30 UTC)".** *Why:* the same rule in the same words everywhere.

**D7. A quota retry targets YouTube's Settings slot, then `Sched.retrySlot` staggers it, looking earlier first down to
reset + 30 min.** *Why:* the slot is the time that posted fine every day; earlier still beats the shared quota running out.

**D8. A YouTube failure that retries for another reason (its media) uses the regular backoff.** *Why:* no video was made
and the quota isn't the issue, so waiting a day would only delay it.

**D9. No cap at all; the count stays as the backoff step.** `maxAutoRetries`, `usedUp` and `retriesUsedUpNote` are gone.
*Why:* Eric wants it to keep going until it posts; the stuck-retry watch remains the safety net.

**D10. Retry 3 onward = the platform's next slot at least an hour after that failure.** *Why:* it is the time that platform
posts well, and it can't pile up: the stagger keeps it clear of the day's regular post.

**D11. An older build's "used up" failure counts as a retry coming, with no migration.** `retryIsComing` accepts a
failure with no promise whose message ends in the old note; the retry step re-records it and strips the note. *Why:* no
schema or data rewrite, it is quiet from the first load after install, and it heals on the next tick.

**D12. Fresh media at create time, by age, not by deleting cache rows.** A cached upload is reused only if it is under 3
days old and, for an automatic retry, uploaded after that retry was made. *Why:* other platforms' posts of the same render
keep their cache; a photo carousel that uploads over several ticks still finishes; the upload happens when it is used.

**D13. A media refusal re-uploads once per post and render** (a `sent_notifications` key), then the normal refusal path.
*Why:* "once" holds even for a carousel whose photos go up across ticks.

**D14. Error reading has five kinds** (`PostizService.classify`: retries, media, signIn, copyright, stays) in a fixed
order: copyright, "already there", media, sign-in, the old veto, YouTube's quota rule. A policy word blocks the media and
sign-in readings. *Why:* "token expired" must read as sign-in and "media URL expired" as media; "already" must still
never retry.

**D15. Sign-in waits live in kv (`postiz.signIn.<platform>`) and end on the channel list or a post going out.** They clear
when the list shows the channel healthy after showing it flagged, or when any post on it publishes; with no word from the
list, one post tries every 6 hours. *Why:* an error alone can't say when Eric reconnected; trusting the list only after
it flagged the channel avoids a retry loop when Postiz never flags it.

**D16. A flagged channel routes to Postiz, not to Manual.** `PostizRouter` no longer falls back for `disabled`/
`refreshNeeded`; `signInDown` holds creates and `waitsForSignIn` keeps the posts from going overdue. *Why:* Eric wants them
to wait and go out by themselves; Postiz keeps any copy it already holds.

**D17. The channel list is read every 30 minutes while a wait is open (6 h otherwise).** *Why:* posts resume soon after
Eric reconnects, at one budgeted call each.

**D18. A timed try makes the waiting failures' attempt rows but sends only one to Postiz.** *Why:* the rows are cheap and
show "Waits for sign-in"; one call tests the channel without risking several failures.

**D19. Sign-in is one item per platform everywhere**: Posts → Problems card, a warning attention card, the menu-bar
attention row, `djq posts --problems` and `djq status` lines, Doctor `postiz.sign_in` (replaces `postiz.channel_disabled`),
and one notification per outage keyed on its start. *Why:* Eric acts once per channel, not once per post.

**D20. `djq posts --problems --json` stays a list of posts.** The sign-in items are in the text output, `djq status` and
Doctor. *Why:* agents parse that JSON as posts; a second shape there would break them.

**D21. The retry chip is neutral (`.soft(.neutral)`, clock icon), with no try count and no error.** *Why:* Shopify's single
quiet status pill; the post needs nothing from Eric.

**D22. The inspector keeps a retrying post's error behind a closed "Details" disclosure** (`DSDisclosure`). *Why:* it's
there for the curious, not a red banner for something that heals itself.

**D23. The sign-in card: platform, "Reconnect TikTok in Postiz", a red "Disconnected" pill, one line, one "Open Postiz"
button.** *Why:* Meetup's single Disconnected pill with one Reconnect action, and Searchable's one callout with one sentence
of what to do. The button opens Postiz's web app (the cloud app, or a self-hosted Postiz's own address).

**D24. The shell card for sign-in is amber, not red, and not dismissible.** *Why:* nothing is lost while it waits, but only
Eric can fix it, so it stays until he does.

**D25. The stuck-retry watch stays, worded calmly** ("waiting to post … Nothing is lost"; an unsendable attempt goes "on
the Calendar to post by hand"), and says nothing for sign-in waits. *Why:* nothing sits silently, but the one sign-in item
already speaks for those posts, and they are never handed over or dropped.

**D26. Post now on a Postiz platform writes the note "post now (Postiz)"** (Manual keeps "post now"), and that note, like
a reset, starts `handedToToday` over. *Why:* the publish step then sends it at now + the lead time (a live copy is replaced
by the usual move rule); an earlier hand-over (a missed slot) no longer pins it to the Calendar; the "is it routed to
Postiz" test is the settings alone, so it needs no Keychain read. `djq post-now` and the app's toast say where it goes.

## Review fixes (independent review NEEDS_FIX, session-parent decisions)

**D27 (F1). Size, length, type and format veto before the media reading** (`sizeOrFormat`), and "invalid" or
"unavailable" alone is no longer a "gone" word (only an invalid url or link). *Why:* "Invalid file format" or "file
exceeds 4GB" would otherwise retry and re-upload forever behind a calm chip; they are Eric's.

**D28 (F2). On YouTube only the upload quota and Postiz failing to fetch the source media retry.** A media reading needs
media, file or url wording and nothing about status, processing, a response, the upload having happened, insert or
publish; sign-in needs the narrow wording (D30). *Why:* any later step may mean the video exists, and a retry would
double-post.

**D29 (F3). Failures an older build left re-queue only if the corrected reading retries, and on the platform's next
slot.** A failure with no promise whose time passed long ago is re-timed to the next Settings slot at least an hour away
(YouTube's quota: its slot after the next reset), then staggered by `retrySlot`. *Why:* Eric wants them posted any day or
time, but never in a burst; on the newest backup there are no unresolved failed posts, so nothing revives there today.

**D30 (F4). Sign-in is read narrowly**: tokens, OAuth, invalid_grant, re-authorize, reconnect, an expired login or
session, 401/unauthorized, refreshNeeded, a channel disabled. Never a bare permission, refresh, session or "disabled"
("comments are disabled"). *Why:* one misread post must never hold a whole platform.

**D31 (F4). A create refused with sign-in wording is a sign-in wait only if the channel list, read again right then,
flags the channel**; otherwise it is the post's own refusal (to the Calendar as before). **A wait clears when a list read
after its last sign-in error shows the channel healthy.** *Why:* the list is the authority on the channel; an error alone
can't hold the platform past the next read (30 minutes), and the failures go back to their paced retries.

**D32 (F5). Seven days failing with the same error (not YouTube's quota) shows one calm item** ("Keeps failing on TikTok:
<reason>"): a card in Posts → Problems with "Show post", counted with what needs Eric, one notification per run of the
same error, Doctor's `postiz.auto_retry` raised to a warning, and lines in `djq posts --problems` and `djq status`. It
keeps retrying. A different error starts the week again. *Why:* no cap (D9), but nothing permanent stays invisible.

**D33 (F6). For a day after a sign-in wait ends, posts whose time passed meanwhile go to Postiz the stagger gap apart**
(`remoteDate` spaces them from the channel's other jobs; their plan times stay). *Why:* no burst after an outage, without
moving regular posts off their plan days.

**D34 (F7). Post now says "goes to Postiz" only when Postiz will send it**: the platform is set to Postiz and the post has
no final job and no published lineage. Otherwise it is "post now", by hand. *Why:* the publish step skips a refused or
deleted post, so promising Postiz was wrong.

**D35 (F8). Copy and scope.** The sign-in line reads "They go out by themselves once you reconnect it." The Problems chip
counts sign-in and keeps-failing items only when they fit the search and the Platform filter. Retries stored by v0.15 at
07:30 UTC move to 00:30 Pacific (after the reset) rather than to the Settings slot: they're already after the reset, so
it's left as is.

**D36 (re-review N1, N2). A sign-in error never makes a Keeps failing card** (the platform's one sign-in item covers a
long outage). **The same error is compared with ids, numbers, links and DJ Queue's note taken out** (`errorShape`), and
**Eric's reset or Fixed starts the run over.** *Why:* one item per thing Eric can act on, and the week counts one real
error, not one id.

## Mobbin references and what they shaped

- Buffer, failed queue (red bar + "Retry now" on every card): the anti-pattern. No per-post retry button or red bar.
- Shopify, rollouts ("Scheduled" pill): the retry chip, one neutral pill (D21).
- Meetup, Mailchimp sync (one "Disconnected" pill, one Reconnect): the sign-in card (D23).
- Searchable, connector callout (title + one sentence): the sign-in card's line and the shell's attention card (D24).
- Basecamp, calm tinted banner with a time in a sentence: the inspector's "Nothing to do: it goes out by itself." line.

## Checks

- `swift build`: 0 warnings. `swift test`: 1084 tests green (icon-tooltip lint included).
- `djq posts --problems`, `djq status`, `djq doctor --json` on a scratch copy of the newest backup (no schema change;
  counts identical). Doctor's only error there is `postiz.stuck`, from the copy's jobs never syncing (unchanged check).
- `scripts/live-checks.sh … screens`: the r9 and r22 shots (retrying chip, inspector Details, sign-in card, menu bar) in
  light and dark, `screen-guard: clean`. One earlier run logged screen-guard breaks on two shots this round doesn't touch
  (`54-calendar-card-menu`, `r4-previews-grid`): every window of the app moving and shrinking over 0.3 s, the system's
  window-zoom animation (Mission Control-like) rather than a window the app showed; the run before and the rerun after,
  on the same code, were clean.
