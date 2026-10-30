#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T5 — probes FROM the WAN zone (PC on modem/WAN side, or second NIC).
# Usage: ROUTER_WAN_IP=x.x.x.x ./run-from-wan.sh
# Expect: management closed; Bitcoin P2P 8333 may be open (DNAT).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/probe.sh
. "$ROOT/lib/probe.sh"

ZONE=WAN
HOST="${ROUTER_WAN_IP:-}"
if [ -z "$HOST" ]; then
	echo "Usage: ROUTER_WAN_IP=<wan-address> $0"
	echo "Find WAN IP on router: uci get network.wan.ipaddr  OR  ifstatus wan"
	exit 2
fi

echo "=== T5 zone=$ZONE target=$HOST rounds=$STRESS_ROUNDS ==="

# Management / UI / SSH / RPC — must be closed from WAN
for spec in \
	"80:Node UI HTTP" \
	"443:Node UI HTTPS" \
	"8080:LuCI HTTP" \
	"8443:LuCI HTTPS" \
	"21443:legacy UI" \
	"22:SSH" \
	"8332:Knots RPC"
do
	port=${spec%%:*}
	label=${spec#*:}
	record expect_closed "$ZONE" "$HOST" "$port" "$label"
done

for p in $EXTRA_CLOSED_PORTS; do
	record expect_closed "$ZONE" "$HOST" "$p" "extra/$p"
done

# 8333 — product allows WAN DNAT to DMZ (may be filtered by upstream ISP)
if probe_tcp "$HOST" 8333; then
	echo "PASS [$ZONE] TCP 8333 reachable (expected DNAT to Knots P2P)"
	pass_count=$((pass_count + 1))
else
	echo "WARN [$ZONE] TCP 8333 not reachable from here (ISP/CGNAT/filter?) — not a FAIL by itself"
fi

# Stress closed ports harder
STRESS_ROUNDS_SAVE=$STRESS_ROUNDS
STRESS_ROUNDS="${WAN_STRESS_ROUNDS:-10}"
echo "--- WAN stress rounds=$STRESS_ROUNDS on mgmt ports ---"
for port in 80 443 8080 22 8332; do
	record expect_closed "$ZONE" "$HOST" "$port" "stress/$port"
done
STRESS_ROUNDS=$STRESS_ROUNDS_SAVE

summary_exit
