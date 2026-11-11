# Round 21 — Photo posts and "Post at a set time"

Eric asked for full photo support and delegated every product choice. Each decision below is the recommended option,
with the reason in one line. Before this round DJ Queue handled video only: every item was a clip from `videos.json`.

## What ships

- **Photo posts**: one photo, or a carousel of several, imported into DJ Queue, edited like a clip, sent to the Queue,
  rendered, posted (by hand or through Postiz) and tracked on the Calendar and in Posts.
- **Post at a set time**: any Queue item can go out at an exact day and time, outside the posts-per-day cadence.

## Requirements

| ID | Requirement | Done when |
|---|---|---|
| P1 | Import photos: file picker, drag and drop, `djq photo add`. JPEG, PNG, HEIC, WebP, TIFF. | A post appears in Edit with its photos; the originals are untouched. |
| P2 | A photo post flows Edit → Queue → Scheduled → Posted. No score needed. | Stage rules, Send to Queue, Back to Edit, undo all work on it. |
| P3 | Render: one JPEG per photo, cropped to the post's aspect, text drawn in. | The files in Ready to Post match the editor exactly. |
| P4 | Per-platform rules: YouTube never; photo count caps; Postiz payloads; manual posting gets every file. | Tests cover each platform's payload. |
| P5 | Photo editor at the depth of the video editor: photos strip, frame and crop per photo, text and look, caption, templates, hashtag groups, title, platforms. | Live check drives it end to end. |
| P6 | Photos in every list: Edit, Queue, Library, Posts, search, previews. | Cards show the photo, a Photo / Carousel mark, no play behaviour. |
| P7 | Post at a set time: from the editor, Edit, Queue and Calendar; change it; go back to the regular schedule. | The post lands at that minute on every platform. |
| P8 | Calendar: photos and set-time posts in Day, 3 Day, Week and Month. | Live check screenshots, light and dark. |
| P9 | `djq`: `photo add`, `post-at`, JSON output carries the photo fields; agent skill updated. | CLI tests. |
| P10 | README stills and GIFs, ARCHITECTURE, this file, knowledge pack. | Pushed and visible on github.com. |

## Decisions

**D1. A photo post is the same kind of record as a clip.** `Video.photos` holds its photos (nil = a video); it is
short-form, has `duration` 0 and lives in one "Photos" session. *Why:* stages, Send to Queue, bulk edits, undo, the
planner, the Calendar, Postiz tracking and Doctor all work on it without a second copy of each.

**D2. DJ Queue keeps its own copy of each photo** in `~/Movies/DJ Video/Photos/Originals/<post id>/`. The file Eric
picked is never moved or changed. Renders go to `Photos/Ready to Post/Shortform/` and move to `Photos/Posted/Shortform/`
like any session. *Why:* a photo dragged from Downloads or AirDrop would otherwise go missing; and the rule "never
touch source material" holds.

**D3. Picking several photos makes one carousel.** The import sheet has one switch, "A post per photo", for the other
case. *Why:* a set from one night is the common case, and splitting later is harder than choosing up front.

**D4. Photos skip Score.** They land in Edit. An unscored photo sent to the Queue takes the next open day ahead of
scored clips, oldest import first; a photo that has a score sorts by it like a clip. *Why:* Eric asked for scoring to be
optional, and a photo is usually timely.

**D5. Photos default to 4:5** (`defaults.photoAspect`), with 1:1, 9:16 and 16:9 as the other choices. Every photo of a
carousel uses the post's one aspect. *Why:* 4:5 is the tallest shape Instagram's feed shows uncropped and reads well
on TikTok, Threads, X and Facebook; Instagram refuses a carousel with mixed shapes.

**D6. Output is JPEG, 1080 px wide, quality 0.9, sRGB**, EXIF orientation applied and metadata dropped. *Why:* it is
what every platform re-encodes to anyway, and location data never leaves the Mac.

**D7. Text on photos uses the same texts, styles and look as video; a text shows on a range of photos** ("Photos 1–3")
instead of a time window, on the same timeline, where each photo is one step. A new photo post starts with no text.
*Why:* one text system to learn; most photos want no text burned in.

**D8. YouTube Shorts never gets a photo post.** The platform is off for photo posts and says why. *Why:* Postiz
requires a video there.

**D9. A carousel longer than a platform's cap sends the first photos there** (X 4, Instagram 10, Facebook 10,
Threads 20, TikTok 35) and the editor says so on that platform's row. It is a notice, not a blocker. *Why:* a
7-photo set should still reach X; blocking would force a second post by hand.

