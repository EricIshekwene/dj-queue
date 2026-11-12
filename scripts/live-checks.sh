#!/bin/zsh
# Live click-through checks, run in the background. Every window stays off every display, nothing takes focus, and only
# dev data is touched. A run fails if a window lands on a screen, even when its own checks pass.
#
#   scripts/live-checks.sh <evidence dir> [check ...]     (default: all of them; see `checks` below)
#
# DJQ_BIN picks the binary (default .build/debug/DJQueueApp). Never point it at the installed app: copy the staged
# build to scratch first.
set -u
setopt null_glob
cd "$(dirname "$0")/.."
OUT=${1:?usage: scripts/live-checks.sh <evidence dir> [check ...]}
shift
mkdir -p "$OUT"
OUT=${OUT:A}
DEV="$HOME/code/dj-queue-dev"
BIN=${DJQ_BIN:-.build/debug/DJQueueApp}
BIN=${BIN:A}
case "$BIN" in
  "$HOME/Applications/"*|/Applications/*|"$HOME/Library/Application Support/DJ Queue/"*)
    echo "live-checks: refusing to run the installed app; copy it to a scratch folder" >&2; exit 2 ;;
esac
[[ -x "$BIN" ]] || { echo "live-checks: no binary at $BIN (run swift build)" >&2; exit 2; }
HOME_DIR=$(mktemp -d "$DEV/scratch-live-XXXXXX") || exit 2
FRESH_DIR=$(mktemp -d "$DEV/scratch-live-XXXXXX") || exit 2
trap 'rm -rf "$HOME_DIR" "$FRESH_DIR"' EXIT
# A copy of the newest backup: most checks need clips waiting in Edit, which a fresh database doesn't have. The ones in
# `fresh` expect clips just read from the session folders instead.
fresh=(editor-selftest search send-to-queue editor-caption editor-template)
# The newest backup that still has clips waiting in Edit: once every clip is in the Queue (7 Nov), the newest has none.
seed=()
for b in "$DEV"/backups/real-queue-*.sqlite(Nom); do
  n=$(sqlite3 "$b" "SELECT count(*) FROM videos WHERE type='short-form' AND excluded=0 AND missing=0 AND state='needs_edit'" 2>/dev/null)
  (( ${n:-0} >= 4 )) && { seed=("$b"); break; }
done
[[ -n "${seed[1]:-}" ]] || { echo "live-checks: no backup in $DEV/backups with clips in Edit" >&2; exit 2; }
echo "live-checks: seed ${seed[1]:t}"
mkdir -p "$HOME_DIR/support"
SEED_DB="$HOME_DIR/support/queue.sqlite"
cp "$seed[1]" "$SEED_DB"
# The database stores absolute paths. Point every one at the dev root, or checks would open the real footage
# (plain and JSON-escaped forms; it fails when either is left anywhere).
scripts/seed-paths.sh "$SEED_DB" "$HOME/Movies/DJ Video" "$DEV/DJ Video" || { echo "live-checks: the seed still points at the real footage" >&2; exit 2; }

typeset -A checks
checks=(
  guard          "DJQ_SCREEN_GUARD_SELFTEST=1 DJQ_SNAPSHOT_ONLY=00-shell-queue"
  screens        ""
  gallery        "DJQ_SNAPSHOT_GALLERY=1"
  editor         "DJQ_SNAPSHOT_EDITOR=1"
  editor-selftest "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_SELFTEST=1"
  editor-live    "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_LIVE=1 DJQ_EDITOR_LIVE_PNG=@/live.png"
  tooltip        "DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PROBE=1"
  tooltip-pass   "DJQ_SNAPSHOT_GALLERY=1 DJQ_TOOLTIP_PASS=1"
  hover          "DJQ_SNAPSHOT_GALLERY=1 DJQ_HOVER_PROBE=1"
  search         "DJQ_SEARCH_PROBE=1"
  send-to-queue  "DJQ_SEND_TO_QUEUE_SCRIPT=1"
  text-layers    "DJQ_SNAPSHOT_EDITOR=1 DJQ_TEXT_LAYERS_SCRIPT=@"
  bulk-caption   "DJQ_SNAPSHOT_EDITOR=1 DJQ_BULK_CAPTION_SCRIPT=@"
  bulk-crop      "DJQ_SNAPSHOT_EDITOR=1 DJQ_BULK_CROP_SCRIPT=@"
  editor-group   "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_GROUP_SCRIPT=@"
  editor-caption "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_CAPTION_SCRIPT=@"
  editor-template "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_TEMPLATE_SCRIPT=@"
  settings-group "DJQ_SNAPSHOT_EDITOR=1 DJQ_SETTINGS_GROUP_SCRIPT=@"
  editor-keys    "DJQ_SNAPSHOT_EDITOR=1 DJQ_EDITOR_KEYS_SCRIPT=@"
  trim-markers   "DJQ_SNAPSHOT_EDITOR=1 DJQ_TRIM_MARKERS_SCRIPT=@"
  repost-ready   "DJQ_SNAPSHOT_EDITOR=1 DJQ_REPOST_READY_SCRIPT=@"
  photo-import   "DJQ_PHOTO_IMPORT_SCRIPT=1"
  photo-editor   "DJQ_SNAPSHOT_EDITOR=1 DJQ_PHOTO_EDITOR_SCRIPT=@"
  post-at        "DJQ_POST_AT_SCRIPT=1"
  photo-audio    "DJQ_PHOTO_AUDIO_SCRIPT=1"
)
# The editor scripts take one look per run; these are the same checks in dark.
for name in text-layers bulk-caption bulk-crop editor-group editor-caption editor-template settings-group editor-keys trim-markers repost-ready \
            photo-import photo-editor post-at photo-audio; do
  checks[$name-dark]="${checks[$name]} DJQ_EDITOR_LIVE_APPEARANCE=dark"
done
order=(guard screens gallery editor editor-selftest editor-live tooltip tooltip-pass hover search send-to-queue text-layers
       bulk-caption bulk-crop editor-group editor-caption editor-template settings-group editor-keys trim-markers repost-ready
       text-layers-dark bulk-caption-dark bulk-crop-dark editor-group-dark editor-caption-dark editor-template-dark settings-group-dark
       editor-keys-dark trim-markers-dark repost-ready-dark
       photo-import photo-editor post-at photo-import-dark photo-editor-dark post-at-dark
       photo-audio photo-audio-dark)
(( $# )) && order=("$@")

failed=0
for name in $order; do
  [[ -n "${checks[$name]+x}" ]] || { echo "unknown check: $name" >&2; failed=$((failed + 1)); continue; }
  dir="$OUT/$name"
  mkdir -p "$dir"
  vars=("${(@s: :)checks[$name]}")
  vars=("${vars[@]//@/$dir}")
  home=$HOME_DIR
  (( ${fresh[(Ie)${name%-dark}]} )) && home=$FRESH_DIR
  env DJQ_HOME="$home" DJQ_ROOT="$DEV/DJ Video" $vars "$BIN" --snapshot "$dir" > "$dir/run.log" 2>&1
  code=$?
  want=0 verdict="^screen-guard: clean"
  # The guard's own proof: its test window must fail the run.
  [[ $name == guard ]] && { want=3; verdict="^screen-guard: FAIL"; }
  if (( code == want )) && grep -q "$verdict" "$dir/run.log"; then
    echo "PASS $name"
  else
    echo "FAIL $name (exit $code): $dir/run.log"
    failed=$((failed + 1))
  fi
done
echo "live-checks: $failed failed of ${#order}"
(( failed == 0 ))
