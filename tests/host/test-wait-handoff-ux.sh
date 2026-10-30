#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-WAIT-UX — user journeys after keep-settings, reset-settings, factory reset
# (U13, U17, N3, N13). Encodes the destination contract in wait-handoff.js.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HO="$ROOT/files/www/knots/wait-handoff.js"
PW="$ROOT/files/www/knots/progress-wait.js"
UPG_JS="$ROOT/files/www/knots/upgrade.js"
UPG_HTML="$ROOT/files/www/knots/upgrade.html"
RST_JS="$ROOT/files/www/knots/reset.js"
RST_HTML="$ROOT/files/www/knots/reset.html"
NGX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
SW="$ROOT/files/www/knots/wait-sw.js"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HO" ] || fail "missing wait-handoff.js"
grep -q 'KnotsWaitHandoff' "$HO" || fail "wait-handoff.js must export KnotsWaitHandoff"
grep -q 'wait-handoff.js' "$UPG_HTML" || fail "upgrade.html must load wait-handoff.js"
grep -q 'wait-handoff.js' "$RST_HTML" || fail "reset.html must load wait-handoff.js"
grep -q 'handoffWhenReady' "$UPG_JS" || fail "upgrade.js must call handoffWhenReady"
grep -q 'handoffWhenReady' "$RST_JS" || fail "reset.js must call handoffWhenReady"
grep -q 'handoffWhenReady' "$PW" || fail "progress-wait.js must implement handoffWhenReady"
grep -q 'Node Status' "$UPG_HTML" || fail "upgrade.html copy must say Node Status"
grep -q 'Opening Node Status' "$PW" || fail "keep-settings last bar must be Opening Node Status"
! grep -q 'openDest("/settings.html"' "$UPG_JS" || fail "keep-settings must not open Settings as the working page"
! grep -q 'opening Settings' "$RST_JS" || fail "factory reset must not open Settings"
grep -q 'setup.html?step=0' "$HO" || fail "handoff dest must be Welcome step=0"
grep -q 'https://' "$HO" || fail "keep-settings dest is HTTPS Node Status"
awk '/listen 80/,/listen 8080/' "$NGX" | grep -c 'location = /api/status' >/dev/null \
	|| fail ":80 must serve /api/status for the wait-page probe"
awk '/listen 80/,/listen 8080/' "$NGX" | grep -c 'location = /api/alive' >/dev/null \
	|| fail ":80 must serve /api/alive"
grep -q 'registration.unregister' "$SW" || fail "wait-sw.js must be the retired self-unregistering stub (D4)"
! grep -q 'addEventListener("fetch"' "$SW" || fail "retired wait-sw.js must not intercept fetches"
grep -q 'startedAt > 15000' "$UPG_JS" && fail "must not finish keep-settings after 15s" || true

node "$HO" >/dev/null 2>&1 || true
HO="$HO" node <<'NODE'
const H = require(process.env.HO);

function check(name, cond) {
  if (!cond) {
    console.error("FAIL:", name);
    process.exit(1);
  }
}

/* UX-KEEP-1 — firmware still applying: stay on wait */
{
  const dest = H.decideDest("upgradeKeep", { upgradeLive: true, setupComplete: true });
  check("UX-KEEP-1 dest wait", dest.page === "wait" && !dest.url);
  check(
    "UX-KEEP-1 no navigate",
    H.canNavigate(dest, { upgradeLive: true, alive: true, setupComplete: true, statusHttps: true }) === false
  );
}

/* UX-KEEP-2 — LAN alive after apply but Status HTTPS not ready: stay */
{
  const probes = {
    alive: true,
    setupComplete: true,
    statusHttps: false,
    statusHttp: false,
    forceFinished: true
  };
  const dest = H.decideDest("upgradeKeep", probes);
  check("UX-KEEP-2 dest status", dest.page === "status" && dest.protocol === "https");
  check("UX-KEEP-2 dest url", dest.url === "https://rnode.local/");
  check("UX-KEEP-2 stay", H.canNavigate(dest, probes) === false);
  check("UX-KEEP-2 reason", H.blockedReason(dest, probes) === "status_not_ready");
}

