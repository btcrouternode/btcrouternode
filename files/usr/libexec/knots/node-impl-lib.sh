# SPDX-License-Identifier: GPL-2.0-only
# Shared Knots/Core selection helpers (B15). Sourced by host scripts.
# State: M.2 primary + /etc/knots backup so preference survives mount races / power loss.

STATE_M2=/mnt/bitcoin/.node-impl
STATE_SYS=/etc/knots/node-impl
MNT=/mnt/bitcoin
# U2 — visible while Knots↔Core switch / binary install / rollback (RPC may flap)
BUSY_FILE="${BUSY_FILE:-/tmp/knots/node-busy}"
BUSY_MAX_AGE_SEC="${BUSY_MAX_AGE_SEC:-3600}"

# File format (3 lines): op / message / unix epoch
# op: switch | install | rollback
set_node_busy() {
	op=${1:-update}
	msg=${2:-Node update in progress}
	mkdir -p /tmp/knots
	printf '%s\n%s\n%s\n' "$op" "$msg" "$(date +%s 2>/dev/null || echo 0)" >"$BUSY_FILE"
	sync "$BUSY_FILE" 2>/dev/null || sync
}

clear_node_busy() {
	rm -f "$BUSY_FILE"
}

# Prints: active|op|message  (active is true|false)
read_node_busy() {
	# L1 — a node-op lock whose owner died: the operation is over.
	if [ -d "${NODE_OP_LOCK:-/tmp/knots/node-op.lock}" ] && ! node_op_busy; then
		node_op_release
	fi
	if [ ! -f "$BUSY_FILE" ]; then
		echo "false||"
		return
	fi
	op=$(sed -n '1p' "$BUSY_FILE" 2>/dev/null)
	msg=$(sed -n '2p' "$BUSY_FILE" 2>/dev/null)
	started=$(sed -n '3p' "$BUSY_FILE" 2>/dev/null)
	now=$(date +%s 2>/dev/null || echo 0)
	case "$started" in
		''|*[!0-9]*) started=0 ;;
	esac
	age=$((now - started))
	if [ "$age" -gt "$BUSY_MAX_AGE_SEC" ] 2>/dev/null; then
		rm -f "$BUSY_FILE"
		echo "false||"
		return
	fi
	[ -n "$op" ] || op=update
	[ -n "$msg" ] || msg="Node update in progress"
	printf 'true|%s|%s\n' "$op" "$msg"
}

# L2 (review 2026-10-11) — outcome of the last node operation. Detached
# workers used to end in `|| true` and report success regardless (stop said
# "stopped" while bitcoind ran on, a failed switch kept the new impl). Each
# worker now records running → ok|failed with a user-facing message; status
# exposes it as last_op and the UI shows it when node_busy clears.
NODE_OP_RESULT="${NODE_OP_RESULT:-${KNOTS_TMP:-/tmp/knots}/node-op.result}"

# node_op_result OP running|ok|failed MESSAGE
node_op_result() {
	mkdir -p "${NODE_OP_RESULT%/*}"
	# JSON-safe without a full escaper: drop quotes, backslashes, controls.
	_m=$(printf '%s' "${3:-}" | tr -d '"\\\000-\037' | cut -c1-300)
	printf '{"op":"%s","state":"%s","message":"%s","ts":%s}\n' \
		"$(printf '%s' "${1:-op}" | tr -cd 'a-z_')" "$2" "$_m" "$(date +%s 2>/dev/null || echo 0)" \
		>"$NODE_OP_RESULT.tmp" && mv -f "$NODE_OP_RESULT.tmp" "$NODE_OP_RESULT"
	unset _m
}

# Prints the last result object, or null.
node_op_result_json() {
	if [ -s "$NODE_OP_RESULT" ]; then
		_r=$(cat "$NODE_OP_RESULT" 2>/dev/null)
		# A worker killed outright never finishes its record.
		case "$_r" in
		*'"state":"running"'*)
			if ! node_op_busy; then
				_o=$(printf '%s' "$_r" | sed -n 's/.*"op":"\([a-z_]*\)".*/\1/p')
				node_op_result "$_o" failed "The ${_o:-node} operation stopped unexpectedly — check Node Status and try again"
				_r=$(cat "$NODE_OP_RESULT" 2>/dev/null)
			fi
			;;
		esac
		printf '%s' "$_r"
		unset _r _o
	else
		printf 'null'
	fi
}

