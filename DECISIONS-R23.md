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
- **The audio is encoded once, first, and its measured length is the video's length.** *Why:* an MP3 header's length can be an estimate; the video must end with the sound. In the import sheet the same encoded audio goes under every photo.
- **Files are never written over: Change audio writes `video-2.mp4` beside `video.mp4`.** *Why:* the undo of Add, Change and Remove then only points the row back, with nothing to re-make inside a database transaction. Old files stay on disk (a 3-minute one is about 25 MB); cleaning them up is a follow-up.
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

- **The README GIF shows the top of the inspector, not the whole editor.** *Why:* the Mac locked itself during the build, and a capture taken then draws the player black; the Audio row is what changed. A full-window GIF is one `scripts/readme-media.sh` line away once the checks run on an unlocked Mac.
