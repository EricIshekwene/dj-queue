# The one-video Postiz test (v0.7.0)

Goal: one clip, approved in DJ Queue, goes out on all six platforms through Postiz, and the live links come back into
the app. The first run is a **Test run**: nothing becomes public by itself.

| Platform | In a Test run |
|---|---|
| TikTok | sent to your TikTok inbox as a draft (finish it in the TikTok app within 24 h, then Mark posted in DJ Queue) |
| YouTube Shorts | uploaded **unlisted** |
| Instagram, Facebook, Threads, X | saved as **Postiz drafts**; nothing reaches the platform until you release them |

You can cancel anything that is still waiting: Postiz calendar → the post → Delete, or in DJ Queue send the day back.

## Before you start (once)

1. DJ Queue shows v0.7.0 (Settings → About, or `djq autoupdate status`). If it says **Update ready**, click
   Restart & update.
2. `djq postiz status` → "connected" and six channels. If it says "no API key" or "key refused": Postiz → Settings →
   Public API → copy the key → DJ Queue Settings → Platforms → Publishing → paste → Save (it goes to the Keychain).
3. Map the channels: `djq postiz map --dry-run` (check it lists IG @dj.lovd, TikTok @dj.lovd, Threads, FB "Dj lovd",
   YT @dj.lovdreal, X @djlovdreal), then `djq postiz map --yes`. Or pick each channel in Settings → Publishing.
4. Turn on **Test run**: `djq postiz test-mode on`, or the switch in Settings → Publishing. A "Test run" badge appears
   in the sidebar.
5. Route the six platforms to Postiz: `djq postiz publisher all postiz`, or each platform's Manual | Postiz control.

## The test

6. **Pick the clip.** Asabone x Forgiveness is the clip that's in the Queue now (round 6 fixed the bug that kept it
   out). Any clip with nothing missing in Edit works.
7. **Dry run (no calls):** `djq postiz test <video> --dry-run` prints the six requests (captions, titles, settings,
   slot times; the key shows as `<redacted>`). Check the YouTube title (≤ 100) and the TikTok title (≤ 90).
8. **Approve a one-day week.** Week → the current week → make sure only the test day has the clip (remove others or
   keep only one ready clip) → Approve. Slots that already passed today are sent 3 minutes after upload; later slots
   go at their time (FB 12:30, Threads 1:30, YT 3:00, X 5:00, IG 6:00, TikTok 7:00 pm NY).
9. **Render → Postiz.** Within a few minutes the render appears (Posts shows "Rendered"), then each platform reads
   "Scheduled in Postiz" or "Draft in Postiz". Open the Postiz calendar: six posts at the right times.
10. **Release the drafts** you want to see live (IG/FB/Threads/X): Posts → the platform → Release (or publish them
    from the Postiz calendar). YouTube goes out unlisted at its slot; TikTok lands in your inbox.
11. **Links back.** Within about 10 minutes of each post going out, DJ Queue shows Posted with the live link (Posts and
    Today). TikTok reads "In your TikTok inbox": finish it in the app, then Mark posted with the link.
12. `djq postiz status` and `djq doctor` should be clean (a Test run info line is expected).

## Afterwards

13. Turn Test run off when you're happy (`djq postiz test-mode off --yes` or the switch; it asks first). From then on new
    posts go out publicly at their slots, with the Mac on or off. Posts already made keep their Test run mode.
14. Any platform you'd rather keep doing by hand: set it back to Manual. Manual works exactly as before.

## If something goes wrong

- A post shows **Failed** or **© Blocked**: the platform's message is on the post. Copyright posts are never retried
  automatically; fix and press Fixed to re-queue the next day.
- **Fell back to manual**: the reason is shown (no key, channel not mapped, channel disabled, Postiz refused it). It's on
  Today like any manual post.
- **"Create result unknown"** (Doctor `postiz.create_unknown`): check the Postiz calendar, then `djq postiz resolve <post>`.
- Postiz allows about 25 calls an hour from DJ Queue; approving a full week takes a couple of hours to upload. Nothing is
  lost while it waits.
