#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Shared CGI JSON helpers for Knots appliance APIs (TECH_SPEC §7.4.4).
# Source this instead of duplicating cgi_headers/fail_json in each *-api.sh.

# shellcheck disable=SC1091
. /usr/libexec/knots/rpc.sh

cgi_headers() {
	printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
}

fail_json() {
	cgi_headers
	printf '{"ok":false,"error":"%s","message":"%s"}\n' \
		"$(json_escape "$1")" "$(json_escape "$2")"
	exit 0
}

ok_raw() {
	cgi_headers
	printf '%s\n' "$1"
	exit 0
}

ok_json() {
	cgi_headers
	printf '%s\n' "$1"
	exit 0
}

urldecode_soft() {
	printf '%s' "$1" | sed 's/+/ /g; s/%20/ /g'
}

# Decode application/x-www-form-urlencoded (+ and %XX). Must stay O(n):
# a per-character `cut` loop took seconds on a WPA2 passphrase and the
# Setup Wi-Fi save timed out before `uci commit` (R7/U17).
urldecode() {
	printf '%s\n' "$1" | awk '
	BEGIN {
		for (i = 1; i <= 255; i++) {
			h = sprintf("%02X", i)
			c = sprintf("%c", i)
			hex[h] = c
			hex[tolower(h)] = c
		}
	}
	{
		gsub(/\+/, " ")
		n = length($0)
		out = ""
		i = 1
		while (i <= n) {
			ch = substr($0, i, 1)
			if (ch == "%" && i + 2 <= n) {
				h = substr($0, i + 1, 2)
				if (h in hex) {
					out = out hex[h]
					i += 3
					continue
				}
			}
			out = out ch
			i++
		}
		printf "%s", out
		exit
	}'
}

require_lan_client() {
	# U15 — mutating Settings/API from LAN (or local) only.
	# S11 (review 2026-10-10): behind nginx this check cannot decide anything —
	# uhttpd does not forward X-Real-IP (HTTP_X_REAL_IP is always empty) and
	# REMOTE_ADDR is nginx's 127.0.0.1. The LAN/WAN decision is made in nginx
	# ($knots_via_lan, by the router address the request arrived on) and by
	# firewall rule reject_wan_luci. Kept for direct uhttpd/CLI callers.
	addr=${HTTP_X_REAL_IP:-}
	[ -n "$addr" ] || addr=${REMOTE_ADDR:-}
	case "$addr" in
		""|127.*|::1) return 0 ;;
		192.168.*|10.*) return 0 ;;
		172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
		[fF][dD]*|[fF][eE]80*) return 0 ;;
		*) return 1 ;;
	esac
}

# U15 — shared mutating-action gate: LAN-only + router user+password verified
# via ubus session login. Caller must define qval (query/body field getter).
#
# S5 (review 2026-10-10) — credentials never travel in the URL (nginx/uhttpd
# logs, browser history, `ps`). Form posts carry them in the body; raw-body
# actions (upgrade image, advanced bitcoin.conf, node tarball) send
#   Authorization: KnotsForm user=<urlenc>&password=<urlenc>
# uhttpd forwards Authorization as HTTP_AUTHORIZATION (busybox has no base64,
# so this reuses the form encoding instead of Basic).
auth_header_field() {
	case "${HTTP_AUTHORIZATION:-}" in
		"KnotsForm "*) ;;
		*) return 0 ;;
	esac
	printf '%s\n' "${HTTP_AUTHORIZATION#KnotsForm }" | tr '&' '\n' | \
		sed -n "s/^${1}=//p" | head -1
}

require_auth_fields() {
	require_lan_client || fail_json "wan_denied" "Changes are LAN-only"
	case "&${QUERY_STRING:-}" in
		*"&password="*|*"&user="*)
			fail_json "creds_in_url" \
				"Credentials must not be sent in the URL (use the form body or Authorization header)"
			;;
	esac
	USER=$(urldecode "$(urldecode_soft "$(qval user)")")
	PASS=$(urldecode "$(qval password)")
	# password may be fully urlencoded
	[ -n "$PASS" ] || PASS=$(urldecode_soft "$(qval password)")
	if [ -z "$USER" ] && [ -z "$PASS" ]; then
		USER=$(urldecode "$(auth_header_field user)")
		PASS=$(urldecode "$(auth_header_field password)")
	fi
	AUTH_LOCKED=
	if ! verify_router_auth "$USER" "$PASS"; then
		[ -z "$AUTH_LOCKED" ] || \
			fail_json "auth_locked" "Too many failed password attempts — wait a minute and try again"
		fail_json "auth_failed" "Router username/password incorrect"
	fi
}

