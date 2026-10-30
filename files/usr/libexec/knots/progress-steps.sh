# SPDX-License-Identifier: GPL-2.0-only
# Shared UI step file for factory reset / firmware apply (U13 / U17).
# Writes /tmp (this boot) and /etc/knots (survives reboot) so the wait page
# can show which user-facing step is running.

_PS_TMP="${KNOTS_TMP:-/tmp/knots}"
_PS_ETC="${KNOTS_ETC:-/etc/knots}"
PROGRESS_TMP="$_PS_TMP/ui-progress.json"
PROGRESS_ETC="$_PS_ETC/ui-progress.json"

progress_steps_label() {
	case "$1" in
		stop_node) printf '%s' "Stopping BTC Node" ;;
		stop_lxc) printf '%s' "Stopping Knots Services" ;;
		reset_settings) printf '%s' "Resetting Router Settings" ;;
		updating) printf '%s' "Updating Router" ;;
		restarting) printf '%s' "Restarting Router" ;;
		starting) printf '%s' "Starting Network Services" ;;
		init) printf '%s' "Opening Setup" ;;
		*) printf '%s' "$1" ;;
	esac
}

progress_steps_rank() {
	case "$1" in
		stop_node) echo 1 ;;
		stop_lxc) echo 2 ;;
		reset_settings|updating) echo 3 ;;
		restarting) echo 4 ;;
		starting) echo 5 ;;
		init) echo 6 ;;
		*) echo 0 ;;
	esac
}

progress_steps_read_field() {
	_f=$1
	_src=$2
	[ -f "$_src" ] || return 1
	sed -n "s/.*\"${_f}\":\"\\([^\"]*\\)\".*/\\1/p" "$_src" | head -1
	unset _f _src
}

# L4/B7 (review 2026-10-11): the step file lives in /etc/knots and outlived
# the reset/upgrade that wrote it. Steps only move forward (rank check), so a
# leftover "init" blocked every later progress display, and pre-reboot-stop /
# knots-start kept re-labelling ordinary reboots as a reset. A step file only
# counts while its wait is armed; otherwise it is stale and removed.
progress_steps_armed() {
	case "$1" in
		reset) [ -f "$_PS_TMP/factory-reset.active" ] || [ -f "$_PS_ETC/factory-reset-pending" ] ;;
		upgrade) [ -f "$_PS_TMP/upgrade.active" ] ;;
		*) return 1 ;;
	esac
}

progress_steps_drop_stale() {
	[ -f "$PROGRESS_TMP" ] || [ -f "$PROGRESS_ETC" ] || return 0
	_k=$(progress_steps_read_field kind "$PROGRESS_TMP" 2>/dev/null || true)
	[ -n "$_k" ] || _k=$(progress_steps_read_field kind "$PROGRESS_ETC" 2>/dev/null || true)
	progress_steps_armed "$_k" || progress_steps_clear
	unset _k
}

progress_steps_current_step() {
	progress_steps_drop_stale
	if [ -f "$PROGRESS_TMP" ]; then
		progress_steps_read_field step "$PROGRESS_TMP"
	elif [ -f "$PROGRESS_ETC" ]; then
		progress_steps_read_field step "$PROGRESS_ETC"
	fi
}

progress_steps_current_kind() {
	progress_steps_drop_stale
	if [ -f "$PROGRESS_TMP" ]; then
		progress_steps_read_field kind "$PROGRESS_TMP"
	elif [ -f "$PROGRESS_ETC" ]; then
		progress_steps_read_field kind "$PROGRESS_ETC"
	fi
}

progress_steps_set() {
	_kind=$1
	_step=$2
	[ -n "$_kind" ] && [ -n "$_step" ] || return 0
	_cur=$(progress_steps_current_step)
	_cr=$(progress_steps_rank "$_cur")
	_nr=$(progress_steps_rank "$_step")
	if [ "$_nr" -lt "$_cr" ]; then
		unset _kind _step _cur _cr _nr
		return 0
	fi
	_label=$(progress_steps_label "$_step")
	mkdir -p "$_PS_TMP" "$_PS_ETC"
	printf '{"kind":"%s","step":"%s","label":"%s"}\n' "$_kind" "$_step" "$_label" \
		>"$PROGRESS_TMP"
	cp -f "$PROGRESS_TMP" "$PROGRESS_ETC" 2>/dev/null || \
		cat "$PROGRESS_TMP" >"$PROGRESS_ETC"
	if command -v knots_step >/dev/null 2>&1; then
		knots_step knots-progress "$_kind $_step"
	else
		logger -t knots-progress "$_kind $_step" 2>/dev/null || true
	fi
	unset _kind _step _cur _cr _nr _label
}

# A new operation always starts from a clean slate (L4).
progress_steps_begin() {
	progress_steps_clear
	progress_steps_set "${1:-reset}" stop_node
}

progress_steps_clear() {
	rm -f "$PROGRESS_TMP" "$PROGRESS_ETC" 2>/dev/null || true
}
