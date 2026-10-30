#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-RST-1 — factory-reset confirm gates (host; no M.2 wipe — S7/N3)
# T-RST-2 — Setup markers cleared + WPS/KEY_RESTART button → appliance reset (U17)
# M17 — this test executes the REAL factory-reset.sh on the dev host; stub
# every destructive verb in PATH so a confirm-gate regression can never
# reboot/power-off the machine the suite runs on.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FR="$ROOT/files/usr/libexec/knots/factory-reset.sh"
LIB="$ROOT/files/usr/libexec/knots/setup-lib.sh"
BTN="$ROOT/files/etc/rc.button/reset"
chmod +x "$FR" "$BTN"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Stub dir prepended to PATH: bare destructive verbs become no-ops that log
# their invocation. The script's /etc/init.d/* calls are absolute-path and
# `|| true`-guarded (and absent on a dev host); its apply-*/knots-start
# helpers are `[ -x ... ]`-gated and absent off-device.
STUB="$tmpdir/stub-bin"
CALLS="$tmpdir/stub-calls"
mkdir -p "$STUB"
# pkill: factory-reset stops an in-flight cutover with `pkill -f knots-cutover`
# (C7) — unstubbed it matched processes on the dev host.
for c in reboot poweroff halt; do
	printf '#!/bin/sh\necho "%s" >>"%s"\nexit 0\n' "$c" "$CALLS" >"$STUB/$c"
	chmod +x "$STUB/$c"
done
# Non-destructive on-device verbs the reset is EXPECTED to call (C7: WAN /
# zonename / LuCI language via uci; cutover stop via pkill) — stubbed so they
# never touch the dev host, logged separately so the test can require them.
BENIGN="$tmpdir/stub-benign"
for c in uci pkill; do
	printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$c" "$BENIGN" >"$STUB/$c"
	chmod +x "$STUB/$c"
done
# logger is benign — stub only so runs stay out of the host journal
printf '#!/bin/sh\nexit 0\n' >"$STUB/logger"
chmod +x "$STUB/logger"
SAFE_PATH="$STUB:$PATH"

# --- Confirm gates on the untouched real script ----------------------------
# No confirm token → must refuse
if PATH="$SAFE_PATH" "$FR" 2>"$tmpdir/fr.err"; then
	echo "FAIL: expected refuse"; exit 1
fi
grep -qi 'RESET\|confirm' "$tmpdir/fr.err" || { echo "FAIL"; cat "$tmpdir/fr.err"; exit 1; }

# --wipe-storage must refuse (retired)
if PATH="$SAFE_PATH" "$FR" --confirm RESET --wipe-storage --no-reboot 2>"$tmpdir/fr2.err"; then
	echo "FAIL: --wipe-storage must refuse"; exit 1
fi
grep -qiE 'refusing|retired|wipe' "$tmpdir/fr2.err" || {
	echo "FAIL: expected wipe-retired message"; cat "$tmpdir/fr2.err"; exit 1
}

# --- Full reset path: real script + real libs, base paths sed-sandboxed ----
# (dash aborts on sourcing a missing `.` file, so the shipped libs are copied
# in with the same path rewrite — gate logic above stays on the real file.)
SB="$tmpdir/sb"
LIBEX="$SB/libexec"
mkdir -p "$LIBEX" "$SB/etcknots"
for f in factory-reset.sh factory-reset-ui.sh setup-lib.sh step-log.sh progress-steps.sh; do
	sed -e "s|/usr/libexec/knots|$LIBEX|g" \
		-e "s|/etc/knots|$SB/etcknots|g" \
		-e "s|/tmp/knots|$SB/tmpknots|g" \
		-e "s|/etc/localtime|$SB/localtime|g" \
		-e "s|/usr/share/zoneinfo|$SB/zoneinfo|g" \
		-e "s|/etc/dropbear|$SB/dropbear|g" \
		-e "s|/www/knots|$SB/www|g" \
		"$ROOT/files/usr/libexec/knots/$f" >"$LIBEX/$f"
done
chmod +x "$LIBEX/factory-reset.sh"

seed_markers() {
	echo 'old-owner-key' >"$SB/etcknots/wifi.key"
	: >"$SB/etcknots/wifi-default-done"
	: >"$SB/etcknots/setup-complete"
	: >"$SB/etcknots/setup-password-done"
	: >"$SB/etcknots/setup-locale-done"
}

