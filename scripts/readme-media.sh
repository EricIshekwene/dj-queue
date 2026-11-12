#!/bin/zsh
# Turn hidden live-check captures into the README's media in docs/media. Nothing here launches the app: capture first
# with scripts/live-checks.sh (off every display, muted, dev data only), then run this on the same folder.
#
#   scripts/live-checks.sh <live dir> screens editor search text-layers bulk-caption editor-caption send-to-queue
#   scripts/readme-media.sh <live dir> [only ...]        (only: names from the lists below; default: all of them)
#
# Stills are JPEG, 1440 px wide. Clips are GIFs, 960 px wide, one step of the click-through every 1.4 s. When a fix
# changes a screen, add or update its line here and in the README (Ship step 8 in skills/djq-daddy/references/djq.md).
set -u
setopt null_glob
cd "$(dirname "$0")/.."
LIVE=${1:?usage: scripts/readme-media.sh <live dir> [only ...]}
LIVE=${LIVE:A}
shift
only=("$@")
OUT=docs/media
mkdir -p "$OUT"
STEP=1.4
missing=0

wanted() { (( ${#only} == 0 )) || (( ${only[(Ie)$1]} )); }

# still <name> <capture, relative to the live dir, without .png>
still() {
  wanted "$1" || return 0
  local src="$LIVE/$2.png"
  [[ -f "$src" ]] || { echo "missing $1: $src" >&2; missing=$((missing + 1)); return 0; }
  sips -s format jpeg -s formatOptions 82 -Z 1440 "$src" --out "$OUT/$1.jpg" > /dev/null || { missing=$((missing + 1)); return 0; }
  echo "still $OUT/$1.jpg ($(( $(stat -f %z "$OUT/$1.jpg") / 1024 )) KB)"
}

# gif <name> <capture> <capture> ...   (one step per capture, in order; CROP=w:h:x:y crops each capture first)
gif() {
  wanted "$1" || return 0
  local name=$1 list f
  shift
  list=$(mktemp -t readme-media)
  for f in "$@"; do
    [[ -f "$LIVE/$f.png" ]] || { echo "missing $name: $LIVE/$f.png" >&2; missing=$((missing + 1)); rm -f "$list"; return 0; }
    print -r -- "file '$LIVE/$f.png'" >> "$list"
    print -r -- "duration $STEP" >> "$list"
  done
  print -r -- "file '$LIVE/${@[-1]}.png'" >> "$list"   # the concat demuxer drops the last duration without this
  ffmpeg -v error -y -f concat -safe 0 -i "$list" \
    -fps_mode passthrough -vf "${CROP:+crop=$CROP,}scale='min(960,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$OUT/$name.gif" || missing=$((missing + 1))
  rm -f "$list"
  echo "gif   $OUT/$name.gif ($(( $(stat -f %z "$OUT/$name.gif") / 1024 )) KB, $# steps)"
}

S=screens
still queue          $S/18-queue-cards-light
still queue-dark     $S/18-queue-cards-dark
still score          $S/10-score-single-light
still edit           $S/1e-edit-single-light
still edit-cards     $S/13-edit-cards-light
still calendar-week  $S/calendar-week-light
still calendar-month $S/calendar-month-light
still calendar-day   $S/calendar-day-today-light
still posts          $S/37-posts-all-inspector-light
still library        $S/30-library-grid-light
still search         $S/3b-command-palette-light
still bulk-caption   $S/16c-edit-bulk-caption-light
still settings-defaults $S/45-settings-newClipDefaults-light
still settings-captions $S/46b-settings-captions-groups-light
still editor         text-layers/text-10-overlap-second-lane-light
D=editor
still editor-zones   $D/editor-07-zones-3-platforms-light
still editor-preview $D/editor-16-preview-compare-light
gif platform-previews $D/editor-10-preview-tiktok-light $D/editor-11-preview-instagram-light \
                 $D/editor-12-preview-facebook-light $D/editor-13-preview-youtube-light $D/editor-14-preview-threads-light \
                 $D/editor-15-preview-x-light

T=text-layers
gif timed-text   $T/text-01-default-closed-rows-light $T/text-05-advanced-open-light $T/text-06-second-text-light \
                 $T/text-07-colour-and-font-light $T/text-09-third-text-light $T/text-10-overlap-second-lane-light \
                 $T/text-11-bar-selected-light
gif timed-text-playback $T/text-17-scrub-02.0-light $T/text-18-scrub-05.0-light $T/text-19-scrub-07.5-light \
                 $T/text-20-scrub-10.0-light $T/text-21-scrub-18.0-light
gif preview-vs-export $T/compare-02.0-light $T/compare-05.0-light $T/compare-07.5-light $T/compare-10.0-light \
                 $T/compare-18.0-light
L=search/light
gif search       $L/01-caption-start $L/02-caption-opened $L/03-caption-caption-hit $L/04-caption-action-page \
                 $L/10-week-date-hit $L/11-week-week-open $L/21-setting-schedule-hit $L/22-setting-schedule-row-flash \
                 $L/23-setting-schedule-after-flash
B=bulk-caption
gif bulk-captions $B/bulk-01-selected-light $B/bulk-02-dialog-open-light $B/bulk-03-three-groups-light \
                 $B/bulk-04-template-and-groups-light $B/bulk-05-applied-light
C=editor-caption
# The caption script runs on a fresh database whose player stays black: show the inspector only.
CROP=iw*0.245:ih*0.62:iw*0.755:0 gif editor-caption $C/caption-01-group-on-light $C/caption-02-second-group-in-written-caption-light \
                 $C/caption-03-template-switch-light $C/caption-05-long-caption-light $C/caption-06-typed-mid-text-light
Q=send-to-queue
gif send-to-queue $Q/send-1-edit-before $Q/send-2-editor-open $Q/send-3-editor-nothing-to-fix $Q/send-4-edit-after-save \
                 $Q/send-5-queue-after-send
K=editor-keys
still settings-arrow-keys $K/keys-08-settings-try-it-light
gif editor-keys      $K/keys-01-space-plays-light $K/keys-02-typing-title-light $K/keys-03-click-away-then-space-light \
                 $K/keys-04-arrow-2s-light $K/keys-05-arrow-5s-light $K/keys-06-down-next-clip-light

R=repost-ready
# Round 20: Ready to repost per version, and bulk edits on versions. Header and inspector only (the player isn't the point).
CROP=iw*0.25:ih*0.5:iw*0.75:0 gif repost-ready $R/repost-02-v2-row-off-light $R/repost-03-v2-ready-light \
                 $R/repost-04-header-check-v2-light
still repost-versions  $R/repost-05-version-list-both-ready-light
still repost-filter    $R/repost-07-library-filter-ready-light
still bulk-versions    $R/repost-11-bulk-reset-versions-note-light
still bulk-caption-versions $R/repost-10-bulk-caption-versions-note-light

du -sh "$OUT"

# Round 21: photo posts and "Post at a set time". No player in these, so the whole window shows.
P=photo-import
gif photo-import     $P/photo-01-edit-before-light $P/photo-03-import-sheet-light $P/photo-04-import-sheet-post-per-photo-light \
                 $P/photo-06-edit-cards-added-light $P/photo-11-quicklook-photo-1-light $P/photo-12-quicklook-photo-2-light
still photos-in-edit     $P/photo-06-edit-cards-added-light
E=photo-editor
gif photo-editor     $E/photo-01-open-carousel-light $E/photo-04-frame-crop-zoom-light $E/photo-05-text-on-photo-3-light \
                 $E/photo-06-shows-on-2-3-light $E/photo-08-style-and-colour-light $E/photo-09-reordered-new-cover-light \
                 $E/photo-13-platform-note-first-4-of-6-light
still photo-editor-crop  $E/photo-04-frame-crop-zoom-light
still photo-editor-shape $E/photo-16-instagram-9x16-issue-light
still photo-preview-export $E/compare-canvas-export-light
A=post-at
gif post-at          $A/post-at-01-edit-photo-ready-light $A/post-at-02-dialog-open-light $A/post-at-05-two-days-out-light \
                 $A/post-at-06-set-toast-light $A/post-at-07-calendar-week-light $A/post-at-11-moved-next-day-light
still post-at-dialog     $A/post-at-05-two-days-out-light
still post-at-youtube    $A/post-at-22-youtube-quiet-hours-light
still calendar-set-time  $A/post-at-07-calendar-week-light

H=screens
# Round 22: failed posts heal themselves. A calm Retrying chip, the inspector's "nothing to do", one sign-in card.
gif self-healing        $H/r9-posts-scheduled-light $H/r22-inspector-retrying-light $H/r22-posts-signin-light
still self-healing-retrying $H/r22-inspector-retrying-light
still self-healing-signin   $H/r22-posts-signin-light

U=photo-audio
# Round 23: photo with audio. The whole editor as a photo post gets its audio and carries on as the clip editor, then
# the fit switch (D12) and the Crop field's Reset. Capture these on an unlocked Mac: a capture taken while it is locked
# draws the player black. The import sheet with an audio file chosen, and a frame of the rendered post: the whole
# photo over its blurred copy.
gif photo-audio $U/audio-03-photo-editor-audio-none-light $U/audio-05-making-the-video-overlay-light \
                 $U/audio-04-clip-editor-with-audio-light $U/audio-16-audio-changed-light $U/audio-17-audio-removed-photo-editor-light
gif photo-audio-fit $U/audio-04-clip-editor-with-audio-light $U/audio-06-fill-the-frame-confirm-the-crop-light \
                 $U/audio-07-whole-photo-nothing-to-fix-light $U/audio-08-whole-photo-zoomed-crop-with-reset-light \
                 $U/audio-09-crop-reset-still-nothing-to-fix-light
still photo-audio-import $U/audio-19-import-sheet-with-audio-light
still photo-audio-whole  $U/render-frame-whole-at-2s-light

T=text-fields
# Round 25: the boxes keep the cursor. The Text box typed into, then Return in the middle of a line (the cursor stays
# right after it), then the caption doing the same.
CROP=iw*0.74:ih*0.76:iw*0.26:0 gif text-fields $T/fields-01-text-start-light $T/fields-02-text-typed-light \
                 $T/fields-03-text-split-light $T/fields-05-caption-typed-light $T/fields-06-caption-split-light
still text-fields-split $T/fields-03-text-split-light

T=trim-markers
# Round 24: trim handles and markers. Crops of just the timeline card (the script writes them beside each full shot):
# grab the end handle, drag it with its time pill, nudge it with the arrows, M markers, the end snapping onto one,
# and zoom with the overview. (The long-file shot isn't used: its dev clip is a personal one.)
gif trim-markers $T/timeline-01-handles-light $T/timeline-02-end-selected-light $T/timeline-03-dragging-readout-light \
                 $T/timeline-04-nudged-light $T/timeline-05-markers-light $T/timeline-06-end-snapped-light \
                 $T/timeline-08-zoomed-light
still trim-markers-dark $T-dark/timeline-05-markers-dark

(( missing == 0 )) || { echo "readme-media: $missing missing (rerun live-checks with those checks)" >&2; exit 1; }
