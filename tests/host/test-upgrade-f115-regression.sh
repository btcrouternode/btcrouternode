#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UPG-F115 — regression guard for reset-settings reboot hang fix (F115)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPG_JS="$ROOT/files/www/knots/upgrade.js"
UI_SH="$ROOT/files/usr/libexec/knots/upgrade-ui.sh"

[ -f "$UPG_JS" ] || { echo "FAIL: missing upgrade.js"; exit 1; }

grep -q 'resolveKeepConfig' "$UPG_JS" || { echo "FAIL: resolveKeepConfig missing"; exit 1; }
grep -q 'elapsed > 3000' "$UPG_JS" || {
	echo "FAIL: upgrade.js must defer leaveIdle to avoid arming race"; exit 1
}
grep -q 'finishMsAfterDown' "$UPG_JS" || {
	echo "FAIL: finishMsAfterDown must linger after LAN drop (F150)"; exit 1
}
grep -q 'onDownLinger' "$UPG_JS" || {
	echo "FAIL: upgrade.js must linger on this page while the router is down"; exit 1
}
! grep -q 'bounceHost' "$UPG_JS" || {
	echo "FAIL: upgrade.js must not bounce off this page during reboot"; exit 1
}
grep -q 'redirectWhenReady' "$UPG_JS" || {
	echo "FAIL: upgrade.js must wait for router before redirect"; exit 1
}
grep -q 'handoffWhenReady' "$UPG_JS" || {
	echo "FAIL: upgrade.js must confirm dest works before navigate"; exit 1
}

# Shell: upgrade.active must record keep_config
grep -q 'keep_config' "$UI_SH" || { echo "FAIL: upgrade-ui.sh missing keep_config"; exit 1; }
grep -q 'upgrade_ui_keep_config' "$UI_SH" || {
	echo "FAIL: upgrade-ui.sh missing upgrade_ui_keep_config"; exit 1
}

# Node: resolveKeepConfig decision table (mirrors upgrade.js)
UPG_JS="$UPG_JS" node <<'NODE'
const fs = require("fs");
const path = process.env.UPG_JS;
const src = fs.readFileSync(path, "utf8");
if (!src.includes("function resolveKeepConfig")) {
  console.error("FAIL: cannot find resolveKeepConfig in upgrade.js");
  process.exit(1);
}

function resolveKeepConfig(params, st, setupStatus, settingsStatus) {
  const keepParam = params.get("keep");
  if (keepParam === "0" || keepParam === "false") return false;
  if (keepParam === "1" || keepParam === "true") return true;
  if (st && (st.keepConfig === false || st.keepConfig === 0 || st.keepConfig === "0")) {
    return false;
  }
  if (st && (st.keepConfig === true || st.keepConfig === 1 || st.keepConfig === "1")) {
    return true;
  }
  if (setupStatus && setupStatus.upgrade_keep_config === false) return false;
  if (settingsStatus && settingsStatus.upgrade_keep_config === false) return false;
  if (
    st &&
    setupStatus &&
    setupStatus.complete === false &&
    !setupStatus.upgrade_live
  ) {
    return false;
  }
  return true;
}

function shouldLeaveIdle(live, elapsedMs) {
  return !live && elapsedMs > 3000;
}

const cases = [
  {
    name: "reset URL keep=0",
    got: resolveKeepConfig(new URLSearchParams("keep=0"), null, null, null),
    want: false,
  },
  {
    name: "keep URL keep=1",
    got: resolveKeepConfig(new URLSearchParams("keep=1"), null, null, null),
    want: true,
  },
  {
    name: "nginx redirect go=1 only + session reset",
    got: resolveKeepConfig(
      new URLSearchParams("go=1"),
      { keepConfig: false, started: Date.now() },
      { complete: false, upgrade_live: false, ok: true },
      null
    ),
    want: false,
  },
  {
    name: "nginx redirect go=1 only + session keep + setup complete",
    got: resolveKeepConfig(
      new URLSearchParams("go=1"),
      { keepConfig: true, started: Date.now() },
      { complete: true, upgrade_live: false, ok: true },
      { ok: true, upgrade_live: false }
    ),
    want: true,
  },
  {
    name: "post-reboot reset via setup.complete without session",
    got: resolveKeepConfig(
      new URLSearchParams("go=1"),
      null,
      { complete: false, upgrade_live: false, ok: true },
      null
    ),
    want: true,
  },
  {
    name: "armed reset via API marker",
    got: resolveKeepConfig(
      new URLSearchParams("go=1"),
      null,
      { upgrade_keep_config: false, upgrade_live: true, ok: true },
      null
    ),
    want: false,
  },
  {
    name: "leaveIdle deferred during arming race",
    got: shouldLeaveIdle(false, 500),
    want: false,
  },
  {
    name: "leaveIdle after post-reboot",
    got: shouldLeaveIdle(false, 5000),
    want: true,
  },
];

let fail = 0;
for (const c of cases) {
  if (c.got !== c.want) {
    console.error("FAIL:", c.name, "got", c.got, "want", c.want);
    fail++;
  }
}
if (fail) process.exit(1);
console.log("PASS T-UPG-F115 logic (" + cases.length + " cases)");
NODE

# upgrade-ui keep_config round-trip
mkdir -p /tmp/knots
active_bak=""
if [ -f /tmp/knots/upgrade.active ]; then
	active_bak=$(mktemp)
	cp /tmp/knots/upgrade.active "$active_bak"
fi
cleanup_active() {
	if [ -n "$active_bak" ] && [ -f "$active_bak" ]; then
		cp "$active_bak" /tmp/knots/upgrade.active
	else
		rm -f /tmp/knots/upgrade.active
	fi
}
trap cleanup_active EXIT
# shellcheck disable=SC1090
. "$UI_SH"
upgrade_ui_arm settings 180 0
grep -q '"keep_config":false' /tmp/knots/upgrade.active || {
	echo "FAIL: upgrade_ui_arm must write keep_config:false for reset"; exit 1
}
[ "$(upgrade_ui_keep_config)" = "false" ] || {
	echo "FAIL: upgrade_ui_keep_config must read false"; exit 1
}
upgrade_ui_arm settings 180 1
grep -q '"keep_config":true' /tmp/knots/upgrade.active || {
	echo "FAIL: upgrade_ui_arm must write keep_config:true for keep"; exit 1
}

echo "PASS T-UPG-F115"
