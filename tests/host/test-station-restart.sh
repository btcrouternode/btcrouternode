#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-STATION-RESTART — start-station.sh (desktop shortcut) must not leave an
# older station running after a new bundle is copied in (25.0.32.0 lab,
# 2026-11-10: the screen kept offering 24.10.8.29.3.118). With a fake station
# that reports its bundle's version and a stage:
#   old version, idle  → restarted, now reports the bundle's version
#   old version, busy  → refused (never stops a batch), old one keeps running
#   same version       → left alone (same process)
#   none running       → started
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
W=$(mktemp -d); trap 'pkill -f "$W/" 2>/dev/null || true; rm -rf "$W"' EXIT
B="$W/rnode-factory"; mkdir -p "$B/factory/station" "$B/build" "$W/home/knots-factory"
cp "$ROOT/factory/station/start-station.sh" "$B/factory/station/"
cp "$ROOT/build/product-version.sh" "$B/build/"
PORT=$((20000 + $$ % 20000))
cat >"$B/factory/station/rnode_station.py" <<'PY'
import http.server, json, os, re, sys
B = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VER = re.search(r"^PRODUCT_VER := (\S+)", open(f"{B}/build/version.env").read(), re.M).group(1)
STAGE = os.path.join(os.path.dirname(B), "stage")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        b = json.dumps({"version": VER, "stage": open(STAGE).read().strip(), "pid": os.getpid()}).encode()
        s.send_response(200); s.send_header("Content-Type", "application/json"); s.end_headers(); s.wfile.write(b)
    def log_message(s, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), H).serve_forever()
PY
setver() { # OPENWRT major.fix.CORE major.fix
	printf 'OPENWRT_VER := %s\nCORE_VER := %s\nPRODUCT_VER := %s\n' "$1" "$2" "$3" >"$B/build/version.env"
}
st() { python3 -c 'import json,sys,urllib.request; s=json.load(urllib.request.urlopen(sys.argv[1],timeout=3)); print(s["version"], s["stage"], s["pid"])' \
	"http://127.0.0.1:$PORT/api/state" 2>/dev/null || echo "no-station - -"; }
run() { HOME="$W/home" KNOTS_STATION_HTTP_PORT=$PORT DISPLAY= WAYLAND_DISPLAY= sh "$B/factory/station/start-station.sh"; }

echo detected >"$W/stage"
setver 25.12.6 32.1 25.0.32.0
run >/dev/null || fail "first start"
set -- $(st); [ "$1" = 25.0.32.0 ] || fail "none running → start: $*"; pid1=$3
run >/dev/null || fail "same version"
set -- $(st); [ "$3" = "$pid1" ] || fail "same version must keep the running station"
pass "starts the station; same bundle version → left running"

setver 25.12.7 32.1 25.1.32.0           # a newer bundle copied in, old station still up
echo building >"$W/stage"
run >"$W/out" 2>&1 && fail "restarted a station busy with a batch"
grep -q "busy with a batch" "$W/out" || fail "busy message: $(cat "$W/out")"
set -- $(st); [ "$3" = "$pid1" ] && [ "$1" = 25.0.32.0 ] || fail "busy station must keep running: $*"
pass "busy station (batch running) is never restarted"

echo detected >"$W/stage"
run >"$W/out" 2>&1 || fail "restart: $(cat "$W/out")"
set -- $(st); [ "$1" = 25.1.32.0 ] && [ "$3" != "$pid1" ] || fail "older station must be replaced: $*"
grep -q "Restarting the station: it is running 25.0.32.0, this bundle is 25.1.32.0" "$W/out" || fail "restart message: $(cat "$W/out")"
grep -q "RNode Factory Station 25.1.32.0" "$W/out" || fail "confirms the version it runs: $(cat "$W/out")"
pass "older idle station restarted on the new bundle; reports the bundle's version"
echo "ALL PASS: test-station-restart (T-STATION-RESTART)"