**D10. TikTok photo posts go out as Direct post with no auto-added music** (`autoAddMusic: no`), title from the Title.
*Why:* Postiz's "yes" attaches a random library track, which a DJ would never want on their name.

**D11. Instagram photo posts are feed posts** (`post_type: post`), a carousel when there are several. Trial reels
don't apply.

**D12. "Post at a set time" posts every platform at the same minute, outside the cadence.** It doesn't use one of the
day's regular positions, so no clip moves for it, and the scheduler never fills, shifts or re-lays it. It is always
pinned. The time must be at least 10 minutes away. *Why:* that is what "this exact day and time" means, and the
regular two-a-day plan should not shuffle because of a one-off.

**D13. Setting a time is Eric's Send to Queue.** It is the same explicit act: the item must be ready (nothing left to
fix), it is sent, and it gets that time. Agents never call `djq post-at` unless Eric says so. *Why:* the standing
rule that only Eric's own Send to Queue moves anything into the Queue.

**D14. It works for clips too.** Core treats photos and clips alike. A clip's YouTube post at a set time inside
02:00–07:00 UTC moves to 07:30 UTC, and the UI says so before Eric confirms. *Why:* the rule costs nothing extra and a
release-day clip needs it as much as a photo; the YouTube quiet window is a standing rule.

**D15. The first photo is the cover.** The Cover section is replaced by the photos strip (drag to reorder). *Why:*
every platform shows the first photo first.

**D16. One version per photo post this round.** The version strip and "Ready to repost" are hidden for photos.
*Why:* versions exist to repost a clip with new text; nobody asked for photo reposts. Follow-up if Eric wants it.

**D17. Bulk crop skips photos** with the reason "photos are cropped in the editor"; bulk caption, title, platforms,
Send to Queue and Back to Edit work. *Why:* bulk crop sets one anchor for many same-shaped clips; photos vary.

**D18. Where clips say "DJ vid" or "Talking", a photo post says "Photo" or "Carousel · 5".** `{session}` in a caption
template is empty for a photo post. *Why:* "Photos" is a storage folder, not a night.

**D19. Test mode behaves as it does for clips** (drafts where the platform has them, TikTok to the inbox).

**D20. A 9:16 photo post can't go to Instagram, and DJ Queue says so before the Queue.** Instagram's publishing API takes photos only
from 4:5 to 1.91:1, so 4:5, 1:1 and 16:9 are fine everywhere and 9:16 is refused there. A 9:16 photo post with Instagram on has the issue
"Instagram takes photos from 4:5 to 16:9 — pick another shape or turn Instagram off for this post" (`photoShape`, fixed in Frame), the
aspect picker and Instagram's row say it too, and Send to Queue leaves the post in Edit until one of the two is done. *Why:* otherwise it
fails at publish time, on a day Eric isn't looking, with the other four platforms already out.

## Not in this round

- Photo reposts and versions (D16).
- Mixed carousels (photos and clips in one post).
- Filters or colour adjustment. The editor frames, crops and adds text; it doesn't retouch.
- Real posts. Nothing was published or scheduled on Eric's accounts while building; Postiz payloads are tested
  against recorded shapes.

## Decisions made while building (set time)

