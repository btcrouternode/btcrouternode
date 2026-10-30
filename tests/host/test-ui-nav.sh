#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UI-NAV — segmented top nav + HTTPS dashboard links + LuCI auth helpers
# Aligned with U1/U1a/N13 (HTTP→HTTPS) and U10 brand (Bitcoin Node / Knots/Core).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WWW="$ROOT/files/www/knots"

grep -qE 'Bitcoin Node|Bitcoin Knots' "$WWW/index.html"
grep -q 'shell.js' "$WWW/index.html"
grep -q 'nav-item' "$WWW/shell.js"
grep -q 'topnav-primary' "$WWW/app.css"
grep -q 'Node Status' "$WWW/shell.js"
grep -q 'Router settings' "$WWW/shell.js"
# U8 — Storage wipe must not appear in primary nav
! grep -q 'label: "Storage"' "$WWW/shell.js" || {
	echo "FAIL: Storage still in primary nav (U8)"
	exit 1
}
grep -q 'U8' "$WWW/shell.js"
# U9 — Phase 2 primary nav omits custody tabs
! grep -q 'label: "Wallet"' "$WWW/shell.js" || {
	echo "FAIL: Wallet still in primary nav (U9 Phase 2)"
	exit 1
}
! grep -q 'label: "External apps"' "$WWW/shell.js" || {
	echo "FAIL: External apps still in primary nav (U9)"
	exit 1
}
! grep -q 'label: "Lightning"' "$WWW/shell.js" || {
	echo "FAIL: Lightning still in primary nav (U9)"
	exit 1
}
! grep -q 'label: "Privacy"' "$WWW/shell.js" || {
	echo "FAIL: Privacy still in primary nav (U9)"
	exit 1
}
grep -q 'U9\|Phase 2' "$WWW/shell.js"
grep -q 'U9' "$ROOT/REQUIREMENTS.md"
# N13 — cert install only in Setup IUE + /tls.html, not Node Status / Settings
! grep -q 'tlsTrustBanner\|ensureTlsBanner' "$WWW/shell.js" || {
	echo "FAIL: shell.js must not inject cert banner on operational pages (N13/U17)"
	exit 1
}
# U10 — brand follows Knots/Core
grep -q 'KnotsBrand' "$WWW/shell.js"
grep -q 'Bitcoin Core' "$WWW/shell.js"
grep -q 'applyBrand\|KnotsBrand.apply' "$WWW/shell.js"
grep -q 'KnotsBrand' "$WWW/app.js"
grep -q 'KnotsBrand' "$WWW/node.js"
grep -q 'U10' "$ROOT/REQUIREMENTS.md"
grep -q 'theme-toggle' "$WWW/shell.js"
grep -q 'brand-bar' "$WWW/shell.js"
grep -q 'ICON_SUN\|theme-icon' "$WWW/shell.js"
grep -q 'ICON_MOON\|theme-icon' "$WWW/shell.js"
grep -q 'theme-auto' "$WWW/shell.js"
grep -q 'KnotsTheme' "$WWW/shell.js"
# LuCI link must hit login CGI (auth), not imply open admin
grep -q 'cgi-bin/luci' "$WWW/shell.js"
# LuCI link must be HTTPS (U1 / U1a); Node Status uses same-origin "/" — nginx :80→:443
grep -q 'https://" + applianceHost() + ":8443' "$WWW/shell.js"
grep -q 'applianceUrl(it.href)' "$WWW/shell.js"

NODE_HTML="$WWW/node.html"
NODE_JS="$WWW/node.js"
grep -q 'data-u7a="wallet-switch-warn"' "$NODE_HTML"
grep -q 'walletAck' "$NODE_HTML"
grep -q 'not recommended' "$NODE_HTML"
grep -q 'wallet_ack' "$NODE_JS"
grep -q 'confirmPopup\|window.confirm' "$NODE_JS"
grep -q 'WALLET_ACK' "$ROOT/files/usr/libexec/knots/node-impl.sh"
grep -q 'wallet_present' "$ROOT/files/usr/libexec/knots/node-impl.sh"
grep -q 'U7a\|U8' "$ROOT/REQUIREMENTS.md"

THEME="$WWW/theme.js"
test -f "$THEME"
grep -q 'prefers-color-scheme' "$THEME"
grep -q 'knots-ui-theme' "$THEME"
grep -q 'data-theme' "$THEME"
grep -q '\[data-theme="dark"\]' "$WWW/app.css"
grep -q 'color-scheme: dark' "$WWW/app.css"
grep -q 'theme-toggle' "$WWW/app.css"

