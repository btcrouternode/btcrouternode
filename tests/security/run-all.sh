#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T5 orchestrator — run whichever zone scripts the environment supports.
# See docs/SECURITY_ZONE_TEST.md
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
rc=0
skipped=0

echo "======== T5 / NF10 zone security suite ========"

echo
echo "--- (1) On-router UCI + DMZ (needs SSH or serial paste) ---"
if [ -n "${ROUTER_SSH:-}" ]; then
	# ROUTER_SSH=root@192.168.1.254
	if ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER_SSH" "sh -s" <"$ROOT/run-on-router-dmz.sh"; then
		echo "PASS on-router via SSH"
	else
		echo "FAIL on-router via SSH"; rc=1
	fi
else
	echo "SKIP on-router (set ROUTER_SSH=root@192.168.1.254 or run run-on-router-dmz.sh on device)"
	skipped=1
fi

echo
echo "--- (2) From LAN ---"
if ROUTER_LAN_IP="${ROUTER_LAN_IP:-192.168.1.254}" "$ROOT/run-from-lan.sh"; then
	echo "PASS LAN suite"
else
	echo "FAIL LAN suite"; rc=1
fi

echo
echo "--- (3) From Wi‑Fi ---"
if [ "${RUN_WIFI:-0}" = "1" ]; then
	if "$ROOT/run-from-wifi.sh"; then
		echo "PASS Wi‑Fi suite"
	else
		echo "FAIL Wi‑Fi suite"; rc=1
	fi
else
	echo "SKIP Wi‑Fi (set RUN_WIFI=1 WIFI_PSK=… or SKIP_ASSOC=1)"
	skipped=1
fi

echo
echo "--- (4) From WAN ---"
if [ -n "${ROUTER_WAN_IP:-}" ]; then
	if "$ROOT/run-from-wan.sh"; then
		echo "PASS WAN suite"
	else
		echo "FAIL WAN suite"; rc=1
	fi
else
	echo "SKIP WAN (set ROUTER_WAN_IP=… from ifstatus wan)"
	skipped=1
fi

echo
# M16 — a skipped zone is not a passed zone: PARTIAL must fail the gate so a
# green run always means all four zones actually executed and passed.
if [ "$rc" -ne 0 ]; then
	echo "=== T5 OVERALL FAIL ==="
elif [ "$skipped" -ne 0 ]; then
	echo "=== T5 PARTIAL (zones skipped) ==="
	rc=1
else
	echo "=== T5 OVERALL PASS (all four zones) ==="
fi
exit "$rc"
