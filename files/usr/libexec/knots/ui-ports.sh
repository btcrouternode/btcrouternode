#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Move LuCI to 8080/8443; nginx owns Node Dashboard on 80/443 (U1/U1a/N2).
# OpenWrt 24 LuCI is ucode-only — never install Lua .htm menu templates.

set -e

log() { logger -t ui-ports "$*"; echo "ui-ports: $*" >&2; }

# uhttpd serves LuCI :8443 AND the Knots API CGI :21444. A restart drops both
# for a few seconds — a Setup step landing in that gap got HTTP 502 (.79 UAT
# Guided Node step after `sysupgrade -n`: this script runs at boot from
# knots-node-ui and again ~70 s later from image-sync). Only restart (and
# clear LuCI sessions) when something uhttpd/LuCI-ucode actually caches
# changed; static files below are served from disk as-is.
UI_RESTART_FILES="/usr/share/ucode/luci/controller/admin/node_dashboard.uc
/usr/share/ucode/luci/template/node_dashboard.ut
/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut
/usr/share/luci/menu.d/node-dashboard.json"
ui_restart_sig() {
	{
		uci -q show uhttpd 2>/dev/null
		for f in $UI_RESTART_FILES; do
			echo "== $f"
			cat "$f" 2>/dev/null || true
		done
	} | md5sum | cut -d' ' -f1
}
UI_SIG_BEFORE=$(ui_restart_sig)

# --- LuCI / uhttpd — HTTPS only on 8443; HTTP :8080 is nginx→HTTPS (U1a) ---
# Same local CA leaf as Node UI :443 so Router settings does not warn after trust (N13).
if [ -f /etc/config/uhttpd ]; then
	uci -q delete uhttpd.main.listen_http || true
	uci -q delete uhttpd.main.listen_https || true
	uci add_list uhttpd.main.listen_https='0.0.0.0:8443'
	uci add_list uhttpd.main.listen_https='[::]:8443'
	uci -q set uhttpd.main.redirect_https='0'
	# Leaf only, never fullchain.pem: uhttpd's TLS (ustream-ssl / mbedTLS 3.6)
	# refuses a file containing the P3 CA, whose nameConstraints are critical
	# ("Failed to load certificate/key files" → LuCI :8443 crash loop, .83).
	# Clients trust the installed CA, so LuCI does not need to send it.
	if [ -f /etc/knots/tls/cert.pem ] && [ -f /etc/knots/tls/key.pem ]; then
		uci -q set uhttpd.main.cert='/etc/knots/tls/cert.pem'
		uci -q set uhttpd.main.key='/etc/knots/tls/key.pem'
		log "uhttpd TLS → /etc/knots/tls/cert.pem (shared with Node UI)"
	fi
	uci -q commit uhttpd
	log "uhttpd listen → HTTPS 8443 only (8080 redirect via nginx)"
fi

if [ -f /etc/config/nginx ]; then
	uci -q delete nginx._lan || true
	uci -q delete nginx._redirect2ssl || true
	uci -q commit nginx || true
fi

if [ -f /www/luci-entry.html ]; then
	cp /www/luci-entry.html /www/index.html
	log "LuCI :8080/ → pre-login chooser"
fi

# Remove broken Lua-era artifacts
rm -f /usr/lib/lua/luci/view/knots_dashboard.htm 2>/dev/null || true
rm -f /usr/share/luci/menu.d/knots-dashboard.json 2>/dev/null || true

mkdir -p /usr/share/luci/menu.d \
	/usr/share/ucode/luci/template/themes/bootstrap \
	/usr/share/ucode/luci/controller/admin \
	/etc/knots/overlay-ui

# Controller: logout + redirect to Node Dashboard
if [ -f /etc/knots/overlay-ui/node_dashboard.uc ]; then
	cp /etc/knots/overlay-ui/node_dashboard.uc \
		/usr/share/ucode/luci/controller/admin/node_dashboard.uc
