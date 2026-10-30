#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# F125 / U13 — run sysupgrade outside CGI lifetime (upload may kill the CGI
# before a background subshell starts). Invoked via setsid from settings-api
# (upload) and setup-api (upgrade_resume).
set -e

# Overridable only so tests/host/test-upgrade-apply.sh can run it sandboxed.
KL="${KNOTS_LIBEXEC:-/usr/libexec/knots}"
KT="${KNOTS_TMP:-/tmp/knots}"

# shellcheck disable=SC1091
. $KL/upgrade-ui.sh 2>/dev/null || true
# shellcheck disable=SC1091
. $KL/step-log.sh 2>/dev/null || true
if ! command -v knots_step >/dev/null 2>&1; then
	knots_step() { shift; echo "STEP $*" >&2; }
fi
# shellcheck disable=SC1091
. $KL/progress-steps.sh 2>/dev/null || true

IMG="${KNOTS_UPG_IMG:-/tmp/knots-upgrade.itb}"
PENDING="$KT/upgrade-pending"
LOCK="$KT/upgrade-apply.lock"
LOG="$KT/upgrade.log"
ETC="${KNOTS_ETC:-/etc/knots}"
LASTLOG="$ETC/upgrade-last.log"

upgrade_status_write() {
	mkdir -p "$KT"
	printf '{"phase":"%s","detail":"%s","bytes":%s,"ts":"%s"}\n' \
		"$1" "$2" "${3:-0}" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$KT/upgrade-status.json"
}

# Phase 3 (review U1/U2/B19, 2026-10-11) ---------------------------------
# Lock records its owner PID: a lock left by a killed worker used to make
# every later apply exit 0 silently while upgrade_resume reported "started".
while ! mkdir "$LOCK" 2>/dev/null; do
	_o=$(cat "$LOCK/pid" 2>/dev/null || true)
	if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
		logger -t knots-upgrade "apply: already running (pid $_o)"
		exit 0
	fi
	logger -t knots-upgrade "apply: reclaiming stale lock (owner ${_o:-unknown} gone)"
	rm -rf "$LOCK"
done
echo "$$" >"$LOCK/pid"

# Own the node-op lock (L1) for the whole apply. The Settings upload hands it
# to us; the unauthenticated F125 resume path did not take it at all, so a
# node stop/start/switch could run concurrently with the flash.
# shellcheck disable=SC1091
. $KL/node-impl-lib.sh 2>/dev/null || true
if command -v node_op_acquire >/dev/null 2>&1; then
	_nop=$(cat "${NODE_OP_LOCK:-$KT/node-op.lock}/pid" 2>/dev/null || true)
	if [ -n "$_nop" ] && { [ "$_nop" = "$$" ] || [ "$_nop" = "${KNOTS_NODE_OP_FROM:-}" ]; }; then
		node_op_owner "$$"
	elif ! node_op_acquire upgrade "Appliance upgrade in progress (chain untouched)"; then
		upgrade_status_write failed "Another node operation is running — try the upgrade again shortly"
		logger -t knots-upgrade "apply: node-op lock busy"
		rm -rf "$LOCK"
		exit 1
	fi
fi

WORK="$KT/upgrade-apply.work"
NODE_STOPPED=0
# One cleanup path for every failure: nothing stale may remain that the
# unauthenticated upgrade_resume could later re-flash (B4); the UI loop is
# disarmed; a node we stopped is started again (B18); locks released.
fail_apply() {
	upgrade_status_write failed "$1"
	logger -t knots-upgrade "apply: FAILED — $1"
	rm -rf "$WORK" 2>/dev/null || true
	rm -f "$IMG" "$PENDING" 2>/dev/null || true
	if command -v upgrade_ui_clear >/dev/null 2>&1; then
		upgrade_ui_clear
	else
		rm -f "$KT/upgrade.active" 2>/dev/null || true
	fi
	if [ "$NODE_STOPPED" = 1 ] && [ -x $KL/knots-start.sh ]; then
		logger -t knots-upgrade "apply: restarting the node stopped for the upgrade"
		$KL/knots-start.sh start >>"$LOG" 2>&1 || true
	fi
	command -v node_op_release >/dev/null 2>&1 && node_op_release
	rm -rf "$LOCK"
	trap - EXIT INT TERM
	exit 1
}
trap 'fail_apply "upgrade worker interrupted"' INT TERM
trap 'rm -rf "$LOCK"' EXIT

