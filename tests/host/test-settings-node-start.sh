#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-SET-START-REINDEX — Settings Start node optional reindex (U18 / B24)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="$ROOT/files/usr/libexec/knots/settings-api.sh"
HTML="$ROOT/files/www/knots/settings.html"
JS="$ROOT/files/www/knots/settings.js"
CTL="$ROOT/files/usr/libexec/knots/bitcoind-ctl.sh"

grep -q 'id="btnStart"' "$HTML" || { echo "FAIL: missing Start node button"; exit 1; }
awk '/id="btnStart"/' "$HTML" | grep -c disabled >/dev/null || {
	echo "FAIL: Start node must be disabled until status is stopped"; exit 1
}
grep -q 'Available only when the node is stopped' "$HTML" || {
	echo "FAIL: Start copy must say it is only available when stopped"; exit 1
}
grep -q 'id="startReindex"' "$HTML" || { echo "FAIL: missing ReIndex Node checkbox"; exit 1; }
grep -q 'ReIndex Node' "$HTML" || { echo "FAIL: checkbox label must be ReIndex Node"; exit 1; }
grep -q 'id="startReindexKind"' "$HTML" || { echo "FAIL: missing reindex kind dropdown"; exit 1; }
grep -q 'startReindexKindWrap' "$HTML" || { echo "FAIL: missing dropdown wrap"; exit 1; }
awk '/id="startReindexKindWrap"/' "$HTML" | grep -c hidden >/dev/null || {
	echo "FAIL: dropdown wrap must start hidden"; exit 1
}
grep -q 'settings-reindex-kind\[hidden\]' "$ROOT/files/www/knots/app.css" || {
	echo "FAIL: CSS must force-hide dropdown while checkbox is off"; exit 1
}
grep -q '.btn:disabled' "$ROOT/files/www/knots/app.css" || {
	echo "FAIL: CSS must mute disabled Start/Stop buttons"; exit 1
}
grep -q 'settings-reindex-progress\[hidden\]' "$ROOT/files/www/knots/app.css" || {
	echo "FAIL: CSS must hide Reindex in progress until status says so"; exit 1
}
grep -q 'value="chainstate" selected' "$HTML" || {
	echo "FAIL: default option must be Repair chain database"; exit 1
}
grep -q 'value="full"' "$HTML" || {
	echo "FAIL: missing Also rebuild the block index option"; exit 1
}
! grep -q -- '-reindex-chainstate' "$HTML" || {
	echo "FAIL: UI must not show raw -reindex flags"; exit 1
}
awk '/id="btnStart"/,/<\/p>/' "$HTML" | grep -c 'startReindex' >/dev/null || {
	echo "FAIL: ReIndex Node checkbox must sit with Start node button"; exit 1
}
grep -q 'id="startReindexProgress"' "$HTML" || {
	echo "FAIL: missing Reindex in progress notice"; exit 1
}
grep -q 'Reindex in progress' "$HTML" || {
	echo "FAIL: progress notice must say Reindex in progress"; exit 1
}
awk '/id="startReindexProgress"/' "$HTML" | grep -c hidden >/dev/null || {
	echo "FAIL: progress notice must start hidden"; exit 1
}

grep -q 'syncStartReindexKind' "$JS" || {
	echo "FAIL: settings.js must show dropdown only when checked"; exit 1
}
grep -q 'function syncNodeCtlButtons' "$JS" || {
	echo "FAIL: settings.js must sync Start/Stop from node_running"; exit 1
}
grep -q 'reindex_running' "$JS" || {
	echo "FAIL: settings.js must read reindex_running from status"; exit 1
}
grep -q 'startReindexProgress' "$JS" || {
	echo "FAIL: settings.js must show Reindex in progress when running"; exit 1
}
grep -q 'nodeIsStopped' "$JS" || {
	echo "FAIL: settings.js must refuse Start click unless stopped"; exit 1
}
grep -q 'Stop the Bitcoin node first' "$JS" || {
	echo "FAIL: settings.js must banner when Start clicked while running"; exit 1
}
grep -q 'reindex=1' "$JS" || { echo "FAIL: settings.js must POST reindex=1 when checked"; exit 1; }
grep -q 'reindex_kind=' "$JS" || { echo "FAIL: settings.js must POST reindex_kind"; exit 1; }
grep -q 'You chose: Repair chain database' "$JS" || {
	echo "FAIL: chainstate warning popup missing"; exit 1
}
grep -q 'You chose: Also rebuild the block index' "$JS" || {
	echo "FAIL: full reindex warning popup missing"; exit 1
}

