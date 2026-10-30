#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-RST-UI — Settings factory reset UI + API surface (N3 / U17 / U15)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="$ROOT/files/usr/libexec/knots/settings-api.sh"
HTML="$ROOT/files/www/knots/settings.html"
JS="$ROOT/files/www/knots/settings.js"

grep -q 'factory_reset)' "$API" || { echo "FAIL: settings-api missing factory_reset"; exit 1; }
grep -q 'factory_reset_confirm' "$API" || { echo "FAIL: status missing factory_reset_confirm"; exit 1; }
grep -q 'expected_seconds' "$API" || { echo "FAIL: API missing expected_seconds"; exit 1; }
# L5: the value lives once in factory-reset-ui.sh (FR_EXPECTED_SECONDS=650).
grep -q '^FR_EXPECTED_SECONDS=650$' "$ROOT/files/usr/libexec/knots/factory-reset-ui.sh" && \
	grep -q '"expected_seconds":%s,"setup_url"' "$API" || {
	echo "FAIL: factory reset expected_seconds must be 650s (F175)"; exit 1
}
grep -q 'factory-reset --confirm RESET' "$API" || {
	echo "FAIL: API must invoke factory-reset"; exit 1
}
grep -q 'btnFactoryReset' "$HTML" || { echo "FAIL: settings.html missing button"; exit 1; }
grep -q 'goFactoryResetPage' "$JS" || { echo "FAIL: settings.js must open reset page"; exit 1; }
grep -q '/reset.html' "$JS" || { echo "FAIL: settings.js must navigate to /reset.html"; exit 1; }
RESET_HTML="$ROOT/files/www/knots/reset.html"
RESET_JS="$ROOT/files/www/knots/reset.js"
[ -f "$RESET_HTML" ] || { echo "FAIL: missing reset.html"; exit 1; }
[ -f "$RESET_JS" ] || { echo "FAIL: missing reset.js"; exit 1; }
grep -q 'Factory Reset in Progress' "$RESET_HTML" || {
	echo "FAIL: reset.html missing Factory Reset in Progress"; exit 1
}
grep -q 'Do NOT Power Cycle' "$RESET_HTML" || {
	echo "FAIL: reset.html missing power-cycle warning"; exit 1
}
grep -q 'factory_reset_ui_arm' "$ROOT/files/etc/rc.button/reset" || {
	echo "FAIL: rc.button must arm UI before factory-reset"; exit 1
}
grep -q 'factory_reset_ui_arm()' "$ROOT/files/usr/libexec/knots/factory-reset-ui.sh" || {
	echo "FAIL: factory-reset-ui.sh must define factory_reset_ui_arm"; exit 1
}
[ -f "$ROOT/files/usr/libexec/knots/factory-reset-ui.sh" ] || {
	echo "FAIL: missing factory-reset-ui.sh"; exit 1
}
grep -q 'watchFactoryReset' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: shell.js must watch factory_reset_active"; exit 1
}
grep -q 'factory_reset_active' "$ROOT/files/usr/libexec/knots/setup-api.sh" || {
	echo "FAIL: setup-api must expose factory_reset_active"; exit 1
}
# H7: shell.js holds the one wait-page poller (reset-watch.js retired).
grep -q 'shell.js' "$ROOT/files/www/knots/index.html" && \
	grep -q 'factory_reset_live' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: index.html must load shell.js, whose poller jumps to the reset page"; exit 1
}
[ ! -f "$ROOT/files/www/knots/reset-watch.js" ] || {
	echo "FAIL: reset-watch.js duplicated the shell.js poller (H7)"; exit 1
}
grep -q 'factory-reset.active' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" || {
	echo "FAIL: nginx must redirect when reset armed"; exit 1
}
grep -q 'leaveIdle' "$RESET_JS" || {
	echo "FAIL: reset.js must leaveIdle when reset not armed (no hang loop)"; exit 1
}
grep -q 'factory_reset_live' "$RESET_JS" || {
	echo "FAIL: reset.js must key off factory_reset_live"; exit 1
}
! grep -q 'bounceHost' "$RESET_JS" || {
	echo "FAIL: reset.js must not bounce off the wait page during reboot"; exit 1
}
grep -q 'Ubuntu turns LAN' "$RESET_HTML" || {
	echo "FAIL: reset.html must explain LAN drop on the PC"; exit 1
}
grep -q 'maybeLanDropPopup' "$JS" || {
	echo "FAIL: settings.js must popup Ubuntu/Linux Ethernet drop before reset"; exit 1
}
grep -q 'tls-os.js' "$HTML" || {
	echo "FAIL: settings.html must load tls-os.js for Ubuntu detect"; exit 1
}
grep -q 'waitStepList' "$RESET_HTML" || {
	echo "FAIL: reset.html must list per-step progress bars"; exit 1
}
grep -q 'stepKind: "reset"' "$RESET_JS" || {
	echo "FAIL: reset.js must use reset stepKind"; exit 1
}
grep -q 'Stopping BTC Node' "$ROOT/files/www/knots/progress-wait.js" || {
	echo "FAIL: progress-wait.js must use Stopping BTC Node"; exit 1
}
grep -q 'Restarting Router' "$ROOT/files/www/knots/progress-wait.js" || {
	echo "FAIL: reset steps must include Restarting Router"; exit 1
}
python3 - "$ROOT/files/www/knots/progress-wait.js" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"(?s)reset:\s*\[(.*?)\n\s*\]", text)
ids = re.findall(r'id:\s*"([^"]+)"', m.group(1) if m else "")
want = ["stop_node", "stop_lxc", "reset_settings", "restarting", "starting", "init"]
if ids != want:
    print("FAIL: factory reset must have six progress bars, got", ids)
    sys.exit(1)
