# DJ Queue round 14 — decisions

Small previews play only while hovered. Eric reported Calendar cards that played with no hover and kept playing, with sound on the next one. A real window confirmed the cause before anything changed: Calendar Week, Calendar 3 Day, Queue Cards and Edit Cards each played up to 4 clips at rest; Queue Grid was already right.

## The rule

- **Size decides.** A large preview plays by itself (Single, Score Single, the full preview, the editor); every small preview shows its cover and plays only while the pointer is on the clip or it has keyboard focus. Why: covers at rest are calm, and hover is a clear request. Artlist and Instagram grids show covers at rest (mobbin.com/screens/41b3a65f-6b82-447c-a1bf-15afd389f328, mobbin.com/screens/86258191-3786-4a3f-b619-f4ac6a31d332).
- **This reverses round 2 decision #12 for Cards and the round 3 line "Cards/List follow the autoplay setting".** Why: four moving cards is the noise round 3 already removed from grids.
- **One rule in `PreviewPlayback.plays`; the private copies in `QueueCards` and `CalendarCover` are gone.** Why: a second copy is how the Calendar missed the grid rule.
- **`gridHoverOnly` keeps its stored name.** Why: no migration; only the label changes, to "Small previews: play on hover only".
- **Calendar covers play muted on hover; the mute button plays the sound.** Queue, Edit, Score and Library keep "Unmute on hover". Why: the Calendar is an overview; Eric asked for sound on hover in round 3 and the other pages keep it.

## Choices the spec left open

- **With hover-only off, past Calendar days still wait for the pointer.** Why: it's the old behaviour the switch promises to bring back, and past clips would otherwise take the 4 slots.
- **List thumbnails play while hovered in both switch positions.** They used to play on hover only when "Unmute on hover" was on. Why: the same rule everywhere, and a list never plays every row.
- **"Which clips play" is disabled while hover-only is on, and says why.** Why: it only changes anything with hover-only off, and the old description promised otherwise.
- **The "Autoplay previews" description says "lists, Score and the Calendar show covers".** Why: the full preview and the editor still play with Autoplay off, so "every preview" would be false.

## Hover exit

- **`dsPlaybackHover` is the one shared guard; the hover sites only swap `.onHover` for it.** While SwiftUI says a region is hovered, a timer checks ten times a second that the pointer is inside the region's visible rect, its window has focus and no menu is open. Why: SwiftUI reports an exit only when a mouse-moved event reaches the window, so it can't see a scroll under a still pointer, a menu, a drag or the app going away.
- **The check is in common run-loop modes.** Why: menus and drags hold the run loop in tracking mode.
- **Hover comes back when the check passes again and SwiftUI never reported an exit.** Why: a menu closed with the pointer still on the card should carry on playing.
- **Hover controls stay on plain `.onHover`; only playback uses the guard.** `DSClipCard`, `QueueCardList` and the Calendar cards hold both. Why: the guard reads as left while a menu is open, and removing a ⋯ button under its open menu could close it.
- **When a preview stops wanting to play, it tears its player down straight away.** Why: a removal inside a hover animation keeps the view, and any sound, until the fade ends.
- **A hover-muted clip forgets the mute when the pointer leaves, even if another clip took the hover first.** Why: moving straight to another card left the mute behind, so the first card came back silent.
- **Focus means the app is active and the window is key.** Why: the spec's "window losing focus". A clip won't play under a pointer in a background DJ Queue window.
- **A scrubber drag holds the hover until it ends (review fix).** The guard can't tell a drag from a pointer that left, and the track sits inside the preview, so reaching 0 % or 100 % overshoots the edge. A gesture state also clears if the drag is cancelled. The guard doesn't read the mouse button, because that would keep a Calendar drag playing.
- **A fading player view stays released (review fix).** SwiftUI's last update on a view fading out would build a new player for 1 ms. Each release also gives the next player a new view identity, so coming back mid-fade can't revive the released one.
- **The check pauses while the app is inactive, with 50 ms of timer tolerance (review fix).** Why: on an always-on Mac a region can stay hovered all night; activation restarts it.
- **A keyboard-focused Score Grid tile counts only while its window is key (review fix).** Why: otherwise it's the one small preview that keeps playing with the app in the background.
- **A hovered Calendar cover gets a priority slot (review fix).** Why: with hover-only off and 4 covers playing, hover used to take a slot through sound; muted covers lost that.

## What the probe can and can't show

`DJQ_SNAPSHOT_GALLERY=1 DJQ_HOVER_PROBE=1` opens the real window on scratch data, reads the budget and the real players, and writes a plain log to `evidence/r14-hover`.

- **Pointer moves are forwarded to the guard.** macOS won't let the app move the pointer, and SwiftUI's hover follows the real cursor. Real SwiftUI events do reach the guard (the log counts them) and are dropped during a run, so the guard's real-cursor path isn't exercised. Eric's hand check covers that, with a real drag and a real right-click menu.
- **Driven for real:** leave, straight to another card, scrolling, a real menu opening and closing, hiding the window, the page changing, leaving and coming back inside a fade, a scrubber drag past the edge (mouse events to the window's content).
- **Stand-ins:** the app going to the background (a flag; the probe never activates the app) and a drag (the pointer moves with no events and `calendarMove` makes the drop; a real drag session needs the real mouse).
- **The key-window check reads the real window, but only its true side is reached.** While the app is inactive, two windows both read as key and `resignKey` changes nothing, so a window losing key status needs the app active. `NSApp.isActive` is never read true in a run.
- **Not driven:** a display change. The rect check runs the same way after one. A keyboard-focused Score Grid tile: `controlActiveState` isn't `.key` in an inactive app either.
- **It can fail.** With the old rule back, 33 checks failed, including 4 players at rest on Calendar Week. With the guard off, 13 failed: scrolling, menus, focus, the hidden window and the drag. Eric's report reproduced in the first of those runs: hovering a Calendar card gave it sound while the other 3 kept playing.
