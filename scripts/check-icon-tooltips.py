#!/usr/bin/env python3
"""Fails when an icon-only button in the app has no tooltip (round 3, F5: every control explains itself).

Finds every SwiftUI `Button` in Sources/DJQueueApp whose visible label is only an image — `Image(systemName:)`, an
SF Symbol, or a `Label` shown with `.labelStyle(.iconOnly)` — and checks that the button (its modifier chain, or its
label) carries `.dsTooltip(` (or `.help(`, which the app maps to nothing visible and is therefore also reported
separately). `DSIconButton` needs no check: its `tooltip:` is required by the compiler.

Usage: scripts/check-icon-tooltips.py [root]   (exit 1 and a list of file:line when anything is missing)
       scripts/check-icon-tooltips.py --count  (just the number of offenders)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
SRC = os.path.join(args[0] if args else ROOT, "Sources", "DJQueueApp")
BUTTON = re.compile(r"(?<![\w.])(?:Button|Menu)\s*(?=[({])")


def match_close(s, i, open_ch, close_ch):
    """Index just past the bracket that closes s[i] (s[i] == open_ch). Skips strings and comments."""
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            if s.startswith('"""', i):
                j = s.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\":
                    if i + 1 < n and s[i + 1] == "(":  # interpolation
                        i = match_close(s, i + 1, "(", ")")
                        continue
                    i += 2
                    continue
                if s[i] == "\n":
                    break
                i += 1
            i += 1
            continue
        if s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def skip_ws(s, i):
    while i < len(s) and s[i] in " \t\r\n":
        i += 1
    return i


def parse_button(s, start):
    """(args, closures [(label, body)], end) for the Button expression starting at `start`."""
    i = start + (4 if s.startswith("Menu", start) else 6)
    i = skip_ws(s, i)
    args = ""
    if i < len(s) and s[i] == "(":
        e = match_close(s, i, "(", ")")
        args = s[i + 1:e - 1]
        i = e
    closures = []
    while True:
        j = skip_ws(s, i)
        m = re.match(r"(\w+)\s*:\s*\{", s[j:])
        if m:
            k = j + m.end() - 1
            e = match_close(s, k, "{", "}")
            closures.append((m.group(1), s[k + 1:e - 1]))
            i = e
            continue
        if j < len(s) and s[j] == "{" and (not closures or True):
            # A trailing closure only on the same line as the previous token (a new line starting with `{` is not one).
            between = s[i:j]
            if "\n" in between and closures:
                break
            e = match_close(s, j, "{", "}")
            closures.append(("", s[j + 1:e - 1]))
            i = e
            continue
        break
    return args, closures, i


def modifier_chain(s, i):
    """The `.modifier(…)` chain that follows position i (lines starting with `.`), as text."""
    out = []
    n = len(s)
    while True:
        j = skip_ws(s, i)
        if j >= n or s[j] != ".":
            # Same-line chain like `} .buttonStyle(...)` is covered; a comment line in between is skipped.
            if s.startswith("//", j):
                k = s.find("\n", j)
                i = n if k < 0 else k
                continue
            break
        m = re.match(r"\.\w+", s[j:])
        if not m:
            break
        k = j + m.end()
        k2 = skip_ws(s, k)
        if k2 < n and s[k2] == "(":
            k = match_close(s, k2, "(", ")")
        k3 = skip_ws(s, k)
        if k3 < n and s[k3] == "{" and "\n" not in s[k:k3]:
            k = match_close(s, k3, "{", "}")
        out.append(s[j:k])
        i = k
    return "\n".join(out)


def icon_only(args, closures, chain):
    """True when the button shows no text."""
    first = args.strip()
    titled = bool(re.match(r'^(LocalizedStringKey\()?"', first)) or bool(re.match(r"^(String|Text)\(", first))
    if re.match(r'^""', first):
        return False  # hidden keyboard-shortcut buttons (Button("") { … }.opacity(0))
    if titled:
        return ".labelStyle(.iconOnly)" in chain
    if re.match(r"^\w+\s*,\s*systemImage:", first) or re.match(r"^\w+\s*,", first) and "systemImage" in first:
        return ".labelStyle(.iconOnly)" in chain  # Button(title, systemImage:) with a variable title
    labels = [b for (name, b) in closures if name == "label"]
    if not labels:
        # Button(action: f) { label } — the only closure is the label; Button { action } / Menu { items } without a
        # `label:` closure have a title argument or nothing we can judge.
        if "action:" in first and closures:
            labels = [closures[0][1]]
        else:
            return False
    label = labels[0]
    if ".labelStyle(.iconOnly)" in label or ".labelStyle(.iconOnly)" in chain:
        return True
    if re.search(r"\bText\(|\bLabel\(|\bDSKeyHint\(|\bDSBadge\(|\bTextField\(", label):
        return False
    if re.search(r"[A-Z]\w*\(", label) and not re.search(r"\bImage\(", label):
        return False  # a custom label view (assume it shows text; reviewed by hand)
    return bool(re.search(r"\bImage\(", label))


def check(root=SRC):
    offenders = []
    for dp, _, files in os.walk(root):
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            p = os.path.join(dp, f)
            s = open(p, encoding="utf-8").read()
            for m in BUTTON.finditer(s):
                line_start = s.rfind("\n", 0, m.start()) + 1
                if s[line_start:m.start()].lstrip().startswith("//"):
                    continue
                args, closures, end = parse_button(s, m.start())
                chain = modifier_chain(s, end)
                if not icon_only(args, closures, chain):
                    continue
                label = " ".join(b for (_, b) in closures)
                if ".dsTooltip(" in chain or ".dsTooltip(" in label:
                    continue
                line = s.count("\n", 0, m.start()) + 1
                offenders.append((os.path.relpath(p, os.path.dirname(os.path.dirname(root))), line,
                                  ".help only" if ".help(" in chain else "no tooltip"))
    # A tooltip that is always empty is no tooltip: `.dsTooltip(nil…)` / `.dsTooltip("")` literals.
    empty = re.compile(r'\.dsTooltip\(\s*(nil|"")\s*\)')
    # Native help tags draw a second, system bubble next to DSTooltip: only where DSTooltip can't reach (the menu-bar
    # status item), marked `// native-help-ok`.
    native = re.compile(r'\.help\(')
    for dp, _, files in os.walk(root):
        for f in sorted(files):
            if f.endswith(".swift"):
                p = os.path.join(dp, f)
                s = open(p, encoding="utf-8").read()
                rel = os.path.relpath(p, os.path.dirname(os.path.dirname(root)))
                for m in empty.finditer(s):
                    offenders.append((rel, s.count("\n", 0, m.start()) + 1, "empty .dsTooltip literal"))
                for m in native.finditer(s):
                    eol = s.find("\n", m.start())
                    line_text = s[s.rfind("\n", 0, m.start()) + 1:eol if eol >= 0 else len(s)]
                    if "native-help-ok" not in line_text and not line_text.lstrip().startswith("//"):
                        offenders.append((rel, s.count("\n", 0, m.start()) + 1, "native .help( — use .dsTooltip (it draws a second, system bubble)"))
    return offenders


if __name__ == "__main__":
    off = check()
    if "--count" in sys.argv:
        print(len(off))
        sys.exit(0)
    for p, line, why in off:
        icon = why in ("no tooltip", ".help only")
        print(f"{p}:{line}: " + (f"icon-only Button/Menu without .dsTooltip ({why})" if icon else why))
    if off:
        print(f"{len(off)} tooltip problem(s)", file=sys.stderr)
        sys.exit(1)
    print("check-icon-tooltips: every icon-only button has a tooltip")