print("reset step count ok")
PY
grep -q 'progress_step' "$API" || {
	echo "FAIL: settings-api status must expose progress_step"; exit 1
}
grep -q 'openWhenReady' "$RESET_JS" || {
	echo "FAIL: reset.js must poll rnode.local before opening Setup"; exit 1
}
grep -q 'handoffWhenReady' "$RESET_JS" || {
	echo "FAIL: reset.js must confirm Setup works before navigate"; exit 1
}
grep -q 'setupStartUrl' "$RESET_JS" || {
	echo "FAIL: reset.js must open IUE at Welcome (setupStartUrl / step=0)"; exit 1
}
grep -q 'step=0' "$ROOT/files/www/knots/shell.js" && grep -q 'KnotsIue.destUrl' "$RESET_JS" || {
	echo "FAIL: reset.js must open Setup via the shared destUrl (step=0)"; exit 1
}

# F201 — Settings sources factory-reset-ui.sh then upgrade-ui.sh. A shared
# ACTIVE= made factory_reset_ui_arm write /tmp/knots/upgrade.active (nginx
# then served Firmware Update). Helpers must use distinct names.
FR_UI="$ROOT/files/usr/libexec/knots/factory-reset-ui.sh"
UPG_UI="$ROOT/files/usr/libexec/knots/upgrade-ui.sh"
if grep -E '^[[:space:]]*ACTIVE=' "$FR_UI" "$UPG_UI"; then
	echo "FAIL: factory-reset-ui.sh / upgrade-ui.sh must not share ACTIVE="; exit 1
fi
grep -q 'FR_UI_ACTIVE=/tmp/knots/factory-reset.active' "$FR_UI" || {
	echo "FAIL: factory-reset-ui.sh must use FR_UI_ACTIVE"; exit 1
}
grep -q 'UPG_UI_ACTIVE=/tmp/knots/upgrade.active' "$UPG_UI" || {
	echo "FAIL: upgrade-ui.sh must use UPG_UI_ACTIVE"; exit 1
}

