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

## v0.8.1 — make hashtag groups from the editor

Eric: "allow me to create hashtags groups from within the editor".

1. **Inline form under the chips, not a popover.** The caption stays in view and updates in place, and a typed caption keeps
   its place. A native popover is a separate window that would take the key window away from the field.
2. **New group is the main path, also in the empty state;** "Manage in Settings" stays beside it. The form replaces both while
   it's open, so Esc never has two meanings.
3. **Same table as Settings and `djq` (`hashtag_sets`).** Rules live in core `HashtagGroups` (shared with `djq hashtag-groups
   add`): tags split on spaces, commas and new lines, each through `Captions.normalizeTag`, duplicates dropped.
4. **Duplicate name (ignoring case and outer spaces): Save is refused, with the reason on the field and the button.** Merging
   would silently change a group other clips use, and two chips with one name can't be told apart (and `djq` can't address
   them). Editing a group may keep its name, even one another group shares. `djq` refuses too (review F4); Settings' rows still
   allow duplicates.
5. **Saving a new group is journaled (`hashtag-group-add`, `djq bulk undo` can take it back) but isn't in the clip's ⌘Z.** ⌘Z
   takes the group off this clip and keeps the group. The UI doesn't mention it: the chip stays there, off.
6. **Focus: Save leaves the keyboard nowhere; Cancel/Esc goes back to the caption if Eric was typing there.** After Save a focused
   text field would take ⌘Z for its own typing instead of taking the group off; with nothing focused ⌘Z undoes the toggle and
   Space plays. ↩ in Name goes to Hashtags (or saves when tags are already there); ↩ in Hashtags saves.
7. **Edit and delete are on the chip's context menu (cheap, so done).** Edit reuses the form. Delete is Settings' code moved to
   `AppModel.confirmDeleteGroup`: same confirm, same journal, Undo on the toast. The editor's confirm doesn't promise ⌘Z, because
   ⌘Z in the editor belongs to the clip. In the snapshot harnesses (no `AppModel`) the Delete item is absent.
8. **Editing a group swaps its tags in this clip's written caption (one undo step); other clips without posts follow decision 32.**
   The clip on screen would otherwise visibly disagree with the group just saved. Clips with posts are decision 16. Edits
   revalidate (tags can push a clip over a limit); a new group doesn't (no clip uses it yet).
9. **The editor re-reads groups on ChangeSignal,** so Settings over the editor, `djq` and Undo on a delete toast reach the chips.
   Before this a group made in Settings didn't appear until the clip reloaded.
10. **The form opens below the fold when New group sits at the bottom edge,** so the inspector's `ScrollViewReader` brings it in
    (`NSView.scrollToVisible` does nothing in a SwiftUI scroll view).
11. **Save is `outline`:** the editor's one primary is Done, and `secondary` disappears on the form's sunken fill.
12. **`DSTextField` gained `focusToken` and `autoFocus`,** the same contract as `DSSearchField`. No new components.
13. **Bug found on the way, fixed: ⌘Z could run Redo.** The live script showed a plain ⌘Z firing the hidden ⇧⌘Z button on about half
    the launches (two SwiftUI shortcuts sharing "z"; which one won changed per launch), leaving the change in place. Undo/redo is now
    read from the key event in the editor's key monitor (`EditorUndoKeys`), matched on the character so other keyboard layouts work.
14. **Model checks live in `DJQ_EDITOR_SELFTEST` and `DJQ_EDITOR_GROUP_SCRIPT`,** not `swift test`: the test target imports only
    DJQCore. Core tests cover the rules; the script drives the real fields, a mouse event through the window's hit testing, and
    keys through AppKit, all handed to this process only.
15. **Not verified by machine (Eric to try by hand):** ⌘Z and ⇧⌘Z in Caption and in the form's Name field (the decision is tested,
    `sendAction` needs a real key window); the disabled Save tooltip on hover; the chip's right-click menu (macOS blocks synthetic
    pointer input into a real menu; its actions are covered by the self-test and script).

### v0.8.1 review fixes

16. **One core path for group edit and delete: `HashtagGroups.update` / `.delete`, used by the editor, Settings and `djq` (F1, F2).**
    Clips with scheduled or posted posts (`clipsWithPosts`) that use the group are frozen first, as schema 6 did: every version's
    resolved hashtags go into its extra hashtags and ALL its group ids are cleared, in the same `record` with `ids:`, so undo
    restores them. All ids, not just this group's: moving one group's tags would reorder them, and order is part of the caption and
    the hash. Captions, YouTube tags and Postiz content hashes stay byte-identical; the test covers template, `{hashtags}`, literal and
    default-group clips for both edit and delete, and fails on all of them with the freeze off. A rename reaches nothing and freezes nothing.
