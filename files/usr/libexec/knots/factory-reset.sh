#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Factory reset system config (N3). Never wipes M.2 (S7).

set -e

CONFIRM=""
REBOOT=1

usage() {
	echo "Usage: $0 --confirm RESET [--no-reboot]" >&2
	echo "Note: M.2 wipe is not supported (REQUIREMENTS S7 / N3)." >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--confirm) CONFIRM="$2"; shift ;;
		--wipe-storage|--confirm-wipe)
			echo "refusing: on-device M.2 wipe retired (S7 / N3)" >&2
			exit 1
			;;
		--no-reboot) REBOOT=0 ;;
		*) usage ;;
	esac
	shift
done

[ "$CONFIRM" = "RESET" ] || {
	echo "refusing: --confirm RESET required" >&2
	exit 1
}

log() { logger -t knots-factory-reset "$*"; echo "factory-reset: $*" >&2; }

# shellcheck disable=SC1091
. /usr/libexec/knots/step-log.sh 2>/dev/null || true
if ! command -v knots_step >/dev/null 2>&1; then
	knots_step() { shift; echo "STEP $*" >&2; }
fi
# shellcheck disable=SC1091
. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true
knots_step knots-factory-reset "begin confirm=RESET reboot=$REBOOT"
if command -v progress_steps_begin >/dev/null 2>&1; then
	progress_steps_begin reset
fi

# Arm reset UI markers if not already (Settings / CLI / button)
# shellcheck disable=SC1091
. /usr/libexec/knots/factory-reset-ui.sh 2>/dev/null || true
if command -v factory_reset_ui_arm >/dev/null 2>&1; then
	factory_reset_ui_is_active || factory_reset_ui_arm cli
fi

# Stop node UI services briefly; leave datadir alone
if command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set reset stop_node
fi
knots_step knots-factory-reset "bitcoind stop begin"
if [ -f /usr/libexec/knots/bitcoind-ctl.sh ]; then
	# shellcheck disable=SC1091
	. /usr/libexec/knots/bitcoind-ctl.sh
	if command -v bitcoind_ctl_stop >/dev/null 2>&1; then
		bitcoind_ctl_stop || true
	fi
fi
knots_step knots-factory-reset "bitcoind stop done"
if command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set reset stop_lxc
fi
knots_step knots-factory-reset "knots-start.sh stop begin"
[ -x /usr/libexec/knots/knots-start.sh ] && /usr/libexec/knots/knots-start.sh stop || true
knots_step knots-factory-reset "knots-start.sh stop done"
if command -v progress_steps_set >/dev/null 2>&1; then
	progress_steps_set reset reset_settings
fi

# Re-apply appliance UCI seeds (same content as uci-defaults 90/91/92).
# M12b — one failing seed must not abort the reset before reboot: that would
# leave the device half-reset with a live reset page. Warn and continue.
if [ -x /usr/libexec/knots/factory/apply-network.sh ]; then
	knots_step knots-factory-reset "apply-network begin"
	/usr/libexec/knots/factory/apply-network.sh || \
		log "WARN: apply-network.sh failed — continuing reset"
	knots_step knots-factory-reset "apply-network done"
fi
if [ -x /usr/libexec/knots/factory/apply-firewall.sh ]; then
	knots_step knots-factory-reset "apply-firewall begin"
	/usr/libexec/knots/factory/apply-firewall.sh || \
		log "WARN: apply-firewall.sh failed — continuing reset"
	knots_step knots-factory-reset "apply-firewall done"
fi
if [ -x /usr/libexec/knots/factory/apply-password.sh ]; then
	knots_step knots-factory-reset "apply-password begin"
	/usr/libexec/knots/factory/apply-password.sh || \
		log "WARN: apply-password.sh failed — continuing reset"
	knots_step knots-factory-reset "apply-password done"
fi

# C7 (review 2026-10-10) — owner-specific state the seeds above do not touch.
# A returned / resold unit must not keep the previous owner's ISP login, SSH
# access, region or language, nor a half-finished LAN cutover.
knots_step knots-factory-reset "owner state reset begin"
# In-flight Setup LAN cutover (setup_schedule_cutover, argv0 knots-cutover):
# it would re-add the old LAN alias / hosts line after this reset.
pkill -f knots-cutover 2>/dev/null || true
# WAN back to DHCP; drop PPPoE credentials
uci -q set network.wan=interface
uci -q set network.wan.proto='dhcp'
uci -q delete network.wan.username 2>/dev/null || true
uci -q delete network.wan.password 2>/dev/null || true
uci -q delete network.wan.service 2>/dev/null || true
uci -q commit network
# Region: apply-network.sh resets timezone (POSIX TZ); zonename + localtime too
uci -q set system.@system[0].zonename='UTC'
uci -q commit system
if [ -f /usr/share/zoneinfo/Etc/UTC ]; then
	ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime 2>/dev/null || true