# F201 — uhttpd :21444 kills a plain `&` CGI child (same class as F125).
# L1: reboot/shutdown/factory_reset detach via cgi_node_worker → cgi_setsid.
awk '/^cgi_setsid\(\)/,/^}/' "$ROOT/files/usr/libexec/knots/cgi-lib.sh" | grep -c 'setsid sh -c' >/dev/null || {
	echo "FAIL: cgi_setsid must setsid-detach (F201)"; exit 1
}
awk '/^cgi_node_worker\(\)/,/^}/' "$ROOT/files/usr/libexec/knots/cgi-lib.sh" | grep -c 'cgi_setsid' >/dev/null || {
	echo "FAIL: cgi_node_worker must detach via cgi_setsid (F201)"; exit 1
}
fr_block=$(sed -n '/factory_reset)/,/^[[:space:]]*upgrade)/p' "$API")
echo "$fr_block" | grep -qE 'setsid|cgi_node_worker' || {
	echo "FAIL: factory_reset must setsid-detach the worker (F201/F125)"; exit 1
}
echo "$fr_block" | grep -q 'factory-reset --confirm RESET' || {
	echo "FAIL: factory_reset setsid worker must still invoke factory-reset"; exit 1
}
reboot_block=$(sed -n '/^	reboot)/,/^	shutdown)/p' "$API")
echo "$reboot_block" | grep -qE 'setsid|cgi_node_worker' || {
	echo "FAIL: reboot must setsid-detach (F201)"; exit 1
}
shutdown_block=$(sed -n '/^	shutdown)/,/^	factory_reset)/p' "$API")
echo "$shutdown_block" | grep -qE 'setsid|cgi_node_worker' || {
	echo "FAIL: shutdown must setsid-detach (F201)"; exit 1
}

# Source both helpers in settings-api order with rewritten paths; arm reset
# must not create upgrade.active, and a later upgrade arm must not clobber reset.
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/libexec"
sed -e "s|/usr/libexec/knots|$SB/libexec|g" \
	-e "s|/tmp/knots|$SB/tmpknots|g" \
	-e "s|/etc/knots|$SB/etcknots|g" \
	"$FR_UI" >"$SB/libexec/factory-reset-ui.sh"
sed -e "s|/usr/libexec/knots|$SB/libexec|g" \
	-e "s|/tmp/knots|$SB/tmpknots|g" \
	-e "s|/etc/knots|$SB/etcknots|g" \
	"$UPG_UI" >"$SB/libexec/upgrade-ui.sh"
# shellcheck disable=SC1091
. "$SB/libexec/factory-reset-ui.sh"
# shellcheck disable=SC1091
. "$SB/libexec/upgrade-ui.sh"
factory_reset_ui_arm settings 650
[ -f "$SB/tmpknots/factory-reset.active" ] || {
	echo "FAIL: factory_reset_ui_arm must write factory-reset.active"; exit 1
}
[ -f "$SB/etcknots/factory-reset-pending" ] || {
	echo "FAIL: factory_reset_ui_arm must write factory-reset-pending"; exit 1
}
[ ! -e "$SB/tmpknots/upgrade.active" ] || {
	echo "FAIL: factory_reset_ui_arm must not write upgrade.active after both sourced"; exit 1
}
grep -q '"reason":"settings"' "$SB/tmpknots/factory-reset.active" || {
	echo "FAIL: reset marker reason=settings"; exit 1
}
if grep -q keep_config "$SB/tmpknots/factory-reset.active"; then
	echo "FAIL: reset marker must not look like upgrade JSON"; exit 1
fi
factory_reset_ui_is_live || {
	echo "FAIL: factory_reset_ui_is_live after arm"; exit 1
}
upgrade_ui_is_live && {
	echo "FAIL: upgrade_ui_is_live must be false after reset arm"; exit 1
}
upgrade_ui_arm settings 180 1
[ -f "$SB/tmpknots/upgrade.active" ] || {
	echo "FAIL: upgrade_ui_arm must write upgrade.active"; exit 1
}
[ -f "$SB/tmpknots/factory-reset.active" ] || {
	echo "FAIL: upgrade_ui_arm must not remove factory-reset.active"; exit 1
}
grep -q '"keep_config":true' "$SB/tmpknots/upgrade.active" || {
	echo "FAIL: upgrade marker must include keep_config"; exit 1
}
factory_reset_ui_is_live || {
	echo "FAIL: factory_reset_ui_is_live must stay true after upgrade arm"; exit 1
}
upgrade_ui_is_live || {
	echo "FAIL: upgrade_ui_is_live after upgrade arm"; exit 1
}

echo "PASS T-RST-UI"
