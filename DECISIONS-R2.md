# DJ Queue — Round 2 decisions

Eric delegated every round-2 decision ("make a good decision"). One line each + why. Sections per agent.

## R2-CORE (core library, `djq`, metadata)

- **Edits store only overrides.** `Edit` fields are optional (nil = follow `Settings.defaults`); `aspect`/`coverIncludesText` are stored as `aspectOverride`/`coverIncludesTextOverride` under the same JSON keys. Why: north star #10; keeping the JSON keys makes the migration a value rewrite, not a format change.
- **Migration v2 rewrites only values equal to the round-1 hard defaults** (aspect 9:16, cover includes text = true) to "follow default"; every other value (crop, trims, cover time, a `false` cover-text) stays. Why: round 1 always wrote those two, so they were never Eric's choice, and the seeded defaults are identical — the resolved edit is unchanged (tested on a copy of the real backup).
- **A file DB is copied to `<app support>/backups/queue-before-schema2-*.sqlite` before migrating.** Why: cheap insurance for Eric's live scores.
- **Round-1 settings keys (`defaultStyle`, `defaultTextSize`, `defaultPosY`, `defaultCaptionTemplateId`, `defaultHashtagSetIds`) seed `Settings.defaults` when it is missing**, and stay available as deprecated forwarding properties. Why: lossless + the round-1 app keeps compiling.
- **Crop must still be confirmed per clip.** The default crop anchor only drives previews/thumbnails/proxies; `Make ready with defaults` confirms it (writes the rect). Why: framing is the one thing that can't be checked without looking; it keeps the 62 real clips in "needs edit" until Eric acts.
- **Text/caption readiness uses resolved values.** A clip whose text resolves from its Title (or "No text" for Talking) and whose caption resolves from an existing template has no text/caption issue; no explicit v1 is needed. Why: "clips store only overrides" — requiring explicit copies of defaults would contradict it.
- **Default text source = Title; with no title the text is empty (issue "Add text (no title yet)")** — never the tidied tag. Options: Title / raw tag verbatim / empty. Why: no in-app intelligence (#9).
- **Caption/YouTube `{text}` = overlay text, else Title, else raw tag verbatim.** Why: north star #9.
- **Over-limit captions stay over-limit;** `ValidationIssue` carries `count`/`limit`/`countWithoutHashtags`, and `Captions.withoutHashtags` is the explicit "Drop hashtags for X" (writes a per-platform caption override). Why: no silent changes (#9).
- **Rotating per-video hashtag sub-sets removed;** `Captions.hashtags(videoId:)` keeps the parameter but ignores it. Why: #9; parameter kept for app compile.
- **Prefill left the app.** The formatter is `scripts/prefill_titles.py` (stdlib, same rules, writes `title_suggestions` with source `prefill_titles.py`, confidence 0.3); `djq prefill` removed. `Prefill`/`PrefillRules` stay only as a deprecated shim (no core caller) so the round-1 app compiles. Why: #9; a shim avoids editing UI-owned files mid-rebuild.
- **Default trim = markers ± extra seconds (default 0/0); clips without markers use the whole file.** The render hash follows the resolved trim, so existing renders re-render once. Why: north star #5 (expected re-render).
- **Default kind applies to new clips at intake; `content-type: talking` still wins.** Why: manifest data beats a default.
- **Platforms default:** `defaults.platforms` (all six) + per-clip `skippedPlatforms` / `includedPlatforms`. Why: lets a default leave a platform out while a clip can opt in.
- **Safe-zone default platforms = TikTok + Instagram.** Why: the two most cropped-by-UI feeds; the editor can add more.
- **Resolved types encode deterministically (sets sorted).** Why: stable hashes and batch snapshots.
