#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host check: HTTP→HTTPS redirects for Node UI + LuCI (U1/U1a/N13).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NGINX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
UI_PORTS="$ROOT/files/usr/libexec/knots/ui-ports.sh"
SHELLJS="$ROOT/files/www/knots/shell.js"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

grep -q 'return 302 https://$knots_rhost' "$NGINX" \
	|| fail "node :80 missing HTTPS redirect (D2 host)"
grep -q 'listen 8080' "$NGINX" || fail "LuCI :8080 server missing"
grep -q 'return 302 https://$knots_rhost:8443' "$NGINX" \
	|| fail "LuCI :8080 missing → :8443 redirect (D2 host)"
grep -q 'https://\$host' "$NGINX" \
	&& fail "nginx must not redirect the browser to \$host (LAN IP)" || true
# F135 — never permanent redirects: browsers cache 301 forever and replay it
# across reflashes (new CA) into an immediate cert warning before the HTTP IUE
grep -q 'return 301' "$NGINX" && fail "permanent 301 redirect must not remain (F135)" || true
# N13 allowlist still on :80
grep -A2 'listen 80' "$NGINX" | head -1 >/dev/null
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'knots-ca.crt' || fail "CA must stay on :80"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location /tls/' || fail "/tls/ must stay on :80"
# U17 — Setup IUE on :80 while incomplete; operational APIs on :443 after complete
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'setup-complete' || fail "Setup cleartext gate missing on :80"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location /api/setup' || fail "setup API on :80 while incomplete"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location = /api/alive' \
	|| fail ":80 must serve /api/alive for wait-page monitor"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location /api/settings' \
	|| fail ":80 must proxy /api/settings for HTTP wait-page progress"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location /api/node' \
	|| fail ":80 must proxy /api/node so POST is not 302→GET (F204)"
awk '/listen 80/,/^}/' "$NGINX" | grep -q 'location = /api/status' \
	|| fail ":80 must serve /api/status for HTTP wait-page status probe"
awk '/listen 443/,/^}/' "$NGINX" | grep -q 'api/setup' || fail "setup API on :443"
pass "nginx :80→443 + Setup HTTP IUE; CA/tls on HTTP"

grep -q "listen_https='0.0.0.0:8443'" "$UI_PORTS" || fail "uhttpd HTTPS 8443"
grep -q "listen_http='0.0.0.0:8080'" "$UI_PORTS" && fail "uhttpd must not bind 8080 (nginx owns it)" || true
grep -q "uhttpd.main.cert='/etc/knots/tls/cert.pem'" "$UI_PORTS" \
	|| fail "uhttpd must use the Knots TLS leaf (shared with Node UI)"
! grep -q "uhttpd.main.cert='/etc/knots/tls/fullchain.pem'" "$UI_PORTS" \
	|| fail "uhttpd must NOT use fullchain.pem (mbedTLS rejects the critical-nameConstraints CA)"
grep -q "uhttpd.main.key='/etc/knots/tls/key.pem'" "$UI_PORTS" \
	|| fail "uhttpd must use Knots TLS key"
grep -q 'ssl_certificate.*/etc/knots/tls/fullchain.pem' "$NGINX" \
	|| fail "nginx must serve Knots fullchain on :443"
pass "uhttpd HTTPS-only 8443 + shared Knots cert"

grep -q 'return 302 https://$knots_rhost/' "$NGINX" \
	|| fail "legacy :21443 must redirect to the D2 host"
grep -q 'https://" + applianceHost() + ":8443' "$SHELLJS" || fail "shell LuCI link must be https:8443"
grep -q 'function hostIsAppliance' "$SHELLJS" && grep -q ': "rnode.local"' "$SHELLJS" \
	|| fail "shell.js must keep the D2 host (names / private IPv4) with rnode.local fallback"
grep -q 'applianceUrl(it.href)' "$SHELLJS" || fail "nav items must be absolute rnode.local URLs"
pass "shell.js HTTPS links (LuCI explicit; Node via rnode.local)"

echo "ALL PASS: test-http-https-redirect"