17. **The dialog, edit form and Settings give the counts** ("N clips with scheduled or posted posts keep these tags"), and the false
    "captions you wrote keep their text" is gone: tags typed into a caption stay, nothing wider is promised.
18. **Settings' group rows save 600 ms after typing stops,** through the same path: each save is now a journaled change that can
    freeze clips. A pending save for a group deleted meanwhile leaves it deleted.
19. **A frozen clip on screen reloads its versions and its ⌘Z history starts over** (the steps refer to versions that changed under
    them). Tags saved on such a clip say so in the toast.
20. **While an overlay covers the editor, ⌘Z belongs to the app (F3),** so Settings' "Undo (⌘Z) brings it back" is true over the editor
    too. `EditorLogic.undoKey` makes that call and has `swift test` coverage (F10).
21. **`djq hashtag-groups add` and `edit` apply `HashtagGroups.problem` (F4):** blank names, no tags and duplicate names are refused, and
    the cleaned name is printed. This reverses part of decision 4.
22. **An edit form closes when its group goes away, and Save never recreates it (F6).** After an edit that swapped this clip's caption,
    the toast says ⌘Z restores only the caption (F7): the group edit is journaled separately.
23. **`DJQ_NO_SIGNAL=1` now lives in `ChangeSignal` (F8).** Every `--snapshot` run sets it, as does the test fixture; the signal then stays
    inside the process, so the scripts still exercise the editor's reload and a dev run can't nudge the installed app.
    The local post runs off the main queue: an observer on `.main` makes the poster wait for it, which deadlocked a live run from the
    main actor. A main-queue `async` wouldn't help (that block would wait on the same queue). A test posts from the main actor.

### v0.8.1 re-review fixes

24. **An editor session never claims a group change (R1).** `BulkActions.commit` moves the session past every `hashtag-group-edit` or
    `-delete` batch since it opened, wherever it came from (the app, or `djq` in another process), so closing the editor journals no
    "Edits to X" for a freeze and that Undo can't un-freeze a scheduled clip. Done in core rather than only in the app so `djq` is covered.
25. **Group edits from the editor and Settings go into the app's history (R1, R4):** toast with Undo, ⌘Z after the editor closes. Settings
    now shows that toast after each typing pause.
26. **Unsaved changes merge with a freeze made underneath them (R2).** `HashtagGroups.keepingFreeze` takes each frozen version's groups and
    extra tags from the store and keeps the rest of the unsaved work; the clip's ⌘Z history starts over. Known limit: a `djq bulk undo` of
    a freeze while the editor has unsaved changes on that clip isn't merged back; the next save keeps the freeze, which is the safe side.
27. **Undoing an older group batch is refused when it would change a clip with posts outside that batch (R3):** such a clip took up the group
    later. `--force` still overrides, as for every other undo conflict.
28. **⌘Z over an overlay stops at edits to the clip open behind it (R5):** "Close the editor to undo…". Those batches are split from the open
    session, so the editor's memory sits on top of them and an undo would be overwritten by the next save.
29. **Known, not changed:** Undo of a group edit leaves a caption already swapped by decision 8 as it is ("⌘Z restores only this caption" says
    which step undoes it). Fixing it would tie one clip's text to a shared group's undo.
30. **Copy (R6):** "No active clip uses this group" (excluded and long-form clips without posts aren't counted); if the count can't be read the
    dialog gives the rule without a number.

## v0.8.3

### Blank hashtag groups

1. **`HashtagGroups.pickable` and `label` are the one rule.** A group with a blank name and no real tag (whitespace and a bare `#` count as
   nothing) is left out of every chip row and menu, and doesn't count towards "No hashtag groups yet". A blank name with tags shows as
   "Untitled group". The stored row isn't changed, so captions and Postiz content read exactly what they did.
2. **A cleared name keeps the previous one (`keepingName`, inside `HashtagGroups.update`), and the row says "Needs a name".** Both, because
   Settings saves as you type: restoring the old name in the field would snap it back mid-typing, so the field stays empty and only the
   store keeps the old name. Tag edits made meanwhile still save. Clearing a name and nothing else saves nothing (no toast, no journal entry).
3. **Add hashtag group is a draft until Eric changes it.** It stays out of the database until the first edit with a name, then saves
   through `HashtagGroups.create` (journaled, so it has Undo). A row left untouched goes when Settings reloads, and a draft deletes
   without asking. A name with no tags still saves, as a named group always could.
4. **Settings shows every stored row, blank ones included,** so they can be fixed or deleted. The same goes for `djq hashtag-groups`.
5. **New clip defaults filters only what it shows,** so a hidden group already in the default list isn't dropped by an unrelated edit.
6. **The Edit screen's bulk menu follows the same rule,** so it can't offer an empty item. Not in the brief, same bug.
