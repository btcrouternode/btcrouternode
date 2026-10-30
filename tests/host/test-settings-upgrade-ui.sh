#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UPG-UI — Firmware upgrade wait page reuses factory-reset UX (U13 / NF9)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="$ROOT/files/usr/libexec/knots/settings-api.sh"
JS="$ROOT/files/www/knots/settings.js"
UPG_HTML="$ROOT/files/www/knots/upgrade.html"
UPG_JS="$ROOT/files/www/knots/upgrade.js"
PW="$ROOT/files/www/knots/progress-wait.js"
UI="$ROOT/files/usr/libexec/knots/upgrade-ui.sh"
NGX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"

grep -q 'upgrade)' "$API" || { echo "FAIL: settings-api missing upgrade"; exit 1; }
grep -q 'upgrade_ui_arm' "$API" || { echo "FAIL: upgrade must arm UI"; exit 1; }
grep -q 'upgrade_live' "$API" || { echo "FAIL: status missing upgrade_live"; exit 1; }
grep -q 'upgrade_url' "$API" || { echo "FAIL: upgrade response missing upgrade_url"; exit 1; }

[ -f "$UI" ] || { echo "FAIL: missing upgrade-ui.sh"; exit 1; }
grep -q 'upgrade_ui_arm' "$UI" || { echo "FAIL: upgrade-ui.sh missing arm"; exit 1; }
grep -q '/tmp/knots/upgrade.active' "$UI" || {
	echo "FAIL: upgrade-ui must use /tmp/knots/upgrade.active"; exit 1
}
grep -q 'UPG_UI_ACTIVE=/tmp/knots/upgrade.active' "$UI" || {
	echo "FAIL: upgrade-ui must use UPG_UI_ACTIVE (F201; do not share ACTIVE=)"; exit 1
}
if grep -E '^[[:space:]]*ACTIVE=' "$UI"; then
	echo "FAIL: upgrade-ui.sh must not set a generic ACTIVE="; exit 1
fi

[ -f "$PW" ] || { echo "FAIL: missing progress-wait.js"; exit 1; }
grep -q 'KnotsProgressWait' "$PW" || { echo "FAIL: progress-wait missing KnotsProgressWait"; exit 1; }

[ -f "$UPG_HTML" ] || { echo "FAIL: missing upgrade.html"; exit 1; }
[ -f "$UPG_JS" ] || { echo "FAIL: missing upgrade.js"; exit 1; }
grep -q 'Firmware Update in Progress' "$UPG_HTML" || {
	echo "FAIL: upgrade.html missing Firmware Update in Progress"; exit 1
}
grep -q 'Do NOT Power Cycle' "$UPG_HTML" || {
	echo "FAIL: upgrade.html missing power-cycle warning"; exit 1
}
grep -q 'progress-wait.js' "$UPG_HTML" || {
	echo "FAIL: upgrade.html must load progress-wait.js"; exit 1
}
grep -q 'KnotsProgressWait' "$UPG_JS" || {
	echo "FAIL: upgrade.js must use KnotsProgressWait"; exit 1
}
grep -q 'goUpgradePage' "$JS" || { echo "FAIL: settings.js must open upgrade page"; exit 1; }
grep -q '/upgrade.html' "$JS" || { echo "FAIL: settings.js must navigate to /upgrade.html"; exit 1; }
grep -q 'namedPage' "$JS" || { echo "FAIL: settings.js must open upgrade via rnode.local"; exit 1; }
grep -q 'rnode.local' "$UPG_JS" || { echo "FAIL: upgrade.js must use rnode.local"; exit 1; }
grep -q 'keep_config' "$API" || { echo "FAIL: API must accept keep_config"; exit 1; }
grep -q 'upgrade-apply.sh' "$API" || { echo "FAIL: settings-api must spawn upgrade-apply.sh"; exit 1; }
[ -f "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" ] || {
	echo "FAIL: missing upgrade-apply.sh"; exit 1
}
grep -q 'sysupgrade' "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" || {
	echo "FAIL: upgrade-apply.sh must run sysupgrade"; exit 1
}
grep -q 'upgrade_resume' "$ROOT/files/usr/libexec/knots/setup-api.sh" || {
	echo "FAIL: setup-api must expose upgrade_resume (F125)"; exit 1
}
grep -q 'upgrade_resume' "$UPG_JS" || {
	echo "FAIL: upgrade.js must retry stalled upgrade"; exit 1
}
grep -q 'upgradeKeepToggle' "$ROOT/files/www/knots/settings.html" || {
	echo "FAIL: settings.html missing keep/reset slider"; exit 1
}
grep -q 'upgradeKeepConfig' "$JS" || {
	echo "FAIL: settings.js missing upgradeKeepConfig helper"; exit 1
}
grep -q 'keepConfig' "$UPG_JS" || {
	echo "FAIL: upgrade.js must honour keep vs reset finish path"; exit 1
}
[ -f "$ROOT/files/lib/upgrade/keep.d/knots" ] || {
	echo "FAIL: missing keep.d/knots so keep_config preserves /etc/knots"; exit 1
}
grep -q '/etc/knots/' "$ROOT/files/lib/upgrade/keep.d/knots" || {
	echo "FAIL: keep.d/knots must list /etc/knots/"; exit 1
}
grep -q 'var(--btc' "$ROOT/files/www/knots/app.css" || {
	echo "FAIL: keep slider must use theme orange --btc"; exit 1
}

