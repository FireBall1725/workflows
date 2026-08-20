#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 FireBall1725

"""Close the gap between adjacent parentheses in C# source.

dotnet format pads the inside of every parenthesis, which is what we want, but it pads
each pair independently: a nested call ends up `Foo( Bar( x ) )`. House style keeps
adjacent parens tight, `Foo( Bar( x ))`, and Roslyn has no option for that.

This walks the file tracking string, char, comment and interpolated-hole state, so parens
inside a literal or a comment are left exactly as written, and removes spaces only where a
run of them sits between two parens of the same direction on one line.

Usage: tighten_parens.py FILE...        rewrite in place
       tighten_parens.py --check FILE... exit 1 if any file would change
"""
import sys


def tighten(src):
    out = []
    i, n = 0, len(src)
    # Stack of interpolated-string depths: entering a `{` hole inside $"..." puts us back
    # into code, and the matching `}` returns to the string.
    interp = []
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j == -1 else j
            out.append(src[i:j])
            i = j
            continue

        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append(src[i:j])
            i = j
            continue

        if c == "'":
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(src[i:j])
            i = j
            continue

        # Verbatim and interpolated-verbatim strings: "" is the only escape.
        if c == "@" and nxt == '"' or (c == "$" and nxt == "@") or (c == "@" and nxt == "$"):
            start = i
            while i < n and src[i] != '"':
                i += 1
            i += 1
            while i < n:
                if src[i] == '"':
                    if i + 1 < n and src[i + 1] == '"':
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(src[start:i])
            continue

        if c == '"' or (c == "$" and nxt == '"'):
            interpolated = c == "$"
            start = i
            i += 2 if interpolated else 1
            while i < n:
                ch = src[i]
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    i += 1
                    break
                if interpolated and ch == "{":
                    if i + 1 < n and src[i + 1] == "{":
                        i += 2
                        continue
                    # A hole is code. Emit the string so far, then fall back to the main
                    # loop so parens inside the hole get the same treatment as anywhere.
                    out.append(src[start : i + 1])
                    interp.append(1)
                    i += 1
                    start = None
                    break
                i += 1
            if start is not None:
                out.append(src[start:i])
            continue

        if interp and c == "}":
            # Back into the interpolated string this hole belongs to.
            interp.pop()
            start = i
            i += 1
            while i < n:
                ch = src[i]
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    i += 1
                    break
                if ch == "{":
                    out.append(src[start : i + 1])
                    interp.append(1)
                    i += 1
                    start = None
                    break
                i += 1
            if start is not None:
                out.append(src[start:i])
            continue

        if c in "()":
            # Look past spaces on this line only; a paren on the next line keeps its indent.
            j = i + 1
            while j < n and src[j] == " ":
                j += 1
            if j > i + 1 and j < n and src[j] == c:
                out.append(c)
                i = j
                continue

        out.append(c)
        i += 1

    return "".join(out)


def main(argv):
    check = argv and argv[0] == "--check"
    files = argv[1:] if check else argv
    changed = []
    for f in files:
        with open(f, encoding="utf-8") as fh:
            src = fh.read()
        new = tighten(src)
        if new != src:
            changed.append(f)
            if not check:
                with open(f, "w", encoding="utf-8") as fh:
                    fh.write(new)
    if check and changed:
        print("adjacent parens need closing up in:")
        for f in changed:
            print(f"  {f}")
        return 1
    if not check:
        print(f"tightened {len(changed)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