- **A time that has passed or is under 10 minutes away fails the whole batch at once,** unless every item already has that very time (then nothing changes). Every item would be skipped for the same reason; one error reads better than N.
- **Seconds are dropped.** "That minute" is the promise, and a picker can hand over any second.
- **Setting the time it already has changes nothing,** even inside the 10 minutes. New post ids would make Postiz cancel and re-create for no change.
- **The slot keeps its id when it takes a set time or its time changes.** The Calendar's selection stays on the same card, as Post today already does.
- **An Edit item that still has something to fix is left exactly as it was:** no crop confirmed, a hold not cleared. Send to Queue keeps that half-step; here Eric asked for a time and didn't get one, so nothing should have happened. The message lists what Eric has to fix (the crop confirms itself next time).
- **An item with something already posted can't take a set time.** The rest of its platforms keep their days; Repost is the way to post it again.
- **A platform that failed keeps one lineage (review M2).** A retry on its way, the engine's or Eric's Fixed, moves to the set time as the same post, so nothing is created beside it and Postiz moves its one copy. A failure whose retry is still to be made keeps its promise and the engine makes the attempt for the set time on its next pass (near it when another post on that platform is within the 3-hour gap). A failure is never left marked retried with nothing coming. A failure that waits for Eric, or a skipped post, gets nothing at the set time, and the preview says which it is.
- **"Use the regular schedule" leaves a retry on its way at its own time, and says so (review N4):** "Back on the regular schedule · TikTok's retry still goes out Fri 6 Nov 10:00 AM", in the toast, the dry run and `djq post-at --clear`. Dropping it would leave the failure with nothing coming; the other platforms get the next open day.
- **Undo of a set time is refused while Postiz sends a copy within 10 minutes (review N2): "Facebook goes out in 3 minutes — too late to undo".** It is the same test a new time, a clear and a move use (`Planner.tooLate`), for the same reason: Postiz would keep its copy and send it at the set time while the plan showed the old days. Force doesn't override it, because it isn't a conflict with later work; nothing can call that copy back.
- **A scheduled item whose day is shared through a per-platform sort can't take a set time; it is refused (reviews M1 and N1, decided by the session parent).** When a platform has its own order, a day's card can carry another clip's post, and the item's own post can sit on another clip's card. Setting a time for an already scheduled item in that state is refused, and the preview shows the blocker: "TikTok has its own order, so this day is shared with another clip. Send it back to Edit, then set the time." Nothing is detached, deleted or guessed. *Why:* two fixes failed on this case. Leaving the item's post on the other card kept that platform on its regular day; taking the other clip's post off the card left a regular post with no card, whose place in the plan had to be guessed from today's Settings, and a wrong guess put a second post on its platform, day and position. The case exists only with a per-platform sort, which Eric's settings don't have today. Back to Edit already takes the whole day off, and from Edit the time can be set. An item still waiting in the Queue has no card and takes a set time as before (its own clip on every platform, no picker); a set-time slot never carries another clip's post, so changing or clearing one isn't affected.
- **No regular post is ever left without a card by a set time.** The tests check it after the operations in their rigs.
- **A copy Postiz sends within 10 minutes refuses a new time, a clear and a move (review M3): "Facebook goes out in 3 minutes — too late to change".** From 5 minutes before, Postiz keeps its copy whatever the plan says, so it would go out at the old time while every screen showed the new one. The window is the set-time lead, not `setSlot`'s 30 minutes: 30 would lock a set time made 10 to 30 minutes ahead the moment Postiz had it. A post Postiz doesn't hold can always change.
- **Through Postiz two posts on a channel never share a minute, and the rule stays (review m2).** It keeps a Postiz post matched to one job. The preview says what happens: "TikTok goes out at 7:01 PM: another post has 7:00 PM" when the other post is already in Postiz, "one of the two goes out a minute later" when neither is yet.
- **A clock time the day doesn't have is refused (review m4),** when typed and on a move: "2:30 AM doesn't exist on Sun 14 Mar: the clocks go forward that night". The calendar would hand back 3:30 and a later move would keep 3:30 for good.
- **Push and Post today leave a set-time item's retry at the set time (review m1),** and the missed notice offers no Shift plan for a set-time post (review m5).
- **A past slot whose posts were missed is replaced too** (the rule Back to Edit uses). Setting a time is also how a missed item gets a new one.
- **`swap`, Skip next and Post today on a set-time item are refused: "It has a set time — change the time instead".** Each would trade or drop the time Eric chose without saying so.
- **Shift plan on a missed set-time post is refused: "It has a set time — post it now or pick a new time".** It has no platform slot to shift into. Post now and Skip work as for any post.
- **Moving a set-time slot to another day keeps its clock time and logs "Set for …"; the same day is a no-op.** A drag across days means "that time, another day". If that time on the new day is too close, it is refused and stays.
- **Posts topped up for a set-time slot (a platform turned on later, through the approval seam) go at the set time and never in the past.** A slot time would break "the same minute".
- **Set times aren't scheduled days in the runway.** "Scheduled through" is about the cadence; a one-off on the 20th doesn't mean the calendar is full to the 20th.
- **"Use the regular schedule" doesn't run the scheduler itself.** The item is back in the Queue and the next tick gives it a day, like every other way into the Queue.
- **The preview runs the real thing in a transaction and rolls it back.** A second copy of the rules would drift.
- **`UnplanItem.setTime` is new and `pinned` stays true for a set-time slot.** Existing words still read right; the UI can say "set time 3:15 PM" instead of "pinned".
- **`djq week --json` slots don't carry `exact_at` yet.** `AgentAPI.WeekOut.SlotOut` is in the photo builder's file this round; `position` 100 or more marks a set time there and `djq video --json` has `plan[].exactAt`. Two lines to add at integration.

## Decisions made while building (B3: set time and Calendar screens)

