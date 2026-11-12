# Round 29: caption defaults from the editor

Eric asked to set caption defaults right from the editor's Caption section, without going to Settings.

1. **One "Make default for new clips…" form at the foot of the Caption section.** It lists the clip's caption template, hashtag groups (in the clip's order), extra hashtags, YouTube title template and the platforms it posts to, each with a checkbox. Parts that differ from New clip defaults start ticked; parts that already match say so and can't be ticked. Why: one place for the whole setup, same inline pattern as the New group and template forms (Mobbin refs in the evidence folder).
2. **New clips only, unless Eric says otherwise.** Saving pins every existing clip that follows a changed default to the old value, so what it posts (captions, tags, YouTube title, platforms) doesn't move. A switch, shown only when it matters, says "Also update N clips that use the current defaults": on, clips without scheduled or posted posts follow. Clips with posts always keep theirs (the `CaptionHold` guarantee). Why: the brief said defaults never reach existing clips silently; the switch keeps the old Settings behaviour one click away and names the count.
3. **A written caption or a typed YouTube title can't become a default.** The row says why and points at "Save caption as template…". Why: defaults are templates and groups; Eric's own words for one clip aren't a template.
4. **"Post to" counts as the per-platform choice.** The editor has no per-platform caption template control, and own captions per platform are text for one clip, so they stay out. A photo post leaves the YouTube default as it is (photo posts never go to YouTube).
5. **The template menu's "Set as default" now opens the same form with only the template ticked**, so both ways in follow the new-clips-only rule. The core `CaptionTemplates.setDefault` stays for `djq` and the older script.
6. **Long-form videos are left out** of the pinning: they never take a caption setup.
7. One journaled batch (`caption-defaults`), so the toast's Undo restores the defaults and every pinned clip exactly; an open editor session moves past it like the other caption batch actions.
