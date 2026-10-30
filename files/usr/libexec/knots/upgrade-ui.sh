#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Firmware-upgrade UI arming (U13) — show /upgrade.html while sysupgrade runs.
# Marker is /tmp only (cleared on reboot).
#
# F201 — unique UPG_UI_ACTIVE; do not reuse a generic ACTIVE= that
# factory-reset-ui.sh also defined (settings-api.sh sources both).

UPG_UI_ACTIVE=/tmp/knots/upgrade.active

upgrade_ui_arm() {
	reason=${1:-settings}
	expected=${2:-180}
	keep_cfg=${3:-1}
	UPG_UI_ACTIVE=/tmp/knots/upgrade.active
	mkdir -p /tmp/knots
	started=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	epoch=$(date +%s 2>/dev/null || echo 0)
	case "$keep_cfg" in
		0|false|False|no|NO) keep_json=false ;;
		*) keep_json=true ;;
	esac
	# shellcheck disable=SC2016
	printf '%s\n' "{\"active\":true,\"reason\":\"${reason}\",\"expected_seconds\":${expected},\"keep_config\":${keep_json},\"started\":\"${started}\",\"started_epoch\":${epoch}}" >"$UPG_UI_ACTIVE"
	logger -t knots-upgrade-ui "armed reason=${reason} expected=${expected}s"
	if [ -d /sys/class/leds/green:status ]; then
		echo timer >/sys/class/leds/green:status/trigger 2>/dev/null || true
		echo 100 >/sys/class/leds/green:status/delay_on 2>/dev/null || true
		echo 100 >/sys/class/leds/green:status/delay_off 2>/dev/null || true
	fi
}

upgrade_ui_clear() {
	UPG_UI_ACTIVE=/tmp/knots/upgrade.active
	rm -f "$UPG_UI_ACTIVE" 2>/dev/null || true
	# shellcheck disable=SC1091
	. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true
	if command -v progress_steps_clear >/dev/null 2>&1; then
		progress_steps_clear
	fi
	logger -t knots-upgrade-ui "cleared"
}

upgrade_ui_is_live() {
	[ -f /tmp/knots/upgrade.active ]
}

upgrade_ui_keep_config() {
	if [ ! -f /tmp/knots/upgrade.active ]; then
		printf 'true'
		return
	fi
	if grep -q '"keep_config":false' /tmp/knots/upgrade.active 2>/dev/null; then
		printf 'false'
	else
		printf 'true'
	fi
}

upgrade_ui_json() {
	if [ -f /tmp/knots/upgrade.active ]; then
		cat /tmp/knots/upgrade.active
	else
		printf 'null'
	fi
}