- **The day is picked in a small month grid and the time is typed** ("7pm", "7:30 pm", "19:00", "730p", "noon"), both built from the design system. *Why:* a native date picker can't be driven by the hidden check and doesn't take the tokens; a typed time is the fastest way to say 9:15.
- **Four quick times: In 1 hour (on the next five minutes), Tonight 7:00 PM, Tomorrow 12:00 PM, Saturday 6:00 PM.** One that has passed or is under 10 minutes away isn't offered. *Why:* they are the times a DJ post usually wants; anything else is two keystrokes.
- **The dialog opens on the time the item has, else the next round hour at least an hour away.**
- **The time field's own problem (passed, under 10 minutes, not a time, a clock time the day doesn't have) shows under the field; every other reason takes the place of the platform rows.** Both turn the primary button off with the reason as its tooltip. *Why:* the field error is about what Eric typed, the rest is about the item.
- **Several items: one row per item ("6 platforms" or "stays — why").** The button is on when at least one can take the time, and it reads "Change time" only when every item already has one. "Use the regular schedule" then acts on the ones that have a time.
- **The clock on the stage control is a ghost icon button, filled once the item has a set time.** It shows for Edit, Queue and Scheduled items; Score comes first and Posted is done. *Why:* one more secondary action, never a second primary.
- **"Use the regular schedule" from a menu runs at once, with Undo on the toast.** *Why:* it is one reversible step on one item, like Pin.
- **On the Calendar a set-time card carries a clock where a pinned card carries a pin.** A set time is always pinned, and the clock says the stronger thing. The pin item is left out of its menu.
- **Set-time cards sit among the day's cards by their own time** (the earliest platform time of each card). Position 100 and up is never shown or sorted on.
- **A day that only has set-time items still shows a small "Open" under them.** *Why:* D12: a set time takes none of the day's places, and the Queue will still fill the day.
- **YouTube moved out of its quiet hours past midnight shows as its own chip on the next day**; the card's clock tooltip names that time, and the chip says why it is there.
- **A photo post's Calendar cover is drawn at the post's own shape (4:5 by default), never stretched or cropped to 9:16**, with "Photo" or "Carousel · N" on it. Month chips and Day headers keep the small 9:16 thumb. Nothing about a photo card plays or asks for a proxy.
- **A missed set-time post's row offers "Change set time…" where a regular post offers Shift.** *Why:* Core refuses the shift ("post it now or pick a new time"), so the row offers the two things that work.
- **Month chips lead with the set time ("3:15p") before the title.** *Why:* the platform row has no room for it at 7 columns, and the time is the point of the chip.
- **The primary button stays off ("Checking this time…") until Core's dry run for the picked day and time is on screen (review M1).** Rows asked for another time, or before the item changed, never count. *Why:* type-then-Return would set a time whose rows, YouTube note or blocker Eric hadn't seen. Given up: Return can't be typed ahead of the rows.
- **An item "has a set time" only while that slot still has a post to come (review m1).** One whose posts all went out is history: the clock goes back to "Post at a set time", and "Use the regular schedule" is offered only where Core can do it (nothing posted yet).
- **A refusal that arrives after the dialog was closed shows as a toast (review m3);** one that arrives while it is open stays in the dialog and the rows are asked for again.
- **The dialog closes by itself when every item it was opened for is gone,** and re-asks Core when an item's stage, day or posts change underneath it (review m4).
- **Several items: the whole reason sits under the item that stays, notes carry the item's name, and one line says that through Postiz they go out a minute apart (review m5).**
- **The day grid takes the arrow keys once it has the keyboard** (← → a day, ↑ ↓ a week), with the focus ring on the picked day (review m10). On-media marks keep white on a dark capsule like the pin: there is no on-media token.
- **In the live check a drag between days and the card's ⋯ menu are stand-ins** (the drop's own function and the menu item's function), and a Queue card's hover is `SnapshotHover`. macOS pulls a drag session and a menu onto a display.

## Decisions made while building (core photos)

- **A post holds at most 35 photos** (`PhotoRules.maxPerPost`), and files past that are skipped with the reason. *Why:* 35 is the largest
  platform cap (TikTok), so a 36th photo could never be posted anywhere.
- **A photo post's name is made unique** ("IMG_1234", then "IMG_1234 2"). *Why:* renders are named after the post, and two imports of the
  same file name would overwrite each other's files in Ready to Post.
- **Removing a photo keeps DJ Queue's copy in `Originals/`.** *Why:* undo has to bring the photo back, and the copy is small.
- **Append, remove and reorder are journal entries** (`photo-add`, `photo-remove`, `photo-reorder`), and an open editor session records them
  with its other changes (`ClipSnap.photos`). *Why:* the journal is how every single-clip edit gets undo; no second undo system.
