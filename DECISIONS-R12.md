# Round 12: bulk captions (v0.10.2)

Eric: give many clips a text and several hashtag groups at once, either by using a template or by picking a template plus several
groups. The old Caption menu took one pick at a time and a group pick replaced the rest.

What the data showed: no bulk caption, template or group batch had ever landed. The confirm sheet worked when driven by hand, so the
failure was the menu: one group at a time, two items that changed nothing on clips already on the defaults, and no sight of the result.
Every untouched clip still posted the default template, with its set line and no hashtags.

1. **A dialog replaces the menu.** Several picks need a surface that stays open, and the preview is the point. References: Shopify's
   bulk "Add tags", Buffer's composer with its preview. Built from DSDialog and DSChip.
2. **Groups add and remove per clip, never replace.** A chip shows all, none, or some (a dash). Picking one group can't take another
   away. A click cycles: on for all, off for all, back to how the clips were.
3. **Template chips, not a dropdown.** Eric's templates stay in view, one click each, like the groups. The default's own name isn't
   shown twice.
4. **Click order is caption order.** Added groups go after the clip's other groups, in click order. A clicked group a clip already has
   moves to its place, so every clip ends on the same tags. A group already on all clips can't be moved by clicking: a click takes it off.
5. **The dialog is its own confirmation.** Apply is one `caption` batch with one Undo; no second sheet.
6. **Clips with scheduled or posted posts are skipped,** with the reason, so their captions stay byte-identical. They don't count toward
   the chips. This is stricter than the single-clip part chips (`BulkActions.togglePart`), which lock only once a post went out: a pass
   over many clips can't be read one by one, and each scheduled clip would go back to Postiz. A scheduled clip can still be changed in the editor.
7. **Picking a template replaces a written caption, as in the editor,** and the dialog counts them first. With Keep captions, a written
   caption keeps its words and only its hashtags change.
8. **Save as template types the groups the preview shows for every clip into the template, and keeps `{hashtags}`.** Typed tags keep
   their order and each tag appears once, so a group added to a clip later still shows. On clips with the same groups the caption
   doesn't move; a clip with an extra group gets it after the typed tags. Started from Keep captions, the template is text then
   hashtags (what Eric's hand-edited captions are), not the default template's set line. The form shows the text before it saves.
9. **The preview shows the shared caption; notes cover the rest:** hashtag caps with what they drop, platforms that post something else,
   captions too long, Queue clips that would go back to Edit, templates that hide the groups. Lines appear only when true.
10. **`djq caption-templates` and `djq bulk caption`,** because agents write only through `djq`.
11. **`ScriptAnchor`:** a view that takes no clicks, so scripted runs click where a control really is. SwiftUI's accessibility tree isn't
    built for a background window.
