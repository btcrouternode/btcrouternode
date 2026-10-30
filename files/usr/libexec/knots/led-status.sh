#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# N4 — map node state to BPI-R4 status LEDs (TECH_SPEC §9.2).
# Primary: green:status   Error accent: blue:wps
# States: booting | syncing | synced | error

set -e

LED_GREEN="${KNOTS_LED_STATUS:-/sys/class/leds/green:status}"
LED_BLUE="${KNOTS_LED_ERROR:-/sys/class/leds/blue:wps}"
STATUS_JSON="${KNOTS_STATUS_JSON:-/tmp/knots/status.json}"
STATE_FILE="${KNOTS_LED_STATE:-/tmp/knots/led.state}"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
# Factory label mode: the station owns the LEDs (blue = "put the sticker on me").
LABEL_TOOL="${KNOTS_LABEL_TOOL:-/usr/libexec/knots/factory-label.sh}"
if [ -x "$LABEL_TOOL" ] && "$LABEL_TOOL" active; then
	exit 0
fi

led_ok() {
	[ -d "$1" ] && [ -w "$1/trigger" ]
}

led_off() {
	led_ok "$1" || return 0
	echo none >"$1/trigger" 2>/dev/null || true
	echo 0 >"$1/brightness" 2>/dev/null || true
}

led_on() {
	led_ok "$1" || return 0
	echo none >"$1/trigger" 2>/dev/null || true
	echo 1 >"$1/brightness" 2>/dev/null || true
}

led_timer() {
	# $1 path  $2 delay_on_ms  $3 delay_off_ms
	led_ok "$1" || return 0
	echo timer >"$1/trigger" 2>/dev/null || true
	echo "$2" >"$1/delay_on" 2>/dev/null || true
	echo "$3" >"$1/delay_off" 2>/dev/null || true
}

derive_state() {
	# Prefer fresh status.json; fall back to storage/rpc clues.
	if [ ! -f "$STATUS_JSON" ]; then
		echo booting
		return
	fi

	running=false
	mounted=false
	# status.json is pretty-printed with optional spaces after ':'
	grep -qE '"running" *: *true' "$STATUS_JSON" && running=true
	grep -qE '"mounted" *: *true' "$STATUS_JSON" && mounted=true
	prog=$(sed -n 's/.*"verification_progress" *: *\([0-9.eE+-]*\).*/\1/p' "$STATUS_JSON" | head -1)
	blocks=$(sed -n 's/.*"blocks" *: *\([0-9]*\).*/\1/p' "$STATUS_JSON" | head -1)
	headers=$(sed -n 's/.*"headers" *: *\([0-9]*\).*/\1/p' "$STATUS_JSON" | head -1)
	[ -n "$prog" ] || prog=0
	[ -n "$blocks" ] || blocks=0
	[ -n "$headers" ] || headers=0

	# Explicit storage / hard errors (not transient "starting")
	if grep -qE '"error" *: *"(storage_not_mounted|error_no_disk|rpc_cookie_missing|bitcoind_rpc_unreachable)"' "$STATUS_JSON"; then
		if grep -qE '"error" *: *"bitcoind_rpc_unreachable"' "$STATUS_JSON" && [ "$mounted" = true ]; then
			echo booting
			return
		fi
		echo error
		return
	fi
	if [ "$mounted" = false ]; then
		echo error
		return
	fi
	if [ "$running" = false ]; then
		echo booting
		return
	fi

	# Syncing while IBD / behind tip / progress not near 1.0
	behind=0
	[ "$headers" -gt "$blocks" ] 2>/dev/null && behind=1
	prog_milli=$(printf '%s' "$prog" | awk '{printf "%d", $1 * 1000}')
	[ -n "$prog_milli" ] || prog_milli=0
	if [ "$behind" -eq 1 ] || [ "$prog_milli" -lt 999 ]; then
		echo syncing
		return
	fi
	echo synced
}

apply_state() {
	state=$1
	case "$state" in
		booting)
			# Slow blink green; blue off
			led_off "$LED_BLUE"
			led_timer "$LED_GREEN" 1000 1000
			;;
		syncing)
			# Fast blink green; blue off
			led_off "$LED_BLUE"
			led_timer "$LED_GREEN" 200 200
			;;
		synced)
			# Solid green
			led_off "$LED_BLUE"
			led_on "$LED_GREEN"
			;;
		error|*)
			# Green off; blue error blink
			led_off "$LED_GREEN"
			led_timer "$LED_BLUE" 400 400
			;;
	esac
	echo "$state" >"$STATE_FILE"
}

STATE=${1:-}
if [ -z "$STATE" ]; then
	STATE=$(derive_state)
fi
apply_state "$STATE"
echo "$STATE"
exit 0
