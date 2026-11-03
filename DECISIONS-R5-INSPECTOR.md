# Round 5: inspector section separation (decisions)

Eric asked for clear separation between the editor inspector's sections ("I don't know which section is what"), the same for other right columns, built from existing components with Mobbin references, and a fix for an agent title-suggestion chip clipped on the right.

1. **Full-width hairline between sections, a `DSSectionHeader` title and 20 pt above and below each section.** Why: the inspector pattern in Framer, Webflow, Figma and Rive (Mobbin). `DSSeparator` and `DSSectionHeader` already exist, so nothing new was built.
2. **Field labels (Aspect, Crop, Trim, Kind, …) are secondary; Zoom and Place are small caption sub-rows of Crop.** Why: section title, field and sub-control now read as three levels. Before, Zoom looked like a peer of Crop and Trim.
3. **The Posts inspector's section titles use `DSSectionHeader` instead of the small eyebrow.** Why: the Metrics eyebrow was quieter than the Views and Likes labels under it. The section hairlines were already there.
4. **`DSFlowLayout` sizes a chip that's wider than its row to the row width.** Why: the chip truncates inside the column instead of being clipped at the edge, which fixes every flow row (title suggestions, hashtags, platforms).
5. **Title suggestion chips wrap to two lines, and the tooltip leads with the full title.** Why: long agent titles ("A x B x C x D x E") fit the 340 pt column. The tooltip bubble shows 3 lines, so the title comes first and the matched tracks follow when there's room.
6. **`DJQ_EDITOR_LIVE_SECTIONS=<dir>` captures each section from the real editor window.** Why: visual checks come from the running editor, not only from snapshots.
