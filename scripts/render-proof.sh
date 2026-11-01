#!/bin/zsh
# Milestone-3 render proof on real clips (read-only, via the dev root's symlinks).
# Renders "Amarider" (rekordbox audio) and "yayo x johnny" (camera audio) into the evidence dir
# and writes PROOF.md there (loudness before/after, preview-vs-export diffs, render times).
set -e
cd "$(dirname "$0")/.."
DEV="$HOME/code/dj-queue-dev"
[[ -d "$DEV/DJ Video/Sessions" ]] || scripts/make-devroot.sh
export DJQ_PROOF=1
export DJQ_ROOT="$DEV/DJ Video"
export DJQ_HOME="${DJQ_HOME:-$DEV/render-home}"
export DJQ_EVIDENCE="${DJQ_EVIDENCE:-$DEV/evidence/render}"
exec scripts/test.sh --filter RenderProofTests "$@"
