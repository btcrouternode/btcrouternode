#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Factory label mode (owner decision 2026-10-24) — used ONLY by the factory
# station over the serial console while stickers are applied to a batch:
#
#   factory-label.sh on [SECONDS]   enter label mode (default 1800 s, max 7200)
#   factory-label.sh led on|off     blue LED fast blink = "put the sticker on me"
#   factory-label.sh off            leave label mode, LEDs back to normal
#   factory-label.sh status         prints "label-mode on|off <unit-name>"
#
# While label mode is on, the WPS button (our reset button) does NOT reboot or
# factory-reset: a press of any length prints
#   RNODE-IDENTIFY <unit-name> <mac>
# on the console (the station reads it on that bay's serial line).
# The marker lives in /tmp (RAM) with an expiry time, so it is gone at the next
# boot and cannot outlive the batch even if the station never turns it off.
set -u
MARK="${KNOTS_LABEL_MODE_FILE:-/tmp/knots/factory-label-mode}"
LED_GREEN="${KNOTS_LED_STATUS:-/sys/class/leds/green:status}"
LED_BLUE="${KNOTS_LED_ERROR:-/sys/class/leds/blue:wps}"
NOW="${KNOTS_NOW:-$(date +%s)}"

unit() {
	n="${KNOTS_UNIT_NAME:-}"
	[ -n "$n" ] || n=$( . /usr/libexec/knots/unit-name.sh 2>/dev/null && knots_unit_name 2>/dev/null )
	echo "${n:-rnode-unknown}"
}
mac() { fw_printenv -n ethaddr 2>/dev/null | tr 'A-F' 'a-f' || true; }
active() {
	[ -f "$MARK" ] || return 1
	exp=$(cat "$MARK" 2>/dev/null)
	case "$exp" in ''|*[!0-9]*) return 1 ;; esac
	[ "$NOW" -lt "$exp" ]
}
led() { # PATH trigger [on off]
	[ -w "$1/trigger" ] || return 0
	echo "$2" >"$1/trigger" 2>/dev/null
	if [ "$2" = timer ]; then echo "$3" >"$1/delay_on"; echo "$4" >"$1/delay_off"; fi
	[ "$2" = none ] && echo 0 >"$1/brightness" 2>/dev/null
	return 0
}

case "${1:-status}" in
	on)
		s="${2:-1800}"; case "$s" in ''|*[!0-9]*) s=1800 ;; esac
		[ "$s" -gt 7200 ] && s=7200
		mkdir -p "$(dirname "$MARK")"
		echo $((NOW + s)) >"$MARK"
		led "$LED_BLUE" none; led "$LED_GREEN" none
		logger -t knots-label "label mode on for ${s}s ($(unit))" 2>/dev/null
		echo "label-mode on $(unit) $(mac)"
		;;
	off)
		rm -f "$MARK"
		led "$LED_BLUE" none
		logger -t knots-label "label mode off ($(unit))" 2>/dev/null
		/usr/libexec/knots/led-status.sh >/dev/null 2>&1 || true
		echo "label-mode off $(unit)"
		;;
	led)
		active || { echo "label-mode off — LED not changed" >&2; exit 1; }
		case "${2:-}" in
			on) led "$LED_GREEN" none; led "$LED_BLUE" timer 100 100 ;;
			off) led "$LED_BLUE" none ;;
			*) echo "usage: factory-label.sh led on|off" >&2; exit 2 ;;
		esac
		echo "label-led ${2} $(unit)"
		;;
	press) # called by /etc/rc.button/reset in label mode
		msg="RNODE-IDENTIFY $(unit) $(mac)"
		echo "$msg" >/dev/console 2>/dev/null
		logger -t knots-label "$msg" 2>/dev/null
		;;
	active) active; exit $? ;;   # must not fall through to the final exit 0
	status) if active; then echo "label-mode on $(unit)"; else echo "label-mode off $(unit)"; fi ;;
	*) echo "usage: factory-label.sh on [SECONDS] | off | led on|off | status" >&2; exit 2 ;;
esac
exit 0
