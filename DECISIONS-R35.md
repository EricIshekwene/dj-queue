# Round 35: clip names, when each version posts, version order, removed clips

Eric (2026-11-15): the five Mix Session clips "had proper names" and now say "vid 2", "vid 3a"; in the editor's version
list v1 says "planned for Facebook, Threads" and v2/v3 say nothing, it should just say when it's planned to post; he wants
to set which version goes first per clip (v2, then v1, then v3 for those five); Library › All shows "File missing" on
versions he made.

## What happened (from the database, the backups, the event log and the batch journal)

- **Names.** Nothing renamed the clips. None of them ever had a Title (every backup since they arrived on 12 Nov). The
  song names came in as title suggestions from the rekordbox recording cues ("Sdudla x Money Tree x Partii x MA TNSANI x
  Bhebha" with the artists under it). Score and Edit show suggestions as chips under the raw tag while a clip has no
  Title; the Queue, Calendar and Library don't, so once the clips went to the Queue only "vid 1" … "vid 4" was left.
- **vid 3a and vid 3b** are two separate CapCut exports with different songs (Sungba x Ayi x Azul; Terminator 3.0 x MA
  TNSANI x Molo), not two versions of one clip. Each clip's v1/v2/v3 live inside it.
- **File missing.** On 12 Nov a helper session made three separate clips "vid 1 quiz", "vid 2 quiz", "vid 3a quiz" (copies
  of the clip files) so a long quiz and a short cut could have different trims. When Eric said the quizzes belong inside
  each video, it took them out of videos.json, moved their files to the Finder Trash and excluded them. The records stayed,
  so Library listed them as File missing. Eric's quizzes are v2 inside vid 1, 2, 3a, 3b and 4, untouched.
- **v3 of vid 3b and vid 4** ("Lagos x Joburg", "Naira Marley on amapiano??", both written by that helper session) were
  removed in one editor save on 13 Nov 11:29 (batch 2cdb75ca, the same save that set those clips' v1 trims). No agent was
  running then. Not put back: see D6.
- **v2/v3 "say nothing"**: only v1 · 1 of each clip has a day (26–27 Nov); their other version posts are waiting, which is
  the round-34 bug (a clip that already has a day only gets its next version post up to a week ahead, and that week is
  full). The version list only listed platforms with a post, so a waiting version showed nothing.

## Decisions

- **D1. Names come back as Titles, from the song-name suggestions.** One undoable batch (`djq bulk accept-title`) on the
  five clips. The Title is what every screen shows; captions, on-video text and YouTube titles of those clips don't use
  `{title}`, so nothing that posts changes (checked against `djq video --json` before and after). The app still never
  invents a title: these are the clips' own suggestions, accepted on Eric's word.
- **D2. Version order is per clip, stored as planning data** (kv `plan.versionOrder`), not in a version or the clip's edit,
  so changing it never re-renders or changes a preview. A version not in the list (made later) posts after the listed
  ones; a deleted one is skipped. Order only decides which version goes next: every version's first post still comes
  before any repeat, and the spacing rules are unchanged.
- **D3. Days already on the calendar keep their dates and swap which version they carry** (the clip's first day becomes
  v2 · 1). A day stays as it is when it's today or earlier, has a set time, has anything posted, is in Postiz, or posts
  within the hour. A day whose new version would sit closer than "same version gap" to another post of it comes off and
  the next pass gives it a fitting day; a pinned day never comes off.
- **D4. The control:** the version list shows versions in posting order with a 1st/2nd/3rd badge and ↑/↓ arrows on each
  row, plus "Post vN first" in the row's ⋯ menu (Mobbin: Upwork reorder highlights, incident.io alert priorities, Square
  rearrange menus). Arrows rather than a drag handle: one click per move, and the hidden checks can click them. `djq
  version-order <video> 2,1,3 | --default` does the same. Not an editor ⌘Z step (like the post count: it changes no
  pixels; moving back is one click).
- **D5. One line per version, no platform list:** "Planned to post Tue 1 Dec 11:00 AM" (its earliest platform post;
  " · again <day>" when another post of it has a day), "Waiting for a day in the Queue", "Not planned yet: plans once the
  clip is in the Queue", or "Doesn't post (Posts: Never)". "Posted on …" stays for what went out.
- **D6. The two removed v3s are not restored.** They were removed in Eric's own editor session, and a version posts twice
  on every platform, which can't be undone. Offered to Eric instead; restoring is one step from batch 2cdb75ca's
  snapshot.
- **D7. A clip out of videos.json and excluded reads "Removed"** (`Video.isDiscarded`), not "File missing": it never posts
  and its file being gone is expected. Library doesn't count it under Missing, Doctor lists it as info `files.removed`
  instead of the `files.missing` error. The records stay (the app never deletes them); the files are in the Trash.
- **D8. Every version gets a day** is round 34's fix (repeat horizon). This round checks it on the five clips once both
  are installed.
