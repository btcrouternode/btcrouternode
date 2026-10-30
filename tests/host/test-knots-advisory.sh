#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-KNOTS-ADVISORY: the shipped Knots (main-chain release 29.3.knots20260507)
# has a known issue (CVE-2026-117349, fixed in the shipped Core 29.5). A popup
# warns whenever Knots is chosen (Setup, Node page) or runs (Node Status, once
# per visit), and it loads on plain-HTTP Setup too.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W="$ROOT/files/www/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

kt=$(sed -n 's/^KNOTS_TAG := //p' "$ROOT/build/version.env")
command -v node >/dev/null 2>&1 || { echo "SKIP: no node for the JS check"; exit 0; }
node - "$W/node-advisory.js" "$kt" <<'JS' || fail "advisory logic"
const fs = require("fs"); global.window = {};
eval(fs.readFileSync(process.argv[2], "utf8"));
const a = window.KnotsNodeAdvisory, kt = process.argv[3];
const ok = (c, m) => { if (!c) { console.error(m); process.exit(1); } };
ok(a.forImpl("knots", kt), "shipped Knots " + kt + " must be flagged");
ok(a.forImpl("knots", ""), "unknown version (Setup) = shipped Knots: flagged");
ok(!a.forImpl("knots", "v29.9.knots20270101"), "another Knots version must not be flagged");
ok(!a.forImpl("core", "v29.5"), "Core must not be flagged");
const t = JSON.stringify(a.forImpl("knots", kt));
ok(/CVE-2026-117349/.test(t) && /Bitcoin Core/.test(t) && /bitcoincore\.org/.test(t), "text must name the CVE, recommend Core, link the advisory");
JS
pass "advisory flags the shipped Knots ($kt) only"

for p in setup:setup.js node:node.js index:app.js; do
	page=${p%%:*}; js=${p#*:}
	a=$(grep -n 'node-advisory.js' "$W/$page.html" | head -1 | cut -d: -f1)
	b=$(grep -n "src=\"$js" "$W/$page.html" | head -1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$page.html must load node-advisory.js before $js"
done
grep -q 'confirmChoice("knots")' "$W/setup.js" || fail "Setup must warn before Knots is chosen"
grep -q 'confirmChoice("knots", knotsVersion)' "$W/node.js" || fail "Node page must warn before switching to Knots"
grep -q 'maybeKnotsAdvisory' "$W/app.js" || fail "Node Status must warn while Knots runs"
grep -q 'id="knotsAdvisory"' "$W/node.html" || fail "Node page needs the standing notice"
pass "Setup, Node page and Node Status show it"

grep -q 'location ~ ^/(shell|theme|node-advisory)\\.js\$' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" ||
	fail "HTTP server must serve node-advisory.js (Setup without the secure connection)"
pass "served on plain-HTTP Setup"
echo "ALL PASS: test-knots-advisory"
