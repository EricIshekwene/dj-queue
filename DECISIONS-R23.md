# Round 23 — Photo with audio: a photo becomes a video

Eric, 2026-11-11: "allow me to add audio to it to make it like a video form. I can put in an image and just the image
is like the video… and then I can put whatever audio I want over it." This was the original goal behind photo posts
(round 21). Eric delegated the product choices; each decision below is the recommended option with its reason.

## What ships

Pick a photo and an audio file. DJ Queue makes a video of that photo with that audio, and from then on the item is a
clip: it opens in the clip editor (9:16 crop, trim, timed texts, cover, captions), goes to the Queue with no score,
renders with the same loudness as every clip, and posts everywhere a video posts, YouTube Shorts included.

## Requirements

| ID | Requirement | Done when |
|---|---|---|
| A1 | Add audio to a photo post (one photo): from its card, the editor and `djq`. | The item becomes a video with that audio; the picked files are untouched. |
| A2 | Add photos with audio in one go: the import sheet has an Audio row. | Each photo becomes its own video with that audio. |
| A3 | The made video behaves as a clip everywhere: editor, lists, previews with sound, Queue, set time, Calendar, render, Postiz, YouTube. | The existing clip checks pass on one; no photo-only rule applies to it by mistake. |
| A4 | No score needed; default "No text"; a mark on cards says what it is. | Stage, Queue order and validation tests. |
| A5 | Change audio, and Remove audio (back to a photo post), while nothing of it is scheduled or posted. Undo for each. | Tests and the live check. |
| A6 | Safe and lossless: schema change proven on a copy of the real backup; sources never modified. | Migration proof and file tests. |
| A7 | README still and GIF, ARCHITECTURE, agent skill, this file. | Pushed and visible on github.com. |

## Decisions

**D1. The photo and the audio become a real video file once, and the item is then an ordinary clip.** DJ Queue makes
`Photos/Stills/<id>/video.mp4` (the photo held for the length of the audio) and points the item at it. *Why:* the
whole clip pipeline (editor, trim, timed texts, cover, proxies, loudness, Postiz video upload, YouTube) is built and
proven on video files. A second "photo that plays sound" pipeline would repeat all of it and miss YouTube.

**D2. It is the same item, converted in place.** "Add audio" on a photo post keeps its id, title, caption, hashtag
groups, texts and looks. What only made sense for a photo is dropped: per-photo crops, the photo shape (the clip
default, 9:16, applies) and "shows on photos" ranges (each text shows for the whole clip until Eric times it).
YouTube, which a photo post always skips, follows the defaults again. *Why:* Eric shouldn't redo the caption because
the format changed.

**D3. One photo per video.** A carousel can't take audio; the control is off and says to use a post with one photo.
In the import sheet, choosing audio makes "a post per photo": several photos become several videos with the same
audio. *Why:* Eric asked for "an image is the video". A slideshow needs its own choices (how long each photo shows,
cuts); follow-up if he wants it.

**D4. Any audio, up to 20 minutes:** MP3, M4A/AAC, WAV, AIFF, FLAC, CAF, and the sound of an MP4 or MOV (a DJ clip or
a set recording). DJ Queue keeps its own copy. The whole file becomes the video and the editor's trim picks the part
that posts. *Why:* "whatever audio I want", and the usual case is a snippet of a longer track or mix; the trim lane
already does that with per-platform trims and "too long for X" fixes.

**D5. The video is 30 fps H.264 at the photo's own shape,** scaled to fit a 4K frame (3840×2160, or 2160×3840 for a
tall or square photo), upright, sRGB to BT.709, AAC 256 kbps. *Why:* the same class of file as Eric's 4K clips, so
every part of the pipeline already handles it; and enough pixels for a 9:16 crop at 1080×1920.

**D6. No score, like a photo post.** It lands in (or stays in) Edit, sorts ahead of scored clips in the Queue, and
"Back to Score" is off. *Why:* Eric said he won't score these.

**D7. It starts with "No text"** and keeps any text the photo post had. `{set}` and `{tag}` in captions are empty, as
for a photo. *Why:* a flyer or photo usually carries its own words; a file name is not a tag.

**D8. Cards mark it "Photo + audio"** where clips show their kind, with the length. The editor shows the audio's name
and length with **Change audio…** and **Remove audio**. *Why:* Eric should see at a glance which videos are a still.