# Worker EXIT hook: a worker that recorded nothing explicit gets a result
# from its exit code (last log line as the reason on failure).
node_op_finish() {
	_op=$1 _rc=$2 _log=${3:-}
	if grep -q '"state":"running"' "$NODE_OP_RESULT" 2>/dev/null; then
		if [ "$_rc" = 0 ]; then
			node_op_result "$_op" ok "Done."
		else
			_why=$(tail -n 1 "$_log" 2>/dev/null | sed 's/^[a-z-]*: //')
			node_op_result "$_op" failed "${_why:-The operation failed (code $_rc)}"
		fi
	fi
	unset _op _rc _log _why
}

# L1 (review 2026-10-10) — one node operation at a time.
# The busy FILE above is only a UI message; nothing stopped a Settings Stop
# from running while a detached conf-restart worker was mid stop/start (seen
# on hardware: .78 UAT SET-6/7 — the restart worker restarted the node the
# user had just stopped). NODE_OP_LOCK is an atomic mkdir lock whose owner
# PID is the process doing the work; a dead owner means a stale lock.
NODE_OP_LOCK="${NODE_OP_LOCK:-/tmp/knots/node-op.lock}"

# node_op_acquire OP MESSAGE — take the lock (owner = caller PID) and set the
# busy message. Returns 1 if another live operation holds it.
node_op_acquire() {
	mkdir -p "${NODE_OP_LOCK%/*}"
	_try=0
	while [ "$_try" -lt 2 ]; do
		if mkdir "$NODE_OP_LOCK" 2>/dev/null; then
			echo "$$" >"$NODE_OP_LOCK/pid"
			echo "${1:-update}" >"$NODE_OP_LOCK/op"
			set_node_busy "${1:-update}" "${2:-Node update in progress}"
			return 0
		fi
		_pid=$(cat "$NODE_OP_LOCK/pid" 2>/dev/null)
		if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
			return 1
		fi
		# Stale (owner gone, or crashed before writing its PID): reclaim once.
		rm -rf "$NODE_OP_LOCK"
		_try=$((_try + 1))
	done
	return 1
}

# Hand the lock to the detached worker that does the work (its PID).
node_op_owner() {
	[ -d "$NODE_OP_LOCK" ] && echo "${1:-$$}" >"$NODE_OP_LOCK/pid"
}

node_op_release() {
	rm -rf "$NODE_OP_LOCK"
	clear_node_busy
}

# True while a live operation holds the lock (stale locks do not count).
node_op_busy() {
	[ -d "$NODE_OP_LOCK" ] || return 1
	_pid=$(cat "$NODE_OP_LOCK/pid" 2>/dev/null)
	[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

m2_mounted() {
	grep -q " $MNT " /proc/mounts 2>/dev/null
}

normalize_impl() {
	case "${1:-}" in
		knots) echo knots ;;
		*) echo core ;;
	esac
}

# Prefer M.2 when mounted; else system backup; else default core.
read_impl() {
	if m2_mounted && [ -f "$STATE_M2" ]; then
		normalize_impl "$(cat "$STATE_M2" 2>/dev/null)"
		return
	fi
	if [ -f "$STATE_SYS" ]; then
		normalize_impl "$(cat "$STATE_SYS" 2>/dev/null)"
		return
	fi
	echo core
}

# Serial MOTD: show active impl (M.2 preference), not only factory default branding.
update_banner_impl() {
	impl=$(normalize_impl "$1")
	[ -f /etc/banner ] || return 0
	case "$impl" in
		core) label="Bitcoin Core" ;;
		*) label="Bitcoin Knots" ;;
	esac
	if grep -q '^ Active:' /etc/banner 2>/dev/null; then
		sed -i "s|^ Active:.*| Active:   ${label} (from M.2 preference)|" /etc/banner 2>/dev/null || true
	fi
}

# Persist to system always; to M.2 only when mounted. fsync both.
write_impl() {
	impl=$(normalize_impl "$1")
	mkdir -p /etc/knots
	printf '%s\n' "$impl" >"$STATE_SYS"
	sync "$STATE_SYS" 2>/dev/null || sync
	if m2_mounted; then
		printf '%s\n' "$impl" >"$STATE_M2"
		sync "$STATE_M2" 2>/dev/null || sync
	fi
	update_banner_impl "$impl"
}

# After M.2 becomes available: reconcile so neither side is stale.
# - If M.2 has a value → copy to system (M.2 wins).
# - Else if system has a value → restore onto M.2.
# - Else → write default core to both.
# Never create files under /mnt/bitcoin when unmounted (would land on overlay).
reconcile_impl() {
	m2_mounted || return 1
	if [ -f "$STATE_M2" ]; then
		write_impl "$(cat "$STATE_M2")"
	elif [ -f "$STATE_SYS" ]; then
		write_impl "$(cat "$STATE_SYS")"
	else
		write_impl core
	fi
}