grep -q 'progress-wait.js' "$ROOT/files/www/knots/reset.html" || {
	echo "FAIL: reset.html must also reuse progress-wait.js"; exit 1
}
grep -q 'upgrade_live' "$ROOT/files/usr/libexec/knots/setup-api.sh" || {
	echo "FAIL: setup-api must expose upgrade_live"; exit 1
}
grep -q 'upgrade.active' "$NGX" || {
	echo "FAIL: nginx must redirect when upgrade armed"; exit 1
}
grep -q 'upgrade_live' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: shell.js poller must jump to upgrade page"; exit 1
}
grep -q 'onUpgradePage' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: shell.js must treat upgrade page like reset"; exit 1
}
grep -q 'Firmware Upgrade Finalising Router Rebooting' "$UPG_JS" || {
	echo "FAIL: upgrade.js must use firmware reboot title"; exit 1
}
grep -q 'upgrade-page' "$UPG_HTML" || {
	echo "FAIL: upgrade.html must use upgrade-page body class"; exit 1
}
grep -q 'factory-reset-progress' "$UPG_HTML" && {
	echo "FAIL: upgrade.html must not reuse factory-reset-progress class"; exit 1
}
grep -q 'rebootTitle' "$PW" || {
	echo "FAIL: progress-wait.js must support rebootTitle"; exit 1
}
grep -q 'leaveIdle' "$UPG_JS" || {
	echo "FAIL: upgrade.js must leaveIdle when upgrade not armed"; exit 1
}
grep -q 'upgrade_clear' "$ROOT/files/usr/libexec/knots/setup-api.sh" || {
	echo "FAIL: setup-api must expose upgrade_clear loop break"; exit 1
}
# H4: Settings keeps no cross-origin sessionStorage resume (the https copy
# was never readable by the http wait page and only went stale).
grep -q 'sessionStorage.setItem' "$JS" && {
	echo "FAIL: settings.js must not write wait hand-off state to sessionStorage (H4)"; exit 1
}
grep -q 'finishMsAfterDown' "$PW" || {
	echo "FAIL: progress-wait.js must support finishMsAfterDown for reset upgrade"; exit 1
}
grep -q 'showLinkDown' "$PW" || {
	echo "FAIL: progress-wait.js must keep wait UI when LAN drops (F150)"; exit 1
}
grep -q 'LAN_DROP' "$PW" || {
	echo "FAIL: progress-wait.js must explain Ethernet/Wi-Fi disconnect"; exit 1
}
grep -q 'finish({})' "$PW" && {
	echo "FAIL: progress-wait must not finish({}) while the origin is down"; exit 1
} || true
test -f "$ROOT/files/www/knots/wait-sw.js" || {
	echo "FAIL: missing wait-sw.js"; exit 1
}
! grep -q 'serviceWorker.register' "$UPG_HTML" || {
	echo "FAIL: upgrade.html must not register the retired wait-sw.js (D4)"; exit 1
}
grep -q 'Ubuntu turns LAN' "$UPG_HTML" || {
	echo "FAIL: upgrade.html must explain LAN drop on the PC"; exit 1
}
grep -q 'maybeLanDropPopup' "$JS" || {
	echo "FAIL: settings.js must popup Ubuntu/Linux Ethernet drop before upgrade"; exit 1
}
grep -q 'isLinuxDesktop' "$ROOT/files/www/knots/tls-os.js" || {
	echo "FAIL: tls-os.js must detect Linux/Ubuntu for LAN-drop popup"; exit 1
}
grep -q 'knots_step' "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" || {
	echo "FAIL: upgrade-apply.sh must emit timestamped STEP logs"; exit 1
}
grep -q 'step-log.sh' "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" || {
	echo "FAIL: upgrade-apply.sh must reuse step-log.sh"; exit 1
}
grep -q 'waitStepList' "$UPG_HTML" || {
	echo "FAIL: upgrade.html must list per-step progress bars"; exit 1
}
grep -q 'upgradeKeep' "$UPG_JS" || {
	echo "FAIL: upgrade.js must pick upgrade vs upgradeKeep stepKind"; exit 1
}
grep -q 'Updating Router' "$PW" || {
	echo "FAIL: progress-wait.js must include Updating Router step"; exit 1
}
python3 - "$PW" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