/* UX-KEEP-3 — HTTP status works, HTTPS cert fails: stay (no cert wall) */
{
  const probes = {
    alive: true,
    setupComplete: true,
    statusHttps: false,
    statusHttp: true,
    forceFinished: true
  };
  const dest = H.decideDest("upgradeKeep", probes);
  check("UX-KEEP-3 stay", H.canNavigate(dest, probes) === false);
  check("UX-KEEP-3 reason", H.blockedReason(dest, probes) === "https_untrusted");
}

/* UX-KEEP-4 — HTTPS Status ready after apply: open Node Status */
{
  const probes = {
    alive: true,
    setupComplete: true,
    statusHttps: true,
    forceFinished: true
  };
  const dest = H.decideDest("upgradeKeep", probes);
  check("UX-KEEP-4 navigate", H.canNavigate(dest, probes) === true);
  check("UX-KEEP-4 not settings", dest.path === "/" && dest.url.indexOf("settings") === -1);
}

/* UX-KEEP-5 — LAN up during apply, Status already works: do not finish early */
{
  const probes = {
    alive: true,
    setupComplete: true,
    statusHttps: true,
    upgradeLive: false,
    sawReboot: false,
    versionChanged: false,
    applyElapsedOk: false,
    forceFinished: false
  };
  const dest = H.decideDest("upgradeKeep", probes);
  check("UX-KEEP-5 stay", H.canNavigate(dest, probes) === false);
  check("UX-KEEP-5 reason", H.blockedReason(dest, probes) === "apply_not_finished");
}

/* UX-N-1 — reset-settings: HTTP Setup Welcome only */
{
  const probes = {
    alive: true,
    setupComplete: false,
    setupPageHttp: true
  };
  const dest = H.decideDest("upgrade", probes);
  check("UX-N-1 page", dest.page === "setup" && dest.protocol === "http");
  check("UX-N-1 url", dest.url === "http://rnode.local/setup.html?step=0");
  check("UX-N-1 navigate", H.canNavigate(dest, probes) === true);
}

/* UX-N-2 — reset-settings must never choose HTTPS first */
{
  const dest = H.decideDest("upgrade", { setupComplete: false, alive: true });
  check("UX-N-2 http", dest.protocol === "http" && dest.url.indexOf("https://") === -1);
}

/* UX-N-3 — Setup HTML still 302s to HTTPS (new CA): stay */
{
  const probes = {
    alive: true,
    setupComplete: false,
    setupPageHttp: false
  };
  const dest = H.decideDest("upgrade", probes);
  check("UX-N-3 stay", H.canNavigate(dest, probes) === false);
  check("UX-N-3 reason", H.blockedReason(dest, probes) === "setup_page_not_http");
}

/* UX-FR-1 — factory reset same dest as reset-settings */
{
  const probes = { alive: true, setupComplete: false, setupPageHttp: true };
  const dest = H.decideDest("reset", probes);
  check("UX-FR-1 setup", dest.url === "http://rnode.local/setup.html?step=0");
  check("UX-FR-1 navigate", H.canNavigate(dest, probes) === true);
}

/* UX-FR-2 — /api/alive alive:true must not send factory reset to Settings */
{
  const dest = H.decideDest("reset", { alive: true, setupComplete: false });
  check("UX-FR-2 not settings", dest.page === "setup" && dest.path.indexOf("settings") === -1);
}

/* UX-FR-3 — markers not cleared: stay, do not open Settings */
{
  const probes = { alive: true, setupComplete: true, statusHttps: true, forceFinished: true };
  const dest = H.decideDest("reset", probes);
  check("UX-FR-3 still setup dest", dest.page === "setup");
  check("UX-FR-3 stay", H.canNavigate(dest, probes) === false);
  check("UX-FR-3 reason", H.blockedReason(dest, probes) === "setup_not_incomplete");
}

/* UX-FR-4 — reset still live: stay */
{
  const dest = H.decideDest("reset", { factoryResetLive: true, setupComplete: false });
  check("UX-FR-4 wait", dest.page === "wait");
}

/* UX-BOUNCE — live upgrade must not navigate even if Status looks healthy */
{
  const dest = H.decideDest("upgradeKeep", { upgradeLive: true });
  check(
    "UX-BOUNCE",
    H.canNavigate(dest, {
      upgradeLive: true,
      alive: true,
      setupComplete: true,
      statusHttps: true,
      forceFinished: true
    }) === false
  );
}

console.log("PASS T-WAIT-UX logic (12 journeys)");
NODE

echo "PASS T-WAIT-UX"
