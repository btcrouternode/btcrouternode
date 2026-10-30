#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# IUE / first-run Setup flow contract (U17 / U19 / R7 / R10a / R13 / N13).
# Host-only: static UI + API contract + validation rules. Looks for bugs.
# Usage: tests/host/test-iue-flow.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HTML="$ROOT/files/www/knots/setup.html"
JS="$ROOT/files/www/knots/setup.js"
CSS="$ROOT/files/www/knots/app.css"
SHELLJS="$ROOT/files/www/knots/shell.js"
API="$ROOT/files/usr/libexec/knots/setup-api.sh"
LIB="$ROOT/files/usr/libexec/knots/setup-lib.sh"
NGINX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Normative step order (FIRST_RUN_UX.md) ---
need_step() {
	id=$1
	n=$2
	grep -q "id=\"$id\"" "$HTML" || fail "missing step $id"
	# Same section line carries data-step and id
	grep -Eq "data-step=\"$n\"[^>]*id=\"$id\"|id=\"$id\"[^>]*data-step=\"$n\"" "$HTML" \
		|| fail "step $id must be data-step=$n"
}

need_step stepWelcome 0
need_step stepTls 1
need_step stepChoice 2
need_step stepQuick 3
need_step stepNode 4
need_step stepWan 5
need_step stepLan 6
need_step stepWifi 7
need_step stepPassword 8
need_step stepDone 9
pass "setup.html step order 0..9 (Welcome→Security→Choice→Quick/Guided→Done)"

# Shared look (U1b)
grep -q 'app.css' "$HTML" || fail "setup must use app.css"
grep -q 'shell.js' "$HTML" || fail "setup must use shell.js"
grep -q 'theme.js' "$HTML" || fail "setup must use theme.js"
grep -q 'tls-os.js' "$HTML" || fail "setup TLS step must use tls-os.js"
grep -q 'function bindNeedValue' "$JS" || fail "required Setup fields need bindNeedValue"
grep -q 'need-value' "$JS" || fail "password/required fields must toggle need-value"
grep -q 'input.need-value' "$CSS" || fail "app.css must style empty required Setup fields red"
pass "Setup shares Node Status chrome/theme/TLS helper"

# Gate: incomplete → Setup
grep -q 'setup-complete' "$SHELLJS" || fail "shell gate missing setup-complete"
grep -q 'setup.html' "$SHELLJS" || fail "shell gate missing setup.html redirect"
grep -q 'setupPageUrl\|KnotsIue' "$SHELLJS" || fail "shell gate must use HTTP setup URL (KnotsIue)"
grep -q 'setupStartUrl' "$SHELLJS" || fail "shell.js must expose setupStartUrl for IUE Welcome"
grep -q 'resumeStep === 0' "$JS" || fail "setup.js must honour step=0 as Welcome (not leftover TLS)"
grep -q 'location.protocol === "https:"' "$JS" \
	|| fail "HTTPS Setup after CA install must resume (not Welcome)"
grep -q 'afterTls' "$JS" || fail "setup.js must treat after_tls / HTTPS as past Security"
awk '/resumeStep === 0/,/showStep\(0\)/' "$JS" | grep -q enterChoice \
	|| fail "after_tls + step=0 must enter Choice, not restart Welcome"
grep -q 'action=status' "$SHELLJS" || fail "shell gate must query /api/setup?action=status"
pass "shell.js Setup gate (U17)"

# API actions present
for a in status locale password wan_dhcp wan_pppoe wan_status wifi node lan complete quickstart; do
	grep -Eq "^[[:space:]]*$a\)" "$API" || fail "setup-api missing action $a"
done
pass "setup-api actions cover full IUE surface"

# Quick Start (IUE v2): one-shot action + security progress + locale auto-detect
grep -qE 'complete\|quickstart(\||\))' "$API" || fail "quickstart must be gated on setup-complete"
awk '/^\tquickstart\)/,/^\t\t;;/' "$API" | grep -q 'setup_pending_set node_impl core' \
	|| fail "quickstart must default the node to Core (C1: only when installed)"
