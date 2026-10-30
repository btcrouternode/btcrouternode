#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Shared bitcoind start/stop/restart for host scripts (TECH_SPEC §7.4.4 / §7.5).
# Reused by external-rpc.sh, settings-api, node reindex (B24).

# shellcheck disable=SC1091
. /usr/libexec/knots/rpc.sh

bitcoind_ctl_log() {
	logger -t bitcoind-ctl "$*"
	echo "bitcoind-ctl: $*" >&2
}

bitcoind_ctl_stop() {
	# Graceful stop (U18) — reused by Settings, conf restart, init.d, reboot wrapper
	lxc-attach -n knots -- /usr/local/bin/knots-service stop 2>/dev/null || true
	i=0
	while bitcoind_ctl_bitcoind_alive; do
		i=$((i + 1))
		if [ "$i" -ge 90 ]; then
			bitcoind_ctl_log "force-killing bitcoind after graceful stop timeout"
			lxc-attach -n knots -- sh -c 'kill -9 $(pidof bitcoind) 2>/dev/null' 2>/dev/null || true
			kill -9 $(pidof bitcoind) 2>/dev/null || true
			sleep 1
			break
		fi
		sleep 1
	done
	lxc-attach -n knots -- /bin/sh -c '
		if [ -f /run/bitcoind.pid ]; then
			old=$(cat /run/bitcoind.pid 2>/dev/null || true)
			if [ -n "$old" ] && ! kill -0 "$old" 2>/dev/null; then
				rm -f /run/bitcoind.pid
			fi
		fi
		pidof bitcoind >/dev/null 2>&1 || rm -f /run/bitcoind.pid /mnt/bitcoin/.lock
	' 2>/dev/null || true
	# Host-visible leftover lock/pid cleanup when container already down
	if ! bitcoind_ctl_bitcoind_alive; then
		rm -f /mnt/bitcoin/.lock 2>/dev/null || true
	fi
}

bitcoind_ctl_start() {
	lxc-attach -n knots -- /usr/local/bin/knots-service start 2>/dev/null || true
}

bitcoind_ctl_wait_rpc() {
	max=${1:-120}
	i=0
	while [ "$i" -lt "$max" ]; do
		if knots_rpc getblockchaininfo '[]' 2>/dev/null | grep -q '"chain"'; then
			return 0
		fi
		sleep 5
		i=$((i + 1))
	done
	return 1
}

bitcoind_ctl_restart() {
	bitcoind_ctl_log "restarting bitcoind"
	bitcoind_ctl_stop
	sleep 1
	bitcoind_ctl_start
	bitcoind_ctl_wait_rpc 120
}

# B24 — rebuild from existing blocks (no re-download).
# $1 = -reindex-chainstate (default) or -reindex (Settings advanced).
bitcoind_ctl_reindex() {
	flag="${1:--reindex-chainstate}"
	case "$flag" in
		-reindex|-reindex-chainstate) ;;
		*) flag="-reindex-chainstate" ;;
	esac
	bitcoind_ctl_log "starting bitcoind $flag"
	mkdir -p /tmp/knots
	bitcoind_ctl_stop
	sleep 1
	: >/tmp/knots/reindex.active
	# C10/B15: one reader (M.2 only when mounted, else /etc backup).
	# shellcheck disable=SC1091
	impl=$(. /usr/libexec/knots/node-impl-lib.sh && read_impl) || impl=core
	case "$impl" in knots) binpref=knots ;; *) binpref=core ;; esac
	lxc-attach -n knots -- /bin/sh -c '
		FLAG="'"$flag"'"
		rm -f /run/bitcoind.pid
		if [ -x /mnt/bitcoin/node-bin/'"$binpref"'/bin/bitcoind ]; then
			/mnt/bitcoin/node-bin/'"$binpref"'/bin/bitcoind \
				-conf=/etc/bitcoin/bitcoin.conf -daemon -pid=/run/bitcoind.pid \
				"$FLAG"
		elif [ -x /mnt/bitcoin/node-bin/knots/bin/bitcoind ]; then
			/mnt/bitcoin/node-bin/knots/bin/bitcoind \
				-conf=/etc/bitcoin/bitcoin.conf -daemon -pid=/run/bitcoind.pid \
				"$FLAG"
		elif [ -x /mnt/bitcoin/node-bin/core/bin/bitcoind ]; then
			/mnt/bitcoin/node-bin/core/bin/bitcoind \
				-conf=/etc/bitcoin/bitcoin.conf -daemon -pid=/run/bitcoind.pid \
				"$FLAG"
		else
			bitcoind -conf=/etc/bitcoin/bitcoin.conf -daemon -pid=/run/bitcoind.pid \
				"$FLAG"
		fi
	' 2>/dev/null || true
	bitcoind_ctl_wait_rpc 36 || true
	pidof bitcoind >/dev/null 2>&1 || \
		lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1
}

