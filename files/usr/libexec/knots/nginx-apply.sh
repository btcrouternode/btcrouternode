#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Apply nginx config changes WITHOUT dropping connections, one at a time.
# .92 UAT-UR-2 (review 2026-10-11): knots-node-ui did `nginx restart` (stop +
# start → "connection refused") on every start — three times on first boot,
# the last from a 25 s retry just after Setup was reported ready — and up to
# four Knots scripts (TLS leaf refresh, LAN-address hotplug, image-sync,
# knots-node-ui) reloaded at once; OpenWrt's reload regenerates uci.conf, so
# overlapping reloads failed with `open() "/etc/nginx/uci.conf" failed`.
# Running → graceful reload (HUP keeps the listening sockets); not running →
# start. Serialized with flock.
INIT="${NGINX_INIT:-/etc/init.d/nginx}"
[ -x "$INIT" ] || exit 0
LOCKDIR="${KNOTS_TMP:-/tmp/knots}"
mkdir -p "$LOCKDIR"
exec 9>"$LOCKDIR/nginx-apply.lock"
if command -v flock >/dev/null 2>&1; then
	flock -w 60 9 || logger -t knots-nginx "nginx-apply: lock wait timed out — applying anyway"
fi
if pidof nginx >/dev/null 2>&1; then
	"$INIT" reload >/dev/null 2>&1 || {
		logger -t knots-nginx "nginx reload failed — starting"
		"$INIT" start >/dev/null 2>&1
	}
else
	"$INIT" start >/dev/null 2>&1
fi