awk '/^\tquickstart\)/,/^\t\t;;/' "$API" | grep -q 'setup_wifi_stage rnode' \
	|| fail "quickstart must stage SSID rnode (applied by the shared Finish path)"
grep -q 'setup_mark_complete' "$API" || fail "quickstart must complete Setup"
grep -q 'btnQuickSubmit' "$JS" || fail "Quick Start submit handler missing"
grep -q 'btnGuided' "$HTML" || fail "Guided Setup button missing"
grep -q 'btnQuick\b' "$HTML" || fail "Quick Start button missing"
grep -q 'quickPppoeModal' "$HTML" || fail "Quick PPPoE popup missing"
grep -q 'startTlsWatch' "$JS" || fail "Security progress watch missing (U17 page 2)"
grep -q 'function stopTlsWatch' "$JS" || fail "TLS watch must be stoppable"
grep -q 'function advancePastTls' "$JS" || fail "advancePastTls missing"
grep -q 'if (step !== 1) return' "$JS" \
	|| fail "TLS success must not reopen Choice after Quick Start"
awk '/function showStep/,/^  }/' "$JS" | grep -q stopTlsWatch \
	|| fail "showStep must stop the TLS watch when leaving Security"
grep -q 'tlsProgressBar' "$HTML" || fail "Security progress bar missing"
grep -q 'resolvedOptions' "$JS" || fail "browser timezone auto-detect missing (U19)"
grep -q 'detectBrowserLocale' "$JS" || fail "browser locale auto-detect missing (U19)"
# C8 (review 2026-10-11): staging steps never move the LAN or drop Wi-Fi, so
# their dead reconnect/restart branches and helpers are gone.
grep -qE 'function (showLanMoving|showWifiReconnect|showRestarting)' "$JS" \
	&& fail "C8: dead wait helpers must stay removed"
awk '/^	(wifi|lan)\)/,/^		;;/' "$API" | grep -qE 'wifi_reconnect|lan_moved|restart' \
	&& fail "C8: staging actions must not return reconnect/restart fields"
pass "Quick Start action + Choice page + Security progress + locale auto-detect"

# Complete requires locale + password (retail)
grep -q 'setup_locale_done' "$API" || fail "complete must require locale"
grep -q 'setup_password_done' "$API" || fail "complete must require password"
grep -q 'locale_required' "$API" || fail "locale_required error missing"
grep -q 'password_required' "$API" || fail "password_required error missing"
pass "complete fails closed without locale/password"

# Password: factory forbidden + min length
grep -q 'FACTORY_PASS=knotsnode21' "$LIB" || fail "factory password constant"
grep -q 'factory_forbidden' "$API" || fail "factory_forbidden JSON"
grep -q 'too_short' "$API" || fail "too_short JSON"
grep -q '\[ "\${#pass}" -ge 8 \]' "$LIB" || grep -q 'ge 8' "$LIB" || fail "min length 8 in lib"
pass "password negatives (factory + short)"

# Wi‑Fi: factory AP rnode / per-device label secret (P1), 8–63 key, IUE must replace PSK
grep -q 'rnode' "$HTML" || fail "SSID default rnode in HTML"
grep -q 'rnode' "$JS" || fail "SSID default rnode in JS"
grep -q 'ssid=rnode' "$API" || fail "API default ssid rnode"
grep -q 'ge 8' "$LIB" || fail "wifi key min 8"
grep -q 'le 63' "$LIB" || fail "wifi key max 63"
# P1: no shared password in the UI — labelled units point at the label,
# unlabelled units (Wi-Fi off) get the LAN-cable variant.
! grep -q 'knotsnode21' "$HTML" || fail "Welcome must not show a shared Wi-Fi password (P1)"
grep -q 'password printed on the label' "$HTML" || fail "Welcome must point at the label password"
grep -q 'id="welcomeBodyNoWifi"' "$HTML" || fail "Welcome needs the unlabelled (Wi-Fi off) variant"
grep -q 'factory_labelled' "$JS" || fail "setup.js must switch Welcome on factory_labelled"
grep -q 'Join Wi' "$HTML" || fail "Welcome must offer factory Wi-Fi"
grep -q 'setup_wifi_is_factory_key' "$LIB" || fail "setup_wifi_is_factory_key missing"
awk '/^	wifi\)/,/^	;;/' "$API" | grep -q setup_wifi_is_factory_key \
	|| fail "wifi action must reject factory PSK"
