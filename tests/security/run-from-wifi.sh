#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T5 — probes FROM Wi‑Fi (same L3 as LAN after associate to rnode).
# Usage:
#   WIFI_IFACE=wlan0 WIFI_SSID=rnode WIFI_PSK='yourpass' ROUTER_LAN_IP=192.168.1.254 \
#     ./run-from-wifi.sh
# Associate first (NetworkManager / iw / wpa_supplicant), then this script
# runs the LAN suite. Optional: set SKIP_ASSOC=1 if already on Wi‑Fi.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)

ZONE=WIFI
HOST="${ROUTER_LAN_IP:-192.168.1.254}"
SSID="${WIFI_SSID:-rnode}"

echo "=== T5 zone=$ZONE ssid=$SSID target=$HOST ==="

if [ "${SKIP_ASSOC:-0}" != "1" ]; then
	if [ -z "${WIFI_PSK:-}" ]; then
		echo "NOTE: WIFI_PSK not set — assuming already associated to $SSID (SKIP_ASSOC implied)"
	elif command -v nmcli >/dev/null 2>&1; then
		IFACE="${WIFI_IFACE:-}"
		echo "Associating via nmcli to $SSID…"
		if [ -n "$IFACE" ]; then
			nmcli dev wifi connect "$SSID" password "$WIFI_PSK" ifname "$IFACE" || \
				nmcli dev wifi connect "$SSID" password "$WIFI_PSK"
		else
			nmcli dev wifi connect "$SSID" password "$WIFI_PSK"
		fi
		sleep 3
	else
		echo "WARN: nmcli not found — connect to $SSID manually, then re-run with SKIP_ASSOC=1"
		exit 2
	fi
fi

# Confirm we can reach the gateway before asserting ports
# shellcheck source=lib/probe.sh
. "$ROOT/lib/probe.sh"
if ! probe_tcp "$HOST" 80; then
	echo "FAIL [$ZONE] cannot reach $HOST:80 — not on appliance Wi‑Fi/LAN?"
	exit 1
fi
echo "PASS [$ZONE] reachability to $HOST"

# Same expectations as Ethernet LAN
export ROUTER_LAN_IP="$HOST"
export STRESS_ROUNDS="${STRESS_ROUNDS:-3}"
exec "$ROOT/run-from-lan.sh"