def ids(kind):
    m = re.search(r"(?s)" + kind + r":\s*\[(.*?)\n\s*\]", text)
    if not m:
        print("FAIL: missing STEP_SETS." + kind)
        sys.exit(1)
    return re.findall(r'id:\s*"([^"]+)"', m.group(1))

keep = ids("upgradeKeep")
upg = ids("upgrade")
rst = ids("reset")
if keep != ["stop_node", "stop_lxc", "updating", "init"]:
    print("FAIL: upgradeKeep must be four in-place steps, got", keep)
    sys.exit(1)
if upg != ["stop_node", "stop_lxc", "updating", "init"]:
    print("FAIL: reset-settings upgrade must be four steps, got", upg)
    sys.exit(1)
if rst != [
    "stop_node", "stop_lxc", "reset_settings",
    "restarting", "starting", "init",
]:
    print("FAIL: factory reset must have six step bars, got", rst)
    sys.exit(1)
if "Opening Node Status" not in text or "Opening Setup" not in text:
    print("FAIL: keep-settings ends at Node Status; reset/upgrade-n at Setup")
    sys.exit(1)

def hold(kind, step):
    m = re.search(r"(?s)" + kind + r":\s*\[(.*?)\n\s*\]", text)
    if not m:
        print("FAIL: missing STEP_SETS." + kind)
        sys.exit(1)
    hm = re.search(
        r'id:\s*"' + re.escape(step) + r'".*?holdMs:\s*(\d+)',
        m.group(1),
        re.S,
    )
    if not hm:
        print("FAIL: missing holdMs for", kind, step)
        sys.exit(1)
    return int(hm.group(1))

# F175 — serial .61 -n: br-lan forwarding 414s; keep-config LAN 51s; lxc-stop 60s
if hold("upgrade", "updating") != 450000:
    print("FAIL: reset-settings Updating Router must be 450s (first-boot LAN)")
    sys.exit(1)
if hold("upgradeKeep", "updating") != 90000:
    print("FAIL: keep-settings Updating Router must be 90s (LAN ~51s + flash)")
    sys.exit(1)
if hold("reset", "starting") != 420000:
    print("FAIL: factory reset Starting Network Services must be 420s")
    sys.exit(1)
if hold("upgrade", "stop_lxc") != 65000 or hold("reset", "stop_lxc") != 65000:
    print("FAIL: Stopping Knots Services must stay 65s (lxc-stop -t 60)")
    sys.exit(1)