grep -q 'reindex_running' "$API" || {
	echo "FAIL: settings status must expose reindex_running"; exit 1
}
grep -q 'bitcoind_ctl_reindex_running' "$API" || {
	echo "FAIL: settings-api must reuse bitcoind_ctl_reindex_running"; exit 1
}
grep -q 'reindex_in_progress' "$API" || {
	echo "FAIL: node_start must refuse reindex_in_progress"; exit 1
}
grep -q 'already_running' "$API" || {
	echo "FAIL: node_start must refuse already_running when bitcoind is alive"; exit 1
}
awk '/node_start\)/,/want_reindex/' "$API" | grep -c 'bitcoind_ctl_bitcoind_alive' >/dev/null || {
	echo "FAIL: node_start must check bitcoind_ctl_bitcoind_alive before start"; exit 1
}
grep -q 'want_reindex' "$API" || { echo "FAIL: settings-api missing reindex flag parse"; exit 1; }
grep -q 'reindex_kind' "$API" || { echo "FAIL: settings-api missing reindex_kind"; exit 1; }
grep -q 'bitcoind_ctl_reindex_chainstate' "$API" || {
	echo "FAIL: chainstate path must reuse bitcoind_ctl_reindex_chainstate"; exit 1
}
grep -q 'bitcoind_ctl_reindex -reindex' "$API" || {
	echo "FAIL: full path must reuse bitcoind_ctl_reindex -reindex"; exit 1
}
grep -q 'bitcoind_ctl_reindex()' "$CTL" || {
	echo "FAIL: bitcoind-ctl must share bitcoind_ctl_reindex"; exit 1
}
grep -q 'bitcoind_ctl_reindex_running()' "$CTL" || {
	echo "FAIL: bitcoind-ctl must expose bitcoind_ctl_reindex_running"; exit 1
}

LIB="$ROOT/files/usr/libexec/knots/cgi-lib.sh"
grep -q 'cgi_setsid()' "$LIB" || { echo "FAIL: cgi-lib must provide cgi_setsid (F204)"; exit 1; }
awk '/conf_save)/,/node_stop)/' "$API" | grep -qE 'cgi_setsid|cgi_node_worker' || {
	echo "FAIL: conf_save must cgi_setsid restart (F204)"; exit 1
}
awk '/node_stop)/,/node_start)/' "$API" | grep -qE 'cgi_setsid|cgi_node_worker' || {
	echo "FAIL: node_stop must cgi_setsid (F204)"; exit 1
}
awk '/node_start)/,/reboot)/' "$API" | grep -qE 'cgi_setsid|cgi_node_worker' || {
	echo "FAIL: node_start must cgi_setsid (F204)"; exit 1
}
awk '/node_start)/,/cgi_node_worker/' "$API" | grep -c 'already_running' >/dev/null || {
	echo "FAIL: already_running must still be checked in CGI before detach"; exit 1
}
grep -q 'pollNodeUntil' "$JS" || {
	echo "FAIL: settings.js must poll until node_running after stop/start/save"; exit 1
}

NAPI="$ROOT/files/usr/libexec/knots/node-impl-api.sh"
awk '/^	set)/,/^	install)/' "$NAPI" | grep -qE 'cgi_setsid|cgi_node_worker' || {
	echo "FAIL: node-impl-api set must cgi_setsid (F204)"; exit 1
}

echo "PASS T-SET-START-REINDEX"
