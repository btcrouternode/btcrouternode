#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# U18 — stop Bitcoin node before clean reboot/poweroff (LuCI included).
# Idempotent; safe if node already stopped or LXC missing.

# shellcheck disable=SC1091
. /usr/libexec/knots/step-log.sh 2>/dev/null || true
if ! command -v knots_step >/dev/null 2>&1; then
	knots_step() { shift; echo "STEP $*" >&2; }
fi
# shellcheck disable=SC1091
. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true
_prog_kind=
if command -v progress_steps_current_kind >/dev/null 2>&1; then
	_prog_kind=$(progress_steps_current_kind)
fi

knots_step knots-pre-reboot "stop: begin"
if [ -n "$_prog_kind" ] && command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set "$_prog_kind" stop_node
fi
# shellcheck disable=SC1091
. /usr/libexec/knots/bitcoind-ctl.sh 2>/dev/null || true
if command -v bitcoind_ctl_stop >/dev/null 2>&1; then
	knots_step knots-pre-reboot "stop: bitcoind_ctl_stop begin"
	bitcoind_ctl_stop || true
	knots_step knots-pre-reboot "stop: bitcoind_ctl_stop done"
else
	/usr/libexec/knots/bitcoind-ctl.sh stop 2>/dev/null || true
fi
if [ -n "$_prog_kind" ] && command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set "$_prog_kind" stop_lxc
fi
knots_step knots-pre-reboot "stop: knots-start.sh stop begin"
/usr/libexec/knots/knots-start.sh stop >>/tmp/knots/knots-boot.log 2>&1 || true
knots_step knots-pre-reboot "stop: knots-start.sh stop done"
knots_step knots-pre-reboot "stop: sync"
sync
knots_step knots-pre-reboot "stop: complete"
exit 0
