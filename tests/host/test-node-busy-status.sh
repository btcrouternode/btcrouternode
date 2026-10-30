#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host: maintenance busy marker for Node Status (U2 / switch+install UX).
set -e
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/node-impl-lib.sh"
STATUS="$ROOT/files/usr/libexec/knots/status-api.sh"
APP="$ROOT/files/www/knots/app.js"

test -f "$LIB"
test -f "$STATUS"
test -f "$APP"

grep -q 'set_node_busy' "$LIB"
grep -q 'read_node_busy' "$LIB"
grep -q 'maintenance' "$STATUS"
grep -q 'maint.active' "$APP"
grep -q 'Node switch in progress' "$ROOT/files/usr/libexec/knots/node-impl.sh"
grep -q 'set_node_busy install' "$ROOT/files/usr/libexec/knots/node-impl-api.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export BUSY_FILE="$tmp/node-busy"
# shellcheck disable=SC1090
. "$LIB"

set_node_busy switch "Node switch in progress — starting Bitcoin Core."
line=$(read_node_busy)
echo "$line" | grep -q '^true|switch|Node switch'
clear_node_busy
line=$(read_node_busy)
echo "$line" | grep -q '^false|'

# Stale marker auto-clears
printf '%s\n%s\n%s\n' install "stale" 1 >"$BUSY_FILE"
export BUSY_MAX_AGE_SEC=10
# re-source to pick up age (function already uses env at call time for BUSY_MAX_AGE_SEC)
line=$(read_node_busy)
echo "$line" | grep -q '^false|'
[ ! -f "$BUSY_FILE" ]

# Soak .96: RPC warm-up (-28, "result":null) is "starting", never running at height 0
awk '/"code": \?-28/{w=NR} /grep -q .*"result"/{r=NR} END{exit !(w && r && w < r)}' "$STATUS" \
	|| { echo "FAIL: status-api must test for RPC warm-up (-28) before treating a reply as running" >&2; exit 1; }
for reply in '{"result":null,"error":{"code":-28,"message":"Loading block index…"},"id":"s"}' \
	'{"result":null,"error":{"code": -28,"message":"Verifying blocks…"},"id":"s"}'; do
	echo "$reply" | grep -qE '"code": ?-28[,}]' || { echo "FAIL: warm-up not detected: $reply" >&2; exit 1; }
done
echo '{"result":{"blocks":972000,"headers":972000},"error":null,"id":"s"}' | grep -qE '"code": ?-28[,}]' \
	&& { echo "FAIL: a normal reply was taken for warm-up" >&2; exit 1; }
grep -q 'starting: 1' "$APP" || { echo "FAIL: app.js must treat starting as initialising, not Error:" >&2; exit 1; }

echo "OK: node-busy status UX"