awk '/^	complete\)/,/^	;;/' "$API" | grep -q setup_wifi_is_factory_key \
	|| fail "complete must require non-factory wifi key"
awk '/^	quickstart\)/,/^	;;/' "$API" | grep -q setup_wifi_is_factory_key \
	|| fail "quickstart must reject factory wifipsk"
grep -q 'isFactoryPass' "$JS" || fail "setup.js must reject factory Wi-Fi PSK"
grep -q 'FACTORY_WIFI_COUNTRY' "$LIB" || fail "factory Wi-Fi country constant missing"
grep -q 'FACTORY_WIFI_COUNTRY=AU' "$LIB" || fail "factory Wi-Fi country must be AU (hostapd rejects 00)"
WDE="$ROOT/files/usr/libexec/knots/wifi-default-enable.sh"
grep -q 'FACTORY_WIFI_COUNTRY' "$WDE" || fail "wifi-default-enable must use FACTORY_WIFI_COUNTRY"
! grep -q 'country=00' "$WDE" || fail "wifi-default-enable must not write country 00 to hostapd"
grep -q 'knots_factory_secret' "$WDE" || fail "wifi-default-enable must use the per-device label secret (P1)"
! grep -q 'FACTORY_PASS' "$WDE" || fail "wifi-default-enable must not use the shared password (P1)"
! grep -Eq 'tr -dc|hexdump|/dev/urandom' "$WDE" \
	|| fail "wifi-default-enable must not invent a random PSK"
pass "Wi‑Fi rnode + per-device label PSK + country 00 (R7/U6/R13/P1)"

# WAN: DHCP + PPPoE + skip allowed in UI
grep -q 'wan_dhcp' "$JS" || fail "WAN DHCP in setup.js"
grep -q 'wan_pppoe' "$JS" || fail "WAN PPPoE in setup.js"
grep -q 'setup_lan_stage' "$LIB" || fail "Guided LAN must stage until Finish"
grep -q 'setup_wifi_stage' "$LIB" || fail "Guided Wi-Fi must stage until Finish"
grep -q 'setup_schedule_cutover' "$LIB" || fail "Finish must schedule one network cutover"
grep -q 'setup_tls_refresh_lan' "$LIB" || fail "LAN IP change must reissue HTTPS leaf"
grep -q 'node-ui-tls.sh node-router --leaf' "$LIB" || fail "LAN TLS refresh must use --leaf (keep IUE CA)"
grep -q 'KNOTS_LAN_IP_EXTRA' "$ROOT/files/usr/libexec/knots/node-ui-tls.sh" \
	|| fail "TLS leaf must accept extra SAN IP during alias hold"
grep -q 'lan_moved' "$API" || fail "complete/lan JSON must include lan_moved"
awk '/^	lan\)/,/^	;;/' "$API" | grep -q setup_lan_stage \
	|| fail "lan action must stage, not ifup"
awk '/^	lan\)/,/^	;;/' "$API" | grep -q setup_schedule_lan_apply \
	&& fail "lan action must not ifup until Finish"
awk '/^	lan\)/,/^	;;/' "$API" | grep -q setup_schedule_reboot \
	&& fail "lan action must not reboot the router"
grep -q 'function showFinishWait' "$JS" || fail "setup.js must wait once at Finish"
grep -q 'waitProgressBar' "$HTML" || fail "LAN wait must show a progress bar"
grep -q 'function setWaitProgress' "$JS" || fail "setup.js must tick LAN wait progress"
grep -q 'probeUrl' "$JS" || fail "LAN wait must abort probes (probeUrl), not hang on fetch"
awk '/function showSetupWait/,/^  function showRestarting/' "$JS" | grep -q 'location.replace' \
	|| fail "LAN/Wi-Fi wait must navigate even if probes fail"
