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
