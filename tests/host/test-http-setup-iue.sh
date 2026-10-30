#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host check: HTTP Setup IUE while setup incomplete (N13 / U17 / F121).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NGINX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
SHELLJS="$ROOT/files/www/knots/shell.js"
UPG_JS="$ROOT/files/www/knots/upgrade.js"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

awk '/listen 80/,/^}/' "$NGINX" | grep -q 'setup-complete' \
	|| fail ":80 block must gate Setup on setup-complete"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location /api/setup' \
	|| fail ":80 must proxy /api/setup while Setup incomplete"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'setup\.html' \
	|| fail ":80 must serve setup.html while Setup incomplete"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'return 302 http://$knots_rhost/setup.html' \
	|| fail ":80 / must redirect to http://<D2 host>/setup.html when incomplete"
awk '/listen 443/,/^}/' "$NGINX" | grep -q 'setup.html?after_tls=1' \
	|| fail ":443 / mid-IUE must resume Setup at after_tls=1 (not Welcome)"
pass "nginx HTTP Setup IUE surface"

grep -q 'KnotsIue' "$SHELLJS" || fail "shell.js must export KnotsIue"
grep -q 'setupPageUrl' "$SHELLJS" || fail "shell.js setupPageUrl"
grep -q 'ensureCleartextIue' "$SHELLJS" || fail "shell.js ensureCleartextIue"
grep -q 'http://' "$SHELLJS" || fail "shell.js must use http setup URL"
grep -q 'setup.html?after_tls=1' "$SHELLJS" \
	|| fail "HTTPS incomplete gate must resume at after_tls=1 not HTTP Welcome"
pass "shell.js KnotsIue HTTP helpers"

grep -q 'KnotsIue.appUrl\|KnotsIue.setupUrl\|setupStartUrl' "$UPG_JS" \
	|| fail "upgrade.js must redirect to HTTP Setup via rnode.local"
grep -q 'handoffWhenReady' "$UPG_JS" || fail "upgrade.js must confirm dest works before redirect"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location = /api/alive' \
	|| fail ":80 must serve /api/alive for the wait-page monitor"
awk '/location ~ \^\/\(upgrade\|reset\)/,/^	}/' "$NGINX" | grep -q 'setup-complete' \
	&& fail "wait pages must stay on HTTP after Setup is complete" || true
pass "upgrade.js HTTP Setup redirect"

echo "ALL PASS: test-http-setup-iue"
