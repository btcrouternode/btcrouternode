#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Settings API — U12–U15 / U18 / R14 / B22–B23 (TECH_SPEC §7.4)
# Reuses cgi-lib, node-impl-lib busy flags, bitcoind-ctl, bitcoin-conf-lib,
# and the same POST-body upload pattern as node-impl-api install.
set -e

# shellcheck disable=SC1091
. /usr/libexec/knots/cgi-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/node-impl-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/bitcoin-conf-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/bitcoind-ctl.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/setup-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/factory-reset-ui.sh 2>/dev/null || true
. /usr/libexec/knots/upgrade-ui.sh 2>/dev/null || true
# shellcheck disable=SC1091
. /usr/libexec/knots/release-sig.sh 2>/dev/null || true
# shellcheck disable=SC1091
. /usr/libexec/knots/unit-name.sh 2>/dev/null || true
# shellcheck disable=SC1091
. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true

QS="${QUERY_STRING:-}"
if [ -n "${1:-}" ] && [ "$1" != "cgi" ]; then
	QS="$1"
fi

ACTION_PEEK=$(echo "$QS" | tr '&' '\n' | sed -n 's/^action=//p' | head -1)
ACTION_PEEK=$(urldecode_soft "$ACTION_PEEK")

# Merge form POST into QS except upgrade / advanced conf_save (raw body).
# M2 — size-gate BEFORE reading the body: 64 KiB form cap; the upgrade image
# is bounded on the CONTENT_LENGTH header before anything is written to /tmp.
if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ]; then
	case "$CONTENT_LENGTH" in
		''|*[!0-9]*) fail_json "bad_length" "Invalid Content-Length" ;;
	esac
	case "$ACTION_PEEK" in
		upgrade)
			# U13/R14 — reject before the body is written to tmpfs
			if [ "$CONTENT_LENGTH" -lt 8388608 ] || [ "$CONTENT_LENGTH" -gt 268435456 ]; then
				fail_json "bad_size" "Image size out of range (8–256 MiB)"
			fi
			;;
		conf_save)
			[ "$CONTENT_LENGTH" -le 65536 ] || \
				fail_json "too_large" "Request body too large"
			ADV_PEEK=$(echo "$QS" | tr '&' '\n' | sed -n 's/^advanced=//p' | head -1)
			ADV_PEEK=$(urldecode_soft "$ADV_PEEK")
			if [ "$ADV_PEEK" = "1" ] || [ "$ADV_PEEK" = "true" ]; then
				:
			else
				body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null || cat)
				if [ -n "$QS" ]; then
					QS="${QS}&${body}"
				else
					QS="$body"
				fi
			fi
			;;
		*)
			[ "$CONTENT_LENGTH" -le 65536 ] || \
				fail_json "too_large" "Request body too large"
			body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null || cat)
			if [ -n "$QS" ]; then
				QS="${QS}&${body}"
			else
				QS="$body"
			fi
			;;
	esac
fi

qval() {
	echo "$QS" | tr '&' '\n' | sed -n "s/^${1}=//p" | head -1
}

ACTION=$(urldecode_soft "$(qval action)")
[ -n "$ACTION" ] || ACTION=status

product_version() {
	cat /etc/knots/product_version 2>/dev/null || echo unknown
}

# Written during appliance upgrade so the UI can poll phase (U13 UX).
upgrade_status_write() {
	mkdir -p /tmp/knots
	printf '{"phase":"%s","detail":"%s","bytes":%s,"ts":"%s"}\n' \
		"$(json_escape "$1")" "$(json_escape "$2")" "${3:-0}" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/tmp/knots/upgrade-status.json
}

upgrade_status_json() {
	if [ -f /tmp/knots/upgrade-status.json ]; then
		cat /tmp/knots/upgrade-status.json
	elif [ -f /tmp/knots/upgrade-pending ]; then
		printf '{"phase":"applying","detail":"sysupgrade pending reboot","bytes":0,"ts":""}'
	else
		printf 'null'
	fi
}

