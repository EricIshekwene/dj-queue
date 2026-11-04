# DJ Queue round 7 — decisions

Routine decisions made while building, one line each with the why.

## Postiz (C2)

1. **Debounce lives in `decide()` as a new `.settle` decision.** Only the content-hash branch (caption, title, hashtags, template, Postiz settings) waits; channel, render and move are checked first and stay immediate, and every cancel returns before it — so cancels can never be delayed by a pending edit.
2. **Stable-since is per job, in kv `postiz.settle.<job id>` (`{hash, since}`), not a schema column.** Schema v6 belongs to another owner this round; kv needs no migration, and a stale row is harmless (swept at the start of every publish step, also when Postiz is off, for jobs no longer open).
3. **`since` is stored as seconds since 1970 (Double).** Exact, so the 120 s boundary can't fire early from a rounded JSON date. A `since` in the future (clock stepped back) restarts the clock at now, so the wait never exceeds 120 s.
4. **Any new hash restarts the clock; an edit back to what Postiz has clears it.** Otherwise "edit → revert → same edit again" would replace without waiting.
5. **The safety window wins.** Within 5 min of the slot a content change is `.hold` exactly as before, also when its 120 s already passed; the debounce never extends past the window and never creates anything (the job stays live, so no second copy can be made).
6. **One quiet "waiting for edits to settle" event per job** (`markNotified("postiz.settle:<job id>")`), plus "waiting on edits for N" in the publish summary; no notification.
7. **Delete-retry notices are keyed on job + kind of failure** (`postiz.deleteRetry:<job id>:<kind>`, kind = the `PostizError` case without its message). Budget-exhausted retries every tick are one event; a different failure (e.g. a 500 after the budget frees up) is logged once more. Attempts and `lastError` are still updated every try.
8. **Content edits are effectively frozen from ~7 min before the slot** (120 s settle + 5 min safety window): accepted, because a late edit replacing a post minutes before it goes out is the riskier side; docs/postiz.md says so.

## Caption (C1, C3–C6)