for f in index.html node.html settings.html; do
	grep -q 'shell.js' "$WWW/$f" || { echo "FAIL: $f missing shell.js"; exit 1; }
	grep -q 'theme.js' "$WWW/$f" || { echo "FAIL: $f missing theme.js"; exit 1; }
done
# S9 — Phase-3 pages deleted
for f in wallet.html wallet.js wallet.css external.html external.js lightning.html lightning.js privacy.html privacy.js; do
	! test -e "$WWW/$f" || { echo "FAIL: $f must not exist (S9)"; exit 1; }
done
# U8/S7 — wipe page must not ship
! test -e "$WWW/storage.html" || { echo "FAIL: storage.html must not exist (S7)"; exit 1; }
! test -e "$WWW/storage.js" || { echo "FAIL: storage.js must not exist (S7)"; exit 1; }

PORTS="$ROOT/files/usr/libexec/knots/ui-ports.sh"
! grep -q '"type": "external"' "$PORTS" || { echo "FAIL: external menu type still present"; exit 1; }
grep -q 'luci-sessions' "$PORTS"
grep -q 'knots-return' "$PORTS"
grep -q 'action_exit' "$PORTS"
grep -q 'knots-return-css-begin' "$PORTS"
# Must embed CSS into cascade; may only mention @import when deleting old broken lines
grep -q 'cat "\$RETURN_CSS" >>' "$PORTS" || grep -q 'cat "$RETURN_CSS" >>' "$PORTS" || {
	echo "FAIL: ui-ports does not append knots-return.css into cascade"
	exit 1
}
! grep -q 'printf.*@import url' "$PORTS" || {
	echo "FAIL: ui-ports still appends broken trailing @import"
	exit 1
}
# Shared Knots TLS for LuCI (N13 / F79 / F82)
grep -q "uhttpd.main.cert='/etc/knots/tls/fullchain.pem'" "$PORTS" \
	|| grep -q "uhttpd.main.cert='/etc/knots/tls/cert.pem'" "$PORTS" \
	|| { echo "FAIL: ui-ports must point uhttpd at Knots TLS"; exit 1; }

ENTRY="$ROOT/files/www/luci-entry.html"
grep -q 'rnode.local' "$ENTRY"
grep -qi 'login is required\|Admin login is required' "$ENTRY"
# Return to Node Dashboard over HTTPS (U1 / N13)
grep -q 'https://rnode.local/' "$ENTRY" \
	|| { echo "FAIL: luci-entry must link Node Dashboard via https://rnode.local/"; exit 1; }

CTRL="$ROOT/files/usr/share/ucode/luci/controller/admin/node_dashboard.uc"
grep -q 'action_exit' "$CTRL"
grep -q 'session.*, .*destroy\|session.*destroy' "$CTRL"
grep -q "HTTP_HOST" "$CTRL" && grep -q "return 'https://rnode.local/'" "$CTRL" \
	|| { echo "FAIL: node_dashboard.uc must redirect to the validated Host (D2) with rnode.local fallback"; exit 1; }

MENU_JSON="$ROOT/files/usr/share/luci/menu.d/node-dashboard.json"
grep -q 'Node Dashboard' "$MENU_JSON"
grep -q 'action_exit' "$MENU_JSON"
grep -q 'luci.controller.admin.node_dashboard' "$MENU_JSON"
! grep -qi 'Knots dashboard' "$MENU_JSON" || { echo "FAIL: old Knots dashboard title remains"; exit 1; }

SYSAUTH="$ROOT/files/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut"
grep -q 'knots-node-return' "$SYSAUTH"
grep -q 'knots-login-return' "$SYSAUTH"
grep -q 'modal.login' "$SYSAUTH"
grep -q 'Node Dashboard' "$SYSAUTH"
grep -qF "rnode\\.local|rnode-[0-9a-f]{4}\\.local|node-router" "$SYSAUTH" \
	|| { echo "FAIL: sysauth return link must use the D2 host rule"; exit 1; }
grep -q 'https://rnode.local/' "$WWW/tls.html" \
	|| { echo "FAIL: tls.html must use https://rnode.local/"; exit 1; }
! grep -q 'https://192.168.1.254' "$WWW/tls.html" \
	|| { echo "FAIL: tls.html still hardcodes 192.168.1.254"; exit 1; }