case "$ACTION" in
	status)
		pv=$(product_version)
		conf_ok=false
		[ -f "$CONF_HOST" ] && conf_ok=true
		upg=$(upgrade_status_json)
		node_running=false
		if bitcoind_ctl_bitcoind_alive; then
			node_running=true
		fi
		rsig_req=false
		command -v release_sig_required >/dev/null 2>&1 && release_sig_required && rsig_req=true
		reindex_running=false
		if bitcoind_ctl_reindex_running; then
			reindex_running=true
		fi
		# P4 — CA fingerprint for out-of-band comparison (Settings is reached
		# over trusted HTTPS) and whether it is the restricted (P3) CA.
		ca_sha256=
		ca_constrained=false
		if [ -f /etc/knots/tls/ca.pem ]; then
			ca_sha256=$(openssl x509 -in /etc/knots/tls/ca.pem -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
			openssl x509 -in /etc/knots/tls/ca.pem -noout -text 2>/dev/null | \
				grep -q 'X509v3 Name Constraints: critical' && ca_constrained=true
		fi
		# L1 — clients (UI, UAT) wait for node_busy=false before the next
		# node action; node_running alone flips before a restart worker ends.
		node_busy=false
		busy_msg=
		busy_line=$(read_node_busy)
		case "$busy_line" in
			true\|*) node_busy=true; busy_msg=${busy_line#true|*|} ;;
		esac
		ulang=$(setup_ui_lang)
		command -v factory_reset_ui_reap_stale >/dev/null 2>&1 && factory_reset_ui_reap_stale
		fr_active=false
		fr_live=false
		fr_sec=${FR_EXPECTED_SECONDS:-650}
		if command -v factory_reset_ui_is_live >/dev/null 2>&1 && factory_reset_ui_is_live; then
			fr_live=true
		fi
		if command -v factory_reset_ui_is_active >/dev/null 2>&1 && factory_reset_ui_is_active; then
			fr_active=true
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
			upg_live=true
			upg_sec=$(sed -n 's/.*"expected_seconds":\([0-9]*\).*/\1/p' /tmp/knots/upgrade.active | head -1)
			[ -n "$upg_sec" ] || upg_sec=180
			if command -v upgrade_ui_keep_config >/dev/null 2>&1; then
				upg_keep=$(upgrade_ui_keep_config)
			fi
		fi
		prog_step=
		prog_label=
		if command -v progress_steps_current_step >/dev/null 2>&1; then
			prog_step=$(progress_steps_current_step)
		fi
		if [ -z "$prog_step" ] && [ "$fr_active" = "true" ]; then
			prog_step=starting
		fi
		[ -n "$prog_step" ] || prog_step=none
		if command -v progress_steps_label >/dev/null 2>&1 && [ "$prog_step" != "none" ]; then
			prog_label=$(progress_steps_label "$prog_step")
		fi
		ok_json "$(printf \
			'{"ok":true,"product_version":"%s","flash_id":"%s","unit_name":"%s","release_sig_required":%s,"build_channel":"%s","conf_path":"%s","conf_present":%s,"upgrade":%s,"ca_sha256":"%s","ca_constrained":%s,"node_running":%s,"node_busy":%s,"busy_message":"%s","reindex_running":%s,"last_op":%s,"lang":"%s","upgrade_confirm":"UPGRADE","save_confirm":"SAVE","advanced_confirm":"ADVANCED","language_confirm":"LANGUAGE","stop_confirm":"STOP","start_confirm":"START","reboot_confirm":"REBOOT","shutdown_confirm":"SHUTDOWN","factory_reset_confirm":"RESET","factory_reset_expected_seconds":%s,"factory_reset_active":%s,"factory_reset_live":%s,"upgrade_live":%s,"upgrade_expected_seconds":%s,"upgrade_keep_config":%s,"progress_step":"%s","progress_label":"%s","note":"Upgrade never wipes the blockchain (NF9). Paste the published SHA256 before upgrading (U13). Knots/Core binaries stay under Node software. Every change needs router username/password (U15). Factory reset never wipes M.2 (N3/S7)."}' \
			"$(json_escape "$pv")" "$(json_escape "$(head -c 64 /etc/knots/flash-id 2>/dev/null)")" "$(json_escape "$(knots_unit_name 2>/dev/null || true)")" "$rsig_req" "$(json_escape "$(head -c 16 /etc/knots/build_channel 2>/dev/null)")" "$(json_escape "$CONF_HOST")" "$conf_ok" "$upg" "$(json_escape "$ca_sha256")" "$ca_constrained" "$node_running" "$node_busy" "$(json_escape "$busy_msg")" "$reindex_running" "$(node_op_result_json)" "$(json_escape "$ulang")" "$fr_sec" "$fr_active" "$fr_live" "$upg_live" "$upg_sec" "$upg_keep" "$(json_escape "$prog_step")" "$(json_escape "$prog_label")" )"
		;;
	locale)
		# U19 — Settings language (Knots UI + LuCI); U15 auth required
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "LANGUAGE" ] || fail_json "confirm_required" "Type LANGUAGE to apply UI language"
		lang=$(urldecode_soft "$(qval lang)")
		[ -n "$lang" ] || fail_json "bad_lang" "Language required"
		setup_ui_lang_apply "$lang" || fail_json "bad_lang" "Unsupported language"
		ok_json "$(printf '{"ok":true,"message":"UI language updated for Knots and LuCI.","lang":"%s"}' \
			"$(json_escape "$(setup_ui_lang)")")"
		;;
	conf)
		[ -f "$CONF_HOST" ] || fail_json "no_conf" "bitcoin.conf not found"
		safe=$(conf_safe_json_map)
		# S4 — rpcauth/rpcpassword values never leave the router (<hidden>).
		# json_escape (rpc.sh) is busybox-safe; the old inline awk gsub with
		# backslash replacements produced invalid JSON on busybox for \ or ".
		raw="$(json_escape "$(conf_redact "$CONF_HOST")")\\n"
		ok_json "$(printf '{"ok":true,"safe":%s,"raw":"%s"}' "$safe" "$raw")"
		;;
	conf_save)
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "SAVE" ] || fail_json "confirm_required" "Type SAVE to apply bitcoin.conf"
		[ -f "$CONF_HOST" ] || fail_json "no_conf" "bitcoin.conf not found"
		# L1 — never rewrite the conf / restart under another node operation.
		require_node_idle conf "Applying bitcoin.conf — restarting node"

		ADV=$(urldecode_soft "$(qval advanced)")
		if [ "$ADV" = "1" ] || [ "$ADV" = "true" ]; then
			CADV=$(urldecode_soft "$(qval confirm_advanced)")
			[ "$CADV" = "ADVANCED" ] || \
				fail_json "confirm_required" "Type ADVANCED for raw editor save"
			tmp=$(mktemp) || fail_json "temp" "mktemp failed"
			# Raw body = conf text (query carries auth + confirms)
			cat >"$tmp"
			[ -s "$tmp" ] || {
				rm -f "$tmp"
				fail_json "empty_conf" "Raw conf body empty"
			}
			err=$(conf_write_raw_validated "$tmp" 2>&1) || {
				rm -f "$tmp"
				fail_json "conf_rejected" "$err"
			}
			rm -f "$tmp"
		else
			pairs=$(mktemp) || fail_json "temp" "mktemp failed"
			for key in dbcache maxconnections maxmempool mempoolexpiry blocksonly peerbloomfilters; do
				val=$(urldecode_soft "$(qval "$key")")
				[ -n "$val" ] || continue
				conf_validate_value "$key" "$val" || {
					rm -f "$pairs"
					fail_json "bad_value" "Invalid value for $key"
				}
				echo "${key}=${val}" >>"$pairs"
			done
			[ -s "$pairs" ] || {
				rm -f "$pairs"
				fail_json "no_changes" "No allowlisted fields provided"
			}
			conf_apply_safe_pairs <"$pairs" || {
				rm -f "$pairs"
				fail_json "write_failed" "Could not write bitcoin.conf"
			}
			rm -f "$pairs"
			conf_assert_product_keys || fail_json "product_keys" "Product-required conf keys missing after save"
		fi

		# F204 — do not wait on bitcoind in CGI (uhttpd 502 HTML).
		# L1 — the restart worker owns the node-op lock until it has finished.
		# L2 — report what actually happened, not "restarted" regardless.
		cgi_node_worker conf-restart.log '. /usr/libexec/knots/bitcoind-ctl.sh
