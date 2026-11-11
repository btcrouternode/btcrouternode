#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-I18N — every RNode page is translated (owner, 2026-11-10; 25.0.32.0 had
# only Setup + the menu) and shows no internal wording:
#  - every language has exactly the English keys, with the same {placeholders}
#    and the same markup (data-i18n-html strings)
#  - i18n/en.js (English bundled with each page) matches en.json
#  - every key a page uses (data-i18n*, T("…"), KnotsI18n.t("…")) exists
#  - no "Knots" (except the sentence saying it was dropped) and no internal
#    requirement codes like "(U15)" / "(NF9)" in any language or visible HTML
#  - markup in strings is limited to simple tags (never script / on* attributes)
#  - confirm words the user types (REINDEX, SAVE…) and terms like SHA256 / DHCP
#    stay unchanged in every language
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

python3 "$ROOT/build/gen-i18n-en.py" --check || fail "i18n/en.js is out of date — run build/gen-i18n-en.py"
pass "en.js matches en.json"

python3 - "$ROOT" <<'PY' || fail "catalogue / page checks (see above)"
import glob, html.parser, json, os, re, sys
root = sys.argv[1]
www = os.path.join(root, "files", "www")
knots = os.path.join(www, "knots")
cat = {os.path.basename(p)[:-5]: json.load(open(p, encoding="utf-8"))
       for p in glob.glob(os.path.join(knots, "i18n", "*.json")) if not p.endswith("regions.json")}
en = cat["en"]
bad = []
want = {"en", "es", "de", "fr", "zh-cn", "ja", "pt-br"}
if set(cat) != want:
    bad.append(f"languages {sorted(cat)} != {sorted(want)}")
PH = re.compile(r"\{[a-z_][a-z0-9_]*\}")
TAG = re.compile(r"</?([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>")
OK_TAGS = {"b", "strong", "em", "i", "code", "kbd", "a", "br", "span", "small"}
CODE = re.compile(r"\((?:[A-Z]{1,3}\d{1,3}[a-z]?)(?:\s*/\s*[A-Z]{1,3}\d{1,3}[a-z]?)*\)")
KNOTS_OK = re.compile(r"no longer|ya no|nicht mehr|ne fait plus|不再|含まれ|não faz mais|dejó|abandon|since build 120|desde|seit|depuis|自|以降|desde a", re.I)
for lang, d in cat.items():
    for k in en:
        if k not in d:
            bad.append(f"{lang}: missing {k}")
        elif lang != "en":
            if sorted(PH.findall(d[k])) != sorted(PH.findall(en[k])):
                bad.append(f"{lang}: {k} placeholders {PH.findall(d[k])} != {PH.findall(en[k])}")
            if sorted(TAG.findall(d[k])) != sorted(TAG.findall(en[k])):
                bad.append(f"{lang}: {k} markup differs from English")
            if not str(d[k]).strip():
                bad.append(f"{lang}: {k} empty")
            # words typed to confirm (REINDEX, SAVE…) and technical terms stay as they are
            for w in set(re.findall(r"\b[A-Z][A-Z0-9_]{3,}\b", en[k])) - {"KEEP", "RESET", "POST"}:
                if w not in d[k]:
                    bad.append(f"{lang}: {k} must keep '{w}' unchanged")
    for k in d:
        if k not in en:
            bad.append(f"{lang}: extra key {k}")
    for k, v in d.items():
        v = str(v)
        if CODE.search(v):
            bad.append(f"{lang}: {k} shows an internal code: {CODE.search(v).group(0)}")
        if re.search(r"knots", v, re.I) and not KNOTS_OK.search(v):
            bad.append(f"{lang}: {k} mentions Knots: {v[:80]}")
        for t in TAG.findall(v):
            if t.lower() not in OK_TAGS:
                bad.append(f"{lang}: {k} has <{t}>")
        if re.search(r"<script|\son[a-z]+\s*=|javascript:", v, re.I):
            bad.append(f"{lang}: {k} has unsafe markup")

# keys used by pages
pages = glob.glob(os.path.join(knots, "*.html")) + glob.glob(os.path.join(knots, "*.js")) + \
    [os.path.join(www, "luci-entry.html"), os.path.join(www, "luci-static", "resources", "knots-return.js")]
used = set()
for p in pages:
    s = open(p, encoding="utf-8").read()
    used |= set(re.findall(r'data-i18n(?:-html)?="([^"]+)"', s))
    used |= set(re.findall(r'\b(?:T|KnotsI18n\.t|I18N\.t|i18nT)\(\s*"([a-z0-9_.-]+)"\s*[,)]', s))
for k in sorted(used):
    if k not in en:
        bad.append(f"page uses unknown key {k}")

# visible HTML text of every page: no Knots / internal codes
class Text(html.parser.HTMLParser):
    def __init__(s):
        super().__init__(); s.skip = 0; s.out = []
    def handle_starttag(s, t, a):
        if t in ("script", "style"): s.skip += 1
        for n, v in a:
            if n in ("title", "placeholder", "aria-label", "alt") and v: s.out.append(v)
    def handle_endtag(s, t):
        if t in ("script", "style"): s.skip -= 1
    def handle_data(s, d):
        if not s.skip: s.out.append(d)
for p in [x for x in pages if x.endswith(".html")]:
    t = Text(); t.feed(open(p, encoding="utf-8").read())
    txt = " ".join(t.out)
    for m in CODE.finditer(txt):
        bad.append(f"{os.path.basename(p)}: visible internal code {m.group(0)}")
    for m in re.finditer(r"[^.]*\bKnots\b[^.]*", txt):
        if not KNOTS_OK.search(m.group(0)):
            bad.append(f"{os.path.basename(p)}: visible 'Knots': {m.group(0).strip()[:80]}")
for b in bad[:60]:
    print(b, file=sys.stderr)
if len(bad) > 60:
    print(f"… {len(bad) - 60} more", file=sys.stderr)
print(f"{len(en)} keys, {len(cat)} languages, {len(used)} keys used by pages")
sys.exit(1 if bad else 0)
PY
pass "7 languages complete (placeholders + markup match English); every page key exists; no Knots / internal codes; safe markup only"
echo "ALL PASS: test-i18n (T-I18N)"