bitcoind_ctl_reindex_chainstate() {
	bitcoind_ctl_reindex -reindex-chainstate
}

bitcoind_ctl_log_needs_reindex() {
	log=/mnt/bitcoin/debug.log
	[ -f "$log" ] || return 1
	# A wrong clock is not a damaged chain: bitcoind says "block … from the
	# future … restart with -reindex" when the router's clock is behind
	# (no RTC battery, no internet yet). Never offer a reindex for that.
	bitcoind_ctl_log_clock_wrong && return 1
	tail -n 80 "$log" 2>/dev/null | grep -qE \
		'Error initializing block database|Please restart with -reindex|reindex-chainstate to recover|Corrupted block database'
}

# True if bitcoind's last start stopped because the router's clock is behind
# the blocks on the M.2 (router B on .104–.107: "needs reindex" was this).
bitcoind_ctl_log_clock_wrong() {
	log=/mnt/bitcoin/debug.log
	[ -f "$log" ] || return 1
	_last=$(tail -n 80 "$log" 2>/dev/null | grep -nE 'appears to be from the future|Bitcoin (Core|Knots) version|init message: Loading' | tail -n 1)
	case "$_last" in *"from the future"*) return 0 ;; esac
	return 1
}

# True if host or LXC bitcoind argv includes -reindex / -reindex-chainstate
bitcoind_ctl_has_reindex_flag() {
	pid=$(pidof bitcoind 2>/dev/null | awk '{print $1; exit}')
	if [ -n "$pid" ]; then
		tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | \
			grep -qE -- '-reindex-chainstate|-reindex( |$)' && return 0
	fi
	lxc-attach -n knots -- /bin/sh -c '
		pid=$(pidof bitcoind 2>/dev/null | awk "{print \$1; exit}")
		[ -n "$pid" ] || exit 1
		tr "\0" " " </proc/$pid/cmdline 2>/dev/null | \
			grep -qE -- "-reindex-chainstate|-reindex( |\$)"
	' 2>/dev/null
}

bitcoind_ctl_bitcoind_alive() {
	pidof bitcoind >/dev/null 2>&1 && return 0
	lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1
}

# Reindex still in progress (flag/marker); caller may clear marker when tip caught up
bitcoind_ctl_reindex_running() {
	if bitcoind_ctl_has_reindex_flag; then
		return 0
	fi
	if [ -f /tmp/knots/reindex.active ] && bitcoind_ctl_bitcoind_alive; then
		return 0
	fi
	rm -f /tmp/knots/reindex.active 2>/dev/null || true
	return 1
}

if [ "${0##*/}" = "bitcoind-ctl.sh" ]; then
	case "${1:-}" in
		restart) bitcoind_ctl_restart ;;
		stop) bitcoind_ctl_stop ;;
		start) bitcoind_ctl_start ;;
		wait) bitcoind_ctl_wait_rpc "${2:-120}" ;;
		reindex-chainstate) bitcoind_ctl_reindex_chainstate ;;
		reindex) bitcoind_ctl_reindex -reindex ;;
		*)
			echo "Usage: $0 restart|stop|start|wait|reindex-chainstate|reindex [iters]" >&2
			exit 2
			;;
	esac
fi
