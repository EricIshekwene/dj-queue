#!/bin/zsh
# Points every path stored in a copy of the DJ Queue database at another root, so a dev run never opens, moves or
# deletes a real file. Every column of every table is rewritten, whatever its declared type: as plain text, in the JSON
# form with escaped slashes ("\/a\/b") and in the URL form with %20 for spaces. It fails closed: an unreadable
# database, a database with no columns, or either root left anywhere afterwards is exit 2.
#
#   scripts/seed-paths.sh <database copy> <old root> <new root>
#
# `scripts/live-checks.sh` runs it on its seed; `R21PhotoReviewTests` runs it on made-up databases.
set -u
DB=${1:?usage: scripts/seed-paths.sh <database copy> <old root> <new root>}
OLD=${2:?old root}
NEW=${3:?new root}
[[ -f "$DB" ]] || { echo "seed-paths: no database at $DB" >&2; exit 2; }
OLD_JSON="${OLD//\//\\/}"
NEW_JSON="${NEW//\//\\/}"
OLD_URL="${OLD// /%20}"
NEW_URL="${NEW// /%20}"
list=$(sqlite3 "$DB" "SELECT m.name || '.' || p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type = 'table'") \
  || { echo "seed-paths: can't read $DB" >&2; exit 2; }
columns=("${(@f)list}")
[[ -n "$list" && ${#columns} -gt 0 ]] || { echo "seed-paths: $DB has no tables to check" >&2; exit 2; }
for col in $columns; do
  [[ -n "$col" ]] || continue
  t="\"${col%%.*}\"" c="\"${col#*.}\""
  has="instr(CAST($c AS TEXT), '$OLD') > 0 OR instr(CAST($c AS TEXT), '$OLD_JSON') > 0 OR instr(CAST($c AS TEXT), '$OLD_URL') > 0"
  sqlite3 "$DB" "UPDATE $t SET $c = replace(replace(replace(CAST($c AS TEXT), '$OLD', '$NEW'), '$OLD_JSON', '$NEW_JSON'), '$OLD_URL', '$NEW_URL') WHERE $has" \
    || { echo "seed-paths: couldn't rewrite $col" >&2; exit 2; }
  left=$(sqlite3 "$DB" "SELECT count(*) FROM $t WHERE $has") || { echo "seed-paths: couldn't check $col" >&2; exit 2; }
  [[ "$left" == 0 ]] || { echo "seed-paths: $col still points at $OLD" >&2; exit 2; }
done