elif [ -f /usr/share/ucode/luci/controller/admin/node_dashboard.uc ]; then
	:
else
	log "WARN: node_dashboard.uc missing"
fi

# Fallback template (JS logout) if menu ever points at template again
if [ -f /etc/knots/overlay-ui/node_dashboard.ut ]; then
	cp /etc/knots/overlay-ui/node_dashboard.ut \
		/usr/share/ucode/luci/template/node_dashboard.ut
fi

cat >/usr/share/luci/menu.d/node-dashboard.json <<'EOF'
{
	"admin/node-dashboard": {
		"title": "Node Dashboard",
		"order": 90,
		"action": {
			"type": "function",
			"module": "luci.controller.admin.node_dashboard",
			"function": "action_exit"
		},
		"depends": {
			"acl": [ "luci-base" ]
		}
	}
}
EOF
log "LuCI menu → Node Dashboard (logout + redirect)"

# Login page: under-modal return link
if [ -f /etc/knots/overlay-ui/sysauth.ut ]; then
	cp /etc/knots/overlay-ui/sysauth.ut \
		/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut
	log "LuCI login sysauth.ut → Node Dashboard under Log in"
fi

# Append CSS into cascade.css — trailing @import is ignored by browsers
RETURN_CSS=/www/luci-static/bootstrap/knots-return.css
CASCADE=/www/luci-static/bootstrap/cascade.css
if [ -f "$RETURN_CSS" ] && [ -f "$CASCADE" ]; then
	# Drop any broken trailing @import lines we may have added earlier
	sed -i '/@import url("knots-return.css")/d' "$CASCADE" 2>/dev/null || true
	if ! grep -q 'knots-return-css-begin' "$CASCADE" 2>/dev/null; then
		printf '\n/* knots-return-css-begin */\n' >>"$CASCADE"
		cat "$RETURN_CSS" >>"$CASCADE"
		printf '\n/* knots-return-css-end */\n' >>"$CASCADE"
		log "cascade.css ← knots-return styles inlined"
	else
		# Refresh embedded block
		awk '
			/knots-return-css-begin/ { skip=1; next }
			/knots-return-css-end/ { skip=0; next }
			!skip { print }
		' "$CASCADE" >"$CASCADE.tmp" && mv "$CASCADE.tmp" "$CASCADE"
		printf '\n/* knots-return-css-begin */\n' >>"$CASCADE"
		cat "$RETURN_CSS" >>"$CASCADE"
		printf '\n/* knots-return-css-end */\n' >>"$CASCADE"
		log "cascade.css ← knots-return styles refreshed"
	fi
fi

# JS backup for authenticated pages
RETURN_JS=/www/luci-static/resources/knots-return.js
LUCI_JS=/www/luci-static/resources/luci.js
if [ -f "$RETURN_JS" ] && [ -f "$LUCI_JS" ]; then
	if ! grep -q 'knots-return.js' "$LUCI_JS" 2>/dev/null; then
		cat >>"$LUCI_JS" <<'EOF'

;/* knots-return */(function(){function l(){if(document.getElementById("knots-return-loader"))return;var s=document.createElement("script");s.id="knots-return-loader";s.src="/luci-static/resources/knots-return.js";(document.head||document.documentElement).appendChild(s);}if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",l);else l();})();
EOF
	fi
fi

if [ "$(ui_restart_sig)" != "$UI_SIG_BEFORE" ] || ! pidof uhttpd >/dev/null 2>&1; then
	rm -rf /tmp/luci-sessions 2>/dev/null || true
	mkdir -p /tmp/luci-sessions
	[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart 2>/dev/null || true
	log "uhttpd restarted (config / LuCI ucode changed)"
else
	mkdir -p /tmp/luci-sessions
	log "uhttpd config unchanged — not restarted (API + LuCI stay up)"
fi
log "Node Dashboard + login return ready"
exit 0