Session-level decisions (migration freeze rule, `{hashtags}` suffix, title templates as a settings list, "hashtag
groups" copy) are D2–D6 in the session record. Routine ones, one line each with the why:

1. **Migration identity step is outside the journaled batch.** Appending "\n{hashtags}" to written captions changes no
   output, so `djq bulk undo` of the migration returns to captions that read exactly as in v0.7.2 (proved: 62/62 clips).
2. **The batch skips revalidation inside `Store.init`;** the next engine tick re-derives stages (no stage move while the
   database opens).
3. **A platform whose caption would still differ after freezing gets its old caption as its own** (safety net inside the
   migration; the migration throws and changes nothing if identity still fails). Not needed on Eric's data.
4. **Whitespace-only written captions are left alone** (they already meant "use the template"; Eric's DB has one).
5. **A settings row without `defaults.hashtagSetIds` (or no row) means the old default groups** for the before-state,
   written out explicitly in the identity step so the undo restores them.
6. **"Built-in" = the six seeded ids**, edited or not; any other group is Eric's and stays.
7. **A caption ending in "\n{hashtags}" builds as body + "\n" + tags (or just the body with no tags)**, i.e. exactly the
   v0.7.2 rule for captions that had no token; other `{hashtags}` captions fill and trim as before.
8. **Hashtag changes swap the tags in place: the old run first, else tag by tag** (new ones join the last hashtag line or a
   new line); whole tags only, a tag already anywhere in the caption is never added twice.
9. **Per-platform captions are not retagged** — they're the platform's own text ("Drop hashtags for X" made them on
   purpose); the section says so.
10. **Choosing a template rewrites a written caption (one undo step, toast says ⌘Z brings it back);** the picker shows
    "Your own text" while the caption is written. Spec: Eric tries templates back to back.
11. **Typed text equal to the template's output stays "follows the template";** clearing the field also goes back to the
    template (the field stays empty until something else changes it, with a hint).
12. **A later version that inherits a written caption can't switch back to a template** (a version only adds to the one
    before it); the picker is disabled with that reason. Edge case for reposts.
13. **Typing is applied to the model 250 ms after the last keystroke** (and before any other change, Done, ⌘Z, clip or
    version switch); the field keeps its own text so the cursor never jumps.
14. **Root cause of "can't edit past a length":** the field was bound to a recomputed caption, so after each keystroke the
    text view was reset and the cursor jumped to the end (typed characters landed at the end); and the field was fixed
    at its minimum height (`fixedSize` used the ideal = min height) with no scroll bar. Both fixed in place.
15. **"Froze" — per-keystroke cost** (2,100-char caption, debug build, real NSTextView): 41 ms → 7–9 ms median. Causes fixed:
    the text overlay PNG re-rendered on every caption keystroke (overlay key was the whole version), the resolved version
    was recomputed dozens of times per update, every keystroke republished the whole editor (`saving = true` on each).
16. **Extra hashtags apply after a 600 ms pause or ↩,** not per keystroke (partial tags no longer churn the caption).
17. **Groups and extra tags have separate ↺ resets** (one reset used to clear both).
18. **Group category headers show only when there's more than one category;** new groups go in "My groups".
19. **Deleting a hashtag group is undoable and also removes it from the default groups** (was: not undoable, and a default
    group couldn't be deleted until removed elsewhere).
20. **Deleting the default YouTube title template is refused** (pick another default first); the last template can't go.
21. **YouTube title: the count shows always (n/100), the picker shows "Your own title" while one is typed;** ↺ goes back
    to the template's title.
22. **Settings → Captions & titles order: hashtag groups, YouTube title templates, caption templates, titles** — the groups
    Eric asked for are first instead of below five tall template editors.
23. **Held clip chip:** jumps to the first issue that has a section; when the only problem is the hold, clicking shows
    "Sent back from Queue — send it to the Queue when it's done" and the tooltip names Send to Queue (next to the chip).
24. **`R6PostizModelTests.schemaV5…` now expects `user_version >= 5`** (one line in a Postiz test file: schema 6 runs right
    after it). No other Postiz file touched.
25. **`djq hashtag-groups` / `title-templates` are journaled** (`bulk undo`) so agents stay on the one data door; the skill
    says not to change groups unless Eric asks.

26. **"Drop hashtags for X" drops every hashtag in the text** — groups, extra tags and tags typed by hand (review M1);
    "has hashtags to drop" is read from the platform's caption text, so a typed-only caption can be fixed too.
27. **Removing a tags-only last line trims what's left** (no trailing newline or space posts; review L1).
28. **Clips whose posts went out with a copyright outcome (muted, blocked, removed) are frozen too** (review L2): the record
    keeps what was posted. Only failed and skipped posts don't freeze.
29. **The YouTube shortened-title notice uses the header's numbers** ("…120 characters — it goes out shortened to 99 to fit
    100"; review L6). The header shows what is sent, or the typed length when a typed title is over.
30. **djq help, usage and unknown commands never open the database** (review C7, from an incident: `djq postiz --help`
    ran the schema-6 migration on the DB it found). `djq`, `djq help`, `djq <cmd> --help|-h|help` and unknown commands
    return before `Store` is opened; test checks a fresh DJQ_HOME stays without a database.
31. **Known, not changed (review L3):** in v2, clearing the caption field (or typing the template's text) falls back to
    v1's written caption — a version only adds to the one before it, so v2 can't say "template" over v1's text. The
    template picker already says so (decision 12).
32. **Known, by design (review L4):** editing a group's tags in Settings changes template and `{hashtags}` captions, not
    written captions that already hold the old tags — a written caption is Eric's text; delete's confirm says so too.
33. **Known (review L5):** `djq bulk undo --force` of a batch from before schema 6 restores its written captions without
    the "\n{hashtags}" suffix, so they post without the implicit hashtags. Without `--force` such an undo is refused
    (the identity step changed those rows).

### C6 review — what was broken or confusing in Caption, and the fix

- Cursor jumped to the end after each keystroke → field owns its text (14).
- Field never grew (fixed ~84 pt, no scroll bar) → grows to 340 pt, then scrolls with a bar.
- Field was empty with the template output as grey placeholder → shows the real caption that posts.
- Template picker disabled once a caption was typed → always available; rewrites with undo (10).
- Separate read-only hashtags line duplicated the caption → removed; the caption shows them.
- Typed caption silently got the hashtags appended on a new line (what you saw wasn't what posted) → literal.
- Groups were the six built-ins with tags Eric didn't want → his own groups, none by default (C3).
- One ↺ cleared groups and extra tags together → separate (17); extra tags churned per keystroke → on pause (16).
- Warning dot / "to fix" chip pointed at Caption for held, missing-file and unreadable clips (C1) → exhaustive mapping;
  tooLarge → Platforms; a missing-template message now shows in Caption.
- "Close to the Instagram limit · 2,160/2,200" wrapped mid-phrase → one text run.
- Platforms with their own caption or own default template weren't mentioned under the field → hint names them.
- YouTube title: only a placeholder, the template editable only in New clip defaults as raw text → picker + real
  editable title, templates in Settings (C5).
- Typing a long caption redrew the whole editor and the overlay → fixed (15).