# Positive run: --no-reboot must complete, clear Setup markers via the REAL
# setup-lib.sh helper, arm the reset UI via the REAL factory-reset-ui.sh, and
# never touch a destructive verb.
seed_markers
PATH="$SAFE_PATH" "$LIBEX/factory-reset.sh" --confirm RESET --no-reboot \
	>"$tmpdir/fr3.out" 2>&1 || {
	echo "FAIL: --confirm RESET --no-reboot should complete"; cat "$tmpdir/fr3.out"; exit 1
}
grep -q 'factory-reset complete' "$tmpdir/fr3.out" || {
	echo "FAIL: expected completion message"; cat "$tmpdir/fr3.out"; exit 1
}
for m in setup-complete setup-password-done setup-locale-done; do
	[ ! -e "$SB/etcknots/$m" ] || { echo "FAIL: $m still present after reset"; exit 1; }
done
# P1 (review 2026-10-10): no fleet-wide shared Wi-Fi key. Reset removes the
# old key; wifi-default-enable re-applies the per-device label secret at boot
# (or keeps Wi-Fi off on an unlabelled unit).
[ ! -e "$SB/etcknots/wifi.key" ] || {
	echo "FAIL: factory reset must not leave a Wi-Fi key behind (P1)"; cat "$SB/etcknots/wifi.key"; exit 1
}
[ ! -e "$SB/etcknots/wifi-default-done" ] || {
	echo "FAIL: factory reset must clear wifi-default-done so the label default re-applies"; exit 1
}
[ -f "$SB/tmpknots/factory-reset.active" ] || {
	echo "FAIL: reset UI not armed (real factory_reset_ui_arm)"; exit 1
}
grep -q '^pkill -f knots-cutover' "$BENIGN" 2>/dev/null || {
	echo "FAIL: reset must stop an in-flight LAN cutover (C7)"; exit 1
}
grep -q "^uci -q set network.wan.proto=dhcp" "$BENIGN" 2>/dev/null || {
	echo "FAIL: reset must put WAN back to DHCP (C7)"; cat "$BENIGN"; exit 1
}
[ ! -e "$CALLS" ] || {
	echo "FAIL: --no-reboot run invoked a destructive stub"; cat "$CALLS"; exit 1
}

# Reboot run: proves the PATH stub really intercepts `reboot` — if a gate
# ever regresses, this test still cannot reboot the host.
seed_markers
PATH="$SAFE_PATH" "$LIBEX/factory-reset.sh" --confirm RESET >"$tmpdir/fr4.out" 2>&1 || {
	echo "FAIL: --confirm RESET should complete via stubbed reboot"; cat "$tmpdir/fr4.out"; exit 1
}
grep -qx 'reboot' "$CALLS" || {
	echo "FAIL: reboot path did not reach the stubbed reboot"; cat "$tmpdir/fr4.out"; exit 1
}

# --- Source-level contracts -------------------------------------------------
# Must clear Setup markers (source path) before reboot
grep -q 'setup_clear_markers' "$FR" || {
	echo "FAIL: factory-reset.sh must call setup_clear_markers"; exit 1
}
grep -q 'knots_step' "$FR" || {
	echo "FAIL: factory-reset.sh must emit timestamped STEP logs"; exit 1
}
grep -q 'progress_steps_set' "$FR" || {
	echo "FAIL: factory-reset.sh must publish UI progress steps"; exit 1
}
grep -q 'setup_clear_markers' "$LIB" || {
	echo "FAIL: setup_clear_markers missing from setup-lib.sh"; exit 1
}

# Button: appliance factory-reset, not jffs2reset; document WPS/KEY_RESTART
[ -f "$BTN" ] || { echo "FAIL: missing $BTN"; exit 1; }
grep -q 'factory-reset' "$BTN" || {
	echo "FAIL: rc.button/reset must invoke factory-reset"; exit 1
}
# Refuse stock overlay wipe invocation (comments may mention the name)
if grep -E '^[[:space:]]*jffs2reset|[[:space:]]jffs2reset[[:space:]]' "$BTN"; then
	echo "FAIL: rc.button/reset must not invoke jffs2reset (N3 soft reset)"; exit 1
fi
grep -qiE 'WPS|KEY_RESTART' "$BTN" || {
	echo "FAIL: button handler must document WPS/KEY_RESTART on BPI-R4"; exit 1
}

echo "PASS T-RST-1 / T-RST-2"
