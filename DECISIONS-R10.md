# DJ Queue round 10 — decisions

Routine decisions made while building whole-app search, one line each with the why. The calls made before the build are in the session record: search stays in ⌘K, ⌘F stays a page filter, literal matching only, sections by best tier then a fixed order.

## Engine

1. **Fields have three roles: primary, body, phrase.** Primary ranks like the title (the bare screen name on Go to rows). Body matches but says where. Phrase must match the whole query as a prefix: without it "12 nov" could take "12" from one date and "nov" from another.
2. **Every item's folded text sits in one flat byte buffer, scanned with `memmem`.** Folding happens once at index time; 5,000 items search well under the 10 ms budget.
3. **Highlight and snippet ranges are worked out per character, only for rendered rows.** Folding can change a character's length (ß), so byte offsets can't map back. Doing it per row keeps the keystroke path byte-only.
4. **Snippets come from the body field with the most query words.** A tie goes to the field listed first, and clip fields are listed most telling first (Tag, Text, Caption…).

## What's indexed

5. **A clip's caption is the text you typed, carried forward; a caption that follows a template isn't filled in.** Otherwise one line of boilerplate in a template would hit every clip. The template itself is found in Settings.
6. **Overlay text uses the resolved value and is skipped when it equals the title.** A second copy of the title adds a duplicate hit, not information.
7. **Tag is a body field, not a title alias.** The spec's "non-title hit shows where it matched" reads better with "Tag: yayo x johnny".
8. **Week items: every week with a plan or a state, plus this, next and last week.** "this week" has to work on an empty week. Nearest first, the coming week before the past one.
9. **A session with no clips isn't listed.** It would open an empty Library.
10. **Dates and month names are English, whatever the Mac's language.** The rest of the app formats days in English, so what you read is what you can type.
11. **Post dates carry short phrases only; weeks and sessions also carry the year.** Posts are the most numerous items, and a post is rarely looked up by year.
12. **Health places cover more than the five named: disk space and the render queue too.** They're on the same screen at the same cost.
13. **Runway opens Queue, not Health.** Health doesn't show it; the Queue toolbar's runway chip does. The row's subtitle has the numbers.
14. **The index rebuilds on every refresh, off the main actor.** Keeping it fresh by checking what changed would be more code than the work it saves, and it's small next to the rest of the load.

## Palette

15. **Health, Actions and Go to share the Actions chip but keep their section headings.** Seven chips is what the spec lists.
16. **"Show all N" switches to that kind's chip.** One way to see everything, and Tab, the counts and the chips stay coherent.
17. **A chip's list stops at 100 rows, with a note in the footer.** Each row is a SwiftUI view; past 100 you'd type more anyway.
18. **Rows carry their position, so hover and ↑↓ never search by id.** The old `ids.firstIndex` inside `ForEach` was quadratic and picked the first of two rows with one id. Results are also de-duplicated by id: "Actions for …" and a clip hit are the same row.
19. **The list is remembered per text, chip and data generation.** Arrow keys and hover redraw the palette without searching again.
20. **Back from a clip's page restores the text you'd typed.** Search made that the natural path; the old palette cleared it.
21. **⌘K while open clears the field too, through one `closePalette`.** Before, the toggle left stale text for the next open.
22. **A setting opens over the editor; it doesn't close it.** Same as ⌘, and the Open Settings row today. Results that go to a screen, or open a clip in the editor, close what covered them, whichever action got there (a comparison of screen and editor around the run).
23. **The palette sits above every modal, under the confirmation dialog.** A confirmation it asks for still has to show.
24. **Leaving for a screen also closes a quick look or the cheat sheet.** Either could be open under the palette now that it's on top.
25. **Opening a post clears its page's search, filters and status chip, not just what hid it.** All holds every post, and working out which chip would keep it adds a second definition of the tabs for little gain.
26. **Results don't touch the sort.** It can't hide a post.

## Settings

27. **The registry lives in DJQCore; `SettingsPane` holds the section titles and the app's `SettingsSection` reads them.** The test target can only see DJQCore, and the titles now have one home.
28. **Per-platform rows read "TikTok slot time", "TikTok order"…, not "TikTok".** Six rows called TikTok don't say what they are in a result list. They land on the row labelled TikTok.
29. **The registry test also checks the pane and the description, and fails on ghost rows.** A row moved or deleted is as wrong as a row missing.
30. **"Installed build" gets a fixed anchor.** Its label is computed from the version.
31. **`PublishingSettings` and `EngineSettings` got one line each** (an anchor), outside the owned file list but needed for those rows to land, and clear of the Postiz core and retry code.

## Empty states

32. **`DSEmptyState` takes one optional `Secondary` value, not five parameters.** A second optional closure would have taken over every existing caller's trailing closure.
33. **"Search everywhere" only shows when the ⌘F field holds text.** With filters alone there's nothing to carry over.

## Proof

34. **Keys reach the window through `performKeyEquivalent` and `sendEvent`, not `NSApp.postEvent`.** Posted key events are dropped while the app isn't active (`NSApp.keyWindow` is nil), and activating it would take the keyboard from whoever is at the Mac. They're still real `NSEvent`s through the same window entry points; every step that reaches the app works this way. Nothing in the proof falls back to calling the palette directly.
35. **`probeFrame` records where a row is, in snapshot runs only.** A row scrolled out of a lazy list has no frame, which is what proves it was scrolled to.