**D9. Change and Remove are allowed only while nothing of the item is scheduled or posted.** Otherwise the control is
off with the reason ("Send it back to Edit first"). Remove audio makes it a photo post again (one photo, 4:5 by
default, YouTube off). *Why:* a scheduled post already has renders and Postiz copies of the old file.

**D10. A YouTube post needs a title.** Without a Title a made video would go out named after the photo's file
("IMG_1234"), so that is an issue to fix before the Queue when YouTube is on. *Why:* clips always have a marker tag
that reads as a name; a camera file name doesn't.

**D11. Stored as one nullable column,** `videos.still` (the photo it was made from, DJ Queue's copy of the audio, its
name and length). Schema 10, additive and lossless. *Why:* the database stays the one source of truth, and Remove
audio needs the original photo back.

**D12. A made video shows the whole photo by default; "Fill the frame" crops instead.** (Added after the first
build: a clip is always cropped to 9:16, so a flyer or a 4:5 or square photo lost up to half its width.) Stored as
`still.fit`, `whole` or `fill`; a video made before this reads as `fill`. *Whole photo:* a 9:16 video (2160×3840, or
smaller so the photo is never enlarged) with the photo fitted inside, centred, over a blurred, darkened copy of itself;
its crop is the whole frame and needs no confirming. *Fill the frame:* the video has the photo's own shape and Eric
picks the 9:16 crop. The choice is one control under the audio's name in the editor, in the import sheet once audio is
picked, and `--fit` in `djq`. Changing it makes the video again from DJ Queue's own audio copy (same rules as Change
audio, with Undo) and resets the crop; trim, texts, cover and captions stay. *Why:* Eric said "just the image is like
the video".

## Not in this round