if bitcoind_ctl_restart; then
  node_op_result conf_restart ok "bitcoin.conf saved; node restarted."
elif bitcoind_ctl_bitcoind_alive; then
  node_op_result conf_restart ok "bitcoin.conf saved; node restarted and is still loading."
else
  echo stopped >/tmp/knots/knots.status
  node_op_result conf_restart failed "bitcoin.conf saved, but the node did not start again. Check the last change, or see the node log."
  exit 1
fi'
		ok_json '{"ok":true,"message":"bitcoin.conf saved; node restarting.","restarted":true}'
		;;
	node_stop)
		# U18 — stop bitcoind only (leave LXC for faster start)
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "STOP" ] || fail_json "confirm_required" "Type STOP to stop the node"
		# F204 — stop can take up to 90s; CGI must return JSON immediately.
		require_node_idle stop "Stopping Bitcoin node"
		# L1/L2 — worker owns the lock; status says "stopped" only if it is.
		cgi_node_worker node-stop.log '. /usr/libexec/knots/bitcoind-ctl.sh
mkdir -p /tmp/knots
bitcoind_ctl_stop || true
if bitcoind_ctl_bitcoind_alive; then
  echo running >/tmp/knots/knots.status
  node_op_result node_stop failed "The Bitcoin node is still running after the stop request. Try again."
  exit 1
