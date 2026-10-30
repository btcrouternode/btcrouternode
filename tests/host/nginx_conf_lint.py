#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Lint Knots nginx overlay for constructs greps miss (F129 / F170 / F172).

OpenWrt nginx_init fail-closes on nginx -t. This catches:
- nested if (F129)
- proxy_pass with a URI inside named/regex/if (F172)
- if + proxy_pass in the same location (F170 stall; valid syntax)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LOC_RE = re.compile(
    r"^\s*location\s+(?P<mod>=|~\*?|@)?\s*(?P<name>\S+)\s*\{"
)
PROXY_RE = re.compile(r"proxy_pass\s+([^;]+);")
URI_RE = re.compile(r"://[^/;\s]+/")


def strip_comment(line: str) -> str:
    out = []
    in_s = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_s:
            out.append(c)
            if c == in_s and line[i - 1 : i] != "\\":
                in_s = None
            i += 1
            continue
        if c in "'\"":
            in_s = c
            out.append(c)
            i += 1
            continue
        if c == "#":
            break
        out.append(c)
        i += 1
    return "".join(out)


def brace_line(line: str) -> tuple[int, int]:
    """Count nginx block braces; ignore ${var} interpolations."""
    s = re.sub(r"\$\{[^}]*\}", "", line)
    return s.count("{"), s.count("}")


def location_kind(mod: str | None) -> str:
    if mod == "@":
        return "named"
    if mod in ("~", "~*"):
        return "regex"
    return "prefix"


def scan_ifs_and_proxy(body: str) -> tuple[bool, bool, bool, list[str]]:
    """Return (has_if, has_proxy, nested_if, uri_in_illegal_context messages)."""
    has_if = False
    has_proxy = False
    nested = False
    uri_hits: list[str] = []
    brace = 0
    if_levels: list[int] = []
    pending_if = False
    i = 0
    n = len(body)
    in_s = None
    while i < n:
        c = body[i]
        if in_s:
            if c == in_s and body[i - 1 : i] != "\\":
                in_s = None
            i += 1
            continue
        if c in "'\"":
            in_s = c
            i += 1
            continue
        if c == "#" and in_s is None:
            while i < n and body[i] != "\n":
                i += 1
            continue
        if body.startswith("${", i):
            j = body.find("}", i + 2)
            i = n if j < 0 else j + 1
            continue
        if c.isalpha() and body.startswith("if", i) and (
            i + 2 >= n or not (body[i + 2].isalnum() or body[i + 2] == "_")
        ) and (i == 0 or not (body[i - 1].isalnum() or body[i - 1] == "_")):
            j = i + 2
            while j < n and body[j].isspace():
                j += 1
            if j < n and body[j] == "(":
                has_if = True
                if if_levels or pending_if:
                    nested = True
                pending_if = True
                i = j
                continue
        if body.startswith("proxy_pass", i) and (
            i + 10 >= n or not (body[i + 10].isalnum() or body[i + 10] == "_")
        ):
            has_proxy = True
            m = PROXY_RE.match(body[i:])
            if m and URI_RE.search(m.group(1)):
                in_if = bool(if_levels) or pending_if
                uri_hits.append((in_if, m.group(1).strip()))
            i += 10
            continue
        if c == "{":
            brace += 1
            if pending_if:
                if_levels.append(brace)
                pending_if = False
            i += 1
            continue
        if c == "}":
            if if_levels and brace == if_levels[-1]:
                if_levels.pop()
            brace = max(0, brace - 1)
            i += 1
            continue
        i += 1
    return has_if, has_proxy, nested, uri_hits


def lint_text(text: str, src: str = "<conf>") -> list[str]:
    fails: list[str] = []
    lines = text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = strip_comment(lines[i])
        m = LOC_RE.search(line)
        if not m:
            i += 1
            continue
        kind = location_kind(m.group("mod"))
        name = m.group("name")
        opens, closes = brace_line(line)
        depth = opens - closes
        block = [line]
        j = i + 1
        while j < n and depth > 0:
            sl = strip_comment(lines[j])
            block.append(sl)
            o, c = brace_line(sl)
            depth += o - c
            j += 1
        body = "\n".join(block)
        has_if, has_proxy, nested, uri_hits = scan_ifs_and_proxy(body)
        if nested:
            fails.append(f"{src}:{i + 1} nested if inside location {name} (F129)")
        if has_if and has_proxy:
            fails.append(
                f"{src}:{i + 1} location {name}: if + proxy_pass in the same "
                "location stalls upstream (F170)"
            )
        for in_if, target in uri_hits:
            if kind in ("named", "regex") or in_if:
                fails.append(
                    f"{src}:{i + 1} location {name} ({kind}): "
                    f"proxy_pass URI '{target}' is illegal here (F172)"
                )
        i = j
    return fails


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: nginx_conf_lint.py FILE...", file=sys.stderr)
        return 2
    fails: list[str] = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        fails.extend(lint_text(p.read_text(encoding="utf-8"), str(p)))
    if fails:
        for f in fails:
            print("FAIL:", f)
        return 1
    print("PASS nginx_conf_lint", " ".join(sys.argv[1:]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