grep -q 'rnode.local' "$WWW/upgrade.js" \
	|| { echo "FAIL: upgrade.js must navigate via rnode.local"; exit 1; }
! grep -q 'ROUTER_FALLBACK_HOST = "192.168.1.254"' "$WWW/upgrade.js" \
	|| { echo "FAIL: upgrade.js still falls back to LAN IP"; exit 1; }
test -f "$WWW/wait-sw.js" || { echo "FAIL: missing wait-sw.js"; exit 1; }
grep -q 'showLinkDown' "$WWW/progress-wait.js" \
	|| { echo "FAIL: progress-wait must keep UI when LAN drops"; exit 1; }
grep -q 'font-size: 16px' "$SYSAUTH"
grep -q 'font-weight: 700' "$SYSAUTH"
grep -q 'offsetWidth' "$SYSAUTH"
# Must not put return link inside <section> (that lands inside the modal frame)
awk '
	/<section[[:space:]>]/ { s=1; next }
	/<\/section>/ { s=0; next }
	s && /knots-login-return|knots-return-bar/ { exit 1 }
' "$SYSAUTH" || { echo "FAIL: return link still inside login <section>"; exit 1; }

# nginx: :80 serves CA/tls; other paths redirect to HTTPS (U1/N13)
NGINX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
grep -q 'listen 80' "$NGINX"
grep -q 'return 302 https' "$NGINX" \
	|| { echo "FAIL: nginx must HTTP→HTTPS redirect (U1)"; exit 1; }
# grep -c (not -q): -q exits early, awk then dies of SIGPIPE and pipefail
# fails the check at random under load.
awk '/listen 80/,/^}/' "$NGINX" | grep -c 'knots-ca.crt' >/dev/null \
	|| { echo "FAIL: CA must remain on :80"; exit 1; }

test -f "$ROOT/files/www/luci-static/resources/knots-return.js"
CSS="$ROOT/files/www/luci-static/bootstrap/knots-return.css"
test -f "$CSS"
grep -q 'knots-login-return' "$CSS"
grep -q 'font-size: 16px' "$CSS"
grep -q 'font-weight: 700' "$CSS"
grep -q 'text-align: center' "$CSS"

# Node Status must paint chrome even if i18n/setup probes fail (HTTPS stall).
grep -q 'inject();' "$WWW/shell.js" || {
	echo "FAIL: shell must inject nav before waiting on i18n"; exit 1
}
grep -q 'detectInitial' "$WWW/shell.js" || {
	echo "FAIL: shell must still load i18n after inject"; exit 1
}
# H6/H7: one wait-page poller (shell.js), on /api/settings, paused while hidden.
awk '/function watchFactoryReset/,/^  }$/' "$WWW/shell.js" | grep -q '/api/settings?action=status' || {
	echo "FAIL: shell poller must poll /api/settings not /api/setup"; exit 1
}
awk '/function watchFactoryReset/,/^  }$/' "$WWW/shell.js" | grep -q 'document.hidden' || {
	echo "FAIL: shell poller must pause while the tab is hidden (H6)"; exit 1
}
[ ! -f "$WWW/reset-watch.js" ] || { echo "FAIL: reset-watch.js must stay retired (H7)"; exit 1; }
grep -q '@knots_setup_proxy' "$NGINX" || {
	echo "FAIL: :443 /api/setup must 404 without proxy_pass in the same location"; exit 1
}
# nginx emerg if named-location proxy_pass includes a URI — kills Node UI (F172).
grep -A8 'location @knots_setup_proxy' "$NGINX" | grep -c 'proxy_pass http://127.0.0.1:21444;' >/dev/null || {
	echo "FAIL: @knots_setup_proxy proxy_pass must have no URI"; exit 1
}
grep -A8 'location @knots_setup_proxy' "$NGINX" | grep -c 'proxy_pass .*/api/setup' >/dev/null && {
	echo "FAIL: @knots_setup_proxy must not proxy_pass with /api/setup URI"; exit 1
}
grep -q 'use-ipv6=no' "$ROOT/files/etc/avahi/avahi-daemon.conf" || {
	echo "FAIL: avahi must not publish IPv6 for rnode.local (slow HTTPS)"; exit 1
}
grep -q 'factory_reset_live' "$ROOT/files/usr/libexec/knots/settings-api.sh" || {
	echo "FAIL: settings status must expose factory_reset_live"; exit 1
}

echo "PASS T-UI-NAV"
