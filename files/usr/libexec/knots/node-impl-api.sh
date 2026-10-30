#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Node implementation API — CGI or: node-impl-api.sh 'action=status'
# B15–B21 / U11: status, set, install (raw POST body), rollback; B24/U16 reindex
# U15: set/install/rollback/reindex_chainstate need POST + router auth (cgi-lib)
set -e

# shellcheck disable=SC1091
. /usr/libexec/knots/cgi-lib.sh
# shellcheck disable=SC1091
. /usr/libexec/knots/node-impl-lib.sh

# Query string only for routing (install POST body is the tarball binary)
QS="${QUERY_STRING:-}"
if [ -n "${1:-}" ] && [ "$1" != "cgi" ]; then
	QS="$1"
fi

# For non-install POST with form body, merge into QS (switch / rollback)
ACTION_PEEK=$(echo "$QS" | tr '&' '\n' | sed -n 's/^action=//p' | head -1)
ACTION_PEEK=$(urldecode_soft "$ACTION_PEEK")
if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ]; then
	case "$ACTION_PEEK" in
		install) ;;
		*)
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
IMPL=$(urldecode_soft "$(qval impl)")
CONFIRM=$(urldecode_soft "$(qval confirm)")
WALLET_ACK=$(urldecode_soft "$(qval wallet_ack)")
SHA=$(urldecode_soft "$(qval sha256)")

# U15 (review C2) — gate every mutation on POST + router root auth before any
# work; the SWITCH/INSTALL/ROLLBACK/REINDEX tokens below stay as friction.
case "$ACTION" in
	set|install|rollback|reindex_chainstate)
		require_mutating_post
		require_auth_fields
		# L1 — one node operation at a time (switch/install/rollback/reindex
		# vs Settings stop/start/conf/upgrade/reboot). Released on CGI exit
		# unless handed to a detached worker (cgi_node_worker).
		require_node_idle "$ACTION" "Node software ${ACTION} in progress"
		;;
esac

case "$ACTION" in
	status)
		# L2 — last_op: outcome of the last switch/install/rollback/reindex.
		st=$(/usr/libexec/knots/node-impl.sh status)
		ok_raw "${st%\}},\"last_op\":$(node_op_result_json)}"
		;;
	set)
		case "$IMPL" in
			knots|core) ;;
			*) fail_json "bad_impl" "impl must be knots or core" ;;
		esac
		if [ "$CONFIRM" != "SWITCH" ]; then
			fail_json "confirm_required" "Type SWITCH to change node implementation"
		fi
		# F204 — switch stop/start bitcoind; CGI must not wait (uhttpd 502).
		ack=
		if [ "$WALLET_ACK" = "WALLET_ACK" ] || [ "$WALLET_ACK" = "1" ] || [ "$WALLET_ACK" = "true" ]; then
			ack=WALLET_ACK
		fi
		cgi_node_worker node-switch.log \
			"/usr/libexec/knots/node-impl.sh set ${IMPL} SWITCH ${ack} && node_op_result set ok 'Now running ${IMPL}. Chain data kept on the shared datadir.'" set
		ok_json '{"ok":true,"accepted":true,"message":"Node implementation switch started. Chain data kept on shared datadir."}'
		;;
	install)
		# B19/B21 — LAN upload: POST body = .tar.gz; metadata in query string
		case "$IMPL" in
			knots|core) ;;
			*) fail_json "bad_impl" "impl must be knots or core" ;;
		esac
		if [ "$CONFIRM" != "INSTALL" ]; then
			fail_json "confirm_required" "Type INSTALL to replace node binaries"
		fi
		# U11/B21 (review C3) — stage under the sanitized original file name so
		# node-impl.sh's aarch64 basename gate sees the real name, not a stub
		NAME=$(urldecode "$(qval name)")
		NAME=${NAME##*/}
		NAME=$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9._-')
		case "$NAME" in
			.|..) NAME= ;;
		esac
		if [ -z "$NAME" ] || [ "${#NAME}" -gt 128 ]; then
			fail_json "bad_filename" \
				"Original file name missing or unusable — the uploaded file name must contain 'aarch64' (official aarch64-linux-gnu .tar.gz)"
		fi
		grep -q ' /mnt/bitcoin ' /proc/mounts 2>/dev/null || \
			fail_json "no_m2" "M.2 not mounted"
		uploaddir=/mnt/bitcoin/.node-uploads
		mkdir -p "$uploaddir"
		tgz="$uploaddir/$NAME"
		# Cover upload + install so Node Status does not show RPC errors (U2)
		set_node_busy install "Node software upload/install in progress (${IMPL})."
		trap 'node_op_release' EXIT INT TERM
		# Stream POST body (tarball) to M.2 — do not parse as form fields
		cat >"$tgz"
		[ -s "$tgz" ] || fail_json "empty_upload" "Uploaded tarball is empty"
		# Size sanity: official aarch64 packages are typically 15–60 MiB; cap
		# matches nginx client_max_body_size 120m = 125829120 (review M7)
		sz=$(wc -c <"$tgz" | tr -d ' ')
		if [ "$sz" -lt 1000000 ] || [ "$sz" -gt 125829120 ]; then
			rm -f "$tgz"
			fail_json "bad_size" "Tarball size out of expected range (1–120 MiB)"
		fi
		ack=""
		if [ "$WALLET_ACK" = "WALLET_ACK" ] || [ "$WALLET_ACK" = "1" ] || [ "$WALLET_ACK" = "true" ]; then
			ack=WALLET_ACK
		fi
		# L3 — install (extract + verify + maybe node restart) can outlast the
		# 120 s proxy timeout (504 HTML). The upload stays in the CGI; the
		# install runs detached and reports via last_op (L2).
		trap - EXIT INT TERM
		_sha_q=$(printf '%s' "$SHA" | tr -cd '0-9a-fA-F')
		cgi_node_worker node-install.log "/usr/libexec/knots/node-impl.sh install-from ${IMPL} \"$tgz\" \"${_sha_q}\" INSTALL ${ack} || { rm -f \"$tgz\"; exit 1; }