fi
echo stopped >/tmp/knots/knots.status
node_op_result node_stop ok "Bitcoin node stopped."' node_stop
		ok_json '{"ok":true,"accepted":true,"message":"Bitcoin node stopping."}'
		;;
	node_start)
		# U18 — optional reindex=1; reindex_kind=chainstate (default) or full
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "START" ] || fail_json "confirm_required" "Type START to start the node"
		require_node_idle start "Starting Bitcoin node"
		if bitcoind_ctl_reindex_running; then
			fail_json "reindex_in_progress" \
				"A reindex is already in progress. Keep power on; wait for it to finish."
		fi
		if bitcoind_ctl_bitcoind_alive; then
			fail_json "already_running" \
				"Stop the Bitcoin node first. Start is only available when the node is stopped."
		fi
		REINDEX=$(urldecode_soft "$(qval reindex)")
		want_reindex=0
		case "$REINDEX" in 1|true|yes|on) want_reindex=1 ;; esac
		KIND=$(urldecode_soft "$(qval reindex_kind)")
		[ "$KIND" = "full" ] || KIND=chainstate
		if [ "$want_reindex" = 1 ]; then
			if [ "$KIND" = "full" ]; then
				set_node_busy reindex \
					"Rebuilding block index and chain database — not re-downloading the blockchain"
			else
				set_node_busy reindex \
					"Validating chain database (reindex) — not re-downloading the blockchain"
			fi
		else
			set_node_busy start "Starting Bitcoin node"
		fi
		# F204 — wait_rpc / reindex in CGI → uhttpd 502 HTML. Detach.
		start_work='. /usr/libexec/knots/bitcoind-ctl.sh
mkdir -p /tmp/knots
if ! lxc-info -n knots 2>/dev/null | grep -q RUNNING; then
  /usr/libexec/knots/knots-start.sh start || true
fi
# L2 — success only once a bitcoind process is really up.
node_up() {
  i=0
  while [ "$i" -lt 30 ]; do
    bitcoind_ctl_bitcoind_alive && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}
'
		if [ "$want_reindex" = 1 ]; then
			if [ "$KIND" = "full" ]; then
				start_work="${start_work}
bitcoind_ctl_reindex -reindex || true
if node_up; then echo recovering >/tmp/knots/knots.status; node_op_result node_start ok \"Full reindex running — keep power on.\"
else echo stopped >/tmp/knots/knots.status; node_op_result node_start failed \"The node did not start the reindex — see the node log.\"; exit 1; fi
"
			else
				start_work="${start_work}
bitcoind_ctl_reindex_chainstate || true
if node_up; then echo recovering >/tmp/knots/knots.status; node_op_result node_start ok \"Reindex running — keep power on.\"
else echo stopped >/tmp/knots/knots.status; node_op_result node_start failed \"The node did not start the reindex — see the node log.\"; exit 1; fi
"
			fi
		else
			start_work="${start_work}
