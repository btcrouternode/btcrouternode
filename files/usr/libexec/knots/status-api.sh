#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Emit GET /api/status JSON — TECH_SPEC §7.2 / REQUIREMENTS U2, B14.
# Safe to run from procd (writes /tmp/knots/status.json) or as CGI.

set -e

ENV_FILE=/etc/knots/node-ui.env
STATUS_DIR=/tmp/knots
OUT="${STATUS_DIR}/status.json"
# TECH_SPEC §5.1 lock: warn below 100 GiB free (107374182400 bytes).
# node-ui.env may override; keep both copies at the spec value.
LOW_SPACE_BYTES=107374182400

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

RPC_HOST="${RPC_HOST:-21.21.21.21}"
RPC_PORT="${RPC_PORT:-8332}"
COOKIE_PATH="${COOKIE_PATH:-/mnt/bitcoin/.cookie}"
COOKIE_PATH_ALT="${COOKIE_PATH_ALT:-/mnt/bitcoin/bitcoin/.cookie}"
MNT="${KNOTS_MNT:-/mnt/bitcoin}"

mkdir -p "$STATUS_DIR"

json_escape() {
	# Minimal escape for hash/hostname strings
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cookie=
if [ -f "$COOKIE_PATH" ]; then
	cookie=$(cut -d: -f2 "$COOKIE_PATH")
elif [ -f "$COOKIE_PATH_ALT" ]; then
	cookie=$(cut -d: -f2 "$COOKIE_PATH_ALT")
fi

product_version=$(cat /etc/knots/product_version 2>/dev/null || echo unknown)
build_number=$(cat /etc/knots/build_number 2>/dev/null || echo unknown)
hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo node-router)
# B15/C10: the one reader in node-impl-lib.sh (M.2 when mounted, else /etc).
# shellcheck disable=SC1091
node_impl=$(. /usr/libexec/knots/node-impl-lib.sh && read_impl) || node_impl=core
case "$node_impl" in knots) ;; *) node_impl=core ;; esac

# M.2 health (disk-health.sh, refreshed every 5 min by the status loop);
# passed through only when it is one JSON object, else null.
disk_j=null
if [ -s "${STATUS_DIR}/disk-health.json" ] && head -c 1 "${STATUS_DIR}/disk-health.json" | grep -q '{' \
	&& jsonfilter -i "${STATUS_DIR}/disk-health.json" -e '@.level' >/dev/null 2>&1; then
	disk_j=$(tr -d '\n' <"${STATUS_DIR}/disk-health.json")
fi

mounted=false
free_bytes=0
low_space=false
if grep -q " $MNT " /proc/mounts 2>/dev/null; then
	mounted=true
	# BusyBox df has no -B1; default is 1K-blocks → convert to bytes
	free_k=$(df -k "$MNT" 2>/dev/null | awk 'NR==2 {print $4}')
	[ -n "$free_k" ] || free_k=0
	free_bytes=$((free_k * 1024))
	if [ "$free_bytes" -lt "$LOW_SPACE_BYTES" ] 2>/dev/null; then
		low_space=true
	fi
fi

running=false
verification_progress=0
blocks=0
headers=0
best_block_hash=""
peers=0
uptime_sec=0
error=

# U2 — switch/install/rollback in progress (see node-impl-lib.sh)
maintenance_active=false
maintenance_op=
maintenance_message=
if [ -f /usr/libexec/knots/node-impl-lib.sh ]; then
	# shellcheck disable=SC1091
	. /usr/libexec/knots/node-impl-lib.sh
	busy_line=$(read_node_busy)
	maintenance_active=$(echo "$busy_line" | cut -d'|' -f1)
	maintenance_op=$(echo "$busy_line" | cut -d'|' -f2)
	maintenance_message=$(echo "$busy_line" | cut -d'|' -f3-)
fi
[ "$maintenance_active" = "true" ] || maintenance_active=false

rpc() {
	method=$1
	curl -sS --max-time 4 \
		--user "__cookie__:${cookie}" \
		--data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"s\",\"method\":\"${method}\",\"params\":[]}" \
		-H 'content-type: text/plain;' \
		"http://${RPC_HOST}:${RPC_PORT}/" 2>/dev/null
}

if [ -z "$cookie" ]; then
	error="rpc_cookie_missing"
elif ! grep -q " $MNT " /proc/mounts 2>/dev/null; then
	error="storage_not_mounted"