print("step counts ok")
PY
grep -q 'Restarting Router' "$PW" || {
	echo "FAIL: factory reset steps must include Restarting Router"; exit 1
}
grep -q 'Starting Network Services' "$PW" || {
	echo "FAIL: factory reset steps must include Starting Network Services"; exit 1
}
grep -q 'has-step-bars' "$PW" || {
	echo "FAIL: wait page must hide the overall bar when step bars render"; exit 1
}
grep -q 'fillHigh' "$PW" || {
	echo "FAIL: step fill must be monotonic (no rewind to 0%)"; exit 1
}
grep -q 'root.children.length && activeStepper' "$PW" || {
	echo "FAIL: must not rebuild the step list (resets bars to 0)"; exit 1
}
grep -q 'startedAt > 15000' "$UPG_JS" && {
	echo "FAIL: must not finish keep-settings after 15s (bounces to Settings)"; exit 1
}
awk '/listen 80/,/^}/' "$NGX" | grep -c 'location /api/settings' >/dev/null || {
	echo "FAIL: :80 must proxy /api/settings for HTTP wait-page probes"; exit 1
}
grep -q 'holdMs' "$PW" || {
	echo "FAIL: progress-wait.js must time-walk steps while LAN is down"; exit 1
}
grep -q 'n < index' "$PW" || {
	echo "FAIL: progress-wait must not rewind a step when API repeats stop_node"; exit 1
}
grep -q 'apiStale' "$PW" || {
	echo "FAIL: progress-wait must clock-walk when API is stuck on one step"; exit 1
}
grep -q 'stallMs' "$UPG_JS" || {
	echo "FAIL: upgrade.js must not retry apply at 3 min during keep-config"; exit 1
}
grep -q 'applyStep("init")' "$PW" && {
	echo "FAIL: LAN drop must not jump to the last step (F156)"; exit 1
}
grep -q 'progress_steps_set upgrade updating' "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" || {
	echo "FAIL: upgrade-apply must set Updating Router step"; exit 1
}
grep -q 'upgrade-last.log' "$ROOT/files/usr/libexec/knots/step-log.sh" || {
	echo "FAIL: STEP lines must persist in /etc/knots/upgrade-last.log"; exit 1
}
grep -q 'progress_steps_set upgrade restarting' "$ROOT/files/usr/libexec/knots/upgrade-apply.sh" && {
	echo "FAIL: upgrade-apply must stay on Updating Router through sysupgrade"; exit 1
}
grep -q 'api/setup' "$UPG_JS" || {
	echo "FAIL: upgrade.js must probe setup API on reset-settings path"; exit 1
}
grep -q 'redirectWhenReady' "$UPG_JS" || {
	echo "FAIL: upgrade.js must wait for router before Setup redirect"; exit 1
}
grep -q 'handoffWhenReady' "$UPG_JS" || {
	echo "FAIL: upgrade.js must confirm dest works before navigate"; exit 1
}
grep -q 'handoffWhenReady' "$PW" || {
	echo "FAIL: progress-wait.js must expose handoffWhenReady"; exit 1
}
grep -q 'watchOnline' "$PW" || {
	echo "FAIL: progress-wait.js must expose watchOnline"; exit 1
}
grep -q '/api/alive' "$PW" || {
	echo "FAIL: progress-wait.js must poll /api/alive on rnode.local"; exit 1
}
grep -q 'location = /api/alive' "$NGX" || {
	echo "FAIL: nginx :80 must serve /api/alive for the wait-page monitor"; exit 1
}
awk '/location = \/api\/alive/,/^	}/' "$NGX" | grep -c 'setup-complete' >/dev/null && {
	echo "FAIL: /api/alive must not redirect when Setup is complete"; exit 1
}
grep -q 'complete === false' "$UPG_JS" || {
	echo "FAIL: upgrade.js must finish reset upgrade when Setup required"; exit 1
}
grep -q 'setupStartUrl' "$UPG_JS" || {
	echo "FAIL: upgrade.js must open IUE at Welcome (setupStartUrl / step=0)"; exit 1
}
grep -q 'KnotsIue.destUrl' "$UPG_JS" && grep -q 'step=0' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: upgrade.js must open Setup via the shared destUrl (step=0)"; exit 1
}
grep -q 'setupStartUrl' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: shell.js must expose KnotsIue.setupStartUrl"; exit 1
}

grep -q 'upgrade_keep_config' "$ROOT/files/usr/libexec/knots/setup-api.sh" || {
	echo "FAIL: setup-api must expose upgrade_keep_config"; exit 1
}
grep -q 'upgrade_keep_config' "$UPG_JS" || {
	echo "FAIL: upgrade.js must read upgrade_keep_config"; exit 1
}
grep -q 'resolveKeepConfig' "$UPG_JS" || {
	echo "FAIL: upgrade.js must resolve keep vs reset reliably"; exit 1
}
grep -q 'keep_config' "$UI" || {
	echo "FAIL: upgrade-ui must persist keep_config in active marker"; exit 1
}
grep -q 'UPG_SEC=300' "$API" || {
	echo "FAIL: keep-settings expected_seconds must be 300s"; exit 1
}
grep -q 'UPG_SEC=630' "$API" || {
	echo "FAIL: reset-settings expected_seconds must be 630s"; exit 1
}

echo "PASS T-UPG-UI"