bitcoind_ctl_start || true
if node_up; then echo running >/tmp/knots/knots.status; node_op_result node_start ok \"Bitcoin node started.\"
else echo stopped >/tmp/knots/knots.status; node_op_result node_start failed \"The Bitcoin node did not start — see the node log.\"; exit 1; fi
"
		fi
		cgi_node_worker node-start.log "$start_work" node_start
		if [ "$want_reindex" = 1 ]; then
			if [ "$KIND" = "full" ]; then
				ok_json '{"ok":true,"message":"Bitcoin node starting with a full reindex. Keep power on — this can take many hours. Not a blockchain re-download.","accepted":true,"reindex":true,"reindex_kind":"full"}'
			else
				ok_json '{"ok":true,"message":"Bitcoin node starting with reindex. Keep power on — validation can take many hours. Not a blockchain re-download.","accepted":true,"reindex":true,"reindex_kind":"chainstate"}'
			fi
		else
			ok_json '{"ok":true,"message":"Bitcoin node starting.","accepted":true}'
		fi
		;;
	reboot)
		# U18 — stop node then reboot (wrapper also stops; belt-and-suspenders)
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "REBOOT" ] || fail_json "confirm_required" "Type REBOOT to reboot the appliance"
		require_node_idle reboot "Stopping node and rebooting"
		# F201 — setsid so uhttpd :21444 does not kill the CGI child (F125).
		# L1 — holds the node-op lock until the reboot (busy no longer cleared
		# immediately while pre-reboot-stop is still stopping bitcoind).
		cgi_node_worker reboot.log '/usr/libexec/knots/pre-reboot-stop.sh || true; sleep 1; reboot'
		cgi_headers
		printf '%s\n' '{"ok":true,"message":"Stopping Bitcoin node and rebooting…"}'
		exit 0
		;;
	shutdown)
		# U18
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "SHUTDOWN" ] || fail_json "confirm_required" "Type SHUTDOWN to power off"
		require_node_idle shutdown "Stopping node and shutting down"
		# F201 — setsid so uhttpd :21444 does not kill the CGI child (F125).
		cgi_node_worker shutdown.log '/usr/libexec/knots/pre-reboot-stop.sh || true; sleep 1; poweroff'
		cgi_headers
		printf '%s\n' '{"ok":true,"message":"Stopping Bitcoin node and shutting down…"}'
		exit 0
		;;
	factory_reset)
		# N3 + U17 — soft system reset; never wipe M.2 (S7). Clears Setup markers.
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "RESET" ] || fail_json "confirm_required" "Type RESET to factory-reset the appliance"
		require_node_idle factory_reset "Factory reset — stopping node"
		# FIRST: arm reset page so any open LAN tab can navigate immediately
		if command -v factory_reset_ui_arm >/dev/null 2>&1; then
			factory_reset_ui_arm settings
		fi
		# F201 — same detach as upgrade (F125). Plain `&` dies with the CGI
		# process group on uhttpd :21444; sleep 2 stays inside the new session
		# so /reset.html can load before apply-network drops LAN.
		cgi_node_worker factory-reset.log 'sleep 2; /usr/sbin/factory-reset --confirm RESET'
		logger -t knots-settings "factory-reset worker pid=$CGI_SETSID_PID"
		cgi_headers
		printf '{"ok":true,"message":"Factory Reset in Progress","expected_seconds":%s,"setup_url":"/setup.html","reset_url":"/reset.html"}\n' "${FR_EXPECTED_SECONDS:-650}"
		exit 0
		;;
	tls_renew)
		# P3 / D3 — explicit "Renew certificate": new name-constrained CA +
		# leaf. Every device must re-install the CA afterwards (tls.html), so
		# this is never automatic.
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "RENEW" ] || fail_json "confirm_required" "Type RENEW to replace the HTTPS certificate"
		out=$(/usr/libexec/knots/node-ui-tls.sh node-router --rotate-ca 2>&1) || \
			fail_json "tls_failed" "Could not create a new certificate: $(printf '%s' "$out" | tail -1)"
		fp=$(openssl x509 -in /etc/knots/tls/ca.pem -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
		ok_json "$(printf '{"ok":true,"message":"New HTTPS certificate created. Install it again on each device (Install trust page) — the old one no longer works.","ca_sha256":"%s","tls_url":"/tls.html"}' "$(json_escape "$fp")")"
		;;
	upgrade)
		require_mutating_post
		require_auth_fields
		CONFIRM=$(urldecode_soft "$(qval confirm)")
		[ "$CONFIRM" = "UPGRADE" ] || fail_json "confirm_required" "Type UPGRADE to install appliance image"

		# U13 / R14 — required SHA256 from trusted release channel (paste field)
		EXPECT_RAW=$(urldecode_soft "$(qval sha256)")
		EXPECT=$(printf '%s' "$EXPECT_RAW" | tr 'A-F' 'a-f' | tr -d '\r' | awk '{print $1}')
		case "$EXPECT" in
			[0-9a-f][0-9a-f]*)
				[ "${#EXPECT}" -eq 64 ] || \
					fail_json "bad_sha256" "SHA256 must be exactly 64 hex characters (paste from the release page)"
				;;
			*)
				fail_json "sha256_required" \
					"Paste the SHA256 checksum from the release / checksum page before upgrading"
				;;
		esac

		# Filename hint — accept OpenWrt / lab *sysupgrade.itb|.bin (not SD card images)
		FNAME=$(urldecode_soft "$(qval filename)")
		case "$FNAME" in
			*sdcard*|*img.gz|*img.GZ)
				fail_json "bad_filename" \
					"That looks like an SD card image. Settings upgrade needs a *sysupgrade.itb (or .bin), e.g. bpi-r4-phase2-*-squashfs-sysupgrade.itb"
				;;
			""|*bananapi_bpi-r4-squashfs-sysupgrade.itb|*bananapi_bpi-r4-squashfs-sysupgrade.bin|*sysupgrade.itb|*sysupgrade.bin) ;;
			*)
				fail_json "bad_filename" \
					"Expected a BPI-R4 *sysupgrade.itb (or .bin) — not an SD *sdcard*.img.gz"
				;;
		esac

		# L1 — no image write / sysupgrade under another node operation.
		require_node_idle upgrade "Appliance upgrade upload in progress (chain untouched)"
		img=/tmp/knots-upgrade.itb
		rm -f "$img"
		mkdir -p /tmp/knots
		upgrade_status_write receiving "Receiving image from browser" "${CONTENT_LENGTH:-0}"
		logger -t knots-upgrade "receiving filename=${FNAME:-unknown} content_length=${CONTENT_LENGTH:-0}"
		# B17: only report "interrupted" when no specific failure was recorded
		# (fail_json exits through this trap after writing e.g. SHA256 mismatch).
		trap 'grep -q "\"phase\":\"failed\"" /tmp/knots/upgrade-status.json 2>/dev/null || upgrade_status_write failed "Upload interrupted"; node_op_release; rm -f /tmp/knots-upgrade.itb /tmp/knots/upgrade-pending' EXIT INT TERM
		cat >"$img"
		[ -s "$img" ] || fail_json "empty_upload" "Uploaded image is empty"
		sz=$(wc -c <"$img" | tr -d ' ')
		upgrade_status_write verifying "Image received — verifying SHA256" "$sz"
		if [ "$sz" -lt 8000000 ] || [ "$sz" -gt 268435456 ]; then
			rm -f "$img"
			upgrade_status_write failed "Image size out of range"
			fail_json "bad_size" "Image size out of range (8–256 MiB)"
		fi

		got=$(sha256sum "$img" | awk '{print $1}')
		if [ "$got" != "$EXPECT" ]; then
			rm -f "$img"
			upgrade_status_write failed "SHA256 mismatch"
			logger -t knots-upgrade "sha256 mismatch expect=$EXPECT got=$got"
			fail_json "sha256_mismatch" \
				"SHA256 does not match. Re-download the image and paste the checksum from the release page. (No upgrade started.)"
		fi
		# Release signature (usign, appended fwtool chunk). Required once a
		# release key is installed; strips the signature so the image is
		# exactly what was signed — the recorded hash is of that image.
		if command -v release_sig_check >/dev/null 2>&1; then
			if ! release_sig_check "$img"; then
				rm -f "$img"
				upgrade_status_write failed "Release signature ${RELEASE_SIG_STATE:-invalid}"
				logger -t knots-upgrade "release signature ${RELEASE_SIG_STATE:-invalid}"
				if [ "${RELEASE_SIG_STATE:-}" = unsigned ]; then
					fail_json "unsigned_image" \
						"This image is not signed. Only signed RNode releases can be installed. (No upgrade started.)"
				fi
				fail_json "bad_signature" \
					"The image signature is not valid for this router. Download the release again. (No upgrade started.)"
			fi
			logger -t knots-upgrade "release signature ${RELEASE_SIG_STATE}"
			got=$(sha256sum "$img" | awk '{print $1}')
			sz=$(wc -c <"$img" | tr -d ' ')
		fi
		upgrade_status_write verifying "SHA256 OK — preparing sysupgrade" "$sz"
		logger -t knots-upgrade "sha256 ok sz=$sz sig=${RELEASE_SIG_STATE:-n/a}"

		# NF9 — never touch M.2; sysupgrade is system partition only
		command -v sysupgrade >/dev/null 2>&1 || fail_json "no_sysupgrade" "sysupgrade not available"

		# U13 — keep router config by default; optional -n resets settings (not M.2)
		KEEP_RAW=$(urldecode_soft "$(qval keep_config)")
		case "$KEEP_RAW" in
			0|false|False|no|NO|reset|RESET) KEEP_CONFIG=0 ;;
			*) KEEP_CONFIG=1 ;;
		esac

		# Detach: write marker (keep + verified sha256 for upgrade-apply re-check, H4)
		# then invoke sysupgrade (device will reboot)
		echo "pending $(date -u +%Y-%m-%dT%H:%M:%SZ) sz=$sz keep=$KEEP_CONFIG sha256=$got" >/tmp/knots/upgrade-pending
		if [ "$KEEP_CONFIG" = "1" ]; then
			upgrade_status_write applying "Starting sysupgrade (keep settings) — device will reboot" "$sz"
			logger -t knots-upgrade "applying sz=$sz keep_config=1"
			keep_json=true
			keep_msg="Checksum verified — upgrade starting (keeping router settings). Device will reboot. Blockchain on M.2 is not wiped."
		else
			upgrade_status_write applying "Starting sysupgrade (reset settings) — device will reboot" "$sz"
			logger -t knots-upgrade "applying sz=$sz keep_config=0"
			keep_json=false
			keep_msg="Checksum verified — upgrade starting (resetting router settings). Device will reboot. Blockchain on M.2 is not wiped."
		fi
		# F125 — detached worker survives CGI teardown after large upload (U13).
		# setsid (present in busybox) — NOT nohup, which is absent on this build.
		# Match progress-wait.js STEP_SETS sums (F175 serial .61 -n).
		UPG_SEC=300
		[ "$KEEP_CONFIG" = "0" ] && UPG_SEC=630
		if command -v upgrade_ui_arm >/dev/null 2>&1; then
			upgrade_ui_arm settings "$UPG_SEC" "$KEEP_CONFIG"
		fi
		# KNOTS_NODE_OP_FROM: upgrade-apply adopts the node-op lock this CGI
		# holds (it may check before node_op_owner below runs).
		KNOTS_NODE_OP_FROM=$$ setsid /usr/libexec/knots/upgrade-apply.sh >>/tmp/knots/upgrade.log 2>&1 </dev/null &
		logger -t knots-upgrade "apply worker pid=$!"
		# L1 — upgrade-apply owns the node-op lock until it reboots (or dies:
		# a dead owner makes the lock stale and read_node_busy clears it).
		node_op_owner "$!"
		trap - EXIT INT TERM
		# Respond before reboot when possible
		cgi_headers
		printf '{"ok":true,"message":"%s","bytes":%s,"sha256":"%s","phase":"applying","expected_seconds":%s,"upgrade_url":"/upgrade.html","keep_config":%s}\n' \
			"$(json_escape "$keep_msg")" "$sz" "$got" "$UPG_SEC" "$keep_json"
		exit 0
		;;
	*)
		fail_json "bad_action" "Unknown action"
		;;
esac
