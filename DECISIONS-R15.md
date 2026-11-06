# Round 15: bulk selection and crop offset (v0.11.2)

Eric edited 22 clips in one pass and lost the selection, so he couldn't send them on. He also wants one crop offset for clips filmed
horizontally, checked clip by clip the way the Caption dialog works.

1. **A bulk edit keeps the selection.** `BulkRequest.clearsSelection` is gone. Clips that leave the screen's stage (Send to Queue, Exclude)
   drop out on every refresh (`pruneSelection`), even when an empty state has replaced the list, so the bar goes when nothing selected is
   left. A bulk edit that takes clips out of a filter keeps them selected, and the bar says how many are hidden: with "No crop" on, cropping
   22 clips mustn't lose them. A search or filter changed afterwards drops hidden clips as it always did.
2. **The offset is where the crop's centre sits, as a share of the frame's width,** from the centre. One number works for any source
   size. Zoom and height stay as they are, and a crop never leaves the frame.
3. **The slider moves every clip, dragging the crop moves one.** A dragged clip follows its own number until "Use the slider". References:
   Square's "Position image" (picture over one slider), Meetup's alignment under the crop, Buffer's preview beside the controls.
4. **A clip with its own crop keeps it unless asked.** Own means not where the default puts it: Send to Queue stamps the default crop, and
   that one was never checked, so it moves with the slider. "Also move the clips with a crop already" takes the rest in, and dragging one
   moves it either way. The slider opens at the median of those own crops, or where the default puts these clips, so an untouched dialog
   changes nothing. Under the "Same as last crop" anchor a stamped default can read as his own; nothing records who placed a crop.
5. **Clips that are only scheduled can move; a clip stays once any platform could post it.** His 22 went to the Queue on the default crop and
   post from Sunday, so this has to reach them. The engine renders again from the edit hash and Postiz is replaced. Locked: a post went
   out, a post is due or overdue, Postiz says published, or a job within 10 minutes of its slot (the 5-minute hold plus a margin for
   a tick), because then platforms would end up on different crops. Undoing a crop pass obeys the same lock. The editor has no such lock
   yet, so bulk is the stricter of the two.
   It differs from a Caption pass, which skips scheduled clips, because a crop is checked here clip by clip.
6. **The dialog shows the whole frame and the clip as it will post,** with its on-video text. A frame comes from the clip's cover time.
7. **The drag is an AppKit view,** because SwiftUI gestures over this dialog didn't reach it in the scripted window, and a drag that can't be
   driven can't be checked. It also takes the first click.
8. **Crop is on the Edit bar, and Kind moved into More,** because six labelled actions wrapped in the 720 pt bar. It's also on the card menu,
   the Queue's More and the Library's More. The Library is where scheduled clips can be selected.
9. **`djq bulk crop-offset`,** because agents write only through `djq`.
