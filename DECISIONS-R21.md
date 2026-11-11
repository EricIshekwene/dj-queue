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
  dev root by text replacement; an escaped path ("\\/Users\\/…") slipped through both the replacement and its check, and the scratch
  engine would then have moved or deleted Eric's real rendered photos.