rm -f \"$tgz\"
ls -1t \"$uploaddir\"/* 2>/dev/null | tail -n +6 | while read -r f; do rm -f \"\$f\"; done
node_op_result install ok 'Installed ${IMPL} from upload. Chain data kept.'" install
		ok_json '{"ok":true,"accepted":true,"message":"Upload received — installing. This can take a few minutes."}'
		;;
	rollback)
		case "$IMPL" in
			knots|core) ;;
			*) fail_json "bad_impl" "impl must be knots or core" ;;
		esac
		if [ "$CONFIRM" != "ROLLBACK" ]; then
			fail_json "confirm_required" "Type ROLLBACK to restore previous binaries"
		fi
		ack=
		if [ "$WALLET_ACK" = "WALLET_ACK" ] || [ "$WALLET_ACK" = "1" ] || [ "$WALLET_ACK" = "true" ]; then
			ack=WALLET_ACK
		fi
		# L3 — detached; outcome via last_op (L2).
		cgi_node_worker node-rollback.log \
			"/usr/libexec/knots/node-impl.sh rollback ${IMPL} ROLLBACK ${ack} && node_op_result rollback ok 'Rolled back ${IMPL}. Chain data kept.'" rollback
		ok_json '{"ok":true,"accepted":true,"message":"Rollback started."}'
		;;
	reindex_chainstate)
		# B24 / U16 — LAN recovery; confirm REINDEX (reuse cgi-lib LAN gate)
		require_lan_client || fail_json "wan_denied" "Reindex is LAN-only"
		if [ "$CONFIRM" != "REINDEX" ]; then
			fail_json "confirm_required" "Type REINDEX to rebuild chainstate from local blocks"
		fi
		set_node_busy reindex \
			"Validating chain database (reindex) — not re-downloading the blockchain"
		mkdir -p /tmp/knots
		echo recovering >/tmp/knots/knots.status
		# L3 — bitcoind_ctl_reindex_chainstate waits on RPC (minutes) — detach;
		# outcome via last_op (L2).
		cgi_node_worker node-reindex.log '. /usr/libexec/knots/bitcoind-ctl.sh
bitcoind_ctl_reindex_chainstate || true
if bitcoind_ctl_bitcoind_alive; then
  echo recovering >/tmp/knots/knots.status
  node_op_result reindex_chainstate ok "Reindex running. Keep power on — validation can take many hours. Not a blockchain re-download."
else
  echo stopped >/tmp/knots/knots.status
  node_op_result reindex_chainstate failed "Could not start the reindex — see the node log."
  exit 1
fi' reindex_chainstate
		ok_raw '{"ok":true,"accepted":true,"message":"Reindex starting. Status will show validation progress. Blocks on the M.2 are kept — this is not a fresh download."}'
		;;
	*)
		fail_json "bad_action" "Unknown action"
		;;
esac
