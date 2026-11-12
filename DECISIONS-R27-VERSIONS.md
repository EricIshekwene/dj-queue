# Decisions: round 27, every version is its own copy

Eric (2026-11-12): "If I create a new version, no edits from the previous version should affect the second version
because that's a new version. Make sure that separation is clear." And: duplicating a version didn't copy everything;
a text that ran the whole video in one version ran only a short part of it in the copy. What a copy takes was left to
us: "it should make sense".

**Cause.** Versions carried forward: a v2+ stored only what it changed and took every other field from the versions
before it, live. So editing v1 changed every later version that hadn't set that field, and a copy made from an older
version left a field empty when the source had it empty on purpose (a text with no end = to the end of the clip), so
that field fell through to the version in between (v2's short window).

1. **A version from v2 on stands alone (`Version.standalone`).** Nothing carries forward into it; a field it doesn't set
   follows the defaults, never another version. The resolver cuts the chain at the latest standalone version. It's an
   optional JSON key: v1 and every version's stored JSON are otherwise as before.
2. **A copy is complete.** `VersionCopy.duplicate` copies what the source shows: every text (words, style, size,
   position, alignment, look, timing, countdown), "No text", the written caption, caption template, hashtag groups,
   extra tags, YouTube title and its template, and each platform's own caption. A text that runs to the end of the clip
   still does. The on-video words are always pinned in the copy, even when the source shows the clip's Title, so a
   later Title edit can't change the copy's video (review finding 5). Other fields the source leaves on the defaults stay
   on the defaults (changing a default in Settings reaches every version that follows it, as it reaches every clip; a
   caption template that uses the Title still reads the clip's Title).
3. **A copy never takes posting state.** "Ready to repost" starts off on the copy (Eric marks each version; the
   repost cycle reads the mark per version). Posts, schedules, Postiz jobs and renders belong to a version number, so
   a new number has none. The round-20 caption pin (`captionsOwn`) isn't copied: a standalone version needs none.
4. **Copied texts get their own ids**, so no text in one version shares an id with a text in another.
5. **Trim, crop, cover, aspect, markers and platforms stay one edit for the clip**, shared by every version (Eric's
   round-20 rule: those are one edit per clip, and bulk edits reach every version). The version list now says so in
   plain words: "Each version is its own copy for a repost: editing one never changes another. The clip's Title, trim,
   crop, cover, size, markers and platforms are shared by every version."
6. **Every way a version is made goes through the same copy.** Editor: "New version from vN" copies the version being
   edited (before: an empty version that followed the latest), and each row's "Duplicate as a separate version" copies
   that row. Library/⌘K "Duplicate latest version" and copyright "Re-upload as a new version" copy the latest. `djq text
   / caption / youtube-title --version N` on a version that doesn't exist yet makes it as a copy of the one before.
7. **`Store.save` and bulk undo are the backstop.** A v2+ saved without the flag (any older path) first gets what it
   shows copied in and the flag set, so it can't start following another version again; an unreadable sibling row never
   blocks the save. Undoing an older bulk batch separates the restored versions the same way. Undoing schema 11's own
   batch puts the versions back linked, so it needs force and says why.
8. **Existing versions were separated by schema 11, losslessly.** Each v2+ gets the fields it took from earlier
   versions copied in and the flag set. Checked per clip before writing: every version of the clip must resolve to the
   same content (texts, look, timing, captions); a clip that wouldn't is left as it was and logged (none on the real
   copy). Only the JSON is written, `updated_at` is kept (no preview redraw), render hashes don't change (no
   re-render), caption output doesn't change (no Postiz update). One journaled batch (`separate-versions`, undoable
   with `djq bulk undo`). The database is backed up to `<app support>/backups/queue-before-schema11-*.sqlite` first.
   Proven on a copy of the real database taken 2026-11-12 17:50: 84 versions on 67 clips checked, 11 clips with v2+
   separated, every version identical, Ready to repost marks and `updated_at` unchanged.
9. **The "from v1" badge stays in the code** for data from before schema 11 that a restore could bring back; a
   standalone version never shows it.
10. **Bulk caption changes on v1 skip standalone versions** (they can't reach them), so `keepLaterCaptions` pins
    nothing new. Pins already stored stay and change nothing.
11. **Follow-up, not in this round:** after the highest version is deleted, the next new version reuses its number,
    and so that number's posts and repost history (review finding 8, older than this round).