- Slideshows (several photos in one video) and transitions.
- Choosing the part of the audio before the video is made, a waveform on the timeline, volume or fades.
- TikTok's or Instagram's own music libraries (the audio is always Eric's file).
- Any real post. Nothing is published or scheduled on Eric's accounts while building.

## Decisions made while building

- **One keyframe interval is encoded and repeated, not the whole length.** A still encoded frame by frame took 15 s for 3 minutes on every core; one 5-second interval repeated under the audio with a stream copy takes 3 s (20 minutes: 13 s, most of it reading the audio). *Why:* Eric is at the Mac while it runs, and the result is the same picture.
- **The keyframe is coded at quantiser 18 and the frames after it code nothing.** x264's own rate control spent as much on the repeats as on the picture (1.65 MB per 5 s for a 4K frame); fixed quantisers give 0.52 MB at 48 dB. A 3-minute 4K video is about 25 MB with its audio (20 minutes: about 170 MB). *Why:* the file is only a source; the post is rendered from it at 12 Mb/s.
- **A keyframe every 5 seconds.** *Why:* an exact frame anywhere decodes in under half a second, and the size above stays small.
- **A photo is never enlarged.** A photo smaller than the 4K frame keeps its pixels (even dimensions). *Why:* enlarging adds bytes and time and no detail; the renderer scales the crop either way.
- **Colours: the photo's sRGB values through the BT.709 matrix, tagged BT.709 limited range.** Measured within 1 of 255 against the photo (test tolerance 6). *Why:* that is how the renderer already treats text overlays, and every render carries the same tags as a clip's.
- **The audio is encoded once, first, and its measured length is the video's length.** *Why:* an MP3 header's length can be an estimate; the video must end with the sound. In the import sheet the same encoded audio goes under every photo. How long that takes depends on the file: a 20-minute tone took 13 s here and the reviewer's 20-minute MP3 39 s, both far inside the 4-minute budget.
- **Files are never written over: Change audio writes `video-2.mp4` beside `video.mp4`.** (Round 3: a fit change back reuses the video already made from the same audio.) *Why:* the undo of Add, Change and Remove then only points the row back, with nothing to re-make inside a database transaction. Old files stay on disk (a 3-minute one is about 25 MB); cleaning them up is a follow-up.
- **The proxy of a made video is one frame and the audio copied.** The clip's way decoded all of it: 104 s on every core for 20 minutes, close to the 120 s limit. *Why:* previews in the lists should not cost more than making the video did. It falls back to the clip's way if it fails.
- **`photoLabel` still means "a photo post"; `markLabel` and `kindLabel` say "Photo + audio".** *Why:* eleven places in the screens read `photoLabel` as "this is a photo post" (a photo card, the Calendar's photo mark), and a made video must not be one of them.
- **The YouTube title issue is raised only when YouTube would have nothing of Eric's to use:** no Title, no text on the video and no typed YouTube title. *Why:* with a typed YouTube title or text on it, "YouTube would name it after the file" would be false.
- **The default crop of a made video is centred, whatever the anchor in Settings, and it never becomes "last crop".** *Why:* the anchor says where the DJ stands in the camera's frame; a flyer has no such place.
- **A text added to a made video shows for the whole clip by default,** even when New clip defaults say "First seconds". *Why:* D2 says each text shows for the whole clip until Eric times it.
- **Remove audio keeps the made files and clears the video-only edit** (crop, trim, per-platform trims, cover time, text windows). *Why:* those are in seconds and source pixels of the video; undo brings them back with it.
- **The undo of an audio change is refused once the item has a day or a post, force or not.** *Why:* D9 holds for an undo too.
- **Two made videos never count as overlapping cuts** (Avoid overlap). *Why:* each is its own file from 0 to its length, not a cut of one recording.
- **The Audio row sits under Kind in the Title section,** in both editors. *Why:* that is where the item says what it is (Photo, Photo + audio); the references show the sound as one row with its name and length and one action under it.
- **While a video is made, the open editor is covered and says how far along it is.** *Why:* an edit typed meanwhile would be written to an item that is about to be something else.
- **The import sheet opens for one photo when asked through ⌘K "Add photo with audio…";** one photo from Add photos still goes straight in. *Why:* the audio is chosen in the sheet.
- **Doctor lists a missing made video under `photos.missing`.** *Why:* the fix is the same (put the file back under Photos), and the clips' finding talks about videos.json.
- **Baseline (round 21 and 22 leftovers), fixed in their own commit:** `post-at` step 10 expected the old UTC YouTube window; Settings → Publishing had no badge for an expired sign-in; `photo-editor` compared text pixels at a locked Mac's tolerance. *Why:* the brief's checks must pass before this round's.
- **One existing test line changed:** `R21FoundationTests.schema8DatabaseGainsTheColumnsAndKeepsEveryRow` asserted `Store.schemaVersion == 9`; it now asserts `>= 9`. *Why:* this round moves the schema to 10.

- **The README clips come from the final run on an unlocked Mac** (2026-11-11, all ten hidden checks, real window pixels, the player showing the photo). *Why:* the builds ran while the Mac was locked, when a capture draws the player black; the earlier clips were inspector crops and were replaced at ship.

### After the independent review (round 2)

- **B1. The lock is about what a restore would do, not what the batch is called.** A forced undo of any older batch (a title change, an Edits entry) carries the item's old media in its snapshot; it is now refused, force or not, when it would change what a scheduled or posted item is (photo post or video, which audio, which fit). *Why:* a photo would have gone out where a video was scheduled.
- **S2. DJ Queue's audio copy is the AAC the video holds (`audio.m4a`), never the picked file.** *Why:* "the sound of an MP4" copied the whole video, once per photo. The copy is now read: a fit change makes the video again from it with a stream copy.
- **S3. While its video is made, an item's editor is covered for keys too, its stage controls and clock are off, and what the editor holds is written before the make and dropped (not flushed) when the item lands as something else.** *Why:* a change typed in the last moments was written onto the converted item.
- **S4. After the undo of an audio batch the open editor reloads from the batch and from what it holds.** *Why:* it used to compare with the model's list, which had already caught up in some runs and not in others.
- **S1. Photos picked while videos are being made are added when they are done.** *Why:* the toast promised it.
- **N1** a failed make removes only a folder it made and left empty. **N2** Remove audio checks again inside its transaction. **N3** Edit's bulk bar treats videos made from photos as the ⋯ menu does. **N4** the D10 sentence is now "Add a title: YouTube needs a name for this video" (it would not have been named after the file: the title would have been empty). **N5** the Audio row reads a blocker cached with the item. **N6** leftovers of a make that was cut short are swept once a day old (`work/still-*`, dot-files in `Photos/Stills/<id>/`). **N8** a photo under 200 px on its short side is refused, in words. **N9** Change audio fits text windows to the new length: one that starts past it shows for the whole clip, one that ends past it runs to the end. **N10** a photo whose import fails stays in the sheet to try again; the ones that were made don't. **N11** README order.
- **`whole` is decided by the resolver as well as stored.** A whole-photo video whose crop override is cleared (Reset to defaults) still resolves to the whole frame, confirmed. *Why:* "Confirm the crop" must never come back for it.
- **A photo within 1 % of 9:16 is made the same way for both fits** (its own shape, no background). *Why:* there is nothing to show behind it, and the whole frame is a valid 9:16 crop. *(Changed in round 3: see S2 below.)*
- **The whole-photo frame is a multiple of 18 pixels wide.** *Why:* that is exactly 9:16 with even sides, at any size down from 2160×3840.

### After the second review (round 3)

- **S1. An undo that skips an item because it is scheduled or posted restores nothing of the batch's plan either.** Undoing an old "taken out of the Queue" batch used to refuse the item and still put its old posts back: a photo post got a YouTube post, or a made video lost its own. Now the plan part waits with the item, forced or not, and the words say what lets it through ("send it back to Edit, then undo again", never "use force"). *Why:* the batch's posts were planned for what the item was then.
- **S2. A whole-photo video's frame is exactly 9:16 for every photo, and "already 9:16" is half a percent.** A photo 1 % off (965×1700) was made at its own shape, said "nothing to fix" and then could not be rendered, because even pixels tipped it past the renderer's 1 %. Now: within 0.5 % of the 9:16 frame the photo covers it (a stretch nobody can see, and less than the renderer already allows a crop); further off it sits inside the frame over its background, even when the bars are a few pixels. Checked for every size from 200 to 9000 px high within 3 % of 9:16. *Why:* its crop is the whole frame, so the frame has to be the shape the renderer asks for. Fill the frame keeps the photo's own shape, as before.
- **S3. A whole-photo video says 9:16 itself when New clip defaults ask for another shape.** It is 9:16 by the way it is made, so add, a fit change to Whole photo and Change audio store the 9:16 on its edit when the default differs (and nothing when the default is 9:16, as on any clip). Fill the frame and Remove audio clear it; undo brings it back. *Why:* with the default at 4:5 every whole-photo video said "nothing to fix" and failed at render time. Not covered: a default changed after the video was made is put right by the next Change audio, or by choosing 9:16 in the editor, the same as for a clip whose crop was confirmed under the old default.
- **S4. The editor asks Core's question about the crop.** Its header chip, the Frame summary and the canvas now use the resolved edit's "confirmed", so Crop → Reset on a whole-photo video stays "Nothing to fix". The Crop field there has no Reset until Eric zooms in or moves the crop, and Reset goes back to the whole frame. On a made video the field's help speaks of the photo, not "the wide recording".
- **A fit change back reuses the video already made from this audio** (`still.other` names it). Flipping Whole photo and Fill the frame leaves two videos per audio, not one per flip. The file is checked first (there, H.264 with sound, the frame a new one would have, the audio's length); otherwise the video is made. After an undo of a fit change the next flip makes its video once more (the undo restores the row exactly, without the pointer). *Why:* six flips of a 20-minute track wrote a gigabyte.
- **The photo is overlaid on an even pixel.** *Why:* a 4:2:0 file keeps one colour sample for two rows; a photo that started on an odd row tinted the background row beside it.
- **A damaged or unreadable audio copy says the same sentence as a missing one:** "Its audio file is missing or can't be read (name): choose the audio again with Change audio". What ffmpeg says in any other failure is shown with the folders taken off every path. *Why:* raw tool output with a path under the home folder is no message for Eric, and the way out is the same.
- **While a video is made, the editor header's Back, previous and next, Undo, Redo, version picker and Done are off too,** with the reason the stage control gives. *Why:* they sit outside the cover, and each of them saves or leaves.
- **Tests:** the clip-rule suites run on both fits; whole-photo cases for a photo stored on its side, a see-through PNG and a panorama; the live check compares the rendered frame's background with the photo's own blurred, darkened colours (tolerance 26 of 255) instead of "not black", and has a Crop Reset step with a real click (sabotage `crop`).