- **YouTube is kept off in three places** (read, save, resolve), not one. *Why:* the planner reads raw edits, and an old journal entry or a
  restore could write a row without the skip; reading it back with the skip makes that harmless.
- **A stored crop that doesn't fit the post's aspect is ignored**, not cleared. *Why:* changing 4:5 to 1:1 and back keeps Eric's 4:5 crops,
  and nothing is ever stretched.
- **A photo with no text never raises "No text"**, also when "No text" was switched off with nothing typed. *Why:* D7 says most photos
  want no text; a blank text draws nothing, so there is nothing to fix.
- **`{text}` falls back to the Title only and `{tag}` is empty for a photo post.** *Why:* a photo's tag is its file name, and "IMG_1234"
  must never reach a caption.
- **TikTok photo posts follow Eric's posting-method setting** (Direct post by default, inbox in a test run), with `autoAddMusic: "no"`
  always. *Why:* D10 is about the music; sending photos public while Eric set TikTok to the inbox would surprise.
- **Clearing a photo's score doesn't take it out of the Queue.** *Why:* it never needed one.
- **`photos.missing` is its own Doctor finding** rather than part of `files.missing`. *Why:* the fix differs (no relink by fingerprint; put
  the copy back or remove the photo).
- **One new issue kind, `noPhotos`**, for a post row with an empty photo list (it can't be made through the app). Two existing tests list
  every kind on purpose and gained that case: `R7CaptionTests.everyIssueKindMapsDeliberately` and the count in `R4StageTests`.
- **`PhotoItem.fingerprint`** was added to the foundation model (optional). *Why:* the render hash needs each photo's content identity
  without re-reading files on every tick.
- **Agents' `djq photo add` sets `title_source: "agent"`**, the app's import `"app"`.
- **`renders.more_paths` is stored with plain slashes** (`JSONCoding.pathList`), and `scripts/live-checks.sh` now also rewrites and checks
  the JSON-escaped form of the real root. *Why:* the live checks run on a copy of Eric's database with every stored path pointed at the
  dev root by text replacement; an escaped path (`\/a\/b`) slipped through both the replacement and its check, and the scratch
  engine would then have moved or deleted Eric's real rendered photos.

### After the review (reviews/core-photos.md)

- **A photo render's file name carries the post id** ("<name> – v1 – a1b2c3d4 – 01.jpg"), and post names are compared as file names
  (case, ":" and "/"). *Why:* "Flyer" and "flyer" were two names and one file, so one post went out with the other's photo.
- **A carousel's photos are uploaded ahead of the Postiz claim, as the hourly budget allows; the post is created when all are up.** The
  earliest slot takes the budget first, and a post that waits doesn't stop the ones behind it. *Why:* 30 photos never fitted the default
  25 calls an hour, so nothing was uploaded, ever, and every later create waited behind it.
- **Nothing outside the store's root is moved or deleted, and photo paths come from `Paths.photos`**, not the session row. *Why:* path
  safety rested on a text rewrite of the database copy; now a dev process can't reach a real file whatever the copy says.
- **With YouTube on its own sort order, YouTube takes its own next clip on a photo's slot** (the existing override behaviour, never the
  photo); without an override that day's YouTube position stays empty.
- **Clips keep their old order on a tie in Edit**; only photos tie-break by import time.
- **`scripts/seed-paths.sh`** holds the path rewrite `live-checks.sh` used to do inline, so a test can run it on a made-up database.
- **Two tests that list every issue kind gained `photoShape`** (`R7CaptionTests.everyIssueKindMapsDeliberately`, the count in `R4StageTests`).

### After the second review (reviews/core-photos-2.md)

- **A path is inside the root as written or after resolving symlinks.** *Why:* resolving only stopped a clip's render from being moved or
  cleaned when its Ready to Post folder is a link to another drive, which worked before. Given up: a dev root holding a folder link into
  the real root would be managed (`make-devroot.sh` makes only real folders and file links).
- **A file that can't move to Posted is a tick error again**, raised after the other renders, the cleanup and the sweep have run.
- **Photo uploads take a per-render lock**, and a failing upload leaves a closed job with the error and one event, like a clip's.
- **`seed-paths.sh` fails closed**: an unreadable or empty database is an error, and every column is rewritten and checked, in plain,
  JSON-escaped and `%20` forms.
- **Not changed:** photo renders made under the first file naming of this branch (dev and test data only; the day-old sweep removes them),
  and the "budget used up" wording after a 429 (the same sentence clips get; changing it changes clips).
