#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Factory-reset UI arming (N3 / U17) — show /reset.html before destructive work.
# Used by WPS rc.button (first) and Settings factory_reset / factory-reset.sh.
#
# F201 — never share a generic ACTIVE= with upgrade-ui.sh. settings-api.sh
# sources both; a clobbered ACTIVE wrote reset JSON onto upgrade.active.

FR_UI_ACTIVE=/tmp/knots/factory-reset.active
FR_UI_PENDING=/etc/knots/factory-reset-pending
# L5/T12 (review 2026-10-11): ONE expected duration for every reset path
# (Settings, CLI, reset button) and every status fallback. The old 150 s
# fallback (and 300 s for the button) made the wait page give up while the
# reset (node stop + baseline + reboot, ~10 min on a synced node) still ran.
FR_EXPECTED_SECONDS=650

factory_reset_ui_arm() {
	reason=${1:-button}
	expected=${2:-$FR_EXPECTED_SECONDS}
	FR_UI_ACTIVE=/tmp/knots/factory-reset.active
	FR_UI_PENDING=/etc/knots/factory-reset-pending
	mkdir -p /tmp/knots /etc/knots
	started=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	epoch=$(date +%s 2>/dev/null || echo 0)
	# shellcheck disable=SC2016
	printf '%s\n' "{\"active\":true,\"reason\":\"${reason}\",\"expected_seconds\":${expected},\"started\":\"${started}\",\"started_epoch\":${epoch}}" >"$FR_UI_ACTIVE"
	cp -f "$FR_UI_ACTIVE" "$FR_UI_PENDING" 2>/dev/null || cat "$FR_UI_ACTIVE" >"$FR_UI_PENDING"
	logger -t knots-factory-reset-ui "armed reason=${reason} expected=${expected}s"
	# Immediate LED cue (best-effort)
	if [ -d /sys/class/leds/green:status ]; then
		echo timer >/sys/class/leds/green:status/trigger 2>/dev/null || true
		echo 100 >/sys/class/leds/green:status/delay_on 2>/dev/null || true
		echo 100 >/sys/class/leds/green:status/delay_off 2>/dev/null || true
	fi
}

factory_reset_ui_clear() {
	FR_UI_ACTIVE=/tmp/knots/factory-reset.active
	FR_UI_PENDING=/etc/knots/factory-reset-pending
	rm -f "$FR_UI_ACTIVE" "$FR_UI_PENDING" 2>/dev/null || true
	# shellcheck disable=SC1091
	. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true
	if command -v progress_steps_clear >/dev/null 2>&1; then
		progress_steps_clear
	fi
	logger -t knots-factory-reset-ui "cleared"
}

# True while reset is running this boot (/tmp). Cleared on reboot.
factory_reset_ui_is_live() {
	[ -f /tmp/knots/factory-reset.active ]
}

# True if live OR pending across reboot (show /reset.html).
factory_reset_ui_is_active() {
	[ -f /tmp/knots/factory-reset.active ] || \
		[ -f /etc/knots/factory-reset-pending ]
}

# C9/B20 (review 2026-10-11): a reset whose worker died before it got going
# leaves factory-reset-pending (it survives reboot) while Setup is still
# complete — nginx then forces /reset.html forever, and the Setup API refused
# factory_reset_clear once Setup was complete. A real reset removes
# setup-complete early and runs with the /tmp live marker, so "pending, not
# live, Setup still complete, no factory-reset process" means it never ran.
factory_reset_ui_reap_stale() {
	[ -f /etc/knots/factory-reset-pending ] || return 0
	[ -f /tmp/knots/factory-reset.active ] && return 0
	[ -f /etc/knots/setup-complete ] || return 0
	pgrep -f '[f]actory-reset' >/dev/null 2>&1 && return 0
	logger -t knots-factory-reset-ui "reaping stale reset marker (worker never ran)"
	factory_reset_ui_clear
}

# Prints JSON object or null
factory_reset_ui_json() {
	if [ -f /tmp/knots/factory-reset.active ]; then
		cat /tmp/knots/factory-reset.active
	elif [ -f /etc/knots/factory-reset-pending ]; then
		cat /etc/knots/factory-reset-pending
	else
		printf 'null'
	fi
}
