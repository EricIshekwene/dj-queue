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
- **"Use the regular schedule" leaves a retry on its way at its own time.** Dropping it would leave the failure with nothing coming; the other platforms get the next open day.
- **With a per-platform sort the item's own posts on other clips' cards are replaced too (review M1),** so all six go out at the set time. Another clip's post on the card that leaves keeps its id, its time and its Postiz copy and only leaves the card: that clip loses nothing and nothing of it moves. Undo puts it back on the card.
- **A regular post with no card counts for the position whose slot time it sits on** (`Store.cardlessPosition`), so it goes on holding its platform, day and position in the `Placer` with two or more posts a day. Any other time is position 0, as before. Known limit: after a change of the second-post offset a card-less post at a later position reads as position 0 until its day passes.
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
