#!/usr/bin/env python3
"""prefill_titles.py — upstream title formatter for DJ Queue (stdlib only).

DJ Queue itself never guesses text (round 2: "the app is a UI over scripts"). This script is the old in-app
"prefill" moved upstream: it reads a session's videos.json and writes `title_suggestions` built mechanically
from each clip's marker tag, for Eric (or an agent) to accept in the app. See docs/metadata.md.

Rules (identical to the round-1 app):
  * Split the tag on " x " into song names (a dangling "x" at either end is dropped).
  * Tidy each name: replacements first (lowercased fragment -> replacement), then title case, keeping
    `lowercaseWords` lowercase inside a name, `keepWords` exactly as written, words with digits as typed and
    ALL-CAPS acronyms as typed.
  * Join with "x", never an arrow; no emoji unless `emoji` is set.
  * Short names (every name <= maxShortName and the line <= maxOneLine) -> one line "Yayo x Johnny";
    otherwise three lines "Song One" / "x" / "Song Two".
  * talking clips (content-type "talking") get no suggestion.

Usage:
  prefill_titles.py videos.json                     # print videos.json with title_suggestions added
  prefill_titles.py videos.json --in-place          # write it back (keeps a videos.json.bak copy)
  prefill_titles.py videos.json --format suggest    # print the `djq suggest --file` array instead
  prefill_titles.py videos.json --rules rules.json  # rules/replacements file (same keys as RULE_DEFAULTS)
  prefill_titles.py --tag "yayo x johnny"           # preview one tag
  prefill_titles.py --self-test

Existing suggestions are kept; a suggestion with the same text is not added twice. `title` is never set
(choosing a title is Eric's job). Never run it on anything but a videos.json you are allowed to edit.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys

SOURCE = "prefill_titles.py"
CONFIDENCE = 0.3  # a mechanical tidy of a typed tag, not a lookup

RULE_DEFAULTS = {
    "joiner": "x",
    "maxShortName": 14,
    "maxOneLine": 26,
    "emoji": "",
    "replacements": {},
    "lowercaseWords": ["a", "of", "the", "and", "to", "in", "on", "ya", "via"],
    "keepWords": ["DJ", "SA", "BB"],
}


def load_rules(path: str | None) -> dict:
    rules = json.loads(json.dumps(RULE_DEFAULTS))
    if path:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise SystemExit(f"{path}: rules must be a JSON object")
        rules.update({k: v for k, v in data.items() if k in RULE_DEFAULTS})
    return rules


def names(tag: str) -> list[str]:
    t = tag.strip()
    t = re.sub(r"^[xX×]\s+|\s+[xX×]$", "", t)
    t = re.sub(r"\s+[xX×]\s+", "\x01", t)
    return [p.strip() for p in t.split("\x01") if p.strip()]


def tidy(name: str, rules: dict) -> str:
    s = name.strip()
    reps = rules["replacements"]
    lower_map = {k.lower(): v for k, v in reps.items()}
    if s.lower() in lower_map:
        return lower_map[s.lower()]
    # Longest keys first so overlapping replacements give the same result every run.
    for k, v in sorted(reps.items(), key=lambda kv: (len(kv[0]), kv[0]), reverse=True):
        if k.lower() in s.lower():
            s = re.sub(re.escape(k), lambda _m, v=v: v, s, flags=re.IGNORECASE)
    keep = {w.lower(): w for w in rules["keepWords"]}
    out = []
    for i, w in enumerate(s.split()):
        lw = w.lower()
        if lw in keep:
            out.append(keep[lw])
        elif i > 0 and lw in rules["lowercaseWords"]:
            out.append(lw)
        elif any(c.isdigit() for c in w):
            out.append(w)
        elif len(w) > 1 and w == w.upper() and any(c.isalpha() for c in w):
            out.append(w)
        else:
            out.append(lw[:1].upper() + lw[1:])
    return " ".join(out)


def text(tag: str, kind: str, rules: dict) -> str:
    if kind == "talking":
        return ""
    parts = [tidy(n, rules) for n in names(tag)]
    if not parts:
        return ""
    j = rules["joiner"]
    one = f" {j} ".join(parts)
    short = len(parts) == 1 or (all(len(p) <= rules["maxShortName"] for p in parts) and len(one) <= rules["maxOneLine"])
    out = one if short else f"\n{j}\n".join(parts)
    if rules["emoji"]:
        out += " " + rules["emoji"]
    return out


def suggestion_for(entry: dict, rules: dict) -> dict | None:
    if entry.get("type") == "long-form":
        return None
    kind = "talking" if str(entry.get("content-type", "")).lower() == "talking" else "dj vid"
    tags = entry.get("tags") or []
    tag = tags[0] if tags else entry.get("name", "")
    t = text(tag, kind, rules)
    if not t:
        return None
    tracks = [{"title": tidy(n, rules)} for n in names(tag)]
    return {"text": t, "tracks": tracks, "confidence": CONFIDENCE, "source": SOURCE}


def add_suggestions(manifest: dict, rules: dict) -> tuple[dict, list[dict]]:
    added = []
    for e in manifest.get("videos", []):
        s = suggestion_for(e, rules)
        if not s:
            continue
        existing = e.get("title_suggestions")
        if not isinstance(existing, list):
            existing = []
        if any(isinstance(x, dict) and x.get("text") == s["text"] for x in existing):
            continue
        e["title_suggestions"] = existing + [s]
        if e.get("id"):
            added.append({"video_id": e["id"], "title_suggestions": [s]})
    return manifest, added


def self_test() -> int:
    r = load_rules(None)
    cases = [
        ("yayo x johnny", "dj vid", "Yayo x Johnny"),
        ("mabalabala x a collision of two worlds", "dj vid", "Mabalabala\nx\nA Collision of Two Worlds"),
        ("bele x aura salad", "dj vid", "Bele x Aura Salad"),
        ("evil jingle x mnike x escaladizzy", "dj vid", "Evil Jingle\nx\nMnike\nx\nEscaladizzy"),
        ("bone shaker", "dj vid", "Bone Shaker"),
        ("aura salad x tobetse 3.0", "dj vid", "Aura Salad x Tobetse 3.0"),
        ("jago x", "dj vid", "Jago"),
        ("mmmnn x take all my money", "dj vid", "Mmmnn\nx\nTake All My Money"),
        ("yayo x johnny", "talking", ""),
    ]
    bad = 0
    for tag, kind, want in cases:
        got = text(tag, kind, r)
        if got != want:
            bad += 1
            print(f"FAIL {tag!r} ({kind}): {got!r} != {want!r}")
    t = text("johnny x jago", "dj vid", r)
    if "→" in t or "➜" in t or not t.isascii():
        bad += 1
        print(f"FAIL arrow/emoji in {t!r}")
    r2 = load_rules(None)
    r2["replacements"] = {"sugnba": "Sungba"}
    if text("sugnba x tshwalabami", "dj vid", r2) != "Sungba x Tshwalabami":
        bad += 1
        print("FAIL replacements")
    m, added = add_suggestions({"videos": [{"id": "a", "name": "n", "tags": ["yayo x johnny"], "file": "f"}]}, r)
    m, again = add_suggestions(m, r)
    if len(added) != 1 or again or len(m["videos"][0]["title_suggestions"]) != 1:
        bad += 1
        print("FAIL idempotent add")
    print("ok" if bad == 0 else f"{bad} failure(s)")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Write title_suggestions into a DJ Queue videos.json (upstream tool).")
    ap.add_argument("manifest", nargs="?", help="path to a session's videos.json")
    ap.add_argument("--rules", help="rules JSON (joiner, maxShortName, maxOneLine, emoji, replacements, ...)")
    ap.add_argument("--in-place", action="store_true", help="write the manifest back (videos.json.bak kept)")
    ap.add_argument("--format", choices=["manifest", "suggest"], default="manifest",
                    help="manifest = videos.json with suggestions; suggest = array for `djq suggest --file`")
    ap.add_argument("--tag", help="preview the text for one tag")
    ap.add_argument("--kind", default="dj vid", help='with --tag: "dj vid" or talking')
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    rules = load_rules(a.rules)
    if a.tag is not None:
        print(text(a.tag, a.kind, rules))
        return 0
    if not a.manifest:
        ap.error("give a videos.json path (or --tag / --self-test)")
    with open(a.manifest, encoding="utf-8") as f:
        manifest = json.load(f)
    manifest, added = add_suggestions(manifest, rules)
    if a.format == "suggest":
        print(json.dumps(added, indent=2, ensure_ascii=False))
        return 0
    out = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if a.in_place:
        shutil.copyfile(a.manifest, a.manifest + ".bak")
        with open(a.manifest, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"{len(added)} suggestion(s) added to {a.manifest}", file=sys.stderr)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
