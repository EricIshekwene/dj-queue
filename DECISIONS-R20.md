# Decisions: round 20, ready to repost and bulk edits on versions

Eric (2026-11-07): when editing several versions of one clip, mark each version ready so the repost cycle includes it. The
repost cycle itself isn't built yet. Same day: a bulk edit on a clip with several versions applies to every version except
captions, and the bulk UI says so.

1. **The flag lives on the version (`Version.repostReady`), in the version's JSON.** No schema change and no migration;
   versions without it are stored byte for byte as before. It never carries forward: v3 isn't ready because v2 is.
2. **Marking never moves anything.** It isn't an input to a clip's state, so `djq repost-ready` writes only the flag and
   doesn't recompute the state. The ONLY way from Edit to Queue stays Send to Queue. Tests check stage, Queue flag, slots,
   posts and resolved versions on Edit, held, Queue and scheduled clips.
3. **No preview or render churn.** The CLI keeps the version's `updated_at`; marking a v1 that was never saved writes a row
   stamped 0, and preview stamps skip 0-stamped rows. Render hashes never read it. The editor's switch writes through the
   same call, and undoing only a toggle writes only the flags, so list previews don't redraw (the live check proves it).
4. **Any version can be ready, v1 included.** A repost round may want to post the original again. Long-form is refused.
5. **The repost round's inputs are ready-made, read-only:** `Store.nextRepostReadyVersion(videoId:platform:)` and
   `RepostReady.candidates` give the ready versions a platform hasn't had (a skipped post doesn't count as having had it).
   The existing manual `djq repost` is unchanged.
6. **Editor:** a Ready to repost row at the top of the inspector once a clip has a second version (or the version is marked),
   a switch on every row of the version list, and a green check on the version picker. Each toggle is its own undo step.
   The words are "Ready to repost" everywhere, never just "Ready", which is the Queue's word.
7. **Filter and search:** a Reposts section (Ready to repost / No version ready) in the Filters popover on Edit, Queue and
   Library; ⌘K "ready to repost" finds the clips.
8. **Bulk captions stay on v1.** Before a caption-family bulk change writes v1, each later version whose caption would change
   gets the caption fields it took from earlier versions copied in and `captionsOwn: true`, so it stops inheriting captions.
   Only versions that would change are touched; bulk undo restores them. A field that followed the defaults still does.
9. **Reset to defaults → Text** resets the look, place and timing on every version, and keeps each version's words (the
   words are what makes a version).
10. **Every bulk dialog that touches version content says what it reaches** when a selected clip has v2 or later: the confirm
    sheet, the Caption dialog and the Crop dialog, plus a short toast detail. Score, kind and exclude aren't per version, so
    they say nothing.
11. **The live check** (`repost-ready`) clicks the inspector row for real. The version list is a native popover, so the
    check shows it in a second backstage window as a stand-in; events don't reach that window, so its switches are pressed
    through their action. Said so in the log.
12. **A version that follows a kept one is kept too.** Otherwise deleting the kept v2 later would hand v3 v1's new caption.
    The cost: v3 then stops following v2's later caption edits. The pin doesn't show in the editor yet; a follow-up can show
    "Keeps its own caption" with a way back to following v1.
13. **An open editor keeps outside changes.** Its saves keep a `djq repost-ready` mark and a bulk caption pin made while it
    was open, unless the editor changed those fields itself (`VersionMerge`).