else
	chain=$(rpc getblockchaininfo)
	# RPC warm-up (-28: loading block index / verifying blocks) answers with
	# "result":null — the node is starting, not running at height 0 (soak .96).
	if echo "$chain" | grep -qE '"code": ?-28[,}]'; then
		error="starting"
	elif echo "$chain" | grep -q '"result"'; then
		running=true
		verification_progress=$(echo "$chain" | sed -n 's/.*"verificationprogress":\([0-9.eE+-]*\).*/\1/p' | head -1)
		blocks=$(echo "$chain" | sed -n 's/.*"blocks":\([0-9]*\).*/\1/p' | head -1)
		headers=$(echo "$chain" | sed -n 's/.*"headers":\([0-9]*\).*/\1/p' | head -1)
		best_block_hash=$(echo "$chain" | sed -n 's/.*"bestblockhash":"\([^"]*\)".*/\1/p' | head -1)
		[ -n "$verification_progress" ] || verification_progress=0
		[ -n "$blocks" ] || blocks=0
		[ -n "$headers" ] || headers=0

		conn=$(rpc getconnectioncount)
		peers=$(echo "$conn" | sed -n 's/.*"result":\([0-9]*\).*/\1/p' | head -1)
		[ -n "$peers" ] || peers=0

		up=$(rpc uptime)
		uptime_sec=$(echo "$up" | sed -n 's/.*"result":\([0-9]*\).*/\1/p' | head -1)
		[ -n "$uptime_sec" ] || uptime_sec=0

		if echo "$chain" | grep -q '"error":{'; then
			error="rpc_error"
		fi
	else
		error="bitcoind_rpc_unreachable"
		if [ -f "${STATUS_DIR}/knots.status" ]; then
			st=$(cat "${STATUS_DIR}/knots.status")
			[ "$st" = "running" ] || error="knots_status_${st}"
		fi
	fi
fi

# During maintenance, RPC flap is expected — do not surface as a hard error (U2).
if [ "$maintenance_active" = "true" ]; then
	case "$error" in
		bitcoind_rpc_unreachable|rpc_cookie_missing|rpc_error|knots_status_*)
			error=
			;;
	esac
	[ -n "$maintenance_message" ] || \
		maintenance_message="Node update in progress. Status will refresh when ready."
fi

# F30/F31 — until RPC is healthy, never show a scare-error for normal bring-up
st_boot=
[ -f "${STATUS_DIR}/knots.status" ] && st_boot=$(cat "${STATUS_DIR}/knots.status")
bitcoind_alive=false
pidof bitcoind >/dev/null 2>&1 && bitcoind_alive=true

is_hard_fail=false
case "$st_boot" in
	error_storage|error_lxc|error_lxc_start|error_rpc)
		is_hard_fail=true
		;;
esac

# B24 — chainstate repair needed / reindex in progress
# shellcheck disable=SC1091
. /usr/libexec/knots/bitcoind-ctl.sh
needs_reindex=false
reindex_kind=
if [ "$running" != "true" ]; then
	if [ "$st_boot" = "needs_reindex" ] || bitcoind_ctl_log_needs_reindex; then
		needs_reindex=true
		reindex_kind=chainstate
		is_hard_fail=false
		error=
		if [ "$st_boot" != "needs_reindex" ]; then
			echo "needs_reindex" >"${STATUS_DIR}/knots.status"
		fi
	fi
fi
# Router clock behind the chain (no RTC battery, no internet time yet):
# bitcoind refuses "blocks from the future". Not damage — never a reindex.
if [ "$running" != "true" ] && { [ "$st_boot" = "waiting_clock" ] || bitcoind_ctl_log_clock_wrong; }; then
	needs_reindex=false
	reindex_kind=
	is_hard_fail=false
	error=
	maintenance_active=true
	maintenance_op="waiting_clock"
	maintenance_message="Waiting for the correct time. The router sets its clock from the internet; the node starts by itself as soon as it has (your blockchain is fine)."
fi
# Reindex progress: argv may keep -reindex* after completion — use tip catch-up to finish
if bitcoind_ctl_reindex_running; then
	reindex_done=false
	if [ "$running" = "true" ]; then
		behind_ri=0
		if [ "$headers" -gt "$blocks" ] 2>/dev/null; then
			behind_ri=$((headers - blocks))
		fi
		# Nearly synced tip → reindex finished (even if argv still has the flag)
		case "$verification_progress" in
			0.999*|1|1.*|0.99[5-9]*)
				[ "$behind_ri" -lt 50 ] 2>/dev/null && reindex_done=true
				;;
		esac
		[ "$behind_ri" -eq 0 ] 2>/dev/null && \
			echo "$verification_progress" | grep -qE '^(0\.999|1(\.0*)?)$' && \
			reindex_done=true
	fi
	if [ "$reindex_done" = "true" ]; then
		rm -f /tmp/knots/reindex.active 2>/dev/null || true
	else
		maintenance_active=true
		maintenance_op="reindex"
		maintenance_message="Validating the chain database (reindex). This uses blocks already on the M.2 — it is not downloading the blockchain again. Keep power on; this can take many hours."
		needs_reindex=false
		error=
		is_hard_fail=false
	fi