grep -q 'wifi_reconnect' "$JS" || fail "setup.js must honour wifi_reconnect JSON"
grep -q 'setup_client_on_wifi' "$LIB" || fail "setup_client_on_wifi missing"
awk '/^	wifi\)/,/^		;;/' "$API" | grep -q setup_wifi_stage \
	|| fail "wifi action must stage SSID/PSK"
awk '/^	wifi\)/,/^		;;/' "$API" | grep -q setup_schedule_wifi_reload \
	&& fail "wifi action must not reload radios (Finish cutover only)"
awk '/^	wifi\)/,/^		;;/' "$API" | grep -q setup_wifi_apply \
	&& fail "wifi action must not apply UCI until Finish"
# C1/C2: complete and quickstart share one validate → apply → respond path.
awk '/^setup_finish_and_respond\(\)/,/^}/' "$API" | grep -q wifi_reconnect \
	|| fail "Finish must return wifi_reconnect"
awk '/^setup_finish_and_respond\(\)/,/^}/' "$API" | grep -q setup_schedule_cutover \
	|| fail "Finish must schedule the cutover"
for a in complete quickstart; do
	awk -v a="	$a)" 'index($0, a) == 1 { f = 1 } f && /^\t\t;;$/ { exit } f' "$API" | grep -q setup_finish_and_respond \
		|| fail "$a must use the shared Finish path"
done
grep -q 'wifiWaitBar' "$HTML" || fail "Wi-Fi save must show a progress bar"
grep -q 'setup-wifi-wait' "$HTML" || fail "Wi-Fi save wait panel missing"
awk '/btnPassword/,/^  \};/' "$JS" | grep -q 'timeoutMs: 12000' \
	|| fail "password save must abort a hung CGI fetch"
awk '/btnPassword/,/^  \};/' "$JS" | grep -q password_done \
	|| fail "password hang must resume if setup-password-done"
awk '/\$\("btnWifi"\)\.onclick/,/^  \};/' "$JS" | grep -q 'finishWifi(false' \
	|| fail "wifi CGI hang must not skip to password as success"
awk '/\$\("btnWifi"\)\.onclick/,/^  \};/' "$JS" | grep -q '8000' \
	&& fail "wifi save must not 8s-timeout before CGI JSON (R7 reconnect)"
awk '/\$\("btnWifi"\)\.onclick/,/^  \};/' "$JS" | grep -q timeoutMs \
	&& fail "wifi save must not abort fetch (browser shows signal aborted)"
grep -q 'function friendlyError' "$JS" || fail "setup.js must map AbortError to a human message"
! grep -q 'signal is aborted' "$JS" || fail "must not show raw abort text"
awk '/\$\("btnWifi"\)\.onclick/,/^  \};/' "$JS" | grep -q wifi_staged \
	|| fail "wifi save abort must resume if wifi_staged"
awk '/^setup_client_on_wifi/,/^}$/' "$LIB" | grep -q 'iw dev' \
	&& fail "client Wi-Fi detect must not stall CGI on iw"
awk '/^setup_client_on_wifi/,/^}$/' "$LIB" | grep -q carrier \
	|| fail "client Wi-Fi detect must treat no-Ethernet as Wi-Fi (R7)"
grep -q 'setup_wifi_deauth_stations' "$LIB" || fail "cutover must deauth Wi-Fi stations"
awk '/^	wifi\)/,/^		;;/' "$API" | grep -q setup_wifi_reload_now \
	&& fail "wifi CGI must not reload radios in-process"