# S3 (review 2026-10-10) — host part of an http(s) Origin is one of the
# appliance's own names / private IP literals (mirrors the nginx
# $knots_origin_ok map). uhttpd forwards Origin as HTTP_ORIGIN; it does NOT
# forward Sec-Fetch-Site or X-Real-IP.
origin_is_appliance() {
	o=$1
	case "$o" in
		http://*) o=${o#http://} ;;
		https://*) o=${o#https://} ;;
		*) return 1 ;;
	esac
	case "$o" in
		*/*|*@*) return 1 ;;
		\[*\]|\[*\]:*) o=${o%%]*}; o="${o}]" ;;
		*) o=${o%%:*} ;;
	esac
	case "$o" in
		localhost|node-router|knots-router) return 0 ;;
		\[*\]) return 0 ;;
		*.lan|*.local)
			case "${o%.*}" in *[!a-z0-9-]*|"") return 1 ;; esac
			return 0
			;;
		127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
			case "$o" in *[!0-9.]*) return 1 ;; esac
			return 0
			;;
	esac
	return 1
}

# Browsers send Origin on every POST and cross-origin fetch; non-browser
# clients (curl, UAT) send none. Refuse a present-but-foreign Origin (incl.
# "null") so another site cannot drive the appliance from a LAN browser.
require_same_origin() {
	[ -z "${HTTP_ORIGIN:-}" ] && return 0
	origin_is_appliance "$HTTP_ORIGIN" || \
		fail_json "origin_denied" "Request from another website refused"
}

# M1 — mutating actions are POST-only (no credentials in URLs, no GET CSRF)
require_mutating_post() {
	[ "${REQUEST_METHOD:-GET}" = "POST" ] || fail_json "method" "POST required"
	require_same_origin
}

# F125 / F201 / F204 — uhttpd :21444 kills the CGI process group and returns
# HTML 502 ("The process did not produce any response") if the script waits
# on bitcoind before writing headers. Detach long work; return JSON now.
cgi_setsid() {
	logf=${1:-worker.log}
	cmd=${2:-}
	[ -n "$cmd" ] || return 1
	logdir=${KNOTS_LOGDIR:-/tmp/knots}
	mkdir -p "$logdir"
	setsid sh -c "$cmd" >"$logdir/$logf" 2>&1 </dev/null &
	CGI_SETSID_PID=$!
}

# L1 — take the node-operation lock or refuse the request (node-impl-lib.sh).
# Any fail_json after this releases the lock (EXIT trap) until a worker owns it.
require_node_idle() {
	if node_op_acquire "$1" "$2"; then
		trap 'node_op_release' EXIT
		return 0
	fi
	busy_msg=$(sed -n '2p' "${BUSY_FILE:-/tmp/knots/node-busy}" 2>/dev/null)
	fail_json "node_busy" "Another node operation is still running${busy_msg:+: $busy_msg}. Wait for it to finish."
}

# L1 — start a detached node worker that owns the lock until it exits.
# The worker re-asserts ownership with its own PID first (same PID as $! from
# the non-interactive setsid exec) and always releases on exit.
cgi_node_worker() {
	logf=$1
	work=$2
	# L2 — result record: running now; the worker finishes it (explicitly via
	# node_op_result, else from its exit code in node_op_finish).
	_wop=${3:-${logf%.log}}
	_wop=$(printf '%s' "$_wop" | tr '-' '_')
	node_op_result "$_wop" running "In progress"
	cgi_setsid "$logf" ". ${KNOTS_LIBEXEC:-/usr/libexec/knots}/node-impl-lib.sh
node_op_owner \$\$
trap '_rc=\$?; node_op_finish $_wop \$_rc \"${KNOTS_LOGDIR:-/tmp/knots}/$logf\"; node_op_release' EXIT
trap 'exit 143' INT TERM
$work"
	node_op_owner "$CGI_SETSID_PID"
	trap - EXIT
}

# S8 (review 2026-10-10) — global auth-failure throttle. The old 1 s sleep was
# per request, so parallel requests guessed at full speed. After
# AUTH_FAIL_MAX failures inside AUTH_FAIL_WINDOW seconds every attempt is
# refused (without even trying the password) until the window has passed.
AUTH_FAIL_FILE=/tmp/knots/auth-failures
AUTH_FAIL_MAX=${AUTH_FAIL_MAX:-10}
AUTH_FAIL_WINDOW=${AUTH_FAIL_WINDOW:-60}

auth_recent_failures() {
	now=$(date +%s)
	[ -f "$AUTH_FAIL_FILE" ] || { echo 0; return 0; }
	awk -v now="$now" -v w="$AUTH_FAIL_WINDOW" '$1 > now - w { n++ } END { print n + 0 }' \
		"$AUTH_FAIL_FILE" 2>/dev/null || echo 0
}

auth_note_failure() {
	mkdir -p /tmp/knots
	now=$(date +%s)
	# keep the file small: only entries still inside the window
	{ awk -v now="$now" -v w="$AUTH_FAIL_WINDOW" '$1 > now - w' "$AUTH_FAIL_FILE" 2>/dev/null
	  echo "$now"; } >"$AUTH_FAIL_FILE.$$" && mv -f "$AUTH_FAIL_FILE.$$" "$AUTH_FAIL_FILE"
	sleep 1
	return 1
}

# U15 — verify LuCI/root password via ubus session login (reuse OpenWrt auth)
verify_router_auth() {
	user=$1
	pass=$2
	if [ "$(auth_recent_failures)" -ge "$AUTH_FAIL_MAX" ]; then
		AUTH_LOCKED=1
		sleep 1
		return 1
	fi
	[ -n "$user" ] && [ -n "$pass" ] || { auth_note_failure; return 1; }
	[ "$user" = "root" ] || { auth_note_failure; return 1; }
	# Escape for JSON string (password on ubus argv = accepted documented risk)
	pass_j=$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')
	user_j=$(printf '%s' "$user" | sed 's/\\/\\\\/g; s/"/\\"/g')
	out=$(ubus call session login \
		"{\"username\":\"${user_j}\",\"password\":\"${pass_j}\"}" 2>/dev/null) || { auth_note_failure; return 1; }
	sid=$(printf '%s' "$out" | sed -n 's/.*"ubus_rpc_session"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' | head -1)
	[ -n "$sid" ] || { auth_note_failure; return 1; }
	# S8 — the session was only a password check; do not leave it alive
	# (each Settings action used to leak one until its timeout).
	ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true
	return 0
}