fi
if [ "$running" = "true" ] && [ "$st_boot" = "needs_reindex" ]; then
	echo "running" >"${STATUS_DIR}/knots.status"
fi

# Soft RPC/start noise must not appear as Error: while the node is still coming up
if [ "$running" != "true" ] && [ "$is_hard_fail" != "true" ] && [ "$needs_reindex" != "true" ]; then
	case "$error" in
		rpc_cookie_missing|bitcoind_rpc_unreachable|rpc_error|storage_not_mounted|\
		knots_status_starting|knots_status_recovering|knots_status_stopped|starting)
			error=
			;;
	esac
fi

if [ "$running" != "true" ] && [ "$maintenance_active" != "true" ] && \
	[ "$is_hard_fail" != "true" ] && [ "$needs_reindex" != "true" ]; then
	want_init=false
	case "$st_boot" in
		""|starting|recovering) want_init=true ;;
	esac
	[ "$bitcoind_alive" = "true" ] && want_init=true
	[ "$mounted" != "true" ] && want_init=true

	if [ "$want_init" = "true" ]; then
		maintenance_active=true
		maintenance_op="initializing"
		if [ "$mounted" != "true" ]; then
			maintenance_message="Node is initialising — waiting for M.2 storage."
		elif [ "$bitcoind_alive" = "true" ] || [ "$st_boot" = "recovering" ]; then
			maintenance_message="Node is initialising — loading and verifying the chain database. This can take a few minutes after power loss."
		else
			maintenance_message="Node is initialising — starting Bitcoin. Status will update when ready."
		fi
		[ -n "$st_boot" ] || echo "starting" >"${STATUS_DIR}/knots.status"
	fi
fi

# Hard failures keep a clear error code
if [ "$is_hard_fail" = "true" ] && [ "$running" != "true" ]; then
	case "$st_boot" in
		error_storage) error="storage_not_ready" ;;
		error_lxc|error_lxc_start) error="container_start_failed" ;;
		error_rpc) error="node_failed_to_become_ready" ;;
	esac
fi

hash_j=$(json_escape "$best_block_hash")
err_j=
if [ -n "$error" ]; then
	err_j="\"$(json_escape "$error")\""
else
	err_j=null
fi
maint_j=false
if [ "$maintenance_active" = "true" ]; then
	maint_j=true
fi
needs_j=false
if [ "$needs_reindex" = "true" ]; then
	needs_j=true
fi
hint_j=
if [ "$needs_reindex" = "true" ]; then
	hint_j="Node cannot start until the chain database is repaired. This rebuilds chainstate from blocks already on the M.2 — it does not download the blockchain again."
fi

# BusyBox ash: no floating printf required for progress — pass through as number token
# Write temp then rename so nginx never sendfiles a truncated /tmp JSON.
_status_tmp="${OUT}.tmp.$$"
cat >"$_status_tmp" <<EOF
{
  "product_version": "$(json_escape "$product_version")",
  "build_number": "$(json_escape "$build_number")",
  "hostname": "$(json_escape "$hostname")",
  "node_impl": "$(json_escape "$node_impl")",
  "maintenance": {
    "active": ${maint_j},
    "op": "$(json_escape "$maintenance_op")",
    "message": "$(json_escape "$maintenance_message")"
  },
  "recovery": {
    "needs_reindex": ${needs_j},
    "kind": "$(json_escape "$reindex_kind")",
    "hint": "$(json_escape "$hint_j")"
  },
  "knots": {
    "running": ${running},
    "verification_progress": ${verification_progress},
    "blocks": ${blocks},
    "headers": ${headers},
    "best_block_hash": "${hash_j}",
    "peers": ${peers},
    "uptime_sec": ${uptime_sec},
    "error": ${err_j}
  },
  "storage": {
    "mounted": ${mounted},
    "path": "${MNT}",
    "free_bytes": ${free_bytes},
    "low_space": ${low_space}
  },
  "disk": ${disk_j}
}
EOF
mv -f "$_status_tmp" "$OUT"

# CGI mode: print headers + body
if [ -n "${REQUEST_METHOD:-}" ] || [ "${1:-}" = "cgi" ]; then
	printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
	cat "$OUT"
fi

exit 0
