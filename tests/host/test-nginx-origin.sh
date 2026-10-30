#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NGX-ORIGIN — review S1/S2/S3 (2026-10-10). Runs the real overlay nginx
# config against a stub CGI upstream and checks, over HTTP:
#   S1  foreign Host (DNS rebinding) → 421 on every server
#   S3  foreign Origin → 403 (incl. "null"); no Origin (curl/UAT) still works
#   S2  no "Access-Control-Allow-Origin: *" anywhere; allowed Origin echoed on
#       /api/alive + /api/status; :80 /api/settings + /api/node never send ACAO
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONF="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
CACHE="$ROOT/build/host-nginx/sbin/nginx"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

NGINX_BIN=$(command -v nginx 2>/dev/null || echo "$CACHE")
[ -x "$NGINX_BIN" ] || { echo "SKIP: no nginx (run test-nginx-conf.sh first to cache one)"; exit 0; }
command -v curl >/dev/null || fail "curl required"

W=$(mktemp -d)
UP_PID=
cleanup() {
	[ -f "$W/nginx.pid" ] && kill "$(cat "$W/nginx.pid")" 2>/dev/null || true
	[ -n "$UP_PID" ] && kill "$UP_PID" 2>/dev/null || true
	rm -rf "$W"
}
trap cleanup EXIT

P80=28080; P443=28443; P8080=28081; P21443=28444; PUP=28445
mkdir -p "$W/body" "$W/proxy" "$W/fastcgi" "$W/uwsgi" "$W/scgi" \
	"$W/www/knots" "$W/tmpk" "$W/etck/tls"
echo '<html>ok</html>' >"$W/www/knots/index.html"
echo '<html>setup</html>' >"$W/www/knots/setup.html"
echo '<html>tls</html>' >"$W/www/knots/tls.html"
mkdir -p "$W/www/knots/tls"; echo 'rem bat' >"$W/www/knots/tls/install-windows.bat"
echo '{"ok":true,"product_version":"t"}' >"$W/tmpk/status.json"
openssl req -x509 -newkey rsa:2048 -keyout "$W/etck/tls/key.pem" \
	-out "$W/etck/tls/fullchain.pem" -days 1 -nodes -subj '/CN=rnode.local' \
	>/dev/null 2>&1 || fail "openssl"
cp "$W/etck/tls/fullchain.pem" "$W/etck/tls/ca.pem"

sed -e "s|/etc/nginx/knots-headers.inc|$ROOT/files/etc/nginx/knots-headers.inc|g" -e "s|/etc/knots/nginx-lan-addrs.map|$W/lan-addrs.map|g" -e "s|/etc/knots|$W/etck|g" -e "s|/tmp/knots|$W/tmpk|g" -e "s|/www/knots|$W/www/knots|g" \
	-e "s|127.0.0.1:21444|127.0.0.1:$PUP|g" \
	-e "s/listen 80 /listen 127.0.0.1:$P80 /" -e '/listen \[::\]:80 /d' \
	-e "s/listen 443 /listen 127.0.0.1:$P443 /" -e '/listen \[::\]:443 /d' \
	-e "s/listen 8080 /listen 127.0.0.1:$P8080 /" -e '/listen \[::\]:8080 /d' \
	-e "s/listen 21443 /listen 127.0.0.1:$P21443 /" -e '/listen \[::\]:21443 /d' \
	-e 's/^\t~^127\\. 1;$/\t~^127\\.0\\.0\\.3 1;/' \
	"$CONF" >"$W/knots-ui.conf"
# S11 topology: 127.0.0.1 is a LAN address via the generated map file;
# 127.0.0.2 is the "WAN" address (the loopback regex is narrowed above).
# Plus the longest possible IPv6 key: the hotplug writes real LAN addresses
# here, and on the router (32-byte default bucket) a 17-char one already broke
# nginx start-up (.77).
printf '"127.0.0.1" 1;\n"ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" 1;\n' >"$W/lan-addrs.map"
sed -i -e "s/listen 127.0.0.1:\([0-9]*\)\(.*\)$/listen 127.0.0.1:\1\2\n\tlisten 127.0.0.2:\1\2/" "$W/knots-ui.conf"

