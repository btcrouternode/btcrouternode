#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Start/stop Knots LXC + bitcoind after storage is ready.

set -e

CMD="${1:-start}"
STATUS_DIR=/tmp/knots
mkdir -p "$STATUS_DIR"

log() {
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	logger -t knots-start "$_ts $*"
	echo "knots-start: $_ts $*" >&2
	if [ -f /etc/openwrt_release ] && [ -c /dev/console ]; then
		echo "STEP $_ts knots-start $*" >/dev/console 2>/dev/null || true
	fi
	unset _ts
}

rpc_ok() {
	# Prefer host->DMZ cookie RPC (matches node UI path). bitcoin-cli inside
	# the container is not on PATH for lxc-attach and binds RPC only on .21.
	cookie=
	if [ -f /mnt/bitcoin/.cookie ]; then
		cookie=$(cut -d: -f2 /mnt/bitcoin/.cookie)
	elif [ -f /mnt/bitcoin/bitcoin/.cookie ]; then
		cookie=$(cut -d: -f2 /mnt/bitcoin/bitcoin/.cookie)
	fi
	[ -n "$cookie" ] || return 1
	curl -sS --max-time 5 \
		--user "__cookie__:${cookie}" \
		--data-binary '{"jsonrpc":"1.0","id":"c","method":"getblockchaininfo","params":[]}' \
		-H 'content-type: text/plain;' \
		http://21.21.21.21:8332/ 2>/dev/null | grep -q '"chain"'
}

