#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate files/www/knots/i18n/en.js from en.json (English bundled with
every page, so no string is ever shown as its key). Run after editing en.json;
tests/host/test-i18n.sh checks the two match."""
import json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(ROOT, "files", "www", "knots", "i18n", "en.json")
dst = os.path.join(ROOT, "files", "www", "knots", "i18n", "en.js")
d = json.load(open(src, encoding="utf-8"))
body = ("/* SPDX-License-Identifier: GPL-2.0-only */\n"
        "/* GENERATED from en.json by build/gen-i18n-en.py — do not edit. */\n"
        "window.KNOTS_I18N_EN = " + json.dumps(d, ensure_ascii=False, indent=1) + ";\n")
if "--check" in sys.argv:
    sys.exit(0 if os.path.exists(dst) and open(dst, encoding="utf-8").read() == body else 1)
open(dst, "w", encoding="utf-8").write(body)