cat >"$W/nginx.conf" <<EOF
daemon on;
pid $W/nginx.pid;
error_log $W/error.log;
worker_processes 1;
events { worker_connections 32; }
http {
  access_log off;
  client_body_temp_path $W/body;
  proxy_temp_path $W/proxy;
  fastcgi_temp_path $W/fastcgi;
  uwsgi_temp_path $W/uwsgi;
  scgi_temp_path $W/scgi;
  include $W/knots-ui.conf;
}
EOF

# Stub CGI upstream: always {"ok":true}
python3 -I - "$PUP" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        b = b'{"ok":true}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = _r
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
UP_PID=$!
# Router nginx defaults the map bucket to 32 bytes (host nginx rounds up to its
# 64-byte cache line, so this cannot be reproduced here — see
# test-nginx-device.sh, which runs the image's own nginx binary).
grep -q '^map_hash_bucket_size 128;' "$CONF" || fail "map_hash_bucket_size 128 missing (router nginx start-up)"
"$NGINX_BIN" -c "$W/nginx.conf" -p "$W" || { cat "$W/error.log" >&2; fail "nginx start"; }
sleep 0.5

# req PORT SCHEME HOST [ORIGIN] PATH [METHOD] → prints "code|acao"
req() {
	port=$1 scheme=$2 host=$3 origin=$4 path=$5 method=${6:-GET}
	set -- -s -k -o /dev/null -D "$W/h" -w '%{http_code}' -X "$method" \
		--resolve "$host:$port:127.0.0.1" -H "Host: $host"
	[ -n "$origin" ] && set -- "$@" -H "Origin: $origin"
	[ "$method" = POST ] && set -- "$@" --data 'action=status'
	code=$(curl "$@" "$scheme://$host:$port$path" 2>/dev/null || echo 000)
	acao=$(tr -d '\r' <"$W/h" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p')
	echo "$code|$acao"
}
expect() { got=$1 want=$2 what=$3; [ "$got" = "$want" ] || fail "$what: got '$got' want '$want'"; }

# --- S11: WAN-arrived requests refused ---
grep -q 'listen 127.0.0.2:' "$W/knots-ui.conf" || fail "test setup: WAN listener missing"
wan() { # PORT SCHEME PATH → code (request to the router's WAN address)
	curl -s -k -o /dev/null -w '%{http_code}' -H "Host: rnode.local" \
		"$2://127.0.0.2:$1$3" 2>/dev/null || echo 000
}
for spec in "$P80 http /api/alive" "$P80 http /setup.html" "$P443 https /settings.html" \
	"$P443 https /api/settings?action=status" "$P8080 http /" "$P21443 https /"; do
	set -- $spec
	[ "$(wan "$1" "$2" "$3")" = 403 ] || fail "S11 WAN :$1 $3 not refused ($(wan "$1" "$2" "$3"))"
done
expect "$(req $P80 http rnode.local "" /api/alive)" "200|" "S11 LAN address still served"
pass "S11 requests arriving on a WAN address → 403; LAN address served"

# --- S1: Host allowlist on every server ---
for h in evil.example attacker.com 1.2.3.4 rnode.local.evil.com; do
	expect "$(req $P80 http "$h" "" /api/alive)" "421|" "S1 :80 Host=$h"
	expect "$(req $P443 https "$h" "" /api/status)" "421|" "S1 :443 Host=$h"
	expect "$(req $P8080 http "$h" "" /)" "421|" "S1 :8080 Host=$h"
	expect "$(req $P21443 https "$h" "" /)" "421|" "S1 :21443 Host=$h"
done
for h in rnode.local node-router knots-router node-router.lan 192.168.1.254 10.0.0.1 172.20.1.1; do
	expect "$(req $P80 http "$h" "" /api/alive)" "200|" "S1 :80 allowed Host=$h"
done
pass "S1 foreign Host → 421 on :80/:443/:8080/:21443; appliance names/IPs allowed"

# --- S3: Origin allowlist ---
for o in https://evil.example http://attacker.com null http://rnode.local.evil.com; do
	expect "$(req $P80 http rnode.local "$o" '/api/setup?action=password' POST)" "403|" "S3 POST setup Origin=$o"
	expect "$(req $P80 http rnode.local "$o" '/api/settings?action=conf')" "403|" "S3 GET conf Origin=$o"
	expect "$(req $P443 https rnode.local "$o" '/api/settings?action=status' POST)" "403|" "S3 :443 Origin=$o"
done
expect "$(req $P80 http rnode.local "" '/api/setup?action=status' POST)" "200|" "S3 no Origin (non-browser)"
expect "$(req $P443 https rnode.local "https://rnode.local" '/api/settings?action=status' POST)" "200|" "S3 same origin"
pass "S3 foreign/null Origin → 403; same-origin and no-Origin clients allowed"

# --- S2: CORS ---
! grep -q 'Allow-Origin "\*"' "$CONF" || fail "S2 wildcard ACAO still in config"
expect "$(req $P80 http rnode.local "https://rnode.local" /api/alive)" "200|https://rnode.local" "S2 alive echo"
expect "$(req $P443 https rnode.local "http://rnode.local" /api/status)" "200|http://rnode.local" "S2 :443 status echo"
expect "$(req $P80 http 192.168.1.254 "http://192.168.1.254" /api/status)" "200|http://192.168.1.254" "S2 IP origin echo"
expect "$(req $P80 http rnode.local "" /api/alive)" "200|" "S2 no Origin → no ACAO"
expect "$(req $P80 http rnode.local "https://rnode.local" '/api/settings?action=status')" "200|" "S2 :80 settings no ACAO"
expect "$(req $P80 http rnode.local "https://rnode.local" '/api/node?action=status')" "200|" "S2 :80 node no ACAO"
pass "S2 no wildcard CORS; allowed Origin echoed only on alive/status/setup"

# --- S6: security headers survive location-level add_header ---
hdr_of() { # PORT SCHEME PATH HEADER
	curl -s -k -o /dev/null -D - --resolve "rnode.local:$1:127.0.0.1" \
		"$2://rnode.local:$1$3" 2>/dev/null | tr -d '\r' | \
		awk -v h="$(echo "$4" | tr 'A-Z' 'a-z')" -F': ' 'tolower($1) == h { print $2 }'
}
for spec in "$P80 http /setup.html" "$P80 http /api/alive" "$P80 http /tls/install-linux.sh" \
	"$P80 http /knots-ca.crt" "$P443 https /settings.html" "$P443 https /api/status" \
	"$P443 https /index.html" "$P443 https /nonexistent" "$P8080 http /" "$P21443 https /"; do
	set -- $spec
	[ "$(hdr_of "$1" "$2" "$3" X-Frame-Options)" = DENY ] || fail "S6 X-Frame-Options missing on :$1 $3"
	[ "$(hdr_of "$1" "$2" "$3" X-Content-Type-Options)" = nosniff ] || fail "S6 nosniff missing on :$1 $3"
	hdr_of "$1" "$2" "$3" Content-Security-Policy | grep -q "frame-ancestors 'none'" \
		|| fail "S6 CSP frame-ancestors missing on :$1 $3"
done
pass "S6 X-Frame-Options/nosniff/CSP frame-ancestors on every location type"

# --- D2/H3: redirects keep the host the browser used (SAN names / LAN IP)
loc() { # PORT HOST PATH → Location header
	curl -s -o /dev/null -D - --resolve "$2:$1:127.0.0.1" -H "Host: $2" "http://$2:$1$3" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^[Ll]ocation: //p'
}
expect "$(loc $P8080 rnode.local /)" "https://rnode.local:8443/" "D2 :8080 Host=rnode.local"
expect "$(loc $P8080 node-router /)" "https://node-router:8443/" "D2 :8080 Host=node-router"
expect "$(loc $P8080 127.0.0.1 /)" "https://127.0.0.1:8443/" "D2 :8080 Host=IP → router address"
expect "$(loc $P8080 192.168.77.7 /)" "https://127.0.0.1:8443/" "D2 :8080 Host=other private IP → router address"
expect "$(loc $P8080 printer.lan /)" "https://rnode.local:8443/" "D2 :8080 other allowed name → rnode.local"
expect "$(loc $P8080 rnode-3f2a.local /)" "https://rnode-3f2a.local:8443/" "N20 :8080 unit name kept"
expect "$(loc $P8080 rnode-2.local /)" "https://rnode.local:8443/" "N20 avahi rename (rnode-2) is not a unit name"
grep -n 'return 302 https\?://rnode\.local' "$CONF" && fail "D2: hard-coded rnode.local redirect left"
pass "D2 redirects: SAN names kept, IPv4 → router address, others → rnode.local"

# --- Setup page after Setup (.97 field report): the https Setup API is locked
# (404) once Setup is complete, so a bookmarked / restored Setup page must
# open Node Status instead of a wizard that cannot work.
sloc() { # PORT SCHEME PATH → code|Location
	curl -s -k -o /dev/null -w '%{http_code}|%{redirect_url}' --resolve "rnode.local:$1:127.0.0.1" \
		"$2://rnode.local:$1$3" 2>/dev/null
}
rm -f "$W/etck/setup-complete"
expect "$(sloc $P443 https '/setup.html?after_tls=1')" "200|" "before Setup: https Setup page served"
touch "$W/etck/setup-complete"
expect "$(sloc $P443 https '/setup.html?after_tls=1')" "302|https://rnode.local/" "after Setup: https Setup page → Node Status"
expect "$(sloc $P80 http /setup.html)" "302|https://rnode.local/setup.html" "after Setup: http Setup page → https (then Node Status)"
expect "$(sloc $P443 https '/api/setup?action=status')" "404|" "after Setup: https Setup API locked"
expect "$(sloc $P443 https /index.html)" "200|" "after Setup: other pages unaffected"
# "Add this computer" (owner, 2026-10-26): a computer that does not trust the
# router yet types the plain address → the Secure connection page, no warning
expect "$(sloc $P80 http /)" "302|http://rnode.local/tls.html?add=1" "after Setup: http / → Add this computer"
expect "$(sloc $P80 http /index.html)" "302|http://rnode.local/tls.html?add=1" "after Setup: http /index.html → Add this computer"
expect "$(sloc $P80 http '/tls.html?add=1')" "200|" "after Setup: the Secure connection page stays on plain http"
expect "$(sloc $P80 http /tls/install-windows.bat)" "200|" "after Setup: installers on plain http"
rm -f "$W/etck/setup-complete"
pass "Setup page after Setup opens Node Status (https API stays locked)"

# --- first-use captive portal: connectivity checks → Setup, only until Setup completes
cap() { # HOST → code|Location on :80
	curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' -H "Host: $1" "http://127.0.0.1:$P80/generate_204" 2>/dev/null
}
rm -f "$W/etck/setup-complete"
for h in connectivitycheck.gstatic.com captive.apple.com www.msftconnecttest.com nmcheck.gnome.org; do
	expect "$(cap $h)" "302|http://127.0.0.1/setup.html" "captive: $h before Setup"
done
expect "$(cap evil.example)" "421|" "captive: other foreign hosts still refused"
touch "$W/etck/setup-complete"
expect "$(cap connectivitycheck.gstatic.com)" "421|" "captive: after Setup the check host is foreign again"
rm -f "$W/etck/setup-complete"
pass "captive portal: phones' connectivity checks → Setup redirect before Setup, refused after; other hosts still 421"

# Phones / tablets have no certificate path any more (Setup is laptop/computer
# only, 2026-10-25): the .106 Android download is gone.
acode=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P80/tls/android-certificate.crt" -H "Host: 192.168.1.254")
[ "$acode" != 200 ] || fail "the Android certificate download must be gone (got 200)"
pass "no Android certificate download (Setup is laptop/computer only)"

echo "ALL PASS: test-nginx-origin (T-NGX-ORIGIN)"