case "$CMD" in
	stop)
		# M10 — serialize with any in-flight start: wait for its RPC wait to
		# finish, then stop (U18 — graceful bitcoind stop before container stop)
		exec 9>/tmp/knots-start.lock
		if command -v flock >/dev/null 2>&1; then
			flock 9
		fi
		# shellcheck disable=SC1091
		. /usr/libexec/knots/bitcoind-ctl.sh 2>/dev/null || true
		if command -v bitcoind_ctl_stop >/dev/null 2>&1; then
			log "stop: bitcoind_ctl_stop begin"
			bitcoind_ctl_stop || true
			log "stop: bitcoind_ctl_stop done"
		fi
		# 9>&- on every spawn: the lock fd must never leak into daemons/containers
		# (inherited fd 9 keeps the flock held → next stop deadlocks).
		if command -v lxc-attach >/dev/null 2>&1; then
			log "stop: knots-service stop begin"
			lxc-attach -n knots -- /usr/local/bin/knots-service stop 9>&- 2>/dev/null || true
			log "stop: knots-service stop done"
		fi
		# Bounded container stop: the baked dash init has no signal handlers, so
		# an unbounded lxc-stop can wedge a factory reset / clean reboot behind it.
		log "stop: lxc-stop -t 60 begin"
		lxc-stop -n knots -t 60 9>&- 2>/dev/null || true
		log "stop: lxc-stop done"
		echo "stopped" >"$STATUS_DIR/knots.status"
		exit 0
		;;
	start|"")
		# M10 — one start at a time. 99-bitcoin-node fires a sleep-20 retry while
		# the foreground start may still be in its RPC wait; a concurrent second
		# start must exit quietly instead of writing a false error_lxc_start.
		# shellcheck disable=SC1091
		. /usr/libexec/knots/progress-steps.sh 2>/dev/null || true
		_prog_kind=
		if command -v progress_steps_current_kind >/dev/null 2>&1; then
			_prog_kind=$(progress_steps_current_kind)
		fi
		if [ -n "$_prog_kind" ] && command -v progress_steps_set >/dev/null 2>&1; then
			progress_steps_set "$_prog_kind" starting
		fi
		exec 9>/tmp/knots-start.lock
		if command -v flock >/dev/null 2>&1; then
			flock -n 9 || exit 0
		fi
		if [ ! -f /tmp/knots/storage.status ] || [ "$(cat /tmp/knots/storage.status)" != "ok" ]; then
			# try prepare once
			/usr/libexec/knots/storage-prepare.sh || true
		fi
		if [ ! -f /tmp/knots/storage.status ] || [ "$(cat /tmp/knots/storage.status)" != "ok" ]; then
			echo "error_storage" >"$STATUS_DIR/knots.status"
			log "storage not ready"
			exit 1
		fi

		/usr/libexec/knots/lxc-ensure.sh || {
			echo "error_lxc" >"$STATUS_DIR/knots.status"
			log "lxc-ensure failed"
			exit 1
		}

		# Ensure mount visible before container start (BusyBox may lack mountpoint)
		if ! grep -q ' /mnt/bitcoin ' /proc/mounts 2>/dev/null; then
			mount -o noatime /mnt/bitcoin 2>/dev/null || mount /mnt/bitcoin 2>/dev/null || true
		fi
		if ! grep -q ' /mnt/bitcoin ' /proc/mounts 2>/dev/null; then
			echo "error_storage" >"$STATUS_DIR/knots.status"
			log "M.2 still not mounted — refusing node start (B15 persist)"
			exit 1
		fi

		# No RTC battery: before NTP the clock can be the firmware build date —
		# months behind the blocks on the M.2, and bitcoind refuses them as
		# "from the future". Never start the node with the clock behind its data.
		/usr/libexec/knots/clock-floor.sh apply >/dev/null 2>&1 || true

		# Restore Knots/Core choice from M.2 + /etc/knots before first start (B15)
		# write_impl (via reconcile) also refreshes /etc/banner Active: line
		/usr/libexec/knots/node-impl.sh reconcile 2>/dev/null || true

		# R1a — serial MOTD shows appliance build (SD/board identity for bugs)
		if [ -f /etc/banner ] && [ -f /etc/knots/product_version ]; then
			_pv=$(cat /etc/knots/product_version 2>/dev/null | tr -d '\r\n')
			_bn=$(cat /etc/knots/build_number 2>/dev/null | tr -d '\r\n')
			[ -n "$_pv" ] || _pv=unknown
			_bl="$_pv"
			[ -n "$_bn" ] && [ "$_bn" != "unknown" ] && _bl="${_pv} (rev ${_bn})"
			if grep -q '^ Build:' /etc/banner 2>/dev/null; then
				sed -i "s|^ Build:.*| Build:    ${_bl}|" /etc/banner 2>/dev/null || true
			fi
		fi

		if ! lxc-info -n knots >/dev/null 2>&1 || \
		   [ "$(lxc-info -n knots -sH 2>/dev/null)" != "RUNNING" ]; then
			# 9>&- — never leak the lock fd into the container/daemon (see stop path)
			lxc-start -n knots -d 9>&- || {
				echo "error_lxc_start" >"$STATUS_DIR/knots.status"
				log "lxc-start failed"
				exit 1
			}
		fi

		# Ensure LXC veth is on br-dmz (OpenWrt often leaves it orphaned)
		/usr/libexec/knots/lxc-ensure.sh attach-veth || true

		# Start selected implementation (reads reconciled .node-impl)
		echo "starting" >"$STATUS_DIR/knots.status"
		# F32 — refuse empty knots-service (0-byte script exits 0 and never starts bitcoind)
		_ksvc=/srv/lxc/knots/rootfs/usr/local/bin/knots-service
		if [ ! -s "$_ksvc" ]; then
			if [ -s "${_ksvc}.bak" ]; then
				cp "${_ksvc}.bak" "$_ksvc"
				chmod 755 "$_ksvc"
				log "restored empty knots-service from .bak"
			else
				echo "error_lxc" >"$STATUS_DIR/knots.status"
				log "knots-service missing or empty"
				exit 1
			fi
		fi
		lxc-attach -n knots -- /usr/local/bin/knots-service start 9>&- 2>/dev/null || true

		# Wait for RPC — unclean power can make chainstate verify take several minutes
		i=0
		while [ "$i" -lt 180 ]; do
			if rpc_ok; then
				break
			fi
			# re-try veth attach while waiting
			/usr/libexec/knots/lxc-ensure.sh attach-veth || true
			# Surface "recovering" while bitcoind is up but RPC not ready yet
			if pidof bitcoind >/dev/null 2>&1 || \
				lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1; then
				echo "recovering" >"$STATUS_DIR/knots.status"
			fi
			sleep 2
			i=$((i + 1))
		done

		if rpc_ok; then
			COOKIE=$(cut -d: -f2 /mnt/bitcoin/.cookie 2>/dev/null || cut -d: -f2 /mnt/bitcoin/bitcoin/.cookie)
			curl -sS --max-time 5 \
				--user "__cookie__:${COOKIE}" \
				--data-binary '{"jsonrpc":"1.0","id":"c","method":"getblockchaininfo","params":[]}' \
				-H 'content-type: text/plain;' \
				http://21.21.21.21:8332/ >"$STATUS_DIR/blockchain.json" 2>/dev/null || true
			echo "running" >"$STATUS_DIR/knots.status"
			log "bitcoind running"
			/usr/libexec/knots/clock-floor.sh stamp >/dev/null 2>&1 || true
			if [ -n "$_prog_kind" ] && command -v progress_steps_set >/dev/null 2>&1; then
				progress_steps_set "$_prog_kind" init
			fi
			exit 0
		fi

		# B24 — detect "need -reindex-chainstate" instead of opaque error_rpc
		# Guarded source (same M12 pattern as the stop path): a missing ctl lib
		# must not abort before the error status is written.
		# shellcheck disable=SC1091
		. /usr/libexec/knots/bitcoind-ctl.sh 2>/dev/null || true
		# Clock still behind the chain (floor not enough): not a damaged chain.
		# The NTP hotplug (hotplug.d/ntp/95-knots-node) starts the node again
		# as soon as the clock is set.
		if command -v bitcoind_ctl_log_clock_wrong >/dev/null 2>&1 && \
			bitcoind_ctl_log_clock_wrong; then
			echo "waiting_clock" >"$STATUS_DIR/knots.status"
			log "bitcoind: router clock is behind the blocks — waiting for the correct time (NTP)"
			exit 1
		fi
		if command -v bitcoind_ctl_log_needs_reindex >/dev/null 2>&1 && \
			bitcoind_ctl_log_needs_reindex; then
			echo "needs_reindex" >"$STATUS_DIR/knots.status"
			log "bitcoind needs -reindex-chainstate (see debug.log)"
			exit 1
		fi

		echo "error_rpc" >"$STATUS_DIR/knots.status"
		log "bitcoind RPC not ready"
		exit 1
		;;
	status)
		lxc-info -n knots 2>/dev/null || true
		cat "$STATUS_DIR/knots.status" 2>/dev/null || true
		rpc_ok && cat "$STATUS_DIR/blockchain.json" 2>/dev/null || true
		;;
	*)
		echo "Usage: $0 start|stop|status" >&2
		exit 2
		;;
esac
