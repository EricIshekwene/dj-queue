#!/bin/zsh
# Builds a development copy of "~/Movies/DJ Video" at ~/code/dj-queue-dev/DJ Video:
# real videos.json files, symlinks to the real clips/long-form, empty output folders.
# Run the app/CLI against it with: DJQ_ROOT=~/code/dj-queue-dev/"DJ Video" DJQ_HOME=~/code/dj-queue-dev/home
set -e
SRC="$HOME/Movies/DJ Video/Sessions"
DST="$HOME/code/dj-queue-dev/DJ Video/Sessions"
mkdir -p "$DST" "$HOME/code/dj-queue-dev/home"
for s in "$SRC"/*/; do
  name=$(basename "$s")
  [[ "$name" == _* ]] && continue
  [[ -f "$s/videos.json" ]] || continue
  d="$DST/$name"
  mkdir -p "$d/Clips" "$d/Ready to Post/Longform" "$d/Ready to Post/Shortform" "$d/Posted/Longform" "$d/Posted/Shortform" "$d/Video" "$d/Audio" "$d/Other"
  cp "$s/videos.json" "$d/videos.json"
  for f in "$s/Clips/"*.mp4(N); do ln -sf "$f" "$d/Clips/$(basename "$f")"; done
  for f in "$s/Ready to Post/Longform/"*.mp4(N); do ln -sf "$f" "$d/Ready to Post/Longform/$(basename "$f")"; done
done
mkdir -p "$DST/_Template – copy me"
echo "devroot ready: $DST"