grep -q 'Opening router password' "$JS" || fail "Wi-Fi save must advance to router password"
grep -q 'stepRestart.*hidden = true' "$JS" || fail "showStep must hide leftover LAN wait"
grep -q 'Router password' "$HTML" || fail "Guided step 8 must be titled Router password"
grep -q 'step=(\\d+)' "$JS" || fail "setup.js must resume a ?step= after LAN move"
grep -q 'setup_pending_clear' "$LIB" || fail "staging dir must be clearable"
grep -q 'SETUP_PENDING_DIR' "$LIB" || fail "setup-pending dir missing"
awk '/^setup_clear_markers/,/^}$/' "$LIB" | grep -q SETUP_PENDING_DIR \
	|| fail "factory reset must clear staged Setup"
# D4 (review 2026-10-10): wait-page service worker retired — stub only
# unregisters; no page registers it; shell.js unregisters existing ones.
grep -q 'registration.unregister' "$ROOT/files/www/knots/wait-sw.js" \
	|| fail "wait-sw.js must be the self-unregistering stub"
! grep -q 'serviceWorker.register' "$ROOT"/files/www/knots/*.html \
	|| fail "no page may register the retired wait-sw.js"
grep -q 'getRegistrations' "$ROOT/files/www/knots/shell.js" \
	|| fail "shell.js must unregister the retired service worker"
grep -qi 'Skip' "$HTML" || fail "WAN/TLS Skip allowed in UI"
pass "WAN DHCP/PPPoE + Skip (R10a)"

# Node: Core default (recommended) + Knots choice
grep -qi 'Knots' "$HTML" || fail "Knots choice in HTML"
grep -q 'value="core" checked' "$HTML" || fail "Core must be the default (checked) node choice"
grep -q '(recommended)' "$HTML" || fail "recommended marker on default node"
pass "Bitcoin node Core default + Knots choice"

# TLS step: OS panels + primary CTA; OS tabs always visible (outside collapsed help)
for os in windows mac linux; do
	grep -q "data-os=\"$os\"" "$HTML" || fail "TLS panel/tab missing for $os"
done
for os in ios android; do   # Setup is laptop/computer only (2026-10-25)
	! grep -q "data-os=\"$os\"" "$HTML" || fail "phone/tablet TLS panel/tab must be gone: $os"
done
grep -q 'id="phoneOnly"' "$HTML" || fail "phone/tablet 'use a laptop or computer' panel missing"
grep -q 'tlsPrimaryCta' "$HTML" || fail "primary TLS CTA missing"
grep -q 'Enable Secure Connection' "$HTML" || fail "Enable Secure Connection CTA missing"
grep -q 'id="tlsOsTabs"' "$HTML" || fail "OS tabs missing"
awk '/id="tlsOsTabs"/,/<\/div>/' "$HTML" | grep 'data-os="mac"' | grep -q hidden \
	|| fail "macOS tab must be hidden for now"
awk 'BEGIN{inhelp=0} /id="tlsHelp"/{inhelp=1} /<\/details>/{if(inhelp){inhelp=0}} inhelp && /id="tlsOsTabs"/{found=1} END{exit found?0:1}' "$HTML" \
	&& fail "OS tabs must be outside Step-by-step help (tlsHelp)"
grep -q 'tlsHelp").open = false' "$JS" || fail "tlsHelp must start collapsed on Security entry"
! grep -q 'tlsOpenHelp' "$JS" || fail "tlsHelp must stay collapsed (no auto-open)"
grep -q 'details:not(\[open\])' "$CSS" || fail "collapsed details must hide panel content"
! grep -q 'detectedOnly' "$JS" \
	|| fail "setup.js must show OS tabs (not detectedOnly)"
grep -q 'tlsLinuxImportant' "$HTML" || fail "Linux Terminal Important callout missing"
# Owner 2026-10-25: every OS has its button + numbered steps ON screen (Linux:
# the Ubuntu/Debian/Mint package), not tucked into the collapsed help.
grep -q 'id="tlsLinuxCta"' "$HTML" || fail "Linux Enable Secure Connection button missing"
awk 'BEGIN{inhelp=0} /id="tlsHelp"/{inhelp=1} /<\/details>/{if(inhelp){inhelp=0}} inhelp && /id="tlsLinuxCta"/{found=1} END{exit found?0:1}' "$HTML" \
	&& fail "Linux Enable Secure Connection button must be on screen, not inside tlsHelp"
grep -q 'applyTlsOsLayout' "$JS" || fail "setup.js must switch Linux vs Windows Security layout"
grep 'id="tlsTopCtaWrap"' "$HTML" | grep -q hidden \
	|| fail "top Enable Secure Connection must start hidden (Linux has none at top)"
grep -q 'tls-actions\[hidden\]' "$CSS" || fail "flex tls-actions must not override hidden"
grep -q 'Firefox closes for a moment and reopens on the secure Setup page by itself' "$HTML" || fail "Linux Terminal fallback must say Firefox reopens by itself"
! grep -q 'fastest way is one command' "$HTML" \
	|| fail "Linux must not repeat the fastest-way one-command intro"
! grep -q 'Still not secure in Firefox' "$JS" \
	|| fail "must not show Firefox manual CA import stall text"
grep -q 'Windows asks whether to run it — click <strong>Run</strong>' "$HTML" || fail "Windows steps must cover the Run prompt"
grep -q 'Do you want to allow this app to make changes?” — click <strong>Yes</strong>' "$HTML" || fail "Windows steps must cover the UAC prompt"
grep -q 'enterTlsTrust' "$JS" || fail "Welcome must enter TLS first"
grep -q 'btnWelcome.*enterTlsTrust\|enterTlsTrust()' "$JS" || fail "Welcome→TLS navigation"
# Welcome onclick calls enterTlsTrust (not enterLocale)
awk '/btnWelcome.*onclick/,/^  \};/' "$JS" | grep -q enterTlsTrust \
	|| fail "btnWelcome must call enterTlsTrust first"
grep -q 'finishTlsTrust\|verifyHttpsTrust\|after_tls' "$JS" \
	|| fail "setup.js must auto-verify HTTPS after TLS step"
grep -q 'luciProbeUrl\|:8443' "$JS" \
	|| fail "setup.js must probe Router settings :8443 (advisory)"
grep -q 'never block Continue on LuCI\|brief LuCI check' "$JS" \
	|| fail "Continue must not hard-require LuCI probe"
grep -q 'softReloadAfterTrust\|knots_tls_reloaded' "$JS" \
	|| fail "setup.js must soft-reload when trust not yet active"
grep -q 'sh "\$f" http://' "$JS" \
	|| fail "Linux one-liner must pass http://host into install-linux.sh"
grep -q 'reopen_setup_https' "$ROOT/files/www/knots/tls/install-linux.sh" \
	|| fail "install-linux.sh must reopen Firefox on HTTPS Setup"
grep -q 'class="copyable"' "$HTML" || fail "setup.html must offer Copy buttons for trust text"
grep 'id="tlsLinuxOneLinerWrap"' "$HTML" | grep -q copyable \
	|| fail "Linux wget one-liner wrap must be copyable (Copy must find a row)"
grep -Fq '.copyable, [data-copy]' "$ROOT/files/www/knots/tls-os.js" \
	|| fail "Copy delegation must match [data-copy] as well as .copyable"
# R10a: inline display:flex on the ISP modal ignores hidden — DHCP never visible
! grep -E 'quickPppoeModal[^>]*display:[[:space:]]*flex' "$HTML" \
	|| fail "quickPppoeModal must not use inline display:flex (hidden is ignored)"
grep -q 'setup-modal' "$HTML" || fail "quickPppoeModal must use setup-modal class"
grep -q 'setup-modal\[hidden\]' "$ROOT/files/www/knots/app.css" \
	|| fail "app.css must hide .setup-modal[hidden]"
grep -q 'enterQuick' "$JS" || fail "enterQuick missing"
awk '/function enterQuick/,/^  }/' "$JS" | grep -q 'wan_dhcp' \
	|| fail "enterQuick must POST wan_dhcp (DHCP first)"
awk '/function enterQuick/,/^  }/' "$JS" | grep -q 'quickPppoeModal.hidden = false' \
	&& fail "enterQuick must not show ISP modal before DHCP"
awk '/function quickWanDown/,/^  }/' "$JS" | grep -q 'quickPppoeModal' \
	|| fail "ISP modal only after DHCP gives no address (quickWanDown)"
grep -q 'bindCopyButtons' "$ROOT/files/www/knots/tls-os.js" || fail "tls-os.js must bind Copy buttons"
grep -q 'installCopyDelegation\|data-knots-copy-delegated' "$ROOT/files/www/knots/tls-os.js" \
	|| fail "tls-os.js must use click delegation for Copy"
grep -q 'legacyCopy\|execCommand' "$ROOT/files/www/knots/tls-os.js" \
	|| fail "tls-os.js must fall back when clipboard API rejects"
pass "HTTPS trust first + OS-only guidance (N13/U17)"

# i18n assets for U19
for f in en es de fr zh-cn ja pt-br; do
	test -f "$ROOT/files/www/knots/i18n/$f.json" || fail "missing i18n/$f.json"
done
test -f "$ROOT/files/www/knots/i18n/regions.json" || fail "missing regions.json"
# X9 (review 2026-10-11): every locale carries every en.json key (no silent
# English fallback on the Setup screens), flat keys only.
python3 -I - "$ROOT/files/www/knots/i18n" <<'PYI' || fail "i18n key parity (see above)"
import json, sys, os
d = sys.argv[1]
en = json.load(open(os.path.join(d, "en.json")))
bad = 0
for f in sorted(os.listdir(d)):
    if not f.endswith(".json") or f in ("en.json", "regions.json"):
        continue
    L = json.load(open(os.path.join(d, f)))
    miss = [k for k in en if k not in L]
    nested = [k for k, v in L.items() if isinstance(v, dict)]
    if miss or nested:
        bad = 1
        print(f"{f}: missing {miss[:5]}{'…' if len(miss) > 5 else ''} nested {nested}")
sys.exit(bad)
PYI
pass "U19 language packs + regions catalog"

# nginx exposes /api/setup
grep -q 'location /api/setup' "$NGINX" || fail "nginx /api/setup"
pass "nginx Setup API proxy"

# rnode.local must be republished after factory reset / LAN ifup (U17)
AN="$ROOT/files/usr/libexec/knots/factory/apply-network.sh"
HP="$ROOT/files/etc/hotplug.d/iface/95-knots-avahi"
grep -q 'rnode\.local' "$AN" || fail "apply-network must restore /etc/hosts rnode.local"
grep -q 'avahi-daemon' "$AN" || fail "apply-network must enable avahi"
test -f "$HP" || fail "missing iface hotplug 95-knots-avahi"
grep -q 'avahi-daemon restart' "$HP" || fail "lan ifup must restart avahi"
grep -q 'rnode-2' "$HP" || fail "avahi hotplug must recover rnode-2.local rename"
grep -q 'publish-aaaa-on-ipv4=no' "$ROOT/files/etc/avahi/avahi-daemon.conf" \
	|| fail "avahi must not publish AAAA on IPv4 (Ubuntu Happy Eyeballs)"
awk '/^setup_finish_and_respond\(\)/,/^}/' "$API" | grep -q 'https://rnode.local/' \
	|| fail "complete must open Node Status at rnode.local, not the LAN IP"
awk '/^	complete\)/,/^	;;/' "$API" | grep -q 'https://\${lan_ip}' \
	&& fail "complete must not redirect to https://<lan-ip>"
grep -q 'https://rnode.local/' "$API" || fail "quickstart/complete must redirect to rnode.local"
grep -q 'function nodeStatusUrl' "$JS" || fail "setup.js must build Node Status on the D2 host"
grep -q 'function hostIsAppliance' "$SHELLJS" && grep -q ': "rnode.local"' "$SHELLJS" \
	|| fail "shell.js must keep the D2 host (names / private IPv4) with rnode.local fallback"
grep -q 'appUrl: applianceUrl' "$SHELLJS" \
	|| fail "shell.js must export KnotsIue.appUrl for named-host pages"
UPG_JS="$ROOT/files/www/knots/upgrade.js"
RST_JS="$ROOT/files/www/knots/reset.js"
TLS_HTML="$ROOT/files/www/knots/tls.html"
SET_JS="$ROOT/files/www/knots/settings.js"
grep -q 'rnode.local' "$UPG_JS" || fail "upgrade.js must finish at rnode.local"
grep -E 'ROUTER_FALLBACK_HOST|"https://" \+ "192\.168\.1\.254"|http://192\.168\.1\.254' "$UPG_JS" \
	&& fail "upgrade.js must not hardcode 192.168.1.254 navigation" || true
grep -q 'rnode.local' "$RST_JS" || fail "reset.js must finish at rnode.local"
grep -q 'http://192.168.1.254' "$RST_JS" \
	&& fail "reset.js must not redirect to 192.168.1.254" || true
grep -q 'https://rnode.local/' "$TLS_HTML" || fail "tls.html must show https://rnode.local/"
grep -q 'https://192.168.1.254' "$TLS_HTML" \
	&& fail "tls.html must not send users to 192.168.1.254" || true
grep -q 'namedPage' "$SET_JS" || fail "settings.js must open upgrade/reset via namedPage"
grep -q 'return 302 https://$knots_rhost/' "$NGINX" \
	|| fail "legacy :21443 must redirect to the D2 host"
grep -q 'showLinkDown' "$UPG_JS" || fail "upgrade.js must stay on the wait page while LAN is down"
! grep -q 'bounceHost' "$UPG_JS" || fail "upgrade.js must not bounce during reboot"
pass "rnode.local hosts + avahi republish after LAN ifup"

# Validation matrix (host-pure mirror of setup-lib wifi/password gates)
wifi_ok() {
	ssid=$1; key=$2; country=$3
	[ -n "$ssid" ] || return 1
	[ "${#ssid}" -le 32 ] || return 1
	[ "${#key}" -ge 8 ] || return 1
	[ "${#key}" -le 63 ] || return 1
	country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
	case "$country" in
		00|[A-Z][A-Z]) ;;
		*) return 1 ;;
	esac
	return 0
}
wifi_ok rnode 'password1' AU || fail "valid wifi should pass"
wifi_ok rnode 'password1' 00 || fail "country 00 (world regulatory) must pass"
wifi_ok rnode short AU && fail "key<8 must fail" || true
wifi_ok rnode "$(printf 'x%.0s' $(seq 1 64))" AU && fail "key>63 must fail" || true
wifi_ok '' 'password1' AU && fail "empty ssid must fail" || true
wifi_ok rnode 'password1' '' && fail "empty country must fail" || true
wifi_ok rnode 'password1' 0 && fail "single-digit country must fail" || true
pass "Wi‑Fi validation matrix (edge cases)"

pw_ok() {
	pass=$1
	[ -n "$pass" ] || return 1
	[ "${#pass}" -ge 8 ] || return 1
	[ "$pass" != "knotsnode21" ] || return 2
	return 0
}
pw_ok 'newpass99' || fail "good password"
pw_ok 'short' && fail "short password" || true
rc=0
pw_ok 'knotsnode21' || rc=$?
[ "$rc" -eq 2 ] || fail "factory password must return 2 (got $rc)"
pass "password validation matrix"

# .85 UAT-IQ-3: the boot status call must not reset to Welcome after the user
# already pressed Continue (race after a factory reset, slow first CGI).
awk '/var boot = Promise.resolve\(\);/,/bindLuciLink/' "$JS" | grep -q 'showStep(0)' \
	&& fail "boot must use welcomeUnlessMoved(), not showStep(0)"
grep -q 'userLeftWelcome = true;' "$JS" || fail "Welcome Continue must mark userLeftWelcome"
pass "boot never throws the user back to Welcome after Continue"

echo "ALL PASS: test-iue-flow"
