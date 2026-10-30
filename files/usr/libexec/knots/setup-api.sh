#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# First-run Setup API — U17 / TECH_SPEC §7.6
set -e

# shellcheck disable=SC1091
. /usr/libexec/knots/cgi-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/setup-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/factory-reset-ui.sh 2>/dev/null || true
. /usr/libexec/knots/upgrade-ui.sh 2>/dev/null || true
# shellcheck disable=SC1091
. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true

QS="${QUERY_STRING:-}"
if [ -n "${1:-}" ] && [ "$1" != "cgi" ]; then
	QS="$1"
fi

ACTION_PEEK=$(echo "$QS" | tr '&' '\n' | sed -n 's/^action=//p' | head -1)
ACTION_PEEK=$(urldecode_soft "$ACTION_PEEK")

if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ]; then
	body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null || cat)
	if [ -n "$QS" ]; then
		QS="${QS}&${body}"
	else
		QS="$body"
	fi
fi

qval() {
	echo "$QS" | tr '&' '\n' | sed -n "s/^${1}=//p" | head -1
}

ACTION=$(urldecode_soft "$(qval action)")
[ -n "$ACTION" ] || ACTION=status

json_escape_local() {
	json_escape "$1"
}

require_lan_or_fail() {
	require_lan_client || fail_json "wan_denied" "Setup is LAN-only"
}

# C1 — once Setup is complete the wizard API must stop answering mutating
# actions (U17: wizard is first-run only). Read-only status/wan_status stay
# open (UI polls them); upgrade_clear stays open (post-sysupgrade loop break).
# upgrade_resume is NOT a Setup action: it is the F125 recovery path used by the
# upgrade wait page precisely when Setup IS complete (keep-config upgrade whose
# apply worker died pre-reboot) — it is gated by the verified pending marker
# below instead (H4), not by this check.
setup_complete_check() {
	[ -f /etc/knots/setup-complete ] || return 0
	case "$ACTION" in
		locale|password|wan_dhcp|wan_pppoe|wifi|node|lan|complete|quickstart)
			fail_json "setup_complete" "Setup is already complete"
			;;
	esac
}

setup_complete_check

# Shared tail of Guided `complete` and Quick Start: apply staged values
# together, mark Setup complete, clear the staging dir (plaintext Wi-Fi key),
# answer, then run the network cutover + node switch detached.
setup_finish_and_respond() {
	cut=$(setup_apply_staged_finish) || \
		fail_json "finish_failed" "Could not apply setup settings — nothing was changed"
	# shellcheck disable=SC2086
	set -- $cut
	old_ip=$1 new_ip=$2 old_mask=$3 wifi_reload=$4 lan_cfg=$5 dhcp_chg=$6 node_target=$7
	setup_mark_complete
	setup_pending_clear
	on_wifi=false
	setup_client_on_wifi && on_wifi=true
	wssid=$(uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null || echo rnode)
	wifi_reconnect=false
	if [ "$on_wifi" = true ] && { [ "$wifi_reload" = 1 ] || [ "$old_ip" != "$new_ip" ]; }; then
		wifi_reconnect=true
	fi
	lan_moved=false
	[ "$old_ip" != "$new_ip" ] && lan_moved=true
	cgi_headers
	printf '{"ok":true,"wifi_reconnect":%s,"lan_moved":%s,"ssid":"%s","lan_ip":"%s","message":"Setup complete.","redirect":"https://rnode.local/"}\n' \
		"$wifi_reconnect" "$lan_moved" "$(json_escape_local "$wssid")" "$(json_escape_local "$new_ip")"
	exec 1>/dev/null 2>/dev/null || true
	setup_schedule_cutover "$old_ip" "$new_ip" "$old_mask" "$wifi_reload" "$lan_cfg" "$dhcp_chg" "$node_target"
	exit 0
}

# S3 (review 2026-10-10) — every non-read action is POST + same-origin. Before
# this, `<img src="http://rnode.local/api/setup?action=password&…">` on any web
# page set the root password of an un-setup appliance.
case "$ACTION" in
	status|wan_status) require_same_origin ;;
	*) require_mutating_post ;;
esac

