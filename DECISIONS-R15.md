# Round 15: bulk selection and crop offset

Eric edited 22 clips in one pass and lost the selection, so he couldn't send them on. He also wants one crop offset for clips filmed
horizontally, checked clip by clip the way the Caption dialog works.

1. **A bulk edit keeps the selection.** `BulkRequest.clearsSelection` is gone. Clips that leave the screen (Send to Queue, Exclude) drop out
   of the selection by themselves, because the lists already prune it, so the bar goes away only when nothing selected is left.
2. **The offset is where the crop's centre sits, as a share of the frame's width,** from the centre. One number works for any source
   size. Zoom and height stay as they are, and a crop never leaves the frame.
3. **The slider moves every clip, dragging the crop moves one.** A dragged clip follows its own number until "Use the slider". References:
   Square's "Position image" (picture over one slider), Meetup's alignment under the crop, Buffer's preview beside the controls.
4. **A clip with a crop keeps it unless asked.** Eric checked those by hand. "Also move the clips with a crop already" takes them in, and
   dragging one moves it either way. The slider opens at the median of the selected clips' own crops, or at the centre.
5. **Clips that are only scheduled can move; clips that went out can't.** His 22 went to the Queue on the default crop and post from Sunday,
   so this has to reach them. The engine renders again from the edit hash and Postiz is replaced, the same path as an editor edit. Same
   rule as the part chips (`CaptionParts.lockReason`). It differs from a Caption pass, which skips scheduled clips, because a crop is
   checked here clip by clip and the reason to reach them is this one.
6. **The dialog shows the whole frame and the clip as it will post,** with its on-video text. A frame comes from the clip's cover time.
7. **The drag is an AppKit view,** because SwiftUI gestures over this dialog didn't reach it in the scripted window, and a drag that can't be
   driven can't be checked. It also takes the first click.
8. **Crop is on the Edit bar, and Kind moved into More,** because six labelled actions wrapped in the 720 pt bar. It's also on the card menu,
   the Queue's More and the Library's More. The Library is where scheduled clips can be selected.
9. **`djq bulk crop-offset`,** because agents write only through `djq`.
