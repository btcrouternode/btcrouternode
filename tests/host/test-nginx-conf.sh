#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NGX-T — nginx overlay must pass real nginx -t (U1/N13).
# Greps are not enough: OpenWrt nginx_init fail-closes on test failure, so :80/:443
# never bind (F129 nested if, F172 named-location proxy_pass URI).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONF="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
LINT="$ROOT/tests/host/nginx_conf_lint.py"
CACHE="$ROOT/build/host-nginx/sbin/nginx"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$CONF" ] || fail "missing $CONF"
[ -f "$LINT" ] || fail "missing nginx_conf_lint.py"

python3 "$LINT" "$CONF" || fail "nginx_conf_lint on overlay"

# Snippets: F172 / F170 / F129 must fail; legal prefix URI and sibling ifs must pass.
python3 - "$LINT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
from nginx_conf_lint import lint_text

def must(name, text, expect_fail):
    f = lint_text(text, name)
    if expect_fail and not f:
        raise SystemExit("FAIL snippet expected errors: " + name)
    if (not expect_fail) and f:
        raise SystemExit("FAIL snippet unexpected: %s %s" % (name, f))

must("f172", "location @x {\nproxy_pass http://127.0.0.1:21444/api/setup;\n}\n", True)
must("ok-named", "location @x {\nproxy_pass http://127.0.0.1:21444;\n}\n", False)
must("f170", "location /api {\nif (-f /x) { return 404; }\nproxy_pass http://127.0.0.1:21444/api;\n}\n", True)
must("nested", "location / {\nif ($a) {\nif ($b) { return 1; }\n}\n}\n", True)
must("flat-if", "location / {\nif ($a) { set $x 1; }\nif ($b) { return 302 /; }\n}\n", False)
must("prefix-uri", "location /api/node {\nproxy_pass http://127.0.0.1:21444/api/node;\n}\n", False)
print("PASS lint snippets")
PY

# Lint must reject the F172 form (would have passed T-UI-NAV greps).
BAD=$(mktemp)
trap 'rm -f "$BAD"' EXIT
sed 's|proxy_pass http://127.0.0.1:21444;|proxy_pass http://127.0.0.1:21444/api/setup;|' \
	"$CONF" >"$BAD"
if python3 "$LINT" "$BAD" >/dev/null 2>&1; then
	fail "lint must reject named-location proxy_pass with URI (F172)"
fi
pass "lint rejects F172 named-location URI"

ensure_nginx() {
	if command -v nginx >/dev/null 2>&1; then
		command -v nginx
		return 0
	fi
	if [ -x "$CACHE" ]; then
		echo "$CACHE"
		return 0
	fi
	debdir=$(mktemp -d)
	# Network fetch of the distro nginx binary so -t is the real compiler, not a grep.
	( cd "$debdir" && apt-get download nginx >/dev/null )
	deb=$(ls "$debdir"/nginx_*.deb 2>/dev/null | head -1)
	[ -n "$deb" ] || fail "apt-get download nginx produced no .deb (install nginx or retry with network)"
	ext=$(mktemp -d)
	dpkg-deb -x "$deb" "$ext"
	mkdir -p "$(dirname "$CACHE")"
	cp "$ext/usr/sbin/nginx" "$CACHE"
	chmod 755 "$CACHE"
	rm -rf "$debdir" "$ext"
	echo "$CACHE"
}

NGINX_BIN=$(ensure_nginx)
[ -x "$NGINX_BIN" ] || fail "nginx binary missing"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"; rm -f "$BAD"' EXIT
mkdir -p "$WORKDIR/body" "$WORKDIR/proxy" "$WORKDIR/fastcgi" \
	"$WORKDIR/uwsgi" "$WORKDIR/scgi"
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/key.pem" \
	-out "$WORKDIR/fullchain.pem" -days 1 -nodes -subj '/CN=rnode.local' \
	>/dev/null 2>&1 || fail "openssl self-signed cert"

# Host nginx -t tries bind(); privileged :80/:443 need rewrite for unprivileged runs.
sed -e "s|/etc/nginx/knots-headers.inc|$ROOT/files/etc/nginx/knots-headers.inc|g" \
	-e "s|/etc/knots/nginx-lan-addrs.map|$ROOT/files/etc/knots/nginx-lan-addrs.map|g" \
	-e "s|/etc/knots/tls/fullchain.pem|$WORKDIR/fullchain.pem|g" \
	-e "s|/etc/knots/tls/key.pem|$WORKDIR/key.pem|g" \
	-e 's/listen 80 /listen 18080 /g' \
	-e 's/listen \[::\]:80 /listen [::]:18080 /g' \
	-e 's/listen 443 /listen 18443 /g' \
	-e 's/listen \[::\]:443 /listen [::]:18443 /g' \
	-e 's/listen 8080 /listen 18081 /g' \
	-e 's/listen \[::\]:8080 /listen [::]:18081 /g' \
	"$CONF" >"$WORKDIR/knots-ui.conf"

cat >"$WORKDIR/nginx.conf" <<EOF
daemon off;
pid $WORKDIR/nginx.pid;
error_log $WORKDIR/error.log;
worker_processes 1;
events { worker_connections 32; }
http {
  access_log off;
  client_body_temp_path $WORKDIR/body;
  proxy_temp_path $WORKDIR/proxy;
  fastcgi_temp_path $WORKDIR/fastcgi;
  uwsgi_temp_path $WORKDIR/uwsgi;
  scgi_temp_path $WORKDIR/scgi;
  include $WORKDIR/knots-ui.conf;
}
EOF

out=$("$NGINX_BIN" -t -c "$WORKDIR/nginx.conf" -p "$WORKDIR" 2>&1) || {
	echo "$out" >&2
	fail "nginx -t of overlay conf (OpenWrt would not start nginx)"
}
echo "$out" | grep -q 'test is successful' \
	|| fail "nginx -t did not report test is successful: $out"
pass "nginx -t overlay"

sed -i 's|proxy_pass http://127.0.0.1:21444;|proxy_pass http://127.0.0.1:21444/api/setup;|' \
	"$WORKDIR/knots-ui.conf"
if "$NGINX_BIN" -t -c "$WORKDIR/nginx.conf" -p "$WORKDIR" >/dev/null 2>&1; then
	fail "nginx -t must fail the F172 URI form (would have shipped)"
fi
pass "nginx -t rejects F172"

# JS served by nginx must parse (F168/F170). node --check is syntax only.
if command -v node >/dev/null 2>&1; then
	for js in wait-handoff.js progress-wait.js upgrade.js reset.js \
		shell.js app.js settings.js node.js; do
		f="$ROOT/files/www/knots/$js"
		[ -f "$f" ] || fail "missing $js"
		node --check "$f" || fail "node --check $js"
	done
	pass "node --check UI JS"
else
	fail "node required for UI syntax check (nvm/node not on PATH)"
fi

echo "ALL PASS: test-nginx-conf (T-NGX-T)"