mkdir -p "$ETC"
: >"$LASTLOG"
if command -v progress_steps_begin >/dev/null 2>&1; then
	progress_steps_begin upgrade
fi

# Allow CGI to finish writing the image and JSON response.
knots_step knots-upgrade "apply: wait 2s for CGI to finish"
sleep 2

if [ ! -s "$IMG" ]; then
	fail_apply "Upgrade image missing on appliance"
fi

# H4 — the pending record (written by the authenticated upload) is required;
# re-verify the staged image against its SHA256 before flashing.
if [ ! -f "$PENDING" ]; then
	fail_apply "Upgrade pending record missing — upload again from Settings"
fi

keep=1
if grep -q 'keep=0' "$PENDING" 2>/dev/null; then
	keep=0
fi

expect=$(sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$PENDING" | head -1)
# U1: fail CLOSED — a pending record without a hash used to skip verification.
[ -n "$expect" ] || fail_apply "Upgrade record has no SHA256 — upload again from Settings"

# U1: take the image private BEFORE verifying it. The old code verified
# /tmp/knots-upgrade.itb, spent 1–2 min in pre-reboot-stop, then flashed the
# same shared path — a second upload in between could swap in a partial or
# different image. rename() within /tmp is atomic; a later upload writes a
# NEW /tmp/knots-upgrade.itb and cannot touch the file we flash.
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"
mv -f "$IMG" "$WORK/image.itb" || fail_apply "Could not stage the upgrade image"
IMG="$WORK/image.itb"
knots_step knots-upgrade "apply: sha256 re-verify begin"
got=$(sha256sum "$IMG" | awk '{print $1}')
if [ "$got" != "$expect" ]; then
	logger -t knots-upgrade "apply: sha256 mismatch expect=$expect got=$got"
	fail_apply "SHA256 re-verify mismatch — upload again from Settings"
fi
knots_step knots-upgrade "apply: sha256 re-verify ok"

sz=$(wc -c <"$IMG" | tr -d ' ')
upgrade_status_write applying "Starting sysupgrade — device will reboot" "$sz"
logger -t knots-upgrade "apply: starting sz=$sz keep=$keep"
knots_step knots-upgrade "apply: pre-reboot-stop begin sz=$sz keep=$keep"

# Restart on failure only a node that was running — never one the owner had
# stopped (B18).
# shellcheck disable=SC1091
. $KL/bitcoind-ctl.sh 2>/dev/null || true
if command -v bitcoind_ctl_bitcoind_alive >/dev/null 2>&1 && bitcoind_ctl_bitcoind_alive; then
	NODE_STOPPED=1
fi
$KL/pre-reboot-stop.sh >>"$LOG" 2>&1 || true
knots_step knots-upgrade "apply: pre-reboot-stop done"
if command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set upgrade updating
fi

# No exec: on sysupgrade failure (no reboot) surface the failure and disarm
# the upgrade UI loop instead of dying silently (U13 UX).
# From here the image belongs to procd. sysupgrade hands it to procd
# (ubus system.sysupgrade) and normally returns NON-ZERO (rc=246 on this
# board) seconds before procd's stage 2 kills every process, flashes and
# reboots. .88 UAT-UR-2: treating that rc as a failure deleted the image
# under procd, which then rebooted WITHOUT flashing. So: a TERM/INT now
# means "procd is taking over" — exit quietly — and a non-zero rc only
# counts as a failure if we are still alive well after it.
SYSUPGRADE_HANDOFF_WAIT="${KNOTS_SYSUPGRADE_HANDOFF_WAIT:-180}"
trap 'trap - EXIT; exit 0' INT TERM
trap - EXIT
rc=0
if [ "$keep" = "0" ]; then
	knots_step knots-upgrade "apply: sysupgrade -n -v begin"
	sysupgrade -n -v "$IMG" >>"$LOG" 2>&1 || rc=$?
else
	knots_step knots-upgrade "apply: sysupgrade -v begin"
	sysupgrade -v "$IMG" >>"$LOG" 2>&1 || rc=$?
fi
knots_step knots-upgrade "apply: sysupgrade returned rc=$rc"
if [ "$rc" -ne 0 ]; then
	_w=0
	while [ "$_w" -lt "$SYSUPGRADE_HANDOFF_WAIT" ]; do
		sleep 5
		_w=$((_w + 5))
	done
	# Still running: procd never took the image — a real failure.
	trap 'fail_apply "upgrade worker interrupted"' INT TERM
	fail_apply "sysupgrade exited rc=$rc"
fi
exit 0