case "$ACTION" in
	status)
		# C9: a reset whose worker died leaves the pending marker → endless
		# reset page. Reap it (see factory_reset_ui_reap_stale).
		command -v factory_reset_ui_reap_stale >/dev/null 2>&1 && factory_reset_ui_reap_stale
		complete=false
		setup_is_complete && complete=true
		pw_done=false
		setup_password_done && pw_done=true
		locale_done=false
		setup_locale_done && locale_done=true
		wifi_av=false
		setup_wifi_available && wifi_av=true
		if setup_pending_has node_impl; then
			impl=$(setup_pending_get node_impl)
		else
			impl=$(setup_current_impl)
		fi
		case "$impl" in knots) ;; *) impl=core ;; esac
		wan_line=$(setup_wan_status_line)
		wan_up=$(echo "$wan_line" | awk '{print $1}')
		wan_proto=$(echo "$wan_line" | awk '{print $2}')
		wan_ip=$(echo "$wan_line" | awk '{print $3}')
		lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.254)
		lan_mask=$(uci -q get network.lan.netmask 2>/dev/null || echo 255.255.255.0)
		dhcp_start=$(uci -q get dhcp.lan.start 2>/dev/null || echo 100)
		dhcp_limit=$(uci -q get dhcp.lan.limit 2>/dev/null || echo 101)
		if setup_pending_has lan_ipaddr; then
			lan_ip=$(setup_pending_get lan_ipaddr)
			lan_mask=$(setup_pending_get lan_netmask 2>/dev/null || echo "$lan_mask")
			dhcp_start=$(setup_pending_get lan_dhcp_start 2>/dev/null || echo "$dhcp_start")
			dhcp_limit=$(setup_pending_get lan_dhcp_limit 2>/dev/null || echo "$dhcp_limit")
		fi
		ulang=$(setup_ui_lang)
		zonename=$(uci -q get system.@system[0].zonename 2>/dev/null || echo UTC)
		wcountry=
		[ -f /etc/knots/wifi-country ] && wcountry=$(tr -d '\r\n' </etc/knots/wifi-country)
		[ -n "$wcountry" ] || wcountry=$(uci -q get wireless.radio0.country 2>/dev/null || true)
		fr_active=false
		fr_live=false
		fr_sec=${FR_EXPECTED_SECONDS:-650}
		if command -v factory_reset_ui_is_active >/dev/null 2>&1 && factory_reset_ui_is_active; then
			fr_active=true
			if command -v factory_reset_ui_is_live >/dev/null 2>&1 && factory_reset_ui_is_live; then
				fr_live=true
			fi
			if [ -f /tmp/knots/factory-reset.active ]; then
				fr_sec=$(sed -n 's/.*"expected_seconds":\([0-9]*\).*/\1/p' /tmp/knots/factory-reset.active | head -1)
			elif [ -f /etc/knots/factory-reset-pending ]; then
				fr_sec=$(sed -n 's/.*"expected_seconds":\([0-9]*\).*/\1/p' /etc/knots/factory-reset-pending | head -1)
			fi
			[ -n "$fr_sec" ] || fr_sec=${FR_EXPECTED_SECONDS:-650}
		fi
		upg_live=false
		upg_sec=180
		upg_keep=true
		if command -v upgrade_ui_is_live >/dev/null 2>&1 && upgrade_ui_is_live; then
			# F123 — stale /tmp marker after sysupgrade must not block Setup
			# B13: also keep it while upgrade-apply is verifying / stopping the
			# node (before sysupgrade starts) — clearing it then killed the
			# upgrade wait page mid-apply.
			_apply_pid=$(cat /tmp/knots/upgrade-apply.lock/pid 2>/dev/null)
			if ! $complete && ! pgrep -x sysupgrade >/dev/null 2>&1 && \
				! pgrep -f '[s]ysupgrade ' >/dev/null 2>&1 && \
				! { [ -n "$_apply_pid" ] && kill -0 "$_apply_pid" 2>/dev/null; }; then
				upgrade_ui_clear
			else
				upg_live=true
				upg_sec=$(sed -n 's/.*"expected_seconds":\([0-9]*\).*/\1/p' /tmp/knots/upgrade.active | head -1)
				[ -n "$upg_sec" ] || upg_sec=180
				if command -v upgrade_ui_keep_config >/dev/null 2>&1; then
					upg_keep=$(upgrade_ui_keep_config)
				fi
			fi
		fi
		prog_step=
		prog_label=
		if command -v progress_steps_current_step >/dev/null 2>&1; then
			prog_step=$(progress_steps_current_step)
		fi
		if [ -z "$prog_step" ] && [ "$fr_active" = "true" ] && [ "$fr_live" = "false" ]; then
			prog_step=starting
		fi
		[ -n "$prog_step" ] || prog_step=none
		if command -v progress_steps_label >/dev/null 2>&1 && [ "$prog_step" != "none" ]; then
			prog_label=$(progress_steps_label "$prog_step")
		fi
		client_wifi=false
		setup_client_on_wifi && client_wifi=true
		# P1 — labelled unit (per-device secret on the label) vs unlabelled
		# (Wi-Fi off until Setup). Never expose the secret itself.
		factory_labelled=false
		knots_has_factory_secret && factory_labelled=true
		# P1 — is any radio enabled in UCI (unlabelled units: off until Setup)
		wifi_on=false
		if uci -q show wireless 2>/dev/null | grep -q '=wifi-device'; then
			for _dev in $(uci -q show wireless | sed -n 's/^wireless\.\([^=]*\)=wifi-device.*/\1/p'); do
				[ "$(uci -q get "wireless.${_dev}.disabled" 2>/dev/null || echo 0)" = 1 ] || wifi_on=true
			done
		fi
		wifi_staged=false
		setup_pending_has wifi_key && wifi_staged=true
		ok_raw "{\"ok\":true,\"complete\":${complete},\"password_done\":${pw_done},\"locale_done\":${locale_done},\"wifi_staged\":${wifi_staged},\"lang\":\"$(json_escape_local "$ulang")\",\"zonename\":\"$(json_escape_local "$zonename")\",\"country\":\"$(json_escape_local "$wcountry")\",\"wifi_available\":${wifi_av},\"client_wifi\":${client_wifi},\"factory_labelled\":${factory_labelled},\"wifi_on\":${wifi_on},\"node_impl\":\"$(json_escape_local "$impl")\",\"factory_reset_active\":${fr_active},\"factory_reset_live\":${fr_live},\"factory_reset_expected_seconds\":${fr_sec},\"upgrade_live\":${upg_live},\"upgrade_expected_seconds\":${upg_sec},\"upgrade_keep_config\":${upg_keep},\"progress_step\":\"$(json_escape_local "$prog_step")\",\"progress_label\":\"$(json_escape_local "$prog_label")\",\"wan\":{\"up\":${wan_up},\"proto\":\"$(json_escape_local "$wan_proto")\",\"ipv4\":\"$(json_escape_local "$wan_ip")\"},\"lan\":{\"ipaddr\":\"$(json_escape_local "$lan_ip")\",\"netmask\":\"$(json_escape_local "$lan_mask")\",\"dhcp_start\":\"$(json_escape_local "$dhcp_start")\",\"dhcp_limit\":\"$(json_escape_local "$dhcp_limit")\"}}"
		;;
	locale)
		require_lan_or_fail
		# Full %XX decode (form-encoded values): urldecode_soft only handles
		# +/%20 — slashed zonenames (Australia/Sydney → %2F) must decode or the
		# M4 charset check rejects every real IANA zone (IUE hard blocker).
		lang=$(urldecode "$(qval lang)")
		country=$(urldecode "$(qval country)")
		zonename=$(urldecode "$(qval zonename)")
		setup_locale_apply "$lang" "$country" "$zonename" || \
			fail_json "locale_failed" "Invalid language or timezone"
		applied_zn=$(uci -q get system.@system[0].zonename 2>/dev/null || true)
		applied_cc=$country
		[ -f /etc/knots/wifi-country ] && applied_cc=$(tr -d '\r\n' </etc/knots/wifi-country)
		ok_raw "{\"ok\":true,\"message\":\"Language and timezone saved.\",\"lang\":\"$(json_escape_local "$lang")\",\"country\":\"$(json_escape_local "$applied_cc")\",\"zonename\":\"$(json_escape_local "$applied_zn")\"}"
		;;
	password)
		require_lan_or_fail
		p1=$(urldecode "$(qval password)")
		p2=$(urldecode "$(qval password2)")
		[ "$p1" = "$p2" ] || fail_json "mismatch" "Passwords do not match"
		[ "${#p1}" -ge 8 ] || fail_json "too_short" "Password must be at least 8 characters"
		rc=0
		setup_set_root_password "$p1" || rc=$?
		if [ "$rc" -eq 2 ]; then
			fail_json "factory_forbidden" "Choose a new password — not the factory default"
		fi
		[ "$rc" -eq 0 ] || fail_json "passwd_failed" "Could not set admin password"
		ok_raw '{"ok":true,"message":"Admin password updated."}'
		;;
	wan_dhcp)
		require_lan_or_fail
		setup_wan_apply_dhcp
		ok_raw '{"ok":true,"message":"WAN set to DHCP — checking connection…"}'
		;;
	wan_pppoe)
		require_lan_or_fail
		u=$(urldecode "$(qval username)")
		p=$(urldecode "$(qval password)")
		setup_wan_apply_pppoe "$u" "$p" || fail_json "bad_pppoe" "Username and password required"
		ok_raw '{"ok":true,"message":"PPPoE applied — checking connection…"}'
		;;
	wan_status)
		wan_line=$(setup_wan_status_line)
		wan_up=$(echo "$wan_line" | awk '{print $1}')
		wan_proto=$(echo "$wan_line" | awk '{print $2}')
		wan_ip=$(echo "$wan_line" | awk '{print $3}')
		ok_raw "{\"ok\":true,\"up\":${wan_up},\"proto\":\"$(json_escape_local "$wan_proto")\",\"ipv4\":\"$(json_escape_local "$wan_ip")\"}"
		;;
	wifi)
		require_lan_or_fail
		setup_wifi_available || fail_json "no_radio" "Wi-Fi hardware not available"
		# Full %XX decode for free-text form fields (SSID may contain & % etc.)
		ssid=$(urldecode "$(qval ssid)")
		key=$(urldecode "$(qval key)")
		country=$(urldecode "$(qval country)")
		[ -n "$ssid" ] || ssid=rnode
		if setup_wifi_is_factory_key "$key"; then
			fail_json "factory_forbidden" "Choose a new Wi-Fi password — not the factory default"
		fi
		setup_wifi_stage "$ssid" "$key" "$country" || \
			fail_json "wifi_failed" "Could not save Wi-Fi (SSID max 32; password 8–63 chars; country required)"
		ok_raw "{\"ok\":true,\"staged\":true,\"ssid\":\"$(json_escape_local "$ssid")\",\"redirect\":\"https://rnode.local/setup.html?after_tls=1&step=8\",\"message\":\"Wi-Fi saved. It applies when you finish Setup.\"}"
		;;
	node)
		require_lan_or_fail
		impl=$(urldecode_soft "$(qval impl)")
		case "$impl" in knots|core) ;; *)
			fail_json "bad_impl" "Choose Bitcoin Knots or Bitcoin Core"
			;;
		esac
		nrc=0
		setup_node_stage "$impl" || nrc=$?
		if [ "$nrc" -eq 2 ]; then
			fail_json "node_missing" \
				"That node is not installed on this appliance yet (or the M.2 drive is not ready). Keep Bitcoin Core for setup, or install the other node later under Node software."
		fi
		[ "$nrc" -eq 0 ] || fail_json "node_failed" "Could not save node choice"
		ok_raw "{\"ok\":true,\"staged\":true,\"message\":\"Node set to $impl.\",\"node_impl\":\"$(json_escape_local "$impl")\"}"
		;;
	lan)
		require_lan_or_fail
		ip=$(urldecode_soft "$(qval ipaddr)")
		mask=$(urldecode_soft "$(qval netmask)")
		st=$(urldecode_soft "$(qval dhcp_start)")
		lim=$(urldecode_soft "$(qval dhcp_limit)")
		setup_lan_stage "$ip" "$mask" "$st" "$lim" || \
			fail_json "lan_failed" "Invalid LAN settings"
		ok_raw "{\"ok\":true,\"staged\":true,\"message\":\"LAN saved. It applies when you finish Setup.\",\"lan_ip\":\"$(json_escape_local "$ip")\"}"
		;;
	complete)
		require_lan_or_fail
		setup_locale_done || fail_json "locale_required" "Choose language and region before finishing"
		setup_password_done || fail_json "password_required" "Set a new admin password before finishing"
		# C1/C2: validate every staged value first, then apply together.
		setup_finish_validate || fail_json "$SETUP_ERR_CODE" "$SETUP_ERR_MSG"
		setup_finish_and_respond
		;;
	quickstart)
		# U17 Quick Start — one call applies all defaults for the non-technical
		# path: locale (browser-detected payload), admin password, node=Core
		# (default), WAN=DHCP, Wi-Fi SSID rnode + given key; then completes Setup.
		require_lan_or_fail
		lang=$(urldecode "$(qval lang)")
		country=$(urldecode "$(qval country)")
		zonename=$(urldecode "$(qval zonename)")
		p1=$(urldecode "$(qval password)")
		p2=$(urldecode "$(qval password2)")
		wkey=$(urldecode "$(qval wifipsk)")
		# C1 (review 2026-10-11): validate EVERYTHING before applying anything —
		# locale/password/node/WAN used to be applied before the Wi-Fi key was
		# checked, leaving a half-configured router on a bad key.
		[ "$p1" = "$p2" ] || fail_json "mismatch" "Passwords do not match"
		[ "${#p1}" -ge 8 ] || fail_json "too_short" "Password must be at least 8 characters"
		setup_is_factory_password "$p1" && \
			fail_json "factory_forbidden" "Choose a new password — not the factory default"
		SETUP_LOCALE_CHECK_ONLY=1 setup_locale_apply "$lang" "$country" "$zonename" || \
			fail_json "locale_failed" "Invalid language or timezone"
		if setup_wifi_available; then
			setup_wifi_is_factory_key "$wkey" && \
				fail_json "factory_forbidden" "Choose a new Wi-Fi password — not the factory default"
			setup_wifi_validate rnode "$wkey" "${country:-00}" || \
				fail_json "wifi_failed" "Wi-Fi password must be 8–63 characters"
		fi
		# Apply (validated above).
		setup_locale_apply "$lang" "$country" "$zonename" || \
			fail_json "locale_failed" "Invalid language or timezone"
		rc=0
		setup_set_root_password "$p1" || rc=$?
		[ "$rc" -eq 0 ] || fail_json "passwd_failed" "Could not set admin password"
		setup_wan_apply_dhcp
		if setup_wifi_available; then
			wcc=$(tr -d '\r\n' </etc/knots/wifi-country 2>/dev/null)
			setup_wifi_stage rnode "$wkey" "${wcc:-$FACTORY_WIFI_COUNTRY}" || \
				fail_json "wifi_failed" "Could not save Wi-Fi"
		fi
		# Node: Quick Start keeps the default (Core); switch only when Core is
		# installed — never fail Setup on a missing / preparing M.2.
		if [ "$(setup_current_impl)" != core ] && setup_node_can_set core; then
			setup_pending_set node_impl core
		fi
		setup_finish_validate || fail_json "$SETUP_ERR_CODE" "$SETUP_ERR_MSG"
		setup_finish_and_respond
		;;
	factory_reset_clear)
		# End reset-page loop: clear pending/active so UI can enter Setup
		require_lan_or_fail
		if command -v factory_reset_ui_clear >/dev/null 2>&1; then
			factory_reset_ui_clear
		else
			rm -f /tmp/knots/factory-reset.active /etc/knots/factory-reset-pending 2>/dev/null || true
		fi
		ok_raw '{"ok":true,"message":"Factory reset UI cleared."}'
		;;
	upgrade_clear)
		# End upgrade-page loop: clear /tmp marker so Settings is reachable
		require_lan_or_fail
		if command -v upgrade_ui_clear >/dev/null 2>&1; then
			upgrade_ui_clear
		else
			rm -f /tmp/knots/upgrade.active 2>/dev/null || true
		fi
		ok_raw '{"ok":true,"message":"Upgrade UI cleared."}'
		;;
	upgrade_resume)
		# F125 — retry sysupgrade when CGI died after upload (image still on /tmp)
		# H4 — no auth here (the wait page has no credentials to give); the gate is
		# the pending marker, written ONLY after an authenticated + hash-verified
		# upload (settings-api action=upgrade), and upgrade-apply.sh re-verifies
		# the recorded sha256 against the staged image before flashing.
		require_lan_or_fail
		[ -f /tmp/knots/upgrade-pending ] || \
			fail_json "no_pending" "No verified upgrade pending — upload again from Settings"
		# U2/B4: a stale pending record must not let an unauthenticated
		# request re-flash an image long after the authenticated upload.
		_pend_age=$(( $(date +%s) - $(date -r /tmp/knots/upgrade-pending +%s 2>/dev/null || echo 0) ))
		[ "$_pend_age" -le 1800 ] || \
			fail_json "pending_expired" "The uploaded upgrade is older than 30 minutes — upload again from Settings"
		if pgrep -x sysupgrade >/dev/null 2>&1 || pgrep -f '[s]ysupgrade ' >/dev/null 2>&1; then
			ok_raw '{"ok":true,"message":"sysupgrade already running"}'
		fi
		_apply_pid=$(cat /tmp/knots/upgrade-apply.lock/pid 2>/dev/null)
		if [ -n "$_apply_pid" ] && kill -0 "$_apply_pid" 2>/dev/null; then
			ok_raw '{"ok":true,"message":"upgrade apply worker already running"}'
		fi
		[ -s /tmp/knots-upgrade.itb ] || fail_json "no_image" "No upgrade image on appliance — upload again from Settings"
		# setsid (busybox has it; nohup is absent on this build) — F125 detach
		setsid /usr/libexec/knots/upgrade-apply.sh >>/tmp/knots/upgrade.log 2>&1 </dev/null &
		ok_raw '{"ok":true,"message":"Upgrade apply worker started"}'
		;;
	*)
		fail_json "bad_action" "Unknown action"
		;;
esac
