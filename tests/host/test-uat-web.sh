#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UAT-WEB — laptop web UAT runner contracts (no board)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="$ROOT/tests/device/uat-web.py"
WIZ="$ROOT/tests/device/uat_wizard.py"
SH="$ROOT/tests/device/uat-web.sh"
DOC="$ROOT/docs/UAT_WEB.md"

[ -f "$PY" ] || { echo "FAIL: missing uat-web.py"; exit 1; }
[ -f "$WIZ" ] || { echo "FAIL: missing uat_wizard.py"; exit 1; }
[ -f "$SH" ] || { echo "FAIL: missing uat-web.sh"; exit 1; }
[ -f "$DOC" ] || { echo "FAIL: missing docs/UAT_WEB.md"; exit 1; }
chmod +x "$PY" "$SH" "$WIZ"

python3 -m py_compile "$PY" "$WIZ" || { echo "FAIL: uat-web.py / uat_wizard.py syntax"; exit 1; }

grep -q 'No serial' "$PY" || { echo "FAIL: suite must not require serial"; exit 1; }
grep -q 'sysupgrade.itb' "$PY" || { echo "FAIL: suite must use Documents sysupgrade.itb"; exit 1; }
grep -q 'factory_reset' "$PY" || { echo "FAIL: suite must wait through factory reset"; exit 1; }
grep -q 'keep_config' "$PY" || { echo "FAIL: suite must cover keep and reset upgrades"; exit 1; }
grep -q 'btnWelcome' "$WIZ" || { echo "FAIL: IUE must click Welcome Continue"; exit 1; }
grep -q 'btnTlsSkip' "$WIZ" || { echo "FAIL: IUE must keep Skip as the Ethernet fallback"; exit 1; }
grep -q 'after_tls=1' "$WIZ" || { echo "FAIL: IUE must resume after_tls at Choice (F208)"; exit 1; }
grep -q 'ClientGuided' "$WIZ" || { echo "FAIL: Guided must use documented custom SSID ClientGuided"; exit 1; }
grep -q 'lanDhcpStart' "$WIZ" || { echo "FAIL: Guided must set custom LAN DHCP start"; exit 1; }
grep -q 'open_luci_and_return' "$WIZ" || { echo "FAIL: Node UI walk must open LuCI and return"; exit 1; }
grep -q 'btnQuickSubmit' "$WIZ" || { echo "FAIL: Quick Start must click Finish setup"; exit 1; }
grep -q 'btnGuided' "$WIZ" || { echo "FAIL: Guided must click Guided Setup"; exit 1; }
grep -q 'btnDone' "$WIZ" || { echo "FAIL: Guided must click Go to Node Status"; exit 1; }
grep -q 'Playwright' "$DOC" || { echo "FAIL: docs must say IUE runs in a real browser"; exit 1; }
grep -q 'Linux x86_64' "$WIZ" || { echo "FAIL: IUE browser must look like a Linux Chrome user"; exit 1; }
grep -q 'wget' "$WIZ" || { echo "FAIL: IUE must assert the Linux Terminal one-liner"; exit 1; }
grep -q 'iue_guided' "$PY" || { echo "FAIL: suite must drive Guided Setup"; exit 1; }
grep -q 'node_start' "$PY" || { echo "FAIL: suite must exercise Start"; exit 1; }
grep -q 'already_running' "$PY" || { echo "FAIL: suite must assert Start-while-running"; exit 1; }
grep -q 'storage.html' "$PY" || { echo "FAIL: suite must assert no wipe page"; exit 1; }
grep -q 'KNOTS_UAT_SHUTDOWN' "$DOC" || { echo "FAIL: docs must skip shutdown by default"; exit 1; }
! grep -q 'jffs2reset' "$PY" || { echo "FAIL: suite must not call jffs2reset"; exit 1; }
! grep -q '/dev/ttyUSB' "$PY" || { echo "FAIL: suite must not use serial"; exit 1; }

for phase in pages status nav settings node luci ui reboot upgrade_keep factory \
	iue_quick upgrade_reset iue_guided; do
	grep -q "\"$phase\"" "$PY" || { echo "FAIL: missing phase $phase"; exit 1; }
done
grep -q 'maxconnections' "$PY" || { echo "FAIL: Settings must change bitcoin.conf maxconnections"; exit 1; }
grep -q 'security_then_after_tls' "$PY" || { echo "FAIL: IUE must use after_tls resume not only Skip"; exit 1; }
grep -q 'GUIDED_SSID' "$PY" || { echo "FAIL: Guided UAT must pass custom SSID"; exit 1; }
grep -q 'GUIDED_DHCP_START' "$PY" || { echo "FAIL: Guided UAT must pass custom LAN DHCP start"; exit 1; }

grep -q 'Documents/knots-uat' "$DOC" || {
	echo "FAIL: docs must tell the user to run ~/Documents/knots-uat/run"; exit 1
}
grep -q 'last-run.log' "$PY" || { echo "FAIL: suite must write last-run.log"; exit 1; }
grep -q 'last-run.json' "$PY" || { echo "FAIL: suite must write last-run.json"; exit 1; }
grep -q 'write_summary' "$PY" || { echo "FAIL: suite must persist a JSON summary"; exit 1; }
grep -q 'last-run.log' "$DOC" || { echo "FAIL: docs must point at results/last-run.log"; exit 1; }
grep -q 'HTTPCookieProcessor' "$PY" || {
	echo "FAIL: LuCI login needs a cookie jar"; exit 1
}
grep -q '8443' "$PY" || { echo "FAIL: LuCI login must POST :8443 not :8080"; exit 1; }
grep -q '_KeepPostRedirect' "$PY" || {
	echo "FAIL: UAT must not convert POST 302 into GET"; exit 1
}
grep -q 'wait_node_running' "$PY" || {
	echo "FAIL: UAT must wait for node_running after stop/start/save"; exit 1
}
grep -q 'with_wizard' "$PY" || { echo "FAIL: IUE phases must use the browser wizard"; exit 1; }
grep -q 'discover_password' "$PY" || { echo "FAIL: suite must find last IUE password"; exit 1; }
! grep -q 'R.setup("quickstart"' "$PY" || {
	echo "FAIL: Quick Start must not POST /api/setup behind the wizard"; exit 1
}

echo "PASS T-UAT-WEB"
