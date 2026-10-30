#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T5 — probes FROM the LAN zone (Ethernet client on 192.168.1.0/24).
# Usage: ROUTER_LAN_IP=192.168.1.254 ./run-from-lan.sh
set -euo pipefail
# LAN-scoped closed list: TCP/53 (dnsmasq) is the LAN resolver — REQUIRED
# router service (R3), not an exposure. It remains required-closed on WAN/DMZ.
EXTRA_CLOSED_PORTS="${EXTRA_CLOSED_PORTS_LAN:-21 23 25 139 445 3389 5900 8081 8444 9000 9100}"
ROOT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/probe.sh
. "$ROOT/lib/probe.sh"

ZONE=LAN
HOST="${ROUTER_LAN_IP:-192.168.1.254}"

echo "=== T5 zone=$ZONE target=$HOST rounds=$STRESS_ROUNDS ==="

# Designed open on LAN
record expect_open "$ZONE" "$HOST" 80 "Node UI HTTP"
record expect_open "$ZONE" "$HOST" 443 "Node UI HTTPS"
record expect_open "$ZONE" "$HOST" 8080 "LuCI HTTP"

# Must stay closed on LAN by default (RPC only via optional enable)
record expect_closed "$ZONE" "$HOST" 8332 "Knots RPC (default off)"

if [ "${RETAIL:-0}" = "1" ]; then
	record expect_closed "$ZONE" "$HOST" 22 "SSH (retail must be closed)"
else
	if probe_tcp "$HOST" 22; then
		echo "WARN [$ZONE] SSH open on LAN — OK for lab; set RETAIL=1 to FAIL"
	else
		echo "PASS [$ZONE] SSH closed on LAN"
		pass_count=$((pass_count + 1))
	fi
fi

for p in $EXTRA_CLOSED_PORTS; do
	record expect_closed "$ZONE" "$HOST" "$p" "extra/$p"
done

# Light HTTP sanity (not a load test)
if command -v curl >/dev/null 2>&1; then
	if curl -fsS --max-time 5 "http://${HOST}/" >/dev/null; then
		echo "PASS [$ZONE] HTTP GET / responds"
		pass_count=$((pass_count + 1))
	else
		echo "FAIL [$ZONE] HTTP GET / failed"
		fail_count=$((fail_count + 1))
	fi
fi

summary_exit
