#!/bin/zsh
# Points every path stored in a copy of the DJ Queue database at another root, so a dev run never opens, moves or
# deletes a real file. Every TEXT column of every table is rewritten, as plain text and in the JSON form with escaped
# slashes ("\/a\/b"), and the run fails if either form of the old root is left anywhere.
#
#   scripts/seed-paths.sh <database copy> <old root> <new root>
#
# `scripts/live-checks.sh` runs it on its seed; `R21PhotoReviewTests` runs it on a made-up database.
set -u
DB=${1:?usage: scripts/seed-paths.sh <database copy> <old root> <new root>}
OLD=${2:?old root}
NEW=${3:?new root}
OLD_JSON="${OLD//\//\\/}"
NEW_JSON="${NEW//\//\\/}"
columns=("${(@f)$(sqlite3 "$DB" "SELECT m.name || '.' || p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type = 'table' AND p.type LIKE '%TEXT%'")}")
for col in $columns; do
  [[ -n "$col" ]] || continue
  sqlite3 "$DB" "UPDATE \"${col%%.*}\" SET \"${col#*.}\" = replace(replace(\"${col#*.}\", '$OLD', '$NEW'), '$OLD_JSON', '$NEW_JSON') WHERE instr(\"${col#*.}\", '$OLD') > 0 OR instr(\"${col#*.}\", '$OLD_JSON') > 0" || exit 2
  left=$(sqlite3 "$DB" "SELECT count(*) FROM \"${col%%.*}\" WHERE instr(\"${col#*.}\", '$OLD') > 0 OR instr(\"${col#*.}\", '$OLD_JSON') > 0")
  [[ "$left" == 0 ]] || { echo "seed-paths: $col still points at $OLD" >&2; exit 2; }
done
