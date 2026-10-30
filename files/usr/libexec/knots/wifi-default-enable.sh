#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Enable LAN Wi‑Fi by default when radios exist (R7 / U6 / R13).
# SSID rnode; factory WPA2 key = the per-device label secret (P1). Unlabelled
# units: radios off until Setup. Setup must replace the key either way.
# shellcheck shell=ash

set -e

. /usr/libexec/knots/setup-lib.sh

KEY_FILE=/etc/knots/wifi.key
DONE_FILE=/etc/knots/wifi-default-done
SSID=rnode

mkdir -p /etc/knots

# Ensure mac80211 has created /etc/config/wireless
if [ ! -f /etc/config/wireless ] || ! setup_wifi_available; then
	command -v wifi >/dev/null 2>&1 && wifi config 2>/dev/null || true
fi
setup_wifi_available || {
	logger -t knots-wifi "no wireless radio — skip default AP"
	exit 0
}

# N1 (review 2026-10-10): once the default has been applied, never re-apply
# at boot. The old guard re-ran whenever radio0 was disabled, so an owner who
# turned Wi-Fi off in LuCI got it back on every boot with the factory PSK and
# their custom SSID/key overwritten. Factory reset removes DONE_FILE on purpose.
if [ -f "$DONE_FILE" ]; then
	exit 0
fi

# P1 / D1: labelled units broadcast rnode with the per-device label secret.
# Unlabelled units (no secret) keep every radio OFF until Setup sets a new key
# — first Setup is over Ethernet — instead of a fleet-wide shared PSK.
key=$(knots_factory_secret 2>/dev/null) || key=
if [ -z "$key" ]; then
	uci -q show wireless | sed -n 's/^\(wireless\.[^=]*\)=wifi-device.*/\1/p' | while read -r sec; do
		uci -q set "${sec}.disabled=1"
	done
	uci -q commit wireless
	rm -f "$KEY_FILE"
	setup_wifi_reload_now
	touch "$DONE_FILE"
	logger -t knots-wifi "no per-device secret (unlabelled unit) — Wi-Fi off until Setup"
	echo "knots-wifi: unlabelled unit — Wi-Fi off until Setup (use a LAN cable)" >&2
	exit 0
fi
( umask 077; printf '%s\n' "$key" >"$KEY_FILE" )

country=
[ -f /etc/knots/wifi-country ] && country=$(tr -d '\r\n' </etc/knots/wifi-country)
[ -n "$country" ] || country=$(uci -q get wireless.radio0.country 2>/dev/null || true)
# hostapd rejects country 00. Use a real ISO code until IUE locale (U17/U19).
[ -n "$country" ] || country=$FACTORY_WIFI_COUNTRY

setup_wifi_apply "$SSID" "$key" "$country" || {
	logger -t knots-wifi "setup_wifi_apply failed"
	exit 1
}
setup_wifi_reload_now

touch "$DONE_FILE"
logger -t knots-wifi "AP enabled SSID=$SSID country=$country (label secret until Setup)"
echo "knots-wifi: SSID=$SSID — factory passphrase (change in Setup)" >&2
exit 0