else
	rm -f /etc/localtime 2>/dev/null || true
fi
# UI language (Knots + LuCI) back to automatic / English default
rm -f /etc/knots/ui-lang /www/knots/ui-lang 2>/dev/null || true
uci -q set luci.main.lang='auto' && uci -q commit luci
# SSH keys installed by the previous owner
rm -f /etc/dropbear/authorized_keys 2>/dev/null || true
# P3 / D3 — new name-constrained local CA + leaf for the next owner. The old
# owner's devices trusted the previous CA; the IUE Security step installs the
# new one. (A factory reset is one of the two moments the CA may change —
# the other is Settings "Renew certificate"; never during an upgrade.)
if [ -x /usr/libexec/knots/node-ui-tls.sh ]; then
	/usr/libexec/knots/node-ui-tls.sh node-router --rotate-ca >/dev/null 2>&1 || \
		log "WARN: CA rotation failed — previous CA kept"
fi
knots_step knots-factory-reset "owner state reset done"

# Re-apply UI ports (LuCI 8080/8443, Knots 80/443) if helper present
[ -x /usr/libexec/knots/ui-ports.sh ] && /usr/libexec/knots/ui-ports.sh || true

# N3 baseline Wi-Fi: a custom SSID from Setup must NOT survive factory reset.
# Removing the done marker makes wifi-default-enable re-apply rnode + the
# per-device label secret (P1; unlabelled units: Wi-Fi off) at next boot (H3 protects custom SSIDs across NORMAL
# reboots; a factory reset is the deliberate exception).
rm -f /etc/knots/wifi-default-done 2>/dev/null || true
# Region country is re-collected by the next IUE locale step (R7/U19)
rm -f /etc/knots/wifi-country 2>/dev/null || true

# U17 — clear Setup markers so retail IUE runs again after reboot.
# M12b — a missing/unsourceable setup-lib.sh must not silently "succeed"
# (IUE gate would stay closed) nor abort the reset under set -e.
if [ -f /usr/libexec/knots/setup-lib.sh ]; then
	# shellcheck disable=SC1091
	. /usr/libexec/knots/setup-lib.sh 2>/dev/null || true
	if command -v setup_clear_markers >/dev/null 2>&1; then
		setup_clear_markers || true
		log "Setup markers cleared (IUE required)"
	else
		log "WARN: setup_clear_markers unavailable — Setup markers NOT cleared"
	fi
	# P1: the default AP key is the per-device label secret (or no AP on an
	# unlabelled unit); wifi-default-enable.sh writes wifi.key itself.
	rm -f /etc/knots/wifi.key 2>/dev/null || true
	# C7 — without a reboot nothing re-runs wifi-default-enable, so the
	# custom SSID/key stayed live while wifi.key already said factory.
	if [ "$REBOOT" -eq 0 ] && [ -x /usr/libexec/knots/wifi-default-enable.sh ]; then
		/usr/libexec/knots/wifi-default-enable.sh || \
			log "WARN: wifi-default-enable.sh failed — Wi-Fi baseline applies at next boot"
	fi
else
	log "WARN: setup-lib.sh missing — Setup markers NOT cleared (IUE may not re-gate)"
fi

knots_step knots-factory-reset "network reload begin (LAN may drop here)"
/etc/init.d/network reload 2>/dev/null || true
knots_step knots-factory-reset "network reload done"
knots_step knots-factory-reset "firewall restart begin"
/etc/init.d/firewall restart 2>/dev/null || true
knots_step knots-factory-reset "firewall restart done"
knots_step knots-factory-reset "knots-node-ui restart begin"
[ -x /etc/init.d/knots-node-ui ] && /etc/init.d/knots-node-ui restart || true
knots_step knots-factory-reset "knots-node-ui restart done"

# U18 — leave bitcoind (Knots or Core) stopped until after reboot.
# Do not start here: start-then-reboot races a clean flush. /sbin/reboot also
# runs pre-reboot-stop.sh (idempotent if already stopped).
if [ "$REBOOT" -eq 0 ]; then
	[ -x /usr/libexec/knots/knots-start.sh ] && /usr/libexec/knots/knots-start.sh start || true
fi

log "system baseline re-applied (M.2 untouched; Setup gate armed)"
echo "factory-reset complete"
knots_step knots-factory-reset "complete reboot=$REBOOT"

if [ "$REBOOT" -eq 1 ]; then
	log "rebooting (node already stopped)"
	sync
	if command -v progress_steps_set >/dev/null 2>&1; then
		progress_steps_set reset restarting
	fi
	# Explicit stop again before reboot wrapper (belt-and-suspenders)
	knots_step knots-factory-reset "pre-reboot-stop begin"
	[ -x /usr/libexec/knots/pre-reboot-stop.sh ] && /usr/libexec/knots/pre-reboot-stop.sh || true
	knots_step knots-factory-reset "pre-reboot-stop done — calling reboot"
	reboot
fi
exit 0
